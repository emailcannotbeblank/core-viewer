<script setup>
import { ref, watch, nextTick, computed } from 'vue'

const props = defineProps({
  log: {
    type: String,
    default: ''
  },
  currentFunc: {
    type: String,
    default: '' // 接收当前正在分析的函数名
  }
})

const emit = defineEmits(['drillDown', 'restore'])

const terminalRef = ref(null)
const historyStack = ref([]) // 历史状态栈

// 监听 log 的变化，自动滚动到底部
watch(() => props.log, async () => {
  await nextTick()
  if (terminalRef.value) {
    terminalRef.value.scrollTop = terminalRef.value.scrollHeight
  }
})

// 核心功能：解析日志文本，转义 HTML 并将函数变为可点击的超链接
const parsedLog = computed(() => {
  if (!props.log) return '等待指令...'

  // 1. 转义 < 和 >，防止 C 语言代码中的尖括号破坏 Vue 模板渲染
  let safeText = props.log
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")

  // 2. 正则匹配：找单词，且该单词后面跟着左括号 `(`
  // 排除掉 C 语言的常见控制关键字
  const keywords = ['if', 'while', 'for', 'switch', 'return', 'sizeof', 'likely', 'unlikely', 'WARN_ON_ONCE', 'catch']
  
  return safeText.replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*\()/g, (match) => {
    if (keywords.includes(match)) return match
    // 渲染成带有 data-func 属性的 span 标签
    return `<span class="clickable-func" data-func="${match}">${match}</span>`
  })
})

// 利用事件委托，监听整个 pre 标签内的点击事件
const handleTerminalClick = (e) => {
  const target = e.target
  if (target.classList.contains('clickable-func')) {
    const funcName = target.getAttribute('data-func')
    if (funcName) {
      // 1. 将当前屏幕的状态压入历史栈
      historyStack.value.push({
        func: props.currentFunc,
        log: props.log
      })
      // 2. 通知父组件，带着新函数名去发请求
      emit('drillDown', funcName)
    }
  }
}

// 返回上一层级
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
  flex: 8; background: #0f172a; color: #22c55e;
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
  font-size: 12px; font-weight: bold; transition: 0.2s;
}
.btn-back:hover { background: #2563eb; }

.terminal-body {
  flex: 1; padding: 20px; overflow-y: auto; font-family: 'Consolas', monospace;
}
pre { margin: 0; white-space: pre-wrap; line-height: 1.5; }

/* 必须使用 :deep() 因为这些 span 是通过 v-html 动态插入的 */
:deep(.clickable-func) {
  color: #60a5fa; /* 亮蓝色，看起来像超链接 */
  text-decoration: underline;
  cursor: pointer;
  border-radius: 2px;
  padding: 0 2px;
  transition: 0.2s;
}
:deep(.clickable-func:hover) {
  background: rgba(96, 165, 250, 0.2);
  color: #93c5fd;
}
</style>