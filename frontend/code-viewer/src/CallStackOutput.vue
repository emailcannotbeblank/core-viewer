<script setup>
import { ref, watch, nextTick, computed } from 'vue'

const props = defineProps({
  log: { type: String, default: '' },
  currentFunc: { type: String, default: '' }
})

const emit = defineEmits(['drillDown', 'restore'])

const terminalRef = ref(null)
const historyStack = ref([])

// 自动滚动到底部
watch(() => props.log, async () => {
  await nextTick()
  if (terminalRef.value) {
    terminalRef.value.scrollTop = terminalRef.value.scrollHeight
  }
})

// 解析文本并提取函数加上超链接
const parsedLog = computed(() => {
  if (!props.log) return '等待指令...'

  let safeText = props.log.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

  // 匹配行内的函数名，打上高亮标签
  return safeText.split('\n').map(line => {
    // 高亮 "🔥 命中次数" 等特殊行
    if (line.includes('🔥 命中次数:')) {
      return `<span class="highlight-count">${line}</span>`
    }
    
    // 给调用栈中的函数名上色并变为可点击
    return line.replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\+0x)/g, (match) => {
      return `<span class="clickable-func" data-func="${match}">${match}</span>`
    })
  }).join('\n')
})

const handleTerminalClick = (e) => {
  const target = e.target
  if (target.classList.contains('clickable-func')) {
    const funcName = target.getAttribute('data-func')
    if (funcName) {
      historyStack.value.push({ func: props.currentFunc, log: props.log })
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
      <span>🧬 CALL STACK ANALYSIS (Aggregated Top Paths)</span>
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

.terminal-body {
  flex: 1; padding: 20px; overflow-y: auto; font-family: 'SimHei', '黑体', monospace;
}
pre { margin: 0; white-space: pre-wrap; line-height: 1.5; font-family: inherit; }

/* 命中频次行高亮 */
:deep(.highlight-count) { color: #f59e0b; font-weight: bold; font-size: 1.1em;}

/* 可点击的函数样式 */
:deep(.clickable-func) {
  color: #60a5fa; text-decoration: underline; cursor: pointer; border-radius: 2px; padding: 0 2px; transition: 0.2s;
}
:deep(.clickable-func:hover) {
  background: rgba(96, 165, 250, 0.2); color: #93c5fd;
}
</style>