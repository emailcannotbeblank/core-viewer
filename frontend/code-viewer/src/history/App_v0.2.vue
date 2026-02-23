<script setup>
import { ref } from 'vue'
import axios from 'axios' // 引入 axios

// --- 状态定义 ---
const currentTab = ref(1)
const formData = ref({
  functionName: '',
  callStack: ''
})
const outputLog = ref('')
const isLoading = ref(false) // 增加一个加载状态锁，防止重复点击

// --- 切换 Tab ---
const selectTab = (idx) => currentTab.value = idx

// --- 清空 ---
const handleClear = () => {
  formData.value.functionName = ''
  formData.value.callStack = ''
  outputLog.value = ''
}

// --- 核心逻辑：发送请求 ---
const handleAnalyze = async () => {
  // 1. 校验输入
  if (!formData.value.functionName) {
    alert('错误：请输入函数名 (Function Name)')
    return
  }
  if (isLoading.value) return // 如果正在分析，点击无效

  // 2. 准备 UI 状态
  isLoading.value = true
  const startTime = new Date()
  outputLog.value = `[${startTime.toLocaleTimeString()}] 正在连接后端服务器...\n----------------------------------\n`
  
  try {
    // 3. 准备发送给 Python 的数据
    // 这里的 key (如 function_name) 要和 Python 后端接收的变量名一致
    const payload = {
      type: currentTab.value === 1 ? 'path' : 'duration', // 告诉后端是哪种分析
      function_name: formData.value.functionName,
      call_stack: formData.value.callStack
    }

    // 4. 发送 POST 请求 (假设后端在 8000 端口)
    // 注意：如果你部署在服务器，把 127.0.0.1 换成服务器 IP
    const res = await axios.post('http://127.0.0.1:8000/api/analyze', payload)

    // 5. 处理成功响应
    const endTime = new Date()
    const duration = (endTime - startTime) / 1000
    
    // 假设后端返回的数据结构是 { code: 200, result: "分析文本..." }
    outputLog.value += `[SUCCESS] 后端响应成功 (耗时 ${duration}s)\n\n`
    outputLog.value += `>>> 分析结果：\n${res.data.result}`

  } catch (error) {
    // 6. 处理错误 (比如后端没启动，或者跨域报错)
    console.error(error)
    outputLog.value += `[ERROR] 请求失败！\n`
    
    if (error.code === 'ERR_NETWORK') {
      outputLog.value += `原因：无法连接到后端服务器 (127.0.0.1:8000)。\n请检查：\n1. Python 服务是否启动？\n2. 是否安装了 flask-cors？`
    } else {
      outputLog.value += `原因：${error.message}`
    }
  } finally {
    // 7. 解锁按钮
    isLoading.value = false
  }
}
</script>

<template>
  <div class="layout-container">
    
    <aside class="sidebar">
      <div class="logo">🚀 Kernel Tools</div>
      <div class="nav-item" :class="{active: currentTab===1}" @click="selectTab(1)">📂 路径分析</div>
      <div class="nav-item" :class="{active: currentTab===2}" @click="selectTab(2)">⏱️ 时长分析</div>
    </aside>

    <main class="workspace">
      
      <div class="floating-actions">
        <button class="btn-clear" @click="handleClear">清空</button>
        <button class="btn-run" @click="handleAnalyze">⚡ 开始分析</button>
      </div>

      <div class="panel-input">
        <div class="input-group">
          <label>函数名 (Function Name)</label>
          <input v-model="formData.functionName" type="text" placeholder="例如: vfs_read" class="full-width">
        </div>
        <div class="input-group flex-grow">
          <label>调用栈 / 日志 (Call Stack)</label>
          <textarea v-model="formData.callStack" class="full-width code-area"></textarea>
        </div>
      </div>

      <div class="panel-output">
        <div class="terminal-header">📺 TERMINAL OUTPUT</div>
        <div class="terminal-body">
          <pre>{{ outputLog || '等待指令...' }}</pre>
        </div>
      </div>

    </main>
  </div>
</template>

<style>
/* 强制覆盖默认样式 */
html, body, #app {
  margin: 0 !important; padding: 0 !important;
  width: 100vw !important; height: 100vh !important;
  max-width: none !important; display: block !important;
  overflow: hidden !important;
  font-family: 'Segoe UI', sans-serif;
  box-sizing: border-box;
}
* { box-sizing: border-box; }
</style>

<style scoped>
/* 整体布局 */
.layout-container { display: flex; width: 100vw; height: 100vh; overflow: hidden; }

/* 左侧 Sidebar */
.sidebar {
  width: 240px; background: #1e293b; color: #fff;
  display: flex; flex-direction: column; flex-shrink: 0;
}
.logo { padding: 20px; font-weight: bold; background: #0f172a; font-size: 18px; }
.nav-item { padding: 15px 20px; cursor: pointer; color: #94a3b8; transition: 0.2s; }
.nav-item:hover { background: #334155; color: #fff; }
.nav-item.active { background: #10b981; color: #fff; font-weight: bold; }

/* 右侧 Workspace */
.workspace {
  flex: 1; display: flex; flex-direction: column;
  position: relative; background: #f1f5f9; width: 0;
}

/* 悬浮按钮 */
.floating-actions {
  position: absolute; top: 15px; right: 20px; z-index: 100;
  display: flex; gap: 10px;
}
.btn-run { background: #10b981; color: white; border: none; padding: 8px 20px; cursor: pointer; border-radius: 4px; font-weight: bold; }
.btn-run:hover { background: #059669; }
.btn-clear { background: #e2e8f0; color: #475569; border: none; padding: 8px 15px; cursor: pointer; border-radius: 4px; }
.btn-clear:hover { background: #cbd5e1; }

/* --- 输入区调整 --- */
.panel-input {
  /* 关键修改：从 2.5 降到 2，甚至你可以试 1.8 */
  flex: 2; 
  background: white;
  
  /* 顶部保留 50px 避开按钮，底部减少到 10px */
  padding: 50px 20px 10px 20px; 
  
  display: flex; flex-direction: column; border-bottom: 2px solid #e2e8f0;
}
.input-group { margin-bottom: 8px; } /* 减小间距 */
.input-group label { display: block; font-size: 13px; font-weight: bold; color: #64748b; margin-bottom: 4px; }
.input-group.flex-grow { flex: 1; display: flex; flex-direction: column; }

.full-width { width: 100%; border: 1px solid #cbd5e1; padding: 8px; border-radius: 4px; font-family: monospace; outline: none; }
.full-width:focus { border-color: #10b981; }
.code-area { flex: 1; resize: none; background: #f8fafc; }

/* --- 输出区调整 --- */
.panel-output {
  /* 对应增加，占满剩余 */
  flex: 8; 
  background: #0f172a; color: #22c55e;
  display: flex; flex-direction: column; overflow: hidden;
}

.terminal-header { padding: 8px 20px; background: #1e293b; color: #94a3b8; font-size: 12px; font-weight: bold; letter-spacing: 1px; }
.terminal-body { flex: 1; padding: 20px; overflow-y: auto; font-family: 'Consolas', monospace; }
pre { margin: 0; white-space: pre-wrap; line-height: 1.5; }
</style>