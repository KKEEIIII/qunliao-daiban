// 检查看板.mjs —— 校验 看板.html 的结构与内嵌数据（不依赖浏览器）
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const boardPath = join(here, '看板.html')
if (!existsSync(boardPath)) { console.error('找不到看板.html'); process.exit(1) }
const h = readFileSync(boardPath, 'utf8')
const checks = []
const check = (d, ok, extra = '') => checks.push([d, ok, extra])

check('是完整 HTML（有 doctype / html / body）', h.startsWith('<!DOCTYPE html>') && h.includes('<html') && h.includes('</body>'))
check('声明了 UTF-8（中文不乱码的前提）', h.includes('charset="utf-8"'))
check('内嵌数据块存在且占位符已替换', h.includes('id="todo-data"') && !h.includes('__DATA__'))
check('没有外部依赖（无 http(s) 引用、无 CDN）', !/src="https?:|href="https?:/.test(h))

const m = h.match(/<script id="todo-data" type="application\/json">([^<]+)<\/script>/)
check('能取到内嵌 base64 数据', !!m)
if (m) {
  const data = JSON.parse(Buffer.from(m[1].trim(), 'base64').toString('utf8'))
  check('内嵌 JSON 可解析', true)
  check('带 generatedAt', typeof data.generatedAt === 'string' && data.generatedAt.length > 10)
  check('items 是数组且非空', Array.isArray(data.items) && data.items.length > 0, `items=${data.items?.length}`)
  const open = data.items.filter((x) => !['done', 'ignored', 'expired'].includes(String(x.status)))
  check('能算出未完成条数', open.length >= 0, `未完成=${open.length} / 共 ${data.items.length}`)
  const withDue = data.items.filter((x) => x.due)
  check('至少有一条带 due（否则日期分桶看不出来）', withDue.length > 0, `带 due=${withDue.length}`)
  console.log('  内嵌数据：共', data.items.length, '条，未完成', open.length, '条，generatedAt =', data.generatedAt)
  console.log('  前 3 条：')
  for (const it of data.items.slice(0, 3)) {
    console.log(`    [${it.status}] ${String(it.title).slice(0, 34)} | due=${it.due ?? '无'} | reason=${it.reason ? '有' : '无'}`)
  }
}

// 前端逻辑的关键点（防止"生成出来但页面空白"）
check('有渲染入口 render()', h.includes('function render()'))
check('有导出补丁的逻辑', h.includes('todo-board-changes') && h.includes('a.download'))
check('用 TextDecoder 解 UTF-8（避免 file:// 下中文乱码）', h.includes('new TextDecoder()'))
check('按 due 分了桶（逾期/今天/本周/以后）', h.includes("'overdue'") && h.includes("'today'") && h.includes("'week'"))
check('会显示 reason 字段', h.includes('为什么是待办'))
check('有"重新打开/忽略"按钮', h.includes('重新打开') && h.includes('忽略'))

let pass = 0
console.log('=== 看板.html 体检 ===')
for (const [d, ok, extra] of checks) { if (ok) pass += 1; console.log(`${ok ? 'PASS' : 'FAIL'}  ${d}${ok || !extra ? '' : `  ← ${extra}`}`) }
console.log(`\n${pass}/${checks.length} 通过`)
process.exit(pass === checks.length ? 0 : 1)
