<script setup>
import { ref, watch, nextTick } from 'vue'

// 定义接收父组件传过来的参数
const props = defineProps({
  log: {
    type: String,
    default: ''
  }
})

const terminalRef = ref(null)

// 监听 log 的变化，自动滚动到底部
watch(() => props.log, async () => {
  await nextTick()
  if (terminalRef.value) {
    terminalRef.value.scrollTop = terminalRef.value.scrollHeight
  }
})
</script>

<template>
  <div class="panel-output">
    <div class="terminal-header">📺 TERMINAL OUTPUT (Live Streaming)</div>
    <div class="terminal-body" ref="terminalRef">
      <pre>{{ log || '等待指令...' }}</pre>
    </div>
  </div>
</template>

<style scoped>
/* 只保留属于终端的样式 */
.panel-output {
  flex: 8;
  background: #0f172a;
  color: #22c55e;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
.terminal-header {
  padding: 8px 20px;
  background: #1e293b;
  color: #94a3b8;
  font-size: 12px;
  font-weight: bold;
  letter-spacing: 1px;
}
.terminal-body {
  flex: 1;
  padding: 20px;
  overflow-y: auto;
  font-family: 'Consolas', monospace;
}
pre {
  margin: 0;
  white-space: pre-wrap;
  line-height: 1.5;
}
</style>