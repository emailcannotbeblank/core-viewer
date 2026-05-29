<script setup>
import { ref, nextTick, watch } from 'vue'

const props = defineProps({
  serverIp: { type: String, default: '' },
  isActive: { type: Boolean, default: false }
})

const shellLog = ref([])           
const shellInput = ref('')         
const isShellLoading = ref(false)  
const terminalBodyRef = ref(null)  

const delayTime = ref(5) // 默认延时 5 秒

const getBaseUrl = () => {
  let ip = props.serverIp.trim()
  if (!ip) return ''
  if (!ip.startsWith('http://') && !ip.startsWith('https://')) {
    ip = 'http://' + ip
  }
  return ip.replace(/\/$/, '')
}

watch(() => props.isActive, (newVal) => {
  if (newVal && shellLog.value.length === 0) {
    initShell()
  }
})

const initShell = async () => {
  const baseUrl = getBaseUrl()
  if (!baseUrl) { alert('请先输入服务器 IP'); return; }
  
  isShellLoading.value = true
  shellLog.value.push({ type: 'system', text: '正在建立 SSH/pty 连接...' })
  
  try {
    const response = await fetch(`${baseUrl}/api/shell/init`, { method: 'POST' })
    const res = await response.json()
    if (res.success) {
      shellLog.value.push({ type: 'system', text: '✅ Shell 准备就绪。' })
    } else {
      shellLog.value.push({ type: 'error', text: '初始化失败: ' + res.error })
    }
  } catch (error) {
    shellLog.value.push({ type: 'error', text: '网络请求异常: ' + error.message })
  } finally {
    isShellLoading.value = false
    scrollToBottom()
  }
}

// 完美的正常发送逻辑（完全保留你的可用版本）
const sendShellCommand = async () => {
  const cmd = shellInput.value.trim()
  if (!cmd) return

  const baseUrl = getBaseUrl()
  if (!baseUrl) { alert('请输入服务器 IP'); return; }

  shellLog.value.push({ type: 'cmd', text: cmd })
  shellInput.value = ''
  isShellLoading.value = true
  scrollToBottom()

  try {
    const response = await fetch(`${baseUrl}/api/shell/exec`, {
      method: 'POST', 
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: cmd })
    })
    const resData = await response.json()
    
    if (resData.success) {
      shellLog.value.push({ type: 'res', text: resData.output || '\r' })
    } else {
      shellLog.value.push({ type: 'error', text: resData.error })
    }
  } catch (error) {
    shellLog.value.push({ type: 'error', text: '请求异常：' + error.message })
  } finally {
    isShellLoading.value = false
    scrollToBottom()
  }
}

// ================= 延时执行 =================
const handleDelayedExecution = () => {
  const cmd = shellInput.value.trim()
  if (!cmd) {
    alert('请先在下方输入要延时执行的命令！')
    return
  }
  
  const t = Number(delayTime.value)
  if (isNaN(t) || t <= 0) {
    alert('请输入有效的时间(大于0的秒数)！')
    return
  }

  shellLog.value.push({ type: 'system', text: `⏳ 计划任务：命令 [${cmd}] 将在 ${t} 秒后自动执行...` })
  scrollToBottom()

  shellInput.value = ''

  setTimeout(async () => {
    shellLog.value.push({ type: 'system', text: `⏰ 延时到达，开始执行: ${cmd}` })
    
    const baseUrl = getBaseUrl()
    isShellLoading.value = true
    scrollToBottom()
    
    try {
      const response = await fetch(`${baseUrl}/api/shell/exec`, {
        method: 'POST', 
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ command: cmd })
      })
      const resData = await response.json()
      if (resData.success) {
        shellLog.value.push({ type: 'res', text: resData.output || '\r' })
      } else {
        shellLog.value.push({ type: 'error', text: resData.error })
      }
    } catch (error) {
      shellLog.value.push({ type: 'error', text: '请求异常：' + error.message })
    } finally {
      isShellLoading.value = false
      scrollToBottom()
    }
  }, t * 1000)
}

// ================= 💥 修复后的触发器逻辑 =================
const handleTrigger = async () => {
  const cmd = shellInput.value.trim()
  const t = Number(delayTime.value) || 0
  
  // 1. 本地 UI 提示，告诉用户去点分析
  shellLog.value.push({ 
    type: 'system', 
    text: `⚡ 触发器已布防：请在代码分析中点击 [运行分析] 或 [开始时延测试]。\n(探针挂载后将自动执行命令 [${cmd || '无'}]，再等待 ${t}s 后采样)` 
  })
  scrollToBottom()

  const baseUrl = getBaseUrl()
  
  // 💥 关键点：进入 loading 状态，把终端挂起，等待测速脚本唤醒它！
  isShellLoading.value = true 
  
  try {
    const res = await fetch(`${baseUrl}/api/trigger`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: cmd, delay: t })
    })
    const data = await res.json()
    if (data.success) {
      // 💥 收到测速脚本送回的输出了！打在屏幕上！
      shellLog.value.push({ type: 'res', text: data.output || '(无输出内容或命令为空)' })
      shellInput.value = '' 
    } else {
      shellLog.value.push({ type: 'error', text: '触发器执行异常：' + data.error })
    }
  } catch (e) {
    shellLog.value.push({ type: 'error', text: '触发器网络异常：' + e.message })
  } finally {
    isShellLoading.value = false
    scrollToBottom()
  }
}

const scrollToBottom = async () => {
  await nextTick()
  if (terminalBodyRef.value) {
    terminalBodyRef.value.scrollTop = terminalBodyRef.value.scrollHeight
  }
}

const clearTerminal = () => {
  shellLog.value = []
}
defineExpose({ clearTerminal })
</script>

<template>
  <div class="web-shell-container">
    <div class="shell-header">
      <span>Session: {{ props.serverIp || '未连接' }}</span>
    </div>
    
    <div class="shell-body" ref="terminalBodyRef">
      <div v-for="(log, idx) in shellLog" :key="idx" :class="['shell-line', 'line-' + log.type]">
        <span v-if="log.type === 'cmd'" class="shell-prompt">root@server:~# </span>
        <pre>{{ log.text }}</pre>
      </div>
      <div v-show="isShellLoading" class="shell-line line-system">
        <pre>... 正在执行并等待输出响应 ...</pre>
      </div>
    </div>

    <div class="shell-toolbar">
      <div class="toolbar-group">
        <label>⏱️ 延时(秒):</label>
        <input type="number" v-model="delayTime" min="1" class="delay-input" />
      </div>
      <button class="btn-tool btn-delay" @click="handleDelayedExecution">
        ⏳ 延时执行
      </button>
      <div class="toolbar-spacer"></div>
      <button class="btn-tool btn-trigger" @click="handleTrigger">
        ⚡ 预设触发器
      </button>
    </div>

    <div class="shell-input-row">
      <span class="shell-prompt">root@server:~# </span>
      <input 
        v-model="shellInput" 
        @keyup.enter="sendShellCommand" 
        :disabled="isShellLoading"
        placeholder="输入 shell 命令并按回车执行，或使用上方按钮延时执行..." 
        autocomplete="off"
        spellcheck="false"
      />
    </div>
  </div>
</template>

<style scoped>
.web-shell-container { flex: 1; display: flex; flex-direction: column; background: #000000; color: #d4d4d4; font-family: 'Consolas', 'Courier New', monospace; height: 100%; }
.shell-header { background: #1e1e1e; padding: 8px 15px; font-size: 12px; color: #858585; border-bottom: 1px solid #333; display: flex; justify-content: space-between; }
.shell-body { flex: 1; overflow-y: auto; padding: 15px; display: flex; flex-direction: column; }
.shell-line { margin-bottom: 4px; display: flex; flex-direction: row; }
.shell-line pre { margin: 0; white-space: pre-wrap; word-break: break-all; font-family: inherit; font-size: 14px; }
.shell-prompt { color: #10b981; font-weight: bold; margin-right: 8px; flex-shrink: 0; }
.line-cmd pre { color: #ffffff; font-weight: bold; }
.line-res pre { color: #cccccc; }
.line-system pre { color: #fbbf24; font-style: italic; } 
.line-error pre { color: #ef4444; } 

.shell-toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 15px;
  background: #1a1a1a;
  border-top: 1px solid #333;
}
.toolbar-group {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: #a3a3a3;
}
.delay-input {
  width: 50px;
  background: #0f172a;
  border: 1px solid #334155;
  color: #fff;
  padding: 4px 6px;
  border-radius: 4px;
  font-family: inherit;
  font-size: 12px;
  outline: none;
  text-align: center;
}
.delay-input:focus {
  border-color: #10b981;
}
.btn-tool {
  background: #334155;
  color: #fff;
  border: none;
  padding: 5px 12px;
  border-radius: 4px;
  cursor: pointer;
  font-size: 12px;
  font-weight: bold;
  font-family: 'SimHei', sans-serif;
  transition: 0.2s;
}
.btn-tool:hover { background: #475569; }
.btn-delay { background: #0ea5e9; }
.btn-delay:hover { background: #0284c7; }
.btn-trigger { background: #d97706; }
.btn-trigger:hover { background: #b45309; }
.toolbar-spacer { flex: 1; } 

.shell-input-row { display: flex; align-items: center; padding: 10px 15px; background: #0a0a0a; border-top: 1px solid #333; }
.shell-input-row input { flex: 1; background: transparent; border: none; color: #ffffff; font-family: inherit; font-size: 14px; outline: none; padding: 0; }
.shell-input-row input:disabled { color: #666; }
</style>
