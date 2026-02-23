from flask import Flask, request, jsonify, Response
from flask_cors import CORS
import subprocess
import os
import re

app = Flask(__name__)
CORS(app)
app.json.ensure_ascii = False

SCRIPT_PATH = "./scripts/trace_line_hits.sh"

def strip_ansi(text):
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', text)

@app.route('/api/analyze_stream', methods=['POST'])
def run_trace_stream():
    data = request.json
    if not data:
        return jsonify({"success": False, "error": "请求体必须是 JSON"}), 400

    target_func = data.get('target_func')
    caller_funcs = data.get('caller_funcs', '*')
    if not caller_funcs:
        caller_funcs = '*'
    sleep_time = data.get('sleep_time', 5)

    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名"}), 400

    if not os.path.exists(SCRIPT_PATH):
         return jsonify({"success": False, "error": f"找不到脚本文件: {SCRIPT_PATH}"}), 500

    cmd = ['sudo', SCRIPT_PATH, str(target_func), str(caller_funcs), str(sleep_time)]

    # 核心改造：创建一个生成器函数，实时读取脚本的 stdout 并推送给前端
    def generate():
        try:
            # 使用 Popen 启动进程，结合 stdout=PIPE 捕获输出
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, # 将错误输出也合并到标准输出一起显示
                text=True,
                bufsize=1, # 行缓冲，确保只要有一行输出就立刻刷出
                universal_newlines=True
            )

            # 只要进程还在跑，就持续读取每一行
            for line in iter(process.stdout.readline, ''):
                clean_line = strip_ansi(line) # 清洗颜色乱码
                yield clean_line              # 将这一行推给前端

            process.stdout.close()
            process.wait() # 等待进程完全结束

        except Exception as e:
            yield f"\n[Python 后端错误] {str(e)}\n"

    # 使用 Response 返回流式数据，mimetype 设置为 plain text
    return Response(generate(), mimetype='text/plain')


@app.route('/api/get_source', methods=['POST'])
def get_source():
    data = request.json
    target_func = data.get('target_func')

    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名"}), 400

    try:
        # 极速运行：只拉取代码，不打探针不抓数据
        cmd = ['sudo', 'perf', 'probe', '-L', str(target_func)]
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        # 清理颜色乱码 (复用你代码里的 strip_ansi)
        clean_output = strip_ansi(result.stdout)
        clean_error = strip_ansi(result.stderr)

        return jsonify({
            "success": result.returncode == 0,
            "output": clean_output,
            "error": clean_error
        })
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500


LATENCY_SCRIPT_PATH = "./scripts/latency_multi_stack_and.sh"

@app.route('/api/analyze_latency_stream', methods=['POST'])
def run_latency_stream():
    data = request.json
    target_func = data.get('target_func')
    start_offset = data.get('start_offset')
    end_offset = data.get('end_offset')
    caller_funcs = data.get('caller_funcs', '*')

    # 将传递来的参数构造成 bash 需要的探针参数
    probe1 = f"probe1={target_func}:{start_offset}"
    probe2 = f"probe2={target_func}:{end_offset}"
    
    cmd = ['sudo', LATENCY_SCRIPT_PATH, probe1, probe2, str(caller_funcs)]

    def generate():
        try:
            process = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, 
                text=True, bufsize=1, universal_newlines=True
            )
            for line in iter(process.stdout.readline, ''):
                yield strip_ansi(line)
            process.stdout.close()
            process.wait()
        except Exception as e:
            yield f"\n[Python 错误] {str(e)}\n"

    return Response(generate(), mimetype='text/plain')


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)