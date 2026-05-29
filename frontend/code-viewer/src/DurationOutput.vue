<script setup>
import { ref, watch, nextTick, computed } from 'vue'

const props = defineProps({
  sourceCode: { type: String, default: '' },
  hitLog: { type: String, default: '' },
  currentFunc: { type: String, default: '' },
  latencyLog: { type: String, default: '' },
  isAnalyzing: { type: Boolean, default: false }
})

const emit = defineEmits(['drillDown', 'restore', 'runAnalysis', 'runLatency'])

const terminalRef = ref(null)
const logRef = ref(null)
const historyStack = ref([])

const startLine = ref(null)
const endLine = ref(null)

watch(() => props.latencyLog, async () => {
  await nextTick()
  if (logRef.value) {
    logRef.value.scrollTop = logRef.value.scrollHeight
  }
})

watch(() => props.hitLog, async () => {
  await nextTick()
  if (logRef.value) {
    logRef.value.scrollTop = logRef.value.scrollHeight
  }
})

const keywords = ['if', 'while', 'for', 'switch', 'return', 'sizeof', 'likely', 'unlikely', 'WARN_ON_ONCE', 'catch']

const progressLog = computed(() => {
  const parts = []
  if (props.hitLog) {
    let inRenderedSource = false
    const filtered = props.hitLog
      .split('\n')
      .filter(line => {
        const trimmed = line.trim()
        if (trimmed.includes('[2/3]') && trimmed.includes('解析')) {
          inRenderedSource = true
          return true
        }
        if (trimmed.includes('[3/3]')) {
          inRenderedSource = false
          return true
        }
        if (!trimmed) return !inRenderedSource
        if (inRenderedSource) return false
        if (/^\[\s*([\dN/A-]+)\s*\]\s*\d+\s+/.test(trimmed)) return false
        if (trimmed.includes('[ 命中次数 ]')) return false
        if (trimmed === '统计结果:' || trimmed.includes('🎯 统计结果')) return false
        if (/^-{6,}$/.test(trimmed)) return false
        return true
      })
      .join('\n')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
    if (filtered.trim()) parts.push(filtered)
  }
  if (props.latencyLog) parts.push(props.latencyLog)
  return parts.join('\n')
})

const hitCountMap = computed(() => {
  const map = new Map()
  const safeText = props.hitLog || ''
  const lines = safeText.split('\n')

  lines.forEach(line => {
    const match = line.match(/^\[\s*([\dN/A-]+)\s*\]\s*(\d+)\s+/)
    if (match) {
      map.set(parseInt(match[2], 10), match[1])
    }
  })

  return map
})

const parsedLines = computed(() => {
  if (!props.sourceCode) return []

  // 1. 转义 HTML 实体，并将 \t 统一转换为空格，避免 HTML 中 Tab 渲染宽度不一致导致错位
  const safeText = props.sourceCode
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\t/g, "    ")

  const rawLines = safeText.split('\n')

  // 2. 第一遍扫描：计算所有包含行号的行中，前缀（前导空格+行号+分隔空格）的最小长度
  let minPrefixLength = Infinity
  const lineMatches = rawLines.map(line => {
    // 匹配格式: [前导空格][数字][行号与代码间的空格][实际代码]
    const match = line.match(/^(\s*)(\d+)(\s*)(.*)$/)
    if (match) {
      const codeContent = match[4]
      if (codeContent.length > 0) {
        // 计算前缀总长度
        const prefixLen = match[1].length + match[2].length + match[3].length
        if (prefixLen < minPrefixLength) {
          minPrefixLength = prefixLen
        }
      }
      return { isMatch: true, match, line }
    }
    return { isMatch: false, line }
  })

  // 如果没有匹配到任何行号，将截断长度设为 0
  if (minPrefixLength === Infinity) minPrefixLength = 0

  // 3. 第二遍扫描：按照算出的最小前缀长度进行统一截断
  const lines = lineMatches.map(({ isMatch, match, line }) => {
    let codeText = ''
    if (isMatch) {
      // 有行号的行，统一截断固定的前缀长度，完美保留代码原始相对缩进
      codeText = line.substring(Math.min(minPrefixLength, line.length))
    } else {
      // 没有行号的上下文/注释行，最多只截断 minPrefixLength 个前导空格，避免误吞正文
      const leadingSpacesMatch = line.match(/^ */)
      const leadingSpaces = leadingSpacesMatch ? leadingSpacesMatch[0].length : 0
      const stripLen = Math.min(leadingSpaces, minPrefixLength)
      codeText = line.substring(stripLen)
    }

    // 4. 关键字与函数高亮处理
    const highlightedCode = codeText.replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*\()/g, (m) => {
      if (keywords.includes(m)) return m
      return `<span class="clickable-func" data-func="${m}">${m}</span>`
    })

    if (isMatch) {
      return {
        hasOffset: true,
        offset: parseInt(match[2], 10),
        hitCount: hitCountMap.value.get(parseInt(match[2], 10)) || '-',
        code: highlightedCode,
        isReturnRow: false
      }
    } else {
      return { hasOffset: false, hitCount: '', code: highlightedCode, isReturnRow: false }
    }
  })

  // 5. 追加虚拟的 Return 行
  lines.push({
    hasOffset: true,
    offset: '%return',
    hitCount: '',
    code: '<span style="color: #ef4444; font-weight: bold; font-style: italic;">// 函数返回点 (Function Return Exit)</span>',
    isReturnRow: true
  })

  return lines
})

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
    endLine.value = offset
  }
}

const clearMarkers = () => {
  startLine.value = null
  endLine.value = null
}

const handleStartLatency = () => {
  if (startLine.value === null || endLine.value === null) {
    alert("请在代码左侧选择【两行】作为起始和结束点！\n（可以选择最后一行作为函数 return 点）")
    return
  }
  emit('runLatency', {
    startOffset: startLine.value,
    endOffset: endLine.value
  })
}

const handleRunAnalysis = () => {
  emit('runAnalysis')
}

const handleTerminalClick = (e) => {
  const target = e.target
  if (target.classList.contains('clickable-func')) {
    const funcName = target.getAttribute('data-func')
    if (funcName) {
      historyStack.value.push({
        func: props.currentFunc,
        code: props.sourceCode,
        hitLog: props.hitLog,
        latencyLog: props.latencyLog
      })
      clearMarkers()
      emit('drillDown', funcName)
    }
  }
}

const handleBack = () => {
  if (historyStack.value.length > 0) {
    const prevState = historyStack.value.pop()
    clearMarkers()
    emit('restore', prevState)
  }
}

const countClass = (count) => {
  if (!count || count === '-') return 'count-empty'
  if (count === '0') return 'count-zero'
  if (count === 'N/A') return 'count-na'
  return 'count-hit'
}
</script>

<template>
  <div class="panel-output">
    <div class="terminal-header">
      <div class="header-left">
        <span>代码分析</span>
      </div>
      <div class="header-actions">
        <button class="btn-tool" @click="clearMarkers">清空标志</button>
        <button class="btn-run-analysis" @click="handleRunAnalysis" :disabled="isAnalyzing || !sourceCode">
          {{ isAnalyzing ? '执行中...' : '运行分析' }}
        </button>
        <button class="btn-run-latency" @click="handleStartLatency" :disabled="isAnalyzing">
          {{ isAnalyzing ? '测试中...' : '开始时延测试' }}
        </button>
        <button v-if="historyStack.length > 0" class="btn-back" @click="handleBack">
          返回 {{ historyStack[historyStack.length - 1].func }}
        </button>
      </div>
    </div>
    
    <div class="terminal-body" ref="terminalRef">
      <div class="source-panel" ref="logRef">
        <div class="source-header">
          <div class="marker-col">标记</div>
          <div class="count-col">次数</div>
          <div class="line-col">行号</div>
          <div class="code-col">代码</div>
        </div>

        <div class="source-container" @click="handleTerminalClick" v-if="parsedLines.length > 1">
          <div v-for="(line, idx) in parsedLines" :key="idx" class="code-line" :class="{ 'return-line-bg': line.isReturnRow }">
          <div class="marker-col" v-if="line.hasOffset" @click.stop="toggleMarker(line.offset)">
            <span v-if="startLine === line.offset" class="mark-s">[S]</span>
            <span v-else-if="endLine === line.offset" class="mark-e">[E]</span>
            <span v-else class="mark-empty">[-]</span>
          </div>
          <div class="marker-col" v-else></div>

          <div class="count-col" :class="countClass(line.hitCount)">
            {{ line.hitCount }}
          </div>
          
          <div class="line-col" v-if="line.hasOffset">
            {{ line.offset === '%return' ? 'RET' : line.offset }}
          </div>
          <div class="line-col" v-else></div>
          
          <div class="code-col" v-html="line.code"></div>
          </div>
        </div>
        <div v-else class="empty-state">等待拉取源码...</div>

        <div class="inline-log">
          <div class="log-title">执行日志</div>
          <pre class="latency-pre">{{ progressLog || '等待执行...' }}</pre>
        </div>
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
  border: none; padding: 4px 12px; border-radius: 4px; cursor: pointer; font-size: 12px; font-weight: bold; transition: 0.2s; font-family: 'SimHei', '黑体', sans-serif;
}
.btn-tool { background: #475569; color: white; }
.btn-tool:hover { background: #64748b; }
.btn-run-analysis { background: #3b82f6; color: white; }
.btn-run-analysis:hover { background: #2563eb; }
.btn-run-analysis:disabled { background: #1e3a8a; color: #94a3b8; cursor: not-allowed; }
.btn-run-latency { background: #10b981; color: white; }
.btn-run-latency:hover { background: #059669; }
.btn-run-latency:disabled { background: #064e3b; color: #94a3b8; cursor: not-allowed; }
.btn-back { background: #3b82f6; color: white; }
.btn-back:hover { background: #2563eb; }

.terminal-body {
  flex: 1; padding: 16px; overflow: hidden; font-family: Consolas, Monaco, 'SimHei', '黑体', monospace; font-size: 14px;
}

.source-panel { height: 100%; overflow: auto; border: 1px solid #1e293b; background: #0b1220; }
.source-header, .code-line { display: grid; grid-template-columns: 52px 88px 58px minmax(0, 1fr); align-items: flex-start; }
.source-header {
  position: sticky; top: 0; z-index: 2; background: #111827; color: #94a3b8; font-size: 12px; font-weight: bold;
  border-bottom: 1px solid #334155; line-height: 2;
}
.source-container { display: flex; flex-direction: column; }
.code-line { display: flex; align-items: flex-start; line-height: 1.5; border-bottom: 1px solid transparent; }
.code-line:hover { background: rgba(255,255,255,0.05); }
.source-container .code-line { display: grid; }

/* 为底部的虚拟 return 行增加一点微弱的高亮背景以示区分 */
.return-line-bg { background: rgba(239, 68, 68, 0.05); border-top: 1px dashed #475569; margin-top: 5px; padding-top: 5px; }

.marker-col { cursor: pointer; user-select: none; text-align: center; color: #64748b; }
.mark-s { color: #10b981; font-weight: bold; }
.mark-e { color: #ef4444; font-weight: bold; }
.mark-empty { color: #475569; }

.count-col { color: #94a3b8; text-align: right; padding-right: 18px; user-select: none; }
.count-hit { color: #22c55e; font-weight: bold; }
.count-zero { color: #64748b; }
.count-na { color: #475569; }
.count-empty { color: #475569; }
.line-col { color: #eab308; text-align: right; padding-right: 12px; user-select: none;} 
.code-col { min-width: 0; color: #f8fafc; white-space: pre-wrap; tab-size: 4; word-break: break-word;} 

:deep(.clickable-func) { color: #60a5fa; text-decoration: underline; cursor: pointer; transition: 0.2s; }
:deep(.clickable-func:hover) { background: rgba(96, 165, 250, 0.2); color: #93c5fd; }

.inline-log { border-top: 1px solid #334155; background: #050b16; margin-top: 12px; padding: 10px 12px; }
.log-title { color: #8b5cf6; font-weight: bold; margin-bottom: 8px; font-size: 12px; }
.latency-pre { margin: 0; color: #22c55e; white-space: pre-wrap; line-height: 1.5; font-family: inherit; tab-size: 4; }
</style>
