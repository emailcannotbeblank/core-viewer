from flask import Flask, request, jsonify
from flask_cors import CORS
import subprocess
import os

app = Flask(__name__)
# 允许跨域请求，方便 Vue 前端调用
CORS(app)
app.json.ensure_ascii = False

# 假设你的 sh 脚本和 app.py 在同一个目录下
SCRIPT_PATH = "./scripts/trace_line_hits.sh"

@app.route('/api/trace', methods=['POST'])
def run_trace():
    # 1. 解析前端传来的 JSON 参数
    data = request.json
    if not data:
        return jsonify({"success": False, "error": "请求体必须是 JSON"}), 400

    target_func = data.get('target_func')
    caller_funcs = data.get('caller_funcs', '*')  # 默认不限制调用栈
    sleep_time = data.get('sleep_time', 5)        # 默认采样 5 秒

    if not target_func:
        return jsonify({"success": False, "error": "缺少目标函数名 (target_func)"}), 400

    # 2. 检查脚本是否存在并有执行权限
    if not os.path.exists(SCRIPT_PATH):
         return jsonify({"success": False, "error": f"找不到脚本文件: {SCRIPT_PATH}"}), 500

    try:
        print(f"🚀 开始执行: {target_func}, 调用栈: {caller_funcs}, 时间: {sleep_time}s")
        
        # 3. 构造命令 (严禁使用 shell=True，防止命令注入)
        # subprocess.run 以列表形式传参，可以完美处理 caller_funcs 中的空格
        cmd = ['sudo', SCRIPT_PATH, str(target_func), str(caller_funcs), str(sleep_time)]
        
        # 运行脚本并捕获输出
        result = subprocess.run(
            cmd, 
            capture_output=True, 
            text=True, 
            check=False # 如果脚本 exit 1，不会抛出异常，而是记录 returncode
        )
        
        # 4. 将结果返回给前端
        return jsonify({
            "success": result.returncode == 0,
            "output": result.stdout,    # 标准输出 (统计结果)
            "error": result.stderr,     # 错误信息 (如果有)
            "returncode": result.returncode
        })

    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

if __name__ == '__main__':
    # 启动 Flask 服务，监听 5000 端口
    app.run(host='0.0.0.0', port=5000, debug=True)