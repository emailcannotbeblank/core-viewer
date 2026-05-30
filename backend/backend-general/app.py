from flask import Flask, request, jsonify, Response
from flask_cors import CORS
import os
import re
import sys
import time
import subprocess
import threading # <--- 新增：引入线程模块

"对齐前留念"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIR = os.path.join(BASE_DIR, 'scripts')
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from format_perf_output import normalize_newlines

app = Flask(__name__)
# 允许所有跨域请求
CORS(app)
app.json.ensure_ascii = False

# ================= 通用 perf 打点脚本 =================
SCRIPT_PATH_STAT = os.path.join(BASE_DIR, 'scripts/perf_e.sh')
LATENCY_SCRIPT_PATH = os.path.join(BASE_DIR, 'scripts/perf_r.sh')
CALLSTACK_SCRIPT_PATH = os.path.join(BASE_DIR, 'scripts/perf_c.sh')
SOURCE_SCRIPT_PATH = os.path.join(BASE_DIR, 'scripts/perf_l.sh')
CONFIGURE_SCRIPT_PATH = os.path.join(BASE_DIR, 'scripts/configure_perf.sh')
RESOLVE_SYMBOL_SCRIPT_PATH = os.path.join(BASE_DIR, 'scripts/resolve_symbol.sh')

def strip_ansi(text):
    if not text:
        return text
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', text)

def format_backend_output(text, mode='auto'):
    return normalize_newlines(strip_ansi(text), mode)

def configure_perf_scripts():
    if not os.path.exists(CONFIGURE_SCRIPT_PATH):
        print(f"[WARN] 找不到 perf 配置脚本: {CONFIGURE_SCRIPT_PATH}")
        return
    result = subprocess.run(
        [CONFIGURE_SCRIPT_PATH],
        capture_output=True,
        text=True,
        check=False
    )
    if result.stdout:
        print(strip_ansi(result.stdout).strip())
    if result.returncode != 0:
        if result.stderr:
            print(strip_ansi(result.stderr).strip())
        raise RuntimeError("perf 脚本配置失败，请检查 config.json")

def build_probe_point(target_func, offset):
    offset = str(offset)
    if offset.startswith('%'):
        return f"{target_func}{offset}"
    return f"{target_func}:{offset}"

def resolve_symbol_name(target_func):
    if not os.path.exists(RESOLVE_SYMBOL_SCRIPT_PATH):
        raise RuntimeError(f"找不到符号解析脚本: {RESOLVE_SYMBOL_SCRIPT_PATH}")
    result = subprocess.run(
        [RESOLVE_SYMBOL_SCRIPT_PATH, str(target_func)],
        capture_output=True,
        text=True,
        check=False
    )
    if result.returncode != 0:
        error = strip_ansi(result.stderr or result.stdout).strip()
        raise RuntimeError(error or f"符号解析失败: {target_func}")
    resolved = strip_ansi(result.stdout).strip().splitlines()
    if not resolved:
        raise RuntimeError(f"符号解析无输出: {target_func}")
    return resolved[-1].strip()

trigger_event = threading.Event()
trigger_done_event = threading.Event()
trigger_task = {"armed": False, "cmd": "", "delay": 0, "output": ""}

configure_perf_scripts()


@app.route('/api/analyze_stream', methods=['POST'])
def run_trace_stream():
    global trigger_task  # <--- 引入全局触发器记事本
    data = request.get_json(force=True, silent=True) or {}
    target_func = data.get('target_func')
    sleep_time = data.get('sleep_time', 5)
    callstack_filter = data.get('callstack_filter') or data.get('caller_funcs') or ''

    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名"}), 400
    try:
        resolved_func = resolve_symbol_name(target_func)
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 400

    current_script = SCRIPT_PATH_STAT

    if not os.path.exists(current_script):
         return jsonify({"success": False, "error": f"找不到脚本文件: {current_script}"}), 500

    def generate():
        try:
            # ================= 阶段一：Setup (打探针) =================
            # 无论是哪个脚本，setup 的传参方式都是一致的
            setup_cmd = ['sudo', current_script, 'setup', str(resolved_func)]
            yield "正在使用 [perf_e] 模式分析执行次数...\n"
            if resolved_func != target_func:
                yield f"符号解析: {target_func} -> {resolved_func}\n"
            print("执行:", " ".join(setup_cmd))
            process1 = subprocess.Popen(setup_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True)
            for line in iter(process1.stdout.readline, ''):
                yield format_backend_output(line, 'log')
            process1.wait()

            if process1.returncode != 0:
                yield "❌ 探针初始化失败，流程中止。\n"
                return

            # ================= 阶段二：触发器逻辑 =================
            if trigger_task['armed']:
                delay = trigger_task['delay']
                cmd = trigger_task['cmd']
                
                yield f"\n🔔 检测到已预设的触发任务！将立即执行命令，随后休眠 {delay} 秒进行录制...\n"
                trigger_event.set() # 唤醒前端等待的 trigger 接口

                # 1. 执行终端命令
                if cmd and global_shell:
                    yield f"🚀 后台正在执行触发命令: {cmd}\n"
                    raw_out = global_shell.run(cmd, timeout=30)
                    trigger_task['output'] = clean_ansi(raw_out)
                elif cmd:
                    yield f"🚀 后台正在执行触发命令: {cmd}\n"
                    proc = subprocess.run(cmd, shell=True, capture_output=True, text=True)
                    trigger_task['output'] = strip_ansi(proc.stdout)
                else:
                    trigger_task['output'] = "(无命令执行)"
                
                # 2. 命令执行完毕，放行前端触发器接口，立刻显示结果
                trigger_done_event.set() 
                
                # 3. 再进行休眠
                if delay > 0:
                    yield f"⏳ 命令已执行完毕。开始休眠 {delay} 秒，等待环境发酵...\n"
                    time.sleep(delay)
                
                # 任务完成，卸载触发器
                trigger_task['armed'] = False

            # ================= 阶段三：Stat (录制与分析) =================
            record_cmd = ['sudo', current_script, 'stat', str(resolved_func), str(sleep_time)]
            if callstack_filter:
                record_cmd.append(str(callstack_filter))
            yield f"\n开始执行分析命令: {' '.join(record_cmd)}\n"
            
            process2 = subprocess.Popen(record_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True)
            for line in iter(process2.stdout.readline, ''):
                yield format_backend_output(line, 'stat')
            process2.wait() 

        except Exception as e:
            yield f"\n[Python 后端错误] {str(e)}\n"

    return Response(generate(), mimetype='text/plain')


@app.route('/api/get_source', methods=['POST'])
def get_source():
    data = request.get_json(force=True, silent=True) or {}
    target_func = data.get('target_func')
    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名"}), 400
    try:
        resolved_func = resolve_symbol_name(target_func)
        # 修改为调用 perf_l.sh
        cmd = ['sudo', SOURCE_SCRIPT_PATH, str(resolved_func)]
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        clean_output = format_backend_output(result.stdout, 'source')
        clean_error = format_backend_output(result.stderr, 'log')
        return jsonify({"success": result.returncode == 0, "output": clean_output, "error": clean_error})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500


# ========================================================
# 💥 核心修复区：触发器和测速的协同
# ========================================================

@app.route('/api/analyze_latency_stream', methods=['POST'])
def run_latency_stream():
    global trigger_task
    data = request.get_json(force=True, silent=True) or {}
    target_func = data.get('target_func')
    start_offset = data.get('start_offset')
    end_offset = data.get('end_offset')
    sleep_time = data.get('sleep_time', 5)
    callstack_filter = data.get('callstack_filter') or data.get('caller_funcs') or ''

    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名"}), 400
    try:
        resolved_func = resolve_symbol_name(target_func)
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 400

    probe1 = build_probe_point(resolved_func, start_offset)
    probe2 = build_probe_point(resolved_func, end_offset)
    
    def generate():
        try:
            # 阶段一：Setup
            setup_cmd = ['sudo', LATENCY_SCRIPT_PATH, 'setup', probe1, probe2]
            cmd_print = " ".join(setup_cmd)
            print(f"[RUN CMD] {cmd_print}")
            if resolved_func != target_func:
                yield f"符号解析: {target_func} -> {resolved_func}\n"
            process1 = subprocess.Popen(setup_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(process1.stdout.readline, ''):
                yield format_backend_output(line, 'log')
            process1.wait()

            if process1.returncode != 0:
                yield "❌ 探针初始化失败，流程中止。\n"
                return

            # =======================================================
            # 💥 修改的阶段二：先执行命令 -> 传回前端 -> 再休眠 -> 然后录制
            # =======================================================
            if trigger_task['armed']:
                delay = trigger_task['delay']
                cmd = trigger_task['cmd']
                
                yield f"\n🔔 检测到已预设的触发任务！将立即执行命令，随后休眠 {delay} 秒进行录制...\n"
                trigger_event.set() # 唤醒前端等待的 trigger 接口（确认收到任务）

                # 1. 先执行命令
                if cmd and global_shell:
                    yield f"🚀 后台正在执行触发命令: {cmd}\n"
                    raw_out = global_shell.run(cmd, timeout=30)
                    trigger_task['output'] = clean_ansi(raw_out)
                elif cmd:
                    yield f"🚀 后台正在执行触发命令: {cmd}\n"
                    proc = subprocess.run(cmd, shell=True, capture_output=True, text=True)
                    trigger_task['output'] = strip_ansi(proc.stdout)
                else:
                    trigger_task['output'] = "(无命令执行)"
                
                # 2. 命令执行完毕，立刻放行前端触发器接口，让终端页面马上显示出结果！
                trigger_done_event.set() 
                
                # 3. 再进行休眠
                if delay > 0:
                    yield f"⏳ 命令已执行完毕。开始休眠 {delay} 秒，等待环境发酵...\n"
                    time.sleep(delay)
                
                # 任务完成，卸载触发器
                trigger_task['armed'] = False

            # 阶段三：Record
            record_cmd = ['sudo', LATENCY_SCRIPT_PATH, 'record', probe1, probe2, str(sleep_time)]
            if callstack_filter:
                record_cmd.append(str(callstack_filter))
            print(f"[RUN CMD] {' '.join(record_cmd)}")
            yield f"\n开始录制命令: {' '.join(record_cmd)}\n"
            
            process2 = subprocess.Popen(record_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(process2.stdout.readline, ''):
                yield format_backend_output(line, 'log')
            process2.wait()
            if process2.returncode != 0:
                yield "❌ 时延录制失败。\n"

        except Exception as e:
            yield f"\n[Python 错误] {str(e)}\n"

    return Response(generate(), mimetype='text/plain')


@app.route('/api/analyze_callstack_stream', methods=['POST'])
def run_callstack_stream():
    data = request.get_json(force=True, silent=True) or {}
    target_func = data.get('target_func')
    caller_funcs = data.get('caller_funcs', '*')
    sleep_time = data.get('sleep_time', 5)
    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名"}), 400
    try:
        resolved_func = resolve_symbol_name(target_func)
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 400
    cmd = ['sudo', CALLSTACK_SCRIPT_PATH, resolved_func, str(sleep_time), str(caller_funcs)]
    def generate():
        try:
            if resolved_func != target_func:
                yield f"符号解析: {target_func} -> {resolved_func}\n"
            process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True)
            for line in iter(process.stdout.readline, ''):
                yield format_backend_output(line, 'log')
            process.wait()
            if process.returncode != 0:
                yield "调用栈分析失败。\n"
        except Exception as e:
            yield f"\n[Python 错误] {str(e)}\n"
    return Response(generate(), mimetype='text/plain')


#############  新建窗口 #############
# try:
#     from sheller3 import ShellSession
#     from sheller3 import clean_ansi, clean_output
# except ImportError:
#     ShellSession = None
#     def clean_ansi(text): return strip_ansi(text)
#     def clean_output(text): return text

from sheller3 import ShellSession
from sheller3 import clean_ansi, clean_output


global_shell = None

@app.route('/api/trigger', methods=['POST'])
def arm_trigger():
    global trigger_task
    data = request.get_json(force=True, silent=True) or {}
    trigger_task['cmd'] = data.get('command', '')
    trigger_task['delay'] = float(data.get('delay', 0))
    trigger_task['armed'] = True
    trigger_task['output'] = ""
    
    trigger_event.clear()
    trigger_done_event.clear()

    # 💥 挂起请求，最长等待 5 分钟
    picked_up = trigger_event.wait(timeout=300)
    if not picked_up:
        trigger_task['armed'] = False
        return jsonify({"success": False, "error": "等待超时（5分钟内未启动时长分析）"})

    # 等待命令执行并拿回输出
    trigger_done_event.wait()
    return jsonify({"success": True, "output": trigger_task['output']})


@app.route('/api/shell/init', methods=['POST'])
def init_shell():
    global global_shell
    try:
        if global_shell is None and ShellSession is not None:
            global_shell = ShellSession("WebShell")
        return jsonify({"success": True, "msg": "Shell 已经就绪"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/shell/exec', methods=['POST'])
def exec_shell():
    global global_shell
    if global_shell is None:
        return jsonify({"success": False, "error": "Shell 未初始化，请先刷新页面重新连接"})

    data = request.get_json(force=True, silent=True) or {}
    cmd = data.get('command', '').strip()
    if not cmd:
        return jsonify({"success": True, "output": ""})

    try:
        raw_output = global_shell.run(cmd, timeout=30)
        clean_out = clean_ansi(raw_output)
        return jsonify({"success": True, "output": clean_out})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/shell/close', methods=['POST'])
def close_shell():
    global global_shell
    if global_shell:
        global_shell.close()
        global_shell = None
    return jsonify({"success": True})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True, debug=True)
