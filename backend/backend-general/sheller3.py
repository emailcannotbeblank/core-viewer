import os
import sys
import select
import pty
import subprocess
import time
import re


def clean_output(ret):
    if not ret:
        return ""
    ret = ret.replace('\u241b', '\x1b')
    # 1. 移除所有 ANSI 转义序列（颜色、标题、坐标等）
    ansi_escape = re.compile(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|[@-Z\\-_])')
    ret = ansi_escape.sub('', ret)
    
    # 2. 移除常见的提示符行（匹配类似 root@hostname:path# 的模式）
    # 这里用正则匹配最后一行如果是以 # 或 $ 结尾的提示符行，直接干掉
    lines = ret.splitlines()
    if lines and (lines[-1].strip().endswith('#') or lines[-1].strip().endswith('$') or '@' in lines[-1]):
        lines = lines[:-1]
        
    return "\n".join(lines).strip()

# def clean_output(text):
#     """
#     清洗 shell 输出：
#     1. 移除 ANSI 转义序列 (如 \x1b[?2004l, \x1b[m 等)
#     2. 移除回车符 \r
#     3. 移除标记位 READY_CONFIRM_MARKER
#     """
#     if not text:
#         return ""
#     # 移除 ANSI 转义序列
#     ansi_escape = re.compile(r'\x1b\[[0-9;?]*[a-zA-Z]')
#     text = ansi_escape.sub('', text)
#     # 移除 READY_CONFIRM_MARKER
#     text = text.replace("READY_CONFIRM_MARKER", "")
#     # 移除回车符，统一换行
#     text = text.replace('\r', '')
#     return text.strip()

def clean_ansi(text):
    """辅助函数：去除 Shell 的 ANSI 转义码（颜色、标题等）"""
    if not text: return ""
    text = text.replace('\u241b', '\x1b')
    ansi_escape = re.compile(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|[@-Z\\-_])')
    return ansi_escape.sub('', text).replace('\r', '').strip()

class ShellSession:
    def __init__(self, name="MainSession", args=['/bin/bash']):
        self.name = name
        self.master_fd, self.slave_fd = pty.openpty()
        # 使用一个非常独特的标记
        self.end_marker = "READY_CONFIRM_MARKER "
        
        self.process = subprocess.Popen(
            args, 
            stdin=self.slave_fd, 
            stdout=self.slave_fd, 
            stderr=self.slave_fd,
            preexec_fn=os.setsid,
            close_fds=True
        )
        os.close(self.slave_fd)
        print(f"[{self.name}] 宿主机会话启动 (PID: {self.process.pid})")
        self._setup_environment()

    def _setup_environment(self):
        """核心逻辑：强制接管当前 Shell 环境"""
        # 1. 给一点缓冲时间
        time.sleep(0.5)
        
        # 2. 清理之前的残余输出
        self._flush()

        # 3. 关闭回显（极其重要，否则脚本会把输入的命令当成输出读取）
        os.write(self.master_fd, b"stty -echo\n")
        time.sleep(0.2)

        # 关闭 bash bracketed paste，避免输出 \x1b[?2004l / \x1b[?2004h。
        os.write(self.master_fd, b"bind 'set enable-bracketed-paste off' 2>/dev/null\n")
        os.write(self.master_fd, b"printf '\\033[?2004l'\n")
        time.sleep(0.1)
        
        # 4. 强制设置 PS1。注意：有些 shell 需要 --norc 启动，
        # 否则 PS1 会被不断覆盖。这里我们暴力设置。
        # \r\n 是为了清除行首干扰
        cmd = f"\r\nexport PS1='{self.end_marker}'\n"
        os.write(self.master_fd, cmd.encode())
        
        # 5. 验证是否设置成功
        if self.read_until_marker(timeout=5.0, print_output=False) is not None:
            print(f"[{self.name}] 环境同步成功: 当前处于 {self._get_current_identity()}")
            return True
        else:
            print(f"[{self.name}] 警告：环境同步超时，尝试盲发命令...")
            return False

    def _get_current_identity(self):
        """辅助函数：查看当前在哪"""
        os.write(self.master_fd, b"hostname\n")
        return self.read_until_marker(timeout=2.0, print_output=False)

    def _flush(self):
        """清空缓冲区"""
        while True:
            r, _, _ = select.select([self.master_fd], [], [], 0.1)
            if r:
                os.read(self.master_fd, 10240)
            else:
                break

    def write_raw(self, cmd):
        if not cmd.endswith("\n"):
            cmd += "\n"
        os.write(self.master_fd, cmd.encode())

    def read_until_marker(self, timeout=15.0, print_output=True):
        output_buffer = ""
        start_time = time.time()
        
        while True:
            if time.time() - start_time > timeout:
                return None

            r, _, _ = select.select([self.master_fd], [], [], 0.1)
            if self.master_fd in r:
                try:
                    data = os.read(self.master_fd, 10240)
                    if not data: break
                    
                    text = data.decode('utf-8', errors='ignore')
                    if print_output:
                        sys.stdout.write(text)
                        sys.stdout.flush()
                    
                    output_buffer += text
                    
                    if self.end_marker in output_buffer:
                        # 找到标记，返回标记之前的内容
                        return output_buffer.split(self.end_marker)[0].strip()
                except OSError:
                    break
        return None



    # def read_until_marker(self, timeout=15.0, print_output=True):
    #     output_buffer = ""
    #     start_time = time.time()
        
    #     while True:
    #         # 1. 检查总超时
    #         if time.time() - start_time > timeout:
    #             return None

    #         # 2. 降低 select 等待时间，提高灵敏度
    #         # 将 0.1 改为 0.01，让 Python 更快地去读取串口数据
    #         r, _, _ = select.select([self.master_fd], [], [], 0.01)
            
    #         if self.master_fd in r:
    #             try:
    #                 # 3. 增大单次读取量
    #                 data = os.read(self.master_fd, 16384)
    #                 if not data: break
                    
    #                 text = data.decode('utf-8', errors='ignore')
                    
    #                 if print_output:
    #                     sys.stdout.write(text)
    #                     sys.stdout.flush()
                    
    #                 output_buffer += text
                    
    #                 # 4. 核心优化：一旦发现标记，立即停止，不要等缓冲区填满
    #                 if self.end_marker in output_buffer:
    #                     # 延迟一丁点时间确保后续字符读完（可选）
    #                     # time.sleep(0.01) 
    #                     return output_buffer.split(self.end_marker)[0].strip()
                        
    #             except OSError:
    #                 break
    #         else:
    #             # 如果没有数据，且已经读到了 marker (可能在上一轮读到了)
    #             # 这种双重检查能极大减少“卡顿感”
    #             if self.end_marker in output_buffer:
    #                 return output_buffer.split(self.end_marker)[0].strip()
    #     return None

    def run1(self, cmd, timeout=15.0, print_output = True):
        """执行普通命令"""
        # 执行前清理一次，防止由于上个命令没读完导致的标记错乱
        self.write_raw(cmd)
        res = self.read_until_marker(timeout=timeout, print_output = print_output)
        if res is None:
            print(f"\n[Warning] 命令超时: {cmd}")
            # 超时后尝试重新同步环境，防止后续命令全部连带超时
            self._setup_environment()
        return res

    def run(self, cmd, timeout=15.0, print_output = False):
        """执行普通命令"""
        
        # [修复] 1. 核心修复：发送命令前，必须把上一次留下的“垃圾”读干净！
        self._flush() 
        
        # 2. 发送命令
        self.write_raw(cmd)
        
        # 3. 读取直到出现标记
        res = self.read_until_marker(timeout=timeout, print_output = print_output)
        
        if res is None:
            print(f"\n[Warning] 命令超时: {cmd}")
            self._setup_environment()
            return "" # 建议超时返回空字符串而不是 None，防止后续 split 报错
            
        # [优化] 4. 建议在这里过滤掉 ANSI 乱码，让返回结果更纯净
        return res
        # return self._clean_ansi(res)

    
    
    
    
    
    

    def enter_context(self, cmd):
        """
        专门用于进入新层级：
        1. 进 Docker: session.enter_context("docker exec ...")
        2. 进 VM: session.enter_context("connect_to_vm_script")
        """
        print(f"\n>>> 切换层级中: {cmd}")
        self.write_raw(cmd)
        
        # 关键：给进入过程留出时间（例如 SSH 握手或容器启动）
        time.sleep(1.5)
        
        # 重新初始化该层的 PS1
        self._setup_environment()

    def close(self):
        self.process.terminate()
        os.close(self.master_fd)
        print(f"\n[{self.name}] 会话已关闭")

# --- 你的业务逻辑 ---
if __name__ == "__main__":
    # 初始化是在宿主机
    shell = ShellSession("MultiLevelShell")

    # 第一层：从宿主机进入 Docker
    # 替换成你的 docker 名字
    shell.enter_context("docker exec -it my2g /bin/bash")

    # 第二层：从 Docker 进入 Firecracker VM
    # 替换成你实际进入 VM 的命令（例如 screen -r 或 串口连接命令）
    # 假设你的命令是 ./entry_vm.sh
    print(">>> 正在从 Docker 进入 Firecracker VM...")
    shell.enter_context("screen -r firecracker") # 举例，换成你进 VM 的真实命令

    # 在 VM 内部执行你的 python 脚本
    print(">>> 开始在 VM 运行测试...")
    output = shell.run("python3 zry_test/image_processing.py", timeout=30)
    
    print(f"\n脚本执行结果: {output}")

    shell.close()
