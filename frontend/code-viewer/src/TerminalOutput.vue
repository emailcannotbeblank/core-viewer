<script setup>
import { ref, watch, nextTick, computed } from 'vue'

const props = defineProps({
  log: {
    type: String,
    default: ''
  },
  currentFunc: {
    type: String,
    default: '' 
  }
})

const emit = defineEmits(['drillDown', 'restore'])

const terminalRef = ref(null)
const historyStack = ref([]) 

// 监听 log 的变化，自动滚动到底部
watch(() => props.log, async () => {
  await nextTick()
  if (terminalRef.value) {
    terminalRef.value.scrollTop = terminalRef.value.scrollHeight
  }
})

// 核心功能：解析日志文本，转义 HTML，分色渲染，并将函数变为可点击的超链接
const parsedLog = computed(() => {
  if (!props.log) return '等待指令...'

  // 辅助函数：专门用来给 C 语言函数名打上可点击的标记
  const highlightFunctions = (text) => {
    const keywords = ['if', 'while', 'for', 'switch', 'return', 'sizeof', 'likely', 'unlikely', 'WARN_ON_ONCE', 'catch']
    return text.replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*\()/g, (match) => {
      if (keywords.includes(match)) return match
      return `<span class="clickable-func" data-func="${match}">${match}</span>`
    })
  }

  // 1. 转义 < 和 >，防止 C 语言代码中的尖括号破坏 Vue 模板渲染
  let safeText = props.log
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")

  // 2. 按行切分，对包含代码统计的行进行拆分着色
  const lines = safeText.split('\n')
  const processedLines = lines.map(line => {
    // 正则匹配 Bash 脚本打印的格式: [ 命中次数 ] 行号 代码
    const statRegex = /^(\[)(.*?)(\])(\s+)(\d+)(\s+)(.*)$/
    const match = line.match(statRegex)

    if (match) {
      const rawCount = match[2].trim()
      
      let countClass = 'count-zero'
      if (rawCount !== '0' && rawCount !== 'N/A' && rawCount !== '-') {
        countClass = 'count-hit'
      } else if (rawCount === 'N/A' || rawCount === '-') {
        countClass = 'count-na'
      }

      const p1_bracketL = match[1]
      const p2_count    = match[2] 
      const p3_bracketR = match[3]
      const p4_space    = match[4]
      const p5_lineNum  = match[5] 
      const p6_space    = match[6]
      const p7_code     = highlightFunctions(match[7]) 

      return `<span class="stat-bracket">${p1_bracketL}</span>` +
             `<span class="stat-count ${countClass}">${p2_count}</span>` +
             `<span class="stat-bracket">${p3_bracketR}</span>` +
             `${p4_space}` +
             `<span class="stat-line">${p5_lineNum}</span>` +
             `${p6_space}` +
             `<span class="stat-code">${p7_code}</span>`
    }

    return highlightFunctions(line)
  })

  return processedLines.join('\n')
})

const handleTerminalClick = (e) => {
  const target = e.target
  if (target.classList.contains('clickable-func')) {
    const funcName = target.getAttribute('data-func')
    if (funcName) {
      historyStack.value.push({
        func: props.currentFunc,
        log: props.log
      })
      emit('drillDown', funcName)
    }
  }
}

const handleBack = () => {
  if (historyStack.value.length > 0) {
    const prevState = historyStack.value.pop()
    emit('restore', prevState)
  }
}
</script>

<template>
  <div class="panel-output">
    <div class="terminal-header">
      <span>📺 TERMINAL OUTPUT (Live Streaming)</span>
      <button v-if="historyStack.length > 0" class="btn-back" @click="handleBack">
        ⬅ 返回上一层 ({{ historyStack[historyStack.length - 1].func }})
      </button>
    </div>
    
    <div class="terminal-body" ref="terminalRef">
      <pre @click="handleTerminalClick" v-html="parsedLog"></pre>
    </div>
  </div>
</template>

<style scoped>
.panel-output {
  flex: 8; background: #0f172a; color: #cbd5e1;
  display: flex; flex-direction: column; overflow: hidden;
}
.terminal-header {
  padding: 8px 20px; background: #1e293b; color: #94a3b8;
  font-size: 12px; font-weight: bold; letter-spacing: 1px;
  display: flex; justify-content: space-between; align-items: center;
}
.btn-back {
  background: #3b82f6; color: white; border: none;
  padding: 4px 12px; border-radius: 4px; cursor: pointer;
  font-size: 12px; font-weight: bold; transition: 0.2s; font-family: 'SimHei', '黑体', sans-serif;
}
.btn-back:hover { background: #2563eb; }

/* 修改点：终端代码区也强制使用黑体字体 */
.terminal-body {
  flex: 1; padding: 20px; overflow-y: auto; font-family: 'SimHei', '黑体', monospace;
}
pre { margin: 0; white-space: pre-wrap; line-height: 1.5; font-family: inherit; }

:deep(.stat-bracket) { color: #64748b; }
:deep(.stat-count.count-hit) { color: #22c55e; font-weight: bold; }
:deep(.stat-count.count-zero) { color: #94a3b8; }
:deep(.stat-count.count-na) { color: #475569; }
:deep(.stat-line) { color: #eab308; }
:deep(.stat-code) { color: #f8fafc; }

:deep(.clickable-func) {
  color: #60a5fa; text-decoration: underline; cursor: pointer; border-radius: 2px; padding: 0 2px; transition: 0.2s;
}
:deep(.clickable-func:hover) {
  background: rgba(96, 165, 250, 0.2); color: #93c5fd;
}
</style>