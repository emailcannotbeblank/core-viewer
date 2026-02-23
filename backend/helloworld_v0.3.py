from flask import Flask, request, jsonify
from flask_cors import CORS
import subprocess
import os
import re

app = Flask(__name__)
CORS(app)
app.json.ensure_ascii = False

# 根据你的实际目录调整路径
SCRIPT_PATH = "./scripts/trace_line_hits.sh"

# 清除 Bash 终端颜色控制字符的正则函数
def strip_ansi(text):
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', text)

@app.route('/api/analyze', methods=['POST'])
def run_trace():
    data = request.json
    if not data:
        return jsonify({"success": False, "error": "请求体必须是 JSON"}), 400

    target_func = data.get('target_func')
    caller_funcs = data.get('caller_funcs', '*')
    if not caller_funcs:
        caller_funcs = '*'
    sleep_time = data.get('sleep_time', 5)

    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名 (target_func)"}), 400

    if not os.path.exists(SCRIPT_PATH):
         return jsonify({"success": False, "error": f"找不到脚本文件: {SCRIPT_PATH}"}), 500

    try:
        print(f"🚀 开始执行: {target_func}, 调用栈: {caller_funcs}, 时间: {sleep_time}s")
        
        cmd = ['sudo', SCRIPT_PATH, str(target_func), str(caller_funcs), str(sleep_time)]
        result = subprocess.run(
            cmd, 
            capture_output=True, 
            text=True, 
            check=False 
        )
        
        # 将输出中的终端颜色符号清洗掉再返回给前端
        clean_output = strip_ansi(result.stdout)
        clean_error = strip_ansi(result.stderr)

        return jsonify({
            "success": result.returncode == 0,
            "output": clean_output,
            "error": clean_error,
            "returncode": result.returncode
        })

    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)