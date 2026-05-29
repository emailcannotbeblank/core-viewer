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

watch(() => props.log, async () => {
  await nextTick()
  if (terminalRef.value) {
    terminalRef.value.scrollTop = terminalRef.value.scrollHeight
  }
})

// 核心功能：带悬挂探测的 C 语言强力缩进计算器
const parsedLogLines = computed(() => {
  if (!props.log) return []

  const keywords = ['if', 'while', 'for', 'switch', 'return', 'sizeof', 'likely', 'unlikely', 'WARN_ON_ONCE', 'catch']

  let safeText = props.log
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")

  const rawLines = safeText.split('\n')
  const result = []
  
  // 初始化基础缩进级别
  let indentLevel = 0
  // 悬挂缩进标记：专门用来处理没有 {} 的 if/while 语句，或者换行的长语句
  let extraIndent = false 

  rawLines.forEach(line => {
    const trimmedLine = line.trim()

    // 忽略完全空行
    if (!trimmedLine) return

    // 保护表头：遇到横线、标题或 <函数签名> 直接原样输出
    if (trimmedLine.includes('----') || trimmedLine.includes('🎯') || trimmedLine.includes('命中次数') || trimmedLine.startsWith('&lt;')) {
      result.push({ isRaw: true, code: trimmedLine })
      return
    }

    // 2. 提取标记和代码
    const regex = /^(?:\[\s*([\dN/A-]+)\s*\]\s*(\d*)\s*)?(.*)$/
    const match = trimmedLine.match(regex)

    if (!match) return

    const rawCount = match[1] || ''
    const lineNum = match[2] || ''
    
    // 彻底扒掉后端给的所有垃圾空格！
    const pureCode = match[3].trim() 

    // ================= 3. AST 级自己计算缩进 =================
    // 获取无注释的纯代码，用于判断语句是否结束
    const textForCheck = pureCode.replace(/\/\/.*|\/\*.*?\*\//g, '').trim()

    // 【计算当前行的实际渲染缩进】：基础缩进 + 悬挂缩进
    let currentRenderIndent = indentLevel + (extraIndent ? 1 : 0)

    // 如果当前行是 {、} 或 跳转 label，它应该无视悬挂缩进，直接跟代码块外围对齐
    if (pureCode.startsWith('{') || pureCode.startsWith('}') || pureCode.match(/^\w+:/)) {
        currentRenderIndent = pureCode.startsWith('}') || pureCode.match(/^\w+:/) ? Math.max(0, indentLevel - 1) : indentLevel
    }

    // 更新下一行的基础缩进级别
    const openBraces = (pureCode.match(/\{/g) || []).length
    const closeBraces = (pureCode.match(/\}/g) || []).length
    indentLevel += (openBraces - closeBraces)
    if (indentLevel < 0) indentLevel = 0

    // 【核心修复】：判断下一行是否需要悬挂缩进！
    // 如果当前行不是注释，且代码不以 分号、大括号、冒号、尖括号 结尾，
    // 说明它是类似 `if (cond)` 或被截断的多行传参，下一行必须强行向右缩进！
    const isCommentLine = pureCode.startsWith('/*') || pureCode.startsWith('*') || pureCode.startsWith('//')
    if (!isCommentLine && textForCheck.length > 0) {
      const lastChar = textForCheck.slice(-1)
      if (lastChar !== ';' && lastChar !== '{' && lastChar !== '}' && lastChar !== ':' && lastChar !== '>') {
        extraIndent = true
      } else {
        extraIndent = false
      }
    }
    // =========================================================

    // 给算出的层级乘上 4 个空格的排版宽度
    const padding = "    ".repeat(currentRenderIndent)

    // 函数高亮
    const highlightedCode = pureCode.replace(/\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?=\s*\()/g, (m) => {
      if (keywords.includes(m)) return m
      return `<span class="clickable-func" data-func="${m}">${m}</span>`
    })

    const finalCodeHTML = padding + highlightedCode

    if (rawCount) {
      let countClass = 'count-zero'
      if (rawCount !== '0' && rawCount !== 'N/A' && rawCount !== '-') countClass = 'count-hit'
      else if (rawCount === 'N/A' || rawCount === '-') countClass = 'count-na'

      result.push({
        isRaw: false,
        hasPrefix: true,
        rawCount,
        countClass,
        lineNum,
        code: finalCodeHTML
      })
    } else {
      result.push({
        isRaw: false,
        hasPrefix: false,
        code: finalCodeHTML
      })
    }
  })

  return result
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
      <span>📺 TERMINAL OUTPUT (Live Streaming)</span>
      <button v-if="historyStack.length > 0" class="btn-back" @click="handleBack">
        ⬅ 返回上一层 ({{ historyStack[historyStack.length - 1].func }})
      </button>
    </div>
    
    <div class="terminal-body" ref="terminalRef">
      <div class="source-container" @click="handleTerminalClick" v-if="parsedLogLines.length > 0">
        <div v-for="(line, idx) in parsedLogLines" :key="idx" class="code-line">
          
          <template v-if="!line.isRaw">
            <div class="stat-col" v-if="line.hasPrefix">
              <span class="stat-bracket">[</span>
              <span class="stat-count" :class="line.countClass">{{ line.rawCount }}</span>
              <span class="stat-bracket">]</span>
            </div>
            <div class="stat-col empty-stat" v-else></div>
            
            <div class="line-col" v-if="line.hasPrefix">{{ line.lineNum }}</div>
            <div class="line-col" v-else></div>
            
            <div class="code-col" v-html="line.code"></div>
          </template>

          <template v-else>
            <div class="raw-col" v-html="line.code"></div>
          </template>

        </div>
      </div>
      <div v-else class="empty-state">等待拉取分析数据...</div>
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
  font-size: 12px; font-weight: bold; transition: 0.2s; 
  font-family: 'SimHei', '黑体', sans-serif;
}
.btn-back:hover { background: #2563eb; }

.terminal-body {
  flex: 1; padding: 20px; overflow-y: auto; 
  font-family: Consolas, Monaco, 'SimHei', '黑体', sans-serif; 
  font-size: 14px;
}

.source-container { display: flex; flex-direction: column; }
.code-line { display: flex; align-items: flex-start; line-height: 1.5; border-bottom: 1px solid transparent; }
.code-line:hover { background: rgba(255,255,255,0.05); }

.stat-col { width: 110px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; }
.empty-stat { width: 110px; }
.stat-bracket { color: #64748b; }
.stat-count { display: inline-block; width: 65px; text-align: right; margin: 0 6px; }
.count-hit { color: #22c55e; font-weight: bold; }
.count-zero { color: #94a3b8; }
.count-na { color: #475569; }

.line-col { width: 45px; flex-shrink: 0; color: #eab308; text-align: right; padding-right: 15px; }

.code-col { flex: 1; color: #f8fafc; white-space: pre-wrap; word-break: break-all; tab-size: 4; }
.raw-col { flex: 1; color: #94a3b8; white-space: pre-wrap; word-break: break-all; margin-left: 10px; tab-size: 4;}

:deep(.clickable-func) {
  color: #60a5fa; text-decoration: underline; cursor: pointer; border-radius: 2px; padding: 0 2px; transition: 0.2s;
}
:deep(.clickable-func:hover) {
  background: rgba(96, 165, 250, 0.2); color: #93c5fd;
}
.empty-state { color: #475569; font-style: italic; }
</style>
