<script setup>
import { ref } from 'vue'
import DurationOutput from './DurationOutput.vue'
import CallStackOutput from './CallStackOutput.vue' 
import ServerTerminal from './ServerTerminal.vue' // <--- 引入终端组件

const currentTab = ref(1)
const serverIp = ref('90.88.16.144:5000')
const serverTerminalRef = ref(null) // <--- 引用终端子组件，用于调用清理方法

const formData = ref({
  functionName: '',
  callStack: '',
  sleepTime: 5
})

const pathOutputLog = ref('') 
const sourceCodeLog = ref('') 
const latencyLog = ref('')    
const callStackLog = ref('')  
const isLoading = ref(false)

const selectTab = (idx) => {
  currentTab.value = idx
}

const handleClear = () => {
  formData.value.functionName = ''
  formData.value.callStack = ''
  pathOutputLog.value = ''
  sourceCodeLog.value = ''
  latencyLog.value = ''
  callStackLog.value = ''    
  // 如果当前在终端 Tab，同时清空终端的记录
  if (currentTab.value === 3 && serverTerminalRef.value) {
    serverTerminalRef.value.clearTerminal()
  }
}

const getBaseUrl = () => {
  let ip = serverIp.value.trim()
  if (!ip) return ''
  if (!ip.startsWith('http://') && !ip.startsWith('https://')) {
    ip = 'http://' + ip
  }
  return ip.replace(/\/$/, '')
}

const handleAnalyze = async () => {
  if (!formData.value.functionName) { alert('请输入函数名'); return; }
  const baseUrl = getBaseUrl()
  if (!baseUrl) { alert('请输入服务器 IP'); return; }
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
      sourceCodeLog.value = ''
      pathOutputLog.value = `[${startTime.toLocaleTimeString()}] 拉取源码...\n--------------------------------------------------\n`
      latencyLog.value = ''

      const sourceResponse = await fetch(`${baseUrl}/api/get_source`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_func: payload.target_func })
      })
      const sourceData = await sourceResponse.json()
      if (sourceData.success) {
        sourceCodeLog.value = sourceData.output
        pathOutputLog.value += `源码拉取完成。\n`
      } else {
        sourceCodeLog.value = `获取源码失败:\n${sourceData.error || sourceData.output}`
        pathOutputLog.value += `源码拉取失败:\n${sourceData.error || sourceData.output}\n`
        return
      }
    } 
    else if (currentTab.value === 2) {
      callStackLog.value = `[${startTime.toLocaleTimeString()}] 🚀 启动调用栈分类分析...\n--------------------------------------------------\n`
      const response = await fetch(`${baseUrl}/api/analyze_callstack_stream`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      })
      const reader = response.body.getReader()
      const decoder = new TextDecoder('utf-8')
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        callStackLog.value += decoder.decode(value, { stream: true })
      }
    }
  } catch (error) {
    const errMsg = `\n请求异常：${error.message}\n(请检查IP是否正确、服务是否启动)`
    if(currentTab.value===1) pathOutputLog.value += errMsg
    else callStackLog.value += errMsg
  } finally {
    isLoading.value = false
  }
}

const handleRunHitAnalysis = async () => {
  if (!formData.value.functionName) { alert('请输入函数名'); return; }
  const baseUrl = getBaseUrl()
  if (!baseUrl) { alert('请输入服务器 IP'); return; }
  if (isLoading.value) return

  isLoading.value = true
  pathOutputLog.value = `[${new Date().toLocaleTimeString()}] 运行分析...\n--------------------------------------------------\n`
  latencyLog.value = ''

  try {
    const payload = {
      target_func: formData.value.functionName.trim(),
      caller_funcs: formData.value.callStack.trim() || '*',
      sleep_time: formData.value.sleepTime
    }
    const response = await fetch(`${baseUrl}/api/analyze_stream`, {
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
  } catch (error) {
    pathOutputLog.value += `\n请求异常：${error.message}\n(请检查IP是否正确、服务是否启动)`
  } finally {
    isLoading.value = false
  }
}

const handleRunLatency = async ({ startOffset, endOffset }) => {
  const baseUrl = getBaseUrl()
  if (!baseUrl) { alert('请输入服务器 IP'); return; }
  if (!formData.value.functionName) { alert('请输入函数名'); return; }
  isLoading.value = true
  latencyLog.value = `\n[${new Date().toLocaleTimeString()}] 启动时延测试脚本...\n----------------------------------\n`
  
  try {
    const payload = {
      target_func: formData.value.functionName.trim(),
      start_offset: startOffset,
      end_offset: endOffset,
      caller_funcs: formData.value.callStack.trim() || '*',
      sleep_time: formData.value.sleepTime 
    }
    const response = await fetch(`${baseUrl}/api/analyze_latency_stream`, {
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
    latencyLog.value += `\n[ERROR] 请求异常：${error.message}`
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
  if (currentTab.value === 1) {
    sourceCodeLog.value = prevState.code || ''
    pathOutputLog.value = prevState.hitLog || ''
    latencyLog.value = prevState.latencyLog || ''
  }
  else if (currentTab.value === 2) callStackLog.value = prevState.log
  else callStackLog.value = prevState.log 
}
</script>

<template>
  <div class="layout-container">
    <aside class="sidebar">
      <div class="logo">🚀 Kernel Tools</div>
      
      <div class="nav-tabs">
        <div class="nav-item" :class="{active: currentTab===1}" @click="selectTab(1)">代码分析</div>
        <div class="nav-item" :class="{active: currentTab===2}" @click="selectTab(2)">调用栈分析</div>
        <div class="nav-item" :class="{active: currentTab===3}" @click="selectTab(3)">服务器交互</div>
      </div>

      <div class="sidebar-form">
        <div class="control-group">
          <label>🎯 函数名 (Function)</label>
          <input v-model="formData.functionName" type="text" placeholder="例如: follow_page_mask">
        </div>

        <div class="control-group flex-grow">
          <label>📜 调用栈过滤 (Call Stack)</label>
          <textarea v-model="formData.callStack" placeholder="限制来源输入，如: get_user_pages。留空为统计所有。"></textarea>
        </div>

        <div class="control-row">
          <div class="control-group" style="flex: 2;">
            <label>🌐 服务器 IP</label>
            <input v-model="serverIp" type="text" placeholder="127.0.0.1:5000">
          </div>
          <div class="control-group" style="flex: 1;">
            <label>⏳ 采样(秒)</label>
            <input v-model.number="formData.sleepTime" type="number" min="1" max="60">
          </div>
        </div>
      </div>

      <div class="sidebar-actions">
        <button class="btn-clear-side" @click="handleClear">清空</button>
        <button v-show="currentTab !== 3" class="btn-run-side" @click="handleAnalyze" :disabled="isLoading">
          {{ isLoading ? '执行中' : (currentTab === 1 ? '拉取代码' : '运行分析') }}
        </button>
      </div>
    </aside>

    <main class="workspace">
      <DurationOutput
        v-show="currentTab === 1"
        :source-code="sourceCodeLog"
        :hit-log="pathOutputLog"
        :latency-log="latencyLog"
        :current-func="formData.functionName"
        :is-analyzing="isLoading"
        @drill-down="handleDrillDown"
        @restore="handleRestore"
        @run-analysis="handleRunHitAnalysis"
        @run-latency="handleRunLatency"
      />
      <CallStackOutput
        v-show="currentTab === 2"  :log="callStackLog"
        :current-func="formData.functionName"
        @drill-down="handleDrillDown"
        @restore="handleRestore"
      />
      
      <ServerTerminal 
        v-show="currentTab === 3" 
        ref="serverTerminalRef"
        :server-ip="serverIp" 
        :is-active="currentTab === 3"
      />
    </main>
  </div>
</template>

<style>
/* 保持原样 */
html, body, #app { margin: 0 !important; padding: 0 !important; width: 100vw !important; height: 100vh !important; max-width: none !important; display: block !important; overflow: hidden !important; font-family: 'SimHei', '黑体', sans-serif; box-sizing: border-box; }
* { box-sizing: border-box; }
</style>

<style scoped>
.layout-container { display: flex; width: 100vw; height: 100vh; overflow: hidden; }

/* 侧边栏调整：加宽到 280px，并采用 Flex 布局以撑满高度 */
.sidebar { 
  width: 280px; background: #1e293b; color: #fff; 
  display: flex; flex-direction: column; flex-shrink: 0; 
  border-right: 1px solid #0f172a;
}
.logo { padding: 20px; font-weight: bold; background: #0f172a; font-size: 18px; }

/* 导航 Tabs */
.nav-tabs { display: flex; flex-direction: column; border-bottom: 1px solid #334155; padding-bottom: 10px; }
.nav-item { padding: 12px 20px; cursor: pointer; color: #94a3b8; transition: 0.2s; font-size: 14px; }
.nav-item:hover { background: #334155; color: #fff; }
.nav-item.active { background: #10b981; color: #fff; font-weight: bold; }

/* 中间的参数表单区 (占据剩余空间) */
.sidebar-form {
  flex: 1; display: flex; flex-direction: column; gap: 15px; 
  padding: 20px; overflow-y: auto;
}
.control-group { display: flex; flex-direction: column; gap: 6px; }
.control-group.flex-grow { flex: 1; }
.control-row { display: flex; gap: 10px; width: 100%; }

/* 暗黑风格的 Input 和 Textarea */
.control-group label { font-size: 12px; color: #94a3b8; font-weight: bold; }
.control-group input, .control-group textarea { 
  background: #0f172a; border: 1px solid #334155; color: #fff; 
  padding: 8px 10px; border-radius: 4px; font-family: 'Consolas', 'SimHei', monospace; 
  font-size: 13px; outline: none; transition: 0.2s; width: 100%; box-sizing: border-box;
}
.control-group input:focus, .control-group textarea:focus { border-color: #10b981; }
.control-group textarea { flex: 1; resize: none; min-height: 100px; } /* 让多行文本框填满空间 */

/* 侧边栏底部控制区 */
.sidebar-actions { 
  padding: 20px; background: #0f172a; border-top: 1px solid #334155; 
  display: flex; gap: 10px; 
}
.btn-run-side { 
  flex: 1; background: #10b981; color: white; border: none; padding: 10px 0; 
  cursor: pointer; border-radius: 4px; font-weight: bold; font-family: inherit; transition: 0.2s;
}
.btn-run-side:hover { background: #059669; }
.btn-run-side:disabled { background: #064e3b; color: #94a3b8; cursor: not-allowed; }

.btn-clear-side { 
  background: #475569; color: white; border: none; padding: 10px 15px; 
  cursor: pointer; border-radius: 4px; font-weight: bold; font-family: inherit; transition: 0.2s;
}
.btn-clear-side:hover { background: #64748b; }

/* 右侧工作区 (纯粹的 Flex 容器) */
.workspace { 
  flex: 1; display: flex; flex-direction: column; position: relative; background: #0f172a; width: 0; 
}
</style>
