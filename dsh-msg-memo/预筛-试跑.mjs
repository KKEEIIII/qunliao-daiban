/**
 * 预筛-试跑.mjs —— 离线看"本地预筛会送什么、筛掉什么"，以及**真实 prompt 有多大**
 *
 * 不调用模型、不碰微信/QQ 窗口、**不写游标、不写任何文件**（纯只读）。
 * 判定逻辑与 prompt 组装都用 lib/index.js 里的**真实代码**（vm 抽取 + 直接 import），
 * 所以这里看到的就是插件上线后的行为。
 *
 * 用法：
 *   node .\dsh-msg-memo\预筛-试跑.mjs                 # 只看游标之后的新记录
 *   node .\dsh-msg-memo\预筛-试跑.mjs --all           # 忽略游标，扫全部历史（检验会不会漏抽）
 *   node .\dsh-msg-memo\预筛-试跑.mjs --days 3        # 只看最近 3 天的 spool 文件
 *   node .\dsh-msg-memo\预筛-试跑.mjs --show 20       # 多列几条例子
 *   node .\dsh-msg-memo\预筛-试跑.mjs --off           # 对照：预筛关掉时全量送模型的数据量
 *   node .\dsh-msg-memo\预筛-试跑.mjs --prompt        # 打印完整 prompt（看格式，别贴到群里）
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))
const workspace = join(here, '..')
const src = readFileSync(join(here, 'lib', 'index.js'), 'utf8')
const { buildPromptForTest, buildPromptLegacy } = await import(new URL('./lib/index.js', import.meta.url).href)

function extractFn(name) {
  const start = src.indexOf(`function ${name}(`)
  if (start < 0) throw new Error('找不到函数 ' + name)
  let depth = 0
  let end = -1
  for (let i = src.indexOf('{', start); i < src.length; i += 1) {
    if (src[i] === '{') depth += 1
    else if (src[i] === '}') { depth -= 1; if (depth === 0) { end = i + 1; break } }
  }
  return src.slice(start, end)
}
function extractConst(name) {
  const start = src.indexOf(`const ${name} =`)
  if (start < 0) throw new Error('找不到常量 ' + name)
  const end = src.indexOf('\n}', start)
  if (end < 0) throw new Error('常量 ' + name + ' 结尾找不到')
  return src.slice(start, end + 2)
}
/** 单行箭头函数（如 `const norm = (s) => ...`） */
function extractArrow(name) {
  const start = src.indexOf(`const ${name} = `)
  if (start < 0) throw new Error('找不到箭头函数 ' + name)
  const end = src.indexOf('\n', start)
  return src.slice(start, end)
}

// ⚠️ 2026-10-16 修：`--all` 一跑就崩（ReferenceError: mentionList is not defined）。
//   isCandidateRecord 会调 mentionList() 读"我被点名的昵称"，而抽取列表里漏了它、
//   也漏了它依赖的模块级 `let _aliasCache`（不先声明的话，函数第一行读它就抛）。
//   顺带把 existsSync/readFileSync/join/process 注入沙箱 —— mentionList 要读两处 config.json。
const sandbox = { console, JSON, String, Number, Object, Array, RegExp, Map, Set, existsSync, readFileSync, join, process, nowIso: () => new Date().toISOString() }
vm.createContext(sandbox)
vm.runInContext(
  [
    'let _aliasCache = null',
    extractConst('PREFILTER_PATTERNS'),
    extractArrow('norm'),
    extractFn('mentionList'),
    extractFn('isCandidateRecord'),
    extractFn('prefilterRecords'),
  ].join('\n\n') + '\nthis.prefilterRecords = prefilterRecords;',
  sandbox,
)

// ── 参数 ──
const argv = process.argv.slice(2)
const has = (f) => argv.includes(f)
const valOf = (f, d) => { const i = argv.indexOf(f); return i >= 0 && argv[i + 1] ? argv[i + 1] : d }
const scanAll = has('--all')
const prefilterOff = has('--off')
const days = Number(valOf('--days', '0')) || 0
const show = Number(valOf('--show', '12'))

// ── 配置（和插件同一份 config.json）──
let cfg = {}
const cfgPath = join(here, 'config.json')
if (existsSync(cfgPath)) cfg = JSON.parse(readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, ''))

const spoolDir = join(workspace, 'wx-采集器', 'spool')
const cursorPath = join(workspace, '群聊待办', '.spool-cursor.json')
const cursor = scanAll || !existsSync(cursorPath)
  ? {}
  : JSON.parse(readFileSync(cursorPath, 'utf8').replace(/^\uFEFF/, ''))

let files = readdirSync(spoolDir).filter((f) => f.startsWith('messages-') && f.endsWith('.jsonl')).sort()
if (days > 0) {
  const cut = new Date(Date.now() - days * 86400000)
  const cutKey = `messages-${cut.getFullYear()}${String(cut.getMonth() + 1).padStart(2, '0')}${String(cut.getDate()).padStart(2, '0')}.jsonl`
  files = files.filter((f) => f >= cutKey)
}

// ── 收集记录（去 BOM，和插件一致）──
const records = []
const perFile = []
let badLines = 0
for (const file of files) {
  let lines = []
  try {
    lines = readFileSync(join(spoolDir, file), 'utf8').replace(/^\uFEFF/, '').split('\n').filter((l) => l.trim() !== '')
  } catch { continue }
  const from = scanAll ? 0 : Number(cursor[file] ?? 0)
  const slice = lines.slice(from)
  perFile.push(`${file}: 共 ${lines.length} 行，游标 ${from}${scanAll ? '（--all 忽略）' : ''} → 看 ${slice.length} 条`)
  for (const line of slice) {
    try { records.push(JSON.parse(line)) } catch { badLines += 1 }
  }
}

console.log('=== 预筛试跑（不调用模型、不写任何文件）===')
console.log(`工作区: ${workspace}`)
console.log(`预筛: ${prefilterOff ? '关（--off 对照）' : `开（config.prefilter=${cfg.prefilter}）`}   范围: ${scanAll ? '全部历史' : '游标之后的新记录'}${days ? `，最近 ${days} 天` : ''}`)
for (const l of perFile) console.log('  ' + l)
console.log(`合计 ${records.length} 条记录${badLines ? `（另有 ${badLines} 行解析失败）` : ''}\n`)
if (records.length === 0) {
  console.log('没有可看的记录。想检验历史漏抽情况可以加 --all。')
  process.exit(0)
}

const charsOf = (r) => String(r?.text ?? r?.preview ?? '').length
const sum = (a) => a.reduce((n, r) => n + charsOf(r), 0)

// ── 预筛 ──
const cfgFilter = { ...cfg, prefilter: !prefilterOff }
const pre = sandbox.prefilterRecords(records, cfgFilter)
const keptChars = sum(pre.kept)
const dropChars = sum(pre.dropped)
const total = keptChars + dropChars
const pct = (n) => (total > 0 ? ((n / total) * 100).toFixed(1) : '0.0')

console.log('=== 第①级：本地预筛（只看"送不送模型"，不看 prompt 大小）===')
console.log(`送模型 ${pre.kept.length} 条 / ${keptChars} 字（占 ${pct(keptChars)}%）`)
console.log(`筛掉   ${pre.dropped.length} 条 / ${dropChars} 字（占 ${pct(dropChars)}%）`)

const hitCount = {}
for (const d of pre.decisions) for (const h of d.hits) hitCount[h] = (hitCount[h] ?? 0) + 1
console.log('命中理由分布：')
for (const [k, v] of Object.entries(hitCount).sort((a, b) => b[1] - a[1])) console.log(`  ${k.padEnd(14)} ${v} 条`)

// ── 第②级：prompt 体积（预筛后 vs 全量）──
const openTodos = (() => {
  const p = join(workspace, '群聊待办', 'todos.json')
  if (!existsSync(p)) return []
  try { return JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, '')).items ?? [] } catch { return [] }
})()
const after = buildPromptForTest(pre.kept, cfgFilter, openTodos)
const before = buildPromptLegacy(records, { ...cfg, prefilter: false }, openTodos)
const tok = (n) => Math.round(n / 1.5)   // 中文粗算：1 字 ≈ 0.6~0.7 token

console.log('\n=== 第②级：真实 prompt 体积（含规则 + 已知待办清单）===')
console.log(`旧版（改造前）：${before.chars} 字 ≈ ${tok(before.chars)} token —— ${records.length} 条记录各一条、已知待办带 evidence、pretty-print`)
console.log(`现在（预筛+压缩）：${after.chars} 字 ≈ ${tok(after.chars)} token —— ${after.stats.groups} 个会话合并、重复已去、已知待办只带 title/群/due`)
const saved = before.chars - after.chars
console.log(`省下：${saved} 字 ≈ ${tok(saved)} token（${before.chars > 0 ? ((saved / before.chars) * 100).toFixed(1) : '0.0'}%）`)
console.log(`其中"逐字重复"合并掉 ${after.stats.deduped} 条（${before.stats?.raw ?? records.length} 条记录 → ${after.stats.groups} 个会话）`)
console.log(`已知未完成待办 ${openTodos.filter((t) => !['done', 'ignored'].includes(String(t.status))).length} 条进了 prompt`)

const preview = (r, n = 90) => String(r?.text ?? r?.preview ?? '').replace(/\s+/g, ' ').slice(0, n)
console.log(`\n=== 送模型的候选（前 ${Math.min(show, pre.kept.length)} 条）===`)
for (const d of pre.decisions.filter((d) => !pre.dropped.includes(d.record)).slice(0, show)) {
  console.log(`  [${d.hits.join('+')}] ${d.record?.chat ?? ''} | ${preview(d.record)}`)
}
console.log(`\n=== 被筛掉的（前 ${Math.min(show, pre.dropped.length)} 条）===`)
for (const d of pre.decisions.filter((d) => pre.dropped.includes(d.record)).slice(0, show)) {
  console.log(`  [${d.hits.join('+') || '无命中'}] ${d.record?.chat ?? ''} | ${preview(d.record)}`)
}

// ⚠️ 漏抽风险：被筛掉但带"时间/请求"味道的行
const risky = pre.decisions.filter(
  (d) => pre.dropped.includes(d.record) &&
    /[前截]止|之前|以前|请|务必|记得|别忘|全体|@/.test(String(d.record?.text ?? d.record?.preview ?? '')),
)
console.log(`\n=== ⚠️ 被筛掉但含"像待办"字样的行（漏抽风险，共 ${risky.length} 条）===`)
for (const d of risky.slice(0, show)) console.log(`  ${d.record?.chat ?? ''} | ${preview(d.record, 120)}`)
if (risky.length === 0) console.log('  （无）')

if (has('--prompt')) {
  console.log('\n=== 完整 prompt ===')
  console.log(after.prompt)
}
