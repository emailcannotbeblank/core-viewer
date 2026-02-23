<script setup>
import { ref, watch } from 'vue'
import TerminalOutput from './TerminalOutput.vue'

const currentTab = ref(1)
const formData = ref({
  functionName: '',
  callStack: '',
  sleepTime: 5
})
const outputLog = ref('')
const isLoading = ref(false)

// 切换 Tab 时，自动清空下方的输出面板，避免数据混淆
const selectTab = (idx) => {
  currentTab.value = idx
  handleClear() 
}

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
  
  const modeName = currentTab.value === 1 ? '路径分析 (行级覆盖率)' : '时长分析 (源码获取)'
  outputLog.value = `[${startTime.toLocaleTimeString()}] 🚀 启动 ${modeName}...\n--------------------------------------------------\n`
  
  try {
    const payload = {
      target_func: formData.value.functionName.trim(),
      caller_funcs: formData.value.callStack.trim() || '*',
      sleep_time: formData.value.sleepTime
    }

    // ==========================================
    // 模式 1：路径分析 (调用 sh 脚本，流式输出)
    // ==========================================
    if (currentTab.value === 1) {
      const response = await fetch('http://127.0.0.1:5000/api/analyze_stream', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      })

      if (!response.ok) throw new Error(`HTTP 错误: ${response.status}`)

      const reader = response.body.getReader()
      const decoder = new TextDecoder('utf-8')

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        outputLog.value += decoder.decode(value, { stream: true })
      }
    } 
    // ==========================================
    // 模式 2：时长分析 (仅获取源码)
    // ==========================================
    else if (currentTab.value === 2) {
      const response = await fetch('http://127.0.0.1:5000/api/get_source', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_func: payload.target_func })
      })

      if (!response.ok) throw new Error(`HTTP 错误: ${response.status}`)
      
      const resData = await response.json()
      if (resData.success) {
        outputLog.value += `🔍 成功获取函数 [${payload.target_func}] 的源码:\n\n`
        outputLog.value += resData.output
      } else {
        outputLog.value += `❌ 获取源码失败:\n${resData.error || resData.output}`
      }
    }

    const endTime = new Date()
    const duration = ((endTime - startTime) / 1000).toFixed(2)
    outputLog.value += `\n[SUCCESS] 全部执行完毕 (总耗时 ${duration}s)\n`

  } catch (error) {
    console.error(error)
    outputLog.value += `\n[ERROR] 请求异常：${error.message}\n(请确保 Python Flask 服务运行于 5000 端口)`
  } finally {
    isLoading.value = false
  }
}

// 处理终端内点击函数的事件（下钻）
const handleDrillDown = (newFuncName) => {
  formData.value.functionName = newFuncName
  // 保持当前的 Tab 模式不变，重新请求
  handleAnalyze()
}

// 处理点击返回按钮的事件（恢复）
const handleRestore = (prevState) => {
  formData.value.functionName = prevState.func
  outputLog.value = prevState.log
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
        <div class="input-row">
          <div class="input-group" style="flex: 2;">
            <label>函数名 (Function Name)</label>
            <input v-model="formData.functionName" type="text" placeholder="例如: follow_page_mask" class="full-width">
          </div>
          <div class="input-group" style="flex: 1; margin-left: 15px;">
            <label>采样时长 (秒)</label>
            <input v-model.number="formData.sleepTime" type="number" min="1" max="60" class="full-width">
          </div>
        </div>

        <div class="input-group flex-grow">
          <label>调用栈 / 日志 (Call Stack) [选填]</label>
          <textarea v-model="formData.callStack" placeholder="若限制来源请输入，如: get_user_pages。留空表示统计所有来源。" class="full-width code-area"></textarea>
        </div>
      </div>

      <TerminalOutput 
        :log="outputLog" 
        :current-func="formData.functionName"
        @drill-down="handleDrillDown"
        @restore="handleRestore"
      />
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
.input-row { display: flex; width: 100%; margin-bottom: 8px; }
.input-group { display: flex; flex-direction: column; }
.input-group label { font-size: 13px; font-weight: bold; color: #64748b; margin-bottom: 4px; }
.input-group.flex-grow { flex: 1; display: flex; flex-direction: column; }
.full-width { width: 100%; border: 1px solid #cbd5e1; padding: 8px; border-radius: 4px; font-family: monospace; outline: none; }
.full-width:focus { border-color: #10b981; }
.code-area { flex: 1; resize: none; background: #f8fafc; }
</style>