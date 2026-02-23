<script setup>
import { ref, watch, nextTick, computed } from 'vue'

const props = defineProps({
  sourceCode: { type: String, default: '' },
  currentFunc: { type: String, default: '' },
  latencyLog: { type: String, default: '' }, // 接收开始测试后的流式时延日志
  isAnalyzing: { type: Boolean, default: false }
})

const emit = defineEmits(['drillDown', 'restore', 'runLatency'])

const terminalRef = ref(null)
const historyStack = ref([])

// 标记的行号
const startLine = ref(null)
const endLine = ref(null)

// 自动滚动 (仅针对时延分析日志部分)
watch(() => props.latencyLog, async () => {
  await nextTick()
  if (terminalRef.value) {
    terminalRef.value.scrollTop = terminalRef.value.scrollHeight
  }
})

// 解析源码：分离出行号、代码，并注入颜色和点击事件
const parsedLines = computed(() => {
  if (!props.sourceCode) return []

  const safeText = props.sourceCode.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  const keywords = ['if', 'while', 'for', 'switch', 'return', 'sizeof', 'likely', 'unlikely', 'WARN_ON_ONCE', 'catch']

  return safeText.split('\n').map(line => {
    // 匹配 perf probe -L 的输出格式：前面的空格 + 行号 + 空格 + 代码
    const match = line.match(/^(\s*)(\d+)(\s+)(.*)$/)
    if (match) {
      const offset = parseInt(match[2], 10)
      
      // 高亮代码中的函数调用
      const highlightedCode = match[4].replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*\()/g, (m) => {
        if (keywords.includes(m)) return m
        return `<span class="clickable-func" data-func="${m}">${m}</span>`
      })

      return {
        hasOffset: true,
        space1: match[1],
        offset: offset,
        space2: match[3],
        code: highlightedCode
      }
    } else {
      // 没有行号的行 (如函数头部或尾部的括号)
      const highlightedCode = line.replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*\()/g, (m) => {
        if (keywords.includes(m)) return m
        return `<span class="clickable-func" data-func="${m}">${m}</span>`
      })
      return { hasOffset: false, code: highlightedCode }
    }
  })
})

// 切换标志位逻辑
const toggleMarker = (offset) => {
  if (startLine.value === offset) {
    startLine.value = null
  } else if (endLine.value === offset) {
    endLine.value = null
  } else if (startLine.value === null) {
    startLine.value = offset
  } else if (endLine.value === null) {
    endLine.value = offset
  } else {
    // 如果已经满了2个，自动替换结束点
    endLine.value = offset
  }
}

const clearMarkers = () => {
  startLine.value = null
  endLine.value = null
}

const handleStartLatency = () => {
  if (startLine.value === null || endLine.value === null) {
    alert("请在代码左侧选择【两行】作为起始和结束点！")
    return
  }
  emit('runLatency', {
    startOffset: startLine.value,
    endOffset: endLine.value
  })
}

// 点击函数下钻
const handleTerminalClick = (e) => {
  const target = e.target
  if (target.classList.contains('clickable-func')) {
    const funcName = target.getAttribute('data-func')
    if (funcName) {
      historyStack.value.push({ func: props.currentFunc, code: props.sourceCode })
      clearMarkers()
      emit('drillDown', funcName)
    }
  }
}

// 返回上一层
const handleBack = () => {
  if (historyStack.value.length > 0) {
    const prevState = historyStack.value.pop()
    clearMarkers()
    emit('restore', prevState)
  }
}
</script>

<template>
  <div class="panel-output">
    <div class="terminal-header">
      <div class="header-left">
        <span>⏱️ 时长分析源码 (请点击左侧 `[-]` 选择起始和结束行)</span>
      </div>
      <div class="header-actions">
        <button class="btn-tool" @click="clearMarkers">🧹 清空标志</button>
        <button class="btn-run-latency" @click="handleStartLatency" :disabled="isAnalyzing">
          {{ isAnalyzing ? '⏳ 测试中...' : '▶ 开始时延测试' }}
        </button>
        <button v-if="historyStack.length > 0" class="btn-back" @click="handleBack">
          ⬅ 返回 ({{ historyStack[historyStack.length - 1].func }})
        </button>
      </div>
    </div>
    
    <div class="terminal-body" ref="terminalRef">
      <div class="source-container" @click="handleTerminalClick" v-if="parsedLines.length > 0">
        <div v-for="(line, idx) in parsedLines" :key="idx" class="code-line">
          <div class="marker-col" v-if="line.hasOffset" @click.stop="toggleMarker(line.offset)">
            <span v-if="startLine === line.offset" class="mark-s">[S]</span>
            <span v-else-if="endLine === line.offset" class="mark-e">[E]</span>
            <span v-else class="mark-empty">[-]</span>
          </div>
          <div class="marker-col" v-else></div>
          
          <div class="line-col" v-if="line.hasOffset">{{ line.offset }}</div>
          <div class="line-col" v-else></div>
          
          <div class="code-col" v-html="line.code"></div>
        </div>
      </div>
      <div v-else class="empty-state">等待拉取源码...</div>

      <div class="latency-log-container" v-if="latencyLog">
        <hr class="divider"/>
        <div class="log-title">> 时延分析执行日志：</div>
        <pre class="latency-pre">{{ latencyLog }}</pre>
      </div>
    </div>
  </div>
</template>

<style scoped>
.panel-output {
  flex: 8; background: #0f172a; color: #cbd5e1; display: flex; flex-direction: column; overflow: hidden;
}
.terminal-header {
  padding: 8px 20px; background: #1e293b; color: #94a3b8; font-size: 13px; font-weight: bold;
  display: flex; justify-content: space-between; align-items: center;
}
.header-actions { display: flex; gap: 8px; }
button {
  border: none; padding: 4px 12px; border-radius: 4px; cursor: pointer; font-size: 12px; font-weight: bold; transition: 0.2s;
}
.btn-tool { background: #475569; color: white; }
.btn-tool:hover { background: #64748b; }
.btn-run-latency { background: #10b981; color: white; }
.btn-run-latency:hover { background: #059669; }
.btn-run-latency:disabled { background: #064e3b; color: #94a3b8; cursor: not-allowed; }
.btn-back { background: #3b82f6; color: white; }
.btn-back:hover { background: #2563eb; }

.terminal-body {
  flex: 1; padding: 20px; overflow-y: auto; font-family: 'Consolas', monospace; font-size: 14px;
}

/* 源码排版 */
.source-container { display: flex; flex-direction: column; }
.code-line { display: flex; align-items: flex-start; line-height: 1.5; }
.code-line:hover { background: rgba(255,255,255,0.05); }

/* 列颜色区分 */
.marker-col { width: 30px; flex-shrink: 0; cursor: pointer; user-select: none; }
.mark-s { color: #10b981; font-weight: bold; } /* 绿色 Start */
.mark-e { color: #ef4444; font-weight: bold; } /* 红色 End */
.mark-empty { color: #475569; } /* 灰色 未选 */

.line-col { width: 40px; flex-shrink: 0; color: #eab308; text-align: right; padding-right: 10px; user-select: none;} /* 黄色行号 */
.code-col { flex: 1; color: #f8fafc; white-space: pre-wrap;} /* 白色代码 */

:deep(.clickable-func) { color: #60a5fa; text-decoration: underline; cursor: pointer; transition: 0.2s; }
:deep(.clickable-func:hover) { background: rgba(96, 165, 250, 0.2); color: #93c5fd; }

/* 底部日志区 */
.divider { border-color: #334155; margin: 20px 0; }
.log-title { color: #8b5cf6; font-weight: bold; margin-bottom: 10px; }
.latency-pre { margin: 0; color: #22c55e; white-space: pre-wrap; line-height: 1.5; }
</style>