<script setup>
import { ref } from 'vue'
import axios from 'axios'

const currentTab = ref(1)
const formData = ref({
  functionName: '',
  callStack: ''
})
const outputLog = ref('')
const isLoading = ref(false)

const selectTab = (idx) => currentTab.value = idx

const handleClear = () => {
  formData.value.functionName = ''
  formData.value.callStack = ''
  outputLog.value = ''
}

const handleAnalyze = async () => {
  if (!formData.value.functionName) {
    alert('错误：请输入函数名 (Function Name)')
    return
  }
  if (isLoading.value) return

  isLoading.value = true
  const startTime = new Date()
  outputLog.value = `[${startTime.toLocaleTimeString()}] 正在连接后端服务器...\n----------------------------------\n`
  
  try {
    // 统一发送给后端的参数命名
    const payload = {
      target_func: formData.value.functionName.trim(),
      caller_funcs: formData.value.callStack.trim() || '*', // 如果没填，默认传 '*' 表示不限制
      sleep_time: 1
    }

    // 确保请求端口是 5000，路径与后端保持一致
    const res = await axios.post('http://127.0.0.1:5000/api/analyze', payload)

    const endTime = new Date()
    const duration = ((endTime - startTime) / 1000).toFixed(2)
    
    // 判断后端执行脚本是否成功
    if (res.data.success) {
      outputLog.value += `[SUCCESS] 分析完成 (耗时 ${duration}s)\n\n`
      outputLog.value += `${res.data.output}`
    } else {
      outputLog.value += `[ERROR] 脚本执行失败 (耗时 ${duration}s)\n\n`
      outputLog.value += `>>> 错误输出：\n${res.data.error || res.data.output}`
    }

  } catch (error) {
    console.error(error)
    outputLog.value += `[ERROR] 请求失败！\n`
    
    if (error.code === 'ERR_NETWORK') {
      outputLog.value += `原因：无法连接到后端服务器 (127.0.0.1:5000)。\n请检查：\n1. Python 服务是否启动？\n2. 是否安装了 flask-cors？`
    } else {
      outputLog.value += `原因：${error.message}`
    }
  } finally {
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
        <button class="btn-run" @click="handleAnalyze" :disabled="isLoading">
          {{ isLoading ? '⏳ 分析中...' : '⚡ 开始分析' }}
        </button>
      </div>

      <div class="panel-input">
        <div class="input-group">
          <label>函数名 (Function Name)</label>
          <input v-model="formData.functionName" type="text" placeholder="例如: follow_page_mask" class="full-width">
        </div>
        <div class="input-group flex-grow">
          <label>调用栈 / 日志 (Call Stack) [选填]</label>
          <textarea v-model="formData.callStack" placeholder="若限制来源请输入，如: get_user_pages。留空表示统计所有来源。" class="full-width code-area"></textarea>
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
html, body, #app { margin: 0 !important; padding: 0 !important; width: 100vw !important; height: 100vh !important; max-width: none !important; display: block !important; overflow: hidden !important; font-family: 'Segoe UI', sans-serif; box-sizing: border-box; }
* { box-sizing: border-box; }
</style>
<style scoped>
.layout-container { display: flex; width: 100vw; height: 100vh; overflow: hidden; }
.sidebar { width: 240px; background: #1e293b; color: #fff; display: flex; flex-direction: column; flex-shrink: 0; }
.logo { padding: 20px; font-weight: bold; background: #0f172a; font-size: 18px; }
.nav-item { padding: 15px 20px; cursor: pointer; color: #94a3b8; transition: 0.2s; }
.nav-item:hover { background: #334155; color: #fff; }
.nav-item.active { background: #10b981; color: #fff; font-weight: bold; }
.workspace { flex: 1; display: flex; flex-direction: column; position: relative; background: #f1f5f9; width: 0; }
.floating-actions { position: absolute; top: 15px; right: 20px; z-index: 100; display: flex; gap: 10px; }
.btn-run { background: #10b981; color: white; border: none; padding: 8px 20px; cursor: pointer; border-radius: 4px; font-weight: bold; }
.btn-run:hover { background: #059669; }
.btn-run:disabled { background: #94a3b8; cursor: not-allowed; }
.btn-clear { background: #e2e8f0; color: #475569; border: none; padding: 8px 15px; cursor: pointer; border-radius: 4px; }
.btn-clear:hover { background: #cbd5e1; }
.panel-input { flex: 2; background: white; padding: 50px 20px 10px 20px; display: flex; flex-direction: column; border-bottom: 2px solid #e2e8f0; }
.input-group { margin-bottom: 8px; }
.input-group label { display: block; font-size: 13px; font-weight: bold; color: #64748b; margin-bottom: 4px; }
.input-group.flex-grow { flex: 1; display: flex; flex-direction: column; }
.full-width { width: 100%; border: 1px solid #cbd5e1; padding: 8px; border-radius: 4px; font-family: monospace; outline: none; }
.full-width:focus { border-color: #10b981; }
.code-area { flex: 1; resize: none; background: #f8fafc; }
.panel-output { flex: 8; background: #0f172a; color: #22c55e; display: flex; flex-direction: column; overflow: hidden; }
.terminal-header { padding: 8px 20px; background: #1e293b; color: #94a3b8; font-size: 12px; font-weight: bold; letter-spacing: 1px; }
.terminal-body { flex: 1; padding: 20px; overflow-y: auto; font-family: 'Consolas', monospace; }
pre { margin: 0; white-space: pre-wrap; line-height: 1.5; }
</style>