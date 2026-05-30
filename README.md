# Core Viewer

Core Viewer 是一个基于 `perf probe` 的代码观测工具，包含 Vue 前端和 Flask 后端。它可以针对内核函数或用户态 ELF 二进制函数查看源码行、统计行级命中次数、测量两处 probe 之间的时延，并按调用栈过滤统计结果。

## 目录结构

```text
core-viewer/
├── frontend/code-viewer/          # Vue + Vite 前端
└── backend/
    ├── backend-general/           # 当前通用后端，推荐使用
    ├── backend-go/                # Go 项目专用旧后端/参考实现
    ├── backend-rust/              # Rust 项目旧后端
    └── backend-kernel/            # 内核实验旧后端
```

当前主要维护的是：

```text
backend/backend-general
frontend/code-viewer
```

## 后端准备

后端依赖系统工具：

```bash
sudo apt install linux-tools-common linux-tools-generic jq binutils python3 python3-pip
```

Python 依赖：

```bash
pip3 install flask flask-cors
```

如果分析用户态二进制，目标二进制需要包含符号和调试信息。Rust debug 构建通常可用；release 构建建议带上 debuginfo。

## 后端配置

编辑：

```bash
backend/backend-general/config.json
```

用户态二进制示例：

```json
{
  "target_type": "user",
  "binary_path": "/path/to/binary",
  "source_dir": "/path/to/source/root",
  "project_name": "my-project-debug",
  "settings": {
    "use_sudo": true,
    "call_graph": "fp"
  },
  "symbol_resolution": {
    "find_func_script": "find_func.py",
    "default_hints": ["src"],
    "func_hints": {
      "process_virtio_queues": ["virtio/net/device.rs"],
      "new": ["src/vmm/src/device_manager/mmio.rs"]
    }
  }
}
```

内核函数示例：

```json
{
  "target_type": "kernel",
  "source_dir": "/path/to/linux/source",
  "project_name": "kernel-probe",
  "settings": {
    "use_sudo": true,
    "call_graph": "fp"
  }
}
```

字段说明：

```text
target_type: user 或 kernel
binary_path: 用户态 ELF 二进制路径，kernel 模式不需要
source_dir: 源码根目录，用于 perf probe -s
call_graph: perf record 调用栈模式，常用 fp 或 dwarf
symbol_resolution.default_hints: 同名函数默认匹配提示
symbol_resolution.func_hints: 按函数名定制匹配提示
```

## 后端启动

进入通用后端目录：

```bash
cd backend/backend-general
python3 app.py
```

默认监听：

```text
0.0.0.0:5000
```

后端启动时会自动执行：

```bash
scripts/configure_perf.sh
```

它会根据 `config.json` 把 `perf_l.sh`、`perf_e.sh`、`perf_r.sh`、`perf_c.sh` 中的 `PERF_PROBE_CMD` 配置成正确的 `perf probe` 命令。

## 前端启动

进入前端目录：

```bash
cd frontend/code-viewer
npm install
npm run dev
```

Vite 会输出访问地址，通常是：

```text
http://localhost:5173
```

打开前端后，在左侧填写后端地址，例如：

```text
127.0.0.1:5000
```

如果前后端不在同一台机器，填写后端机器的 IP 和端口。

## 前端用法

左侧通用输入：

```text
函数名: 要分析的函数名，可以填简单名，如 main_exec
调用栈过滤: 可选，留空或 * 表示不过滤
服务器 IP: 后端地址
采样秒数: perf stat/record 的采样时间
```

### 代码分析

代码分析页支持：

```text
拉取代码: 调用 /api/get_source，显示函数源码行
运行分析: 调用 /api/analyze_stream，对函数内源码行批量打 probe 并统计命中次数
时延测试: 在源码视图中选择起点/终点行，调用 /api/analyze_latency_stream
```

### 调用栈分析

调用：

```text
/api/analyze_callstack_stream
```

后端会在目标函数入口打 probe，使用 `perf record -g` 采样，并聚合不同调用栈。

### 服务器交互

服务器交互页提供一个后端 shell 会话：

```text
普通执行: 直接运行命令
延时执行: 前端延迟若干秒后执行命令
预设触发器: 先挂起命令，等代码分析或时延分析完成 probe setup 后自动执行
```

预设触发器适合这种流程：

```text
1. 在服务器交互页输入触发业务行为的命令
2. 点击预设触发器
3. 切回代码分析页运行命中统计或时延测试
4. 后端完成 probe setup 后自动执行命令并开始采样
```

## 符号解析

Rust/Go/C++ 等语言可能存在大量同名函数，前端可以只填写简单名，后端会调用：

```bash
backend/backend-general/scripts/resolve_symbol.sh
backend/backend-general/find_func.py
```

解析流程：

```text
1. 使用 nm 获取 ELF 真实符号和 demangle 后的函数名
2. 使用 addr2line 获取候选函数对应源码路径
3. 根据 config.json 中的 hints 选择最接近的函数
4. 返回 perf probe 可用的真实符号名
```

例如 Firecracker 中 `process_virtio_queues` 有多个同名候选，可以这样配置：

```json
{
  "symbol_resolution": {
    "func_hints": {
      "process_virtio_queues": ["virtio/net/device.rs"]
    }
  }
}
```

调试符号解析：

```bash
cd backend/backend-general
scripts/resolve_symbol.sh process_virtio_queues
python3 find_func.py -c config.json -f process_virtio_queues -l '["virtio/net/device.rs"]'
```

## 后端 API

```text
POST /api/get_source
  body: { "target_func": "main_exec" }

POST /api/analyze_stream
  body: { "target_func": "main_exec", "sleep_time": 5, "caller_funcs": "*" }

POST /api/analyze_latency_stream
  body: {
    "target_func": "main_exec",
    "start_offset": 0,
    "end_offset": 20,
    "sleep_time": 5,
    "caller_funcs": "*"
  }

POST /api/analyze_callstack_stream
  body: { "target_func": "main_exec", "sleep_time": 5, "caller_funcs": "*" }

POST /api/trigger
  body: { "command": "curl ...", "delay": 3 }

POST /api/shell/init
POST /api/shell/exec
POST /api/shell/close
```

## 常见问题

### perf probe 提示函数找不到

检查目标二进制是否有符号和 DWARF 调试信息：

```bash
file /path/to/binary
readelf -S /path/to/binary | grep -E 'debug_info|debug_line|symtab'
```

### Rust 函数名带 `::` 导致 perf 解析错误

不要直接把 `firecracker::main_exec` 传给 `perf probe -L`。通用后端会先解析为 `_ZN...` 真实符号，再传给 perf。

### perf 事件名过长

脚本内部会把 probe event 名压缩成短 hash，例如：

```text
l_d44253879183_0
c_d44253879183
```

目标函数名可以很长，event 名不会超过 perf 限制。

### 权限问题

perf probe、perf stat、perf record 通常需要 root 权限。后端脚本默认通过 `sudo` 调用。如果出现权限错误，先确认当前用户可以执行 sudo，并检查：

```bash
sudo perf probe --list
```

### 用户态程序没有命中

确认采样期间目标进程确实执行了该函数。可以使用服务器交互页的预设触发器，在 probe setup 后自动触发业务请求。
