// 改状态.mjs —— 微信"完成反馈"的确定性执行器（群聊待办）
//
// 为什么存在：用户在微信里说"第3条做完了"时，DSH agent 会来改 todos.json。
// 但如果让 agent 自己（用 PowerShell 或任何方式）重写这个 JSON，历史坑很多：
//   · PS 5.1 ConvertTo-Json 会写 UTF-8 BOM + 把单元素数组写成对象 → 插件读成空 → 待办被清空（实测丢过 2 条）
//   · agent 手写 JSON 可能丢字段/改错状态
// 所以把"改状态"收敛成这一个脚本：只做一件事，安全地读改写 + 用插件自己的 renderMemo 重建 MEMO.md。
//
// 用法（node 绝对路径，见 dsh-接入\提醒配置.json 的 wechat.nodePath）：
//   node 改状态.mjs list               列出未完成待办（编号 = "第N条"的 N）
//   node 改状态.mjs done    <查询词>    标记完成
//   node 改状态.mjs ignored <查询词>    忽略
//   node 改状态.mjs open    <查询词>    重新打开（撤销完成/忽略）
//   node 改状态.mjs add     <标题> [--due <ISO时间>]   新增待办（2026-10-16 起支持，手动加提醒用）
// <查询词> 三种写法：
//   数字（如 3）        = list 里的第 N 条（1 起）
//   id 或 id 前缀       = 如 tg-20261014-001
//   标题关键词          = 标题包含该词；命中多条时列候选退出码 2，绝不猜
//
// 退出码：0 成功 / 2 有歧义（打印候选）/ 1 没找到或出错（打印原因）
// 改动前自动备份 todos.json / MEMO.md → *.bak-wx-<时间戳>（和看板一致的习惯）
// 测试可用环境变量 DSH_TODO_DIR 指向一个临时目录（真实数据零风险）。
import { copyFileSync, existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))
const ws = resolve(here, '..')
// 默认就在 群聊待办\ 目录里；测试时用 DSH_TODO_DIR 覆盖
const todoDir = process.env.DSH_TODO_DIR || here
const todosPath = join(todoDir, 'todos.json')
const memoPath = join(todoDir, 'MEMO.md')
const lockPath = join(todoDir, '改状态.lock')
const pluginIndex = join(ws, 'dsh-msg-memo', 'lib', 'index.js')

const argv = process.argv.slice(2)
const CMD = (argv[0] || '').toLowerCase()
const QUERY = (argv.slice(1).join(' ')).trim()   // 允许"报名表"或"示例学校新闻 电视台"这类带空格的
const VALID_CMDS = new Set(['list', 'done', 'ignored', 'open', 'add'])

// add 的参数：标题允许空格；`--due <ISO时间>`（形如 2026-10-30T14:00:00+08:00）为可选截止时间
let ADD_TITLE = ''
let ADD_DUE = null
if (CMD === 'add') {
  const i = QUERY.lastIndexOf(' --due ')
  if (i >= 0) { ADD_TITLE = QUERY.slice(0, i).trim(); ADD_DUE = QUERY.slice(i + ' --due '.length).trim() }
  else ADD_TITLE = QUERY
}

const nowIso = () => {
  const d = new Date()
  const off = -d.getTimezoneOffset()
  const pad = (n) => String(Math.abs(n)).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${off >= 0 ? '+' : '-'}${pad(off / 60)}:${pad(off % 60)}`
}

function readTodos() {
  const raw = readFileSync(todosPath, 'utf8').replace(/^\uFEFF/, '')   // 去 BOM
  const doc = JSON.parse(raw)
  // 容忍"单元素数组被写成对象"（PowerShell 老坑）
  const items = Array.isArray(doc?.items) ? doc.items : doc?.items && typeof doc.items === 'object' ? [doc.items] : []
  return { doc, items }
}

/** 用插件自己的 renderMemo 重建 MEMO.md（vm 抽真实源码，格式和插件一致） */
function renderMemoLikePlugin(items) {
  const src = readFileSync(pluginIndex, 'utf8')
  const start = src.indexOf('function renderMemo(items) {')
  if (start < 0) throw new Error('插件源码里找不到 renderMemo(items)')
  let depth = 0
  let end = -1
  for (let i = src.indexOf('{', start); i < src.length; i += 1) {
    if (src[i] === '{') depth += 1
    else if (src[i] === '}') { depth -= 1; if (depth === 0) { end = i + 1; break } }
  }
  const fnSrc = src.slice(start, end)
  const sandbox = { console, Date, Number, String, Array, Object, JSON, Boolean }
  vm.createContext(sandbox)
  vm.runInContext(`${fnSrc}\nthis.renderMemo = renderMemo`, sandbox)
  return sandbox.renderMemo(items)
}

const CLOSED = new Set(['done', 'ignored', 'expired'])
const isActive = (it) => it && !CLOSED.has(String(it.status))

/** 未完成列表的编号顺序 = list 命令打印的顺序（due 升序，无 due 排后；再按 createdAt） */
function activeSorted(items) {
  return items.filter(isActive).sort((a, b) => {
    const ta = a.due ? Date.parse(a.due) : Infinity
    const tb = b.due ? Date.parse(b.due) : Infinity
    if (ta !== tb) return ta - tb
    const ca = a.createdAt ? Date.parse(a.createdAt) : 0
    const cb = b.createdAt ? Date.parse(b.createdAt) : 0
    return ca - cb
  })
}

function fmtDue(it) {
  if (!it.due) return '无截止'
  const d = new Date(it.due)
  if (Number.isNaN(d.getTime())) return String(it.due)
  const pad = (n) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/** 相对今天的天数提示（自动取本机日期，2026-10-16 用户要求"显示还有几天"） */
function daysHint(it) {
  if (!it.due) return ''
  const d = new Date(it.due)
  if (Number.isNaN(d.getTime())) return ''
  const now = new Date()
  const day0 = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate())
  const diff = Math.round((day0(d) - day0(now)) / 86400000)
  if (diff > 0) return `｜还有 ${diff} 天`
  if (diff === 0) return '｜今天到期'
  return `｜已过期 ${-diff} 天`
}

function clip(s, n) {
  s = String(s ?? '')
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

/** 截断展示；但"请假/去不了"类标题不省略（2026-10-16 用户要求） */
function clipSmart(s, n) {
  s = String(s ?? '')
  if (/请假|去不了|无法到场|缺席/.test(s)) return s
  return clip(s, n)
}

function lineOf(it, idx) {
  const src = it.source && it.source.chat ? `（${it.source.chat}）` : ''
  return `${idx !== undefined ? idx + 1 + '. ' : ''}${clipSmart(it.title, 36)}｜${fmtDue(it)}${daysHint(it)}${src}`
}

// ── 单实例锁：改状态是"读-改-写"，两个并发实例可能互相覆盖 ──
// 与 提醒器.ps1 的 reminder.lock 同一思路；>60 秒视为上次崩了，接管。
// ⚠️ 只在拿到锁之后才允许 process.exit 之外的正常路径；释放锁必须发生在退出之前
//   （Node 的 process.exit 不执行 finally，所以锁的释放靠 run() 返回 + 外层 finally）。
function acquireLock() {
  try {
    writeFileSync(lockPath, `${Date.now()}\n`, { flag: 'wx' })
    return true
  } catch (e) {
    if (e.code === 'EEXIST' && existsSync(lockPath)) {
      try {
        const ageMs = Date.now() - Number(String(readFileSync(lockPath, 'utf8')).trim())
        if (Number.isFinite(ageMs) && ageMs > 60000) {
          writeFileSync(lockPath, `${Date.now()}\n`, { flag: 'w' })
          return true
        }
      } catch { /* fallthrough */ }
      console.error('另一个改状态实例还在跑（改状态.lock）→ 稍等几秒再试')
      process.exit(1)
    }
    throw e
  }
}
function releaseLock() {
  try { if (existsSync(lockPath)) unlinkSync(lockPath) } catch { /* 不致命 */ }
}

if (!VALID_CMDS.has(CMD)) {
  console.error('用法：\n  node 改状态.mjs list\n  node 改状态.mjs done <编号|id|关键词>\n  node 改状态.mjs ignored <编号|id|关键词>\n  node 改状态.mjs open <编号|id|关键词>\n  node 改状态.mjs add <标题> [--due <ISO时间>]')
  process.exit(1)
}
if (CMD !== 'list' && !QUERY) {
  console.error(`${CMD} 需要一个查询词：编号（list 里的第 N 条）/ id / 标题关键词`)
  process.exit(1)
}

/** 返回退出码；锁的获取/释放都在外面，保证 process.exit 之前一定已释放 */
function run() {
  const { doc, items } = readTodos()
  const act = activeSorted(items)

  // ── list：只读，不拿锁 ──
  if (CMD === 'list') {
    if (act.length === 0) {
      console.log(`没有未完成的待办。（共 ${items.length} 条，${items.length - act.length} 条已关闭）`)
      return 0
    }
    console.log(`未完成 ${act.length} 条：`)
    act.forEach((it, i) => console.log(lineOf(it, i)))
    const doneN = items.length - act.length
    if (doneN > 0) console.log(`另外 ${doneN} 条已完成/已忽略。`)
    console.log('回复"完成+编号"（如"完成 3"）或"完成+关键词"标记完成；"忽略+编号"表示这条不算。')
    return 0
  }

  // ── add：新增待办（手动加提醒；与下方改状态一样走 备份→渲染→Node 落盘，不带 BOM）──
  if (CMD === 'add') {
    if (!ADD_TITLE) { console.error('add 需要标题：node 改状态.mjs add <标题> [--due <ISO时间>]'); return 1 }
    if (ADD_DUE && Number.isNaN(Date.parse(ADD_DUE))) {
      console.error(`--due 时间解析不了："${ADD_DUE}"（建议形如 2026-10-30T14:00:00+08:00）`)
      return 1
    }
    const same = act.find((x) => String(x.title || '').trim() === ADD_TITLE)
    if (same) { console.error(`已经有一条未完成的同名待办：${clipSmart(same.title, 50)}（编号见 list）`); return 1 }
    const pad2 = (n) => String(n).padStart(2, '0')
    const dNow = new Date()
    const prefix = `tg-${dNow.getFullYear()}${pad2(dNow.getMonth() + 1)}${pad2(dNow.getDate())}-`
    let maxSeq = 0
    for (const x of items) {
      if (x.id && x.id.startsWith(prefix)) {
        const n = Number(x.id.slice(prefix.length))
        if (Number.isInteger(n) && n > maxSeq) maxSeq = n
      }
    }
    const newItem = {
      id: `${prefix}${String(maxSeq + 1).padStart(3, '0')}`,
      title: ADD_TITLE,
      who: '我',
      due: ADD_DUE || null,
      due_kind: ADD_DUE ? 'absolute' : 'none',
      priority: 'normal',
      confidence: 0.9,
      status: 'open',
      source: { chat: '待办管家', sender: '<用户名>', ts: nowIso(), msgId: '' },
      evidence: '微信「待办管家」手动添加（用户要求设提醒）',
      createdAt: nowIso()
    }
    items.push(newItem)
    doc.updatedAt = nowIso()
    const stamp2 = new Date().toISOString().replace(/[:.]/g, '-')
    copyFileSync(todosPath, `${todosPath}.bak-wx-${stamp2}`)
    if (existsSync(memoPath)) copyFileSync(memoPath, `${memoPath}.bak-wx-${stamp2}`)
    const memoText2 = renderMemoLikePlugin(items)
    writeFileSync(todosPath, JSON.stringify(doc, null, 2), 'utf8')
    writeFileSync(memoPath, memoText2, 'utf8')
    console.log(`已添加 ✅：${clipSmart(newItem.title, 50)}`)
    console.log(`（截止 ${fmtDue(newItem)}；MEMO.md 已同步重建）`)
    return 0
  }

  // ── 解析查询词 ──
  let target = null
  if (/^\d+$/.test(QUERY)) {
    const idx = Number(QUERY) - 1
    if (idx >= 0 && idx < act.length) target = act[idx]
    else {
      console.error(`编号 ${QUERY} 超出范围：当前未完成只有 ${act.length} 条。当前列表：`)
      act.forEach((it, i) => console.error(lineOf(it, i)))
      return 1
    }
  } else {
    // 先精确 id，再 id 前缀，再标题包含
    const byId = items.find((x) => x.id === QUERY)
    const byPrefix = byId ? [] : items.filter((x) => x.id && x.id.startsWith(QUERY))
    const byTitle = (byId || byPrefix.length)
      ? []
      : items.filter((x) => String(x.title || '').toLowerCase().includes(QUERY.toLowerCase()))
    const cands = byId ? [byId] : byPrefix.length ? byPrefix : byTitle
    if (cands.length === 0) {
      console.error(`没找到和"${QUERY}"匹配的待办。当前未完成：`)
      act.forEach((it, i) => console.error(lineOf(it, i)))
      return 1
    }
    if (cands.length > 1) {
      console.error(`"${QUERY}"匹配到 ${cands.length} 条，请说具体一点：`)
      cands.forEach((it, i) => console.error(lineOf(it, i)))
      return 2
    }
    target = cands[0]
  }

  const newStatus = CMD === 'open' ? 'open' : CMD   // done / ignored / open
  if (String(target.status) === newStatus) {
    console.log(`这条已经是该状态：${clipSmart(target.title, 50)}`)
    return 0
  }

  // ── 备份 → 改 → 写回（全程 Node，不带 BOM）──
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  copyFileSync(todosPath, `${todosPath}.bak-wx-${stamp}`)
  if (existsSync(memoPath)) copyFileSync(memoPath, `${memoPath}.bak-wx-${stamp}`)

  target.status = newStatus
  if (newStatus === 'open') delete target.closedAt
  else target.closedAt = nowIso()
  doc.updatedAt = nowIso()
  // ⚠️ 2026-10-15 深夜修（外部审查 F17）：先渲染 MEMO、再落盘——渲染失败时 todos 不会被改一半
  const memoText = renderMemoLikePlugin(items)
  writeFileSync(todosPath, JSON.stringify(doc, null, 2), 'utf8')
  writeFileSync(memoPath, memoText, 'utf8')

  const label = { done: '已完成 ✅', ignored: '已忽略', open: '已重新打开' }[newStatus]
  console.log(`${label}：${clipSmart(target.title, 50)}`)
  console.log(`（原截止 ${fmtDue(target)}；MEMO.md 已同步重建）`)
  return 0
}

// 结构化退出：先放锁，再 process.exit（Node 的 process.exit 不跑 finally）
let code = 1
if (CMD === 'list') {
  try { code = run() } catch (e) { console.error('list 失败：' + (e && e.message ? e.message : e)); code = 1 }
} else {
  acquireLock()   // 抢不到锁时在这里 process.exit(1)（此时还没拿到锁，不需要释放）
  try { code = run() } catch (e) { console.error('改状态失败：' + (e && e.message ? e.message : e)); code = 1 } finally { releaseLock() }
}
process.exit(code)
