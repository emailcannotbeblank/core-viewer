<script setup>
import { ref } from 'vue'
import TerminalOutput from './TerminalOutput.vue'
import DurationOutput from './DurationOutput.vue' // 引入新组件

const currentTab = ref(1)
const formData = ref({
  functionName: '',
  callStack: '',
  sleepTime: 5
})

const pathOutputLog = ref('') // 路径分析日志
const sourceCodeLog = ref('') // 时长分析获取的源码
const latencyLog = ref('')    // 时长分析执行的实时日志
const isLoading = ref(false)

const selectTab = (idx) => {
  currentTab.value = idx
  handleClear() 
}

const handleClear = () => {
  formData.value.functionName = ''
  formData.value.callStack = ''
  pathOutputLog.value = ''
  sourceCodeLog.value = ''
  latencyLog.value = ''
}

// 主分析按钮：获取代码 或 执行路径分析
const handleAnalyze = async () => {
  if (!formData.value.functionName) { alert('请输入函数名'); return; }
  if (isLoading.value) return

  isLoading.value = true
  const startTime = new Date()
  
  try {
    const payload = {
      target_func: formData.value.functionName.trim(),
      caller_funcs: formData.value.callStack.trim() || '*',
      sleep_time: formData.value.sleepTime
    }

    if (currentTab.value === 1) {
      pathOutputLog.value = `[${startTime.toLocaleTimeString()}] 🚀 启动路径分析...\n--------------------------------------------------\n`
      const response = await fetch('http://127.0.0.1:5000/api/analyze_stream', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      })
      const reader = response.body.getReader()
      const decoder = new TextDecoder('utf-8')
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        pathOutputLog.value += decoder.decode(value, { stream: true })
      }
    } 
    else if (currentTab.value === 2) {
      sourceCodeLog.value = ''
      latencyLog.value = ''
      const response = await fetch('http://127.0.0.1:5000/api/get_source', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_func: payload.target_func })
      })
      const resData = await response.json()
      if (resData.success) {
        sourceCodeLog.value = resData.output
      } else {
        sourceCodeLog.value = `获取源码失败:\n${resData.error || resData.output}`
      }
    }
  } catch (error) {
    if(currentTab.value===1) pathOutputLog.value += `\n请求异常：${error.message}`
    else sourceCodeLog.value = `请求异常：${error.message}`
  } finally {
    isLoading.value = false
  }
}

// 接收子组件传来的时延测试请求 (两个偏移量)
const handleRunLatency = async ({ startOffset, endOffset }) => {
  isLoading.value = true
  latencyLog.value = `🚀 启动时延测试脚本...\n----------------------------------\n`
  
  try {
    const payload = {
      target_func: formData.value.functionName.trim(),
      start_offset: startOffset,
      end_offset: endOffset,
      caller_funcs: formData.value.callStack.trim() || '*'
    }

    const response = await fetch('http://127.0.0.1:5000/api/analyze_latency_stream', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    })

    const reader = response.body.getReader()
    const decoder = new TextDecoder('utf-8')
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      latencyLog.value += decoder.decode(value, { stream: true })
    }
  } catch (error) {
    latencyLog.value += `\n[ERROR] ${error.message}`
  } finally {
    isLoading.value = false
  }
}

const handleDrillDown = (newFuncName) => {
  formData.value.functionName = newFuncName
  handleAnalyze()
}
const handleRestore = (prevState) => {
  formData.value.functionName = prevState.func
  if (currentTab.value === 1) pathOutputLog.value = prevState.log
  else sourceCodeLog.value = prevState.code
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
          {{ isLoading ? '⏳ 执行中...' : '⚡ 拉取信息' }}
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
        v-if="currentTab === 1"
        :log="pathOutputLog" 
        :current-func="formData.functionName"
        @drill-down="handleDrillDown"
        @restore="handleRestore"
      />
      <DurationOutput
        v-if="currentTab === 2"
        :source-code="sourceCodeLog"
        :latency-log="latencyLog"
        :current-func="formData.functionName"
        :is-analyzing="isLoading"
        @drill-down="handleDrillDown"
        @restore="handleRestore"
        @run-latency="handleRunLatency"
      />
    </main>
  </div>
</template>

<style>
html, body, #app { margin: 0 !important; padding: 0 !important; width: 100vw !important; height: 100vh !important; max-width: none !important; display: block !important; overflow: hidden !important; font-family: 'Segoe UI', sans-serif; box-sizing: border-box; }
* { box-sizing: border-box; }
</style>
<style scoped>
/* 保持你的原样式不变 */
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