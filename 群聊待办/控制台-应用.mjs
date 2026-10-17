// 控制台-应用.mjs —— 应用「控制台」导出的改动补丁（JSON 一律 Node 写，规避 PS 写 JSON 的 BOM/单元素数组坑）
//
// 用法：node 控制台-应用.mjs <补丁.json>
// ⚠️ 2026-10-15 深夜重写（外部审查 F6）：原来边读边写——先写运行配置.json 再读提醒配置.json，
//    后者缺守卫/读失败 → 抛错时前一个已落盘 → "配置改了一半、计划任务没改"，用户还看到"任务未改动"。
//    现在**两段式**：① 全部读入 + 校验（任何失败在写盘前退出，不落半个字节）② 全部备份 + 统一落盘。
// 退出码：0 = 有改动已应用 / 2 = 补丁里没有需要应用的改动（字段全空或与现状相同） / 1 = 出错（未写任何文件）
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const ws = resolve(here, '..')   // 开发=工作区根；部署后=安装目录

const patchPath = process.argv[2]
if (!patchPath) { console.error('用法：node 控制台-应用.mjs <补丁.json>'); process.exit(1) }
let p
try {
  p = JSON.parse(readFileSync(patchPath, 'utf8').replace(/^\uFEFF/, ''))
} catch (e) {
  console.error('补丁不是合法 JSON：' + e.message)
  process.exit(1)
}
if (!p || p.kind !== 'console-changes') { console.error('这不是控制台的改动补丁（kind != console-changes）'); process.exit(1) }

const stamp = new Date().toISOString().replace(/[:.]/g, '-')
const read = (pth) => JSON.parse(readFileSync(pth, 'utf8').replace(/^\uFEFF/, ''))
const readOr = (pth, fallback) => (existsSync(pth) ? read(pth) : fallback)

// ────────── ① 全部读入 + 校验（不写任何东西） ──────────
const RANGES = { collectMinutes: [15, 720], remindMinutes: [1, 60], selfcheckMinutes: [30, 1440] }
const iv = {}
if (p.intervals) {
  for (const k of Object.keys(RANGES)) {
    const v = p.intervals[k]
    if (v === undefined || v === null) continue
    const n = Number(v)
    if (!Number.isInteger(n) || n < RANGES[k][0] || n > RANGES[k][1]) {
      console.error('周期数值不合法：' + k + '=' + v + '（允许 ' + RANGES[k][0] + '~' + RANGES[k][1] + '）')
      process.exit(1)
    }
    iv[k] = n
  }
}

const writes = []   // { file, content, label }

const runCfgFile = join(ws, 'dsh-接入', '运行配置.json')
const runCfg = readOr(runCfgFile, {})
const runCfgNew = { ...runCfg, ...iv }
if (Object.keys(iv).length > 0 && JSON.stringify(runCfgNew) !== JSON.stringify(runCfg)) {
  writes.push({ file: runCfgFile, content: runCfgNew, label: '运行配置.json：' + JSON.stringify(iv) })
}

if (p.wecomWebhook !== undefined) {
  const f = join(ws, 'dsh-接入', '提醒配置.json')
  const cur = read(f)   // 缺文件/坏 JSON 都在这里抛 → 此时还没有任何写盘（F6 的修复核心）
  cur.phonePush = cur.phonePush || {}
  cur.phonePush.wecom = cur.phonePush.wecom || {}
  cur.phonePush.wecom.webhook = String(p.wecomWebhook || '').trim()
  writes.push({ file: f, content: cur, label: '提醒配置.json：webhook ' + (cur.phonePush.wecom.webhook ? '已更新' : '已清空（兜底停用）') })
}

if (Array.isArray(p.aliases)) {
  for (const rel of ['wx-采集器/config.json', 'dsh-msg-memo/config.json']) {
    const f = join(ws, ...rel.split('/'))
    if (!existsSync(f)) { console.error(rel + ' 不存在，中止（避免别名只写一半）'); process.exit(1) }
    const cur = read(f)
    cur.myAliases = p.aliases.map(String)
    writes.push({ file: f, content: cur, label: rel + '：myAliases = ' + p.aliases.join(', ') })
  }
}
if (Array.isArray(p.whitelistWx)) {
  const f = join(ws, 'wx-采集器', 'config.json')
  if (!existsSync(f)) { console.error('wx-采集器/config.json 不存在，中止'); process.exit(1) }
  const cur = read(f)
  cur.groupWhitelist = p.whitelistWx.map(String)
  writes.push({ file: f, content: cur, label: 'wx-采集器/config.json：groupWhitelist = ' + (p.whitelistWx.join(', ') || '（空=不过滤）') })
}
if (Array.isArray(p.whitelistQq)) {
  const f = join(ws, 'wx-采集器', 'config-qq.json')
  if (!existsSync(f)) { console.error('wx-采集器/config-qq.json 不存在，中止'); process.exit(1) }
  const cur = read(f)
  cur.groupWhitelist = p.whitelistQq.map(String)
  writes.push({ file: f, content: cur, label: 'wx-采集器/config-qq.json：groupWhitelist = ' + (p.whitelistQq.join(', ') || '（空）') })
}

// ⚠️ 2026-10-16 修：只改「开机自启」的补丁不含任何 JSON 写入（那一步由 控制台.ps1 的 PowerShell 侧做），
//   原来会在这里 exit 2 早退 → 后面的开机自启步骤永远跑不到（实测：勾了自启、点确定、结果什么都没发生）。
const psSideChanges = (p.autostartDsh === true || p.autostartDsh === false) ? 1 : 0
if (writes.length === 0 && psSideChanges === 0) {
  console.log('补丁里没有需要应用的改动（字段全空、或与现状相同）→ 什么都没写。')
  process.exit(2)
}
if (writes.length === 0) {
  console.log('本次只有「开机自启」这一类改动（不需要写 JSON，由 PowerShell 侧应用）。')
  process.exit(0)
}

// ────────── ② 统一落盘（先备份全部，再逐个写；失败也只会停在已写项，且清单已打印） ──────────
for (const w of writes) {
  if (existsSync(w.file)) copyFileSync(w.file, `${w.file}.bak-console-${stamp}`)
}
let done = 0
for (const w of writes) {
  writeFileSync(w.file, JSON.stringify(w.content, null, 2) + '\n', 'utf8')   // 无 BOM
  done++
}
console.log('已应用 ' + done + ' 处：')
writes.forEach((w) => console.log('  · ' + w.label))
console.log('备份后缀：.bak-console-' + stamp)
process.exit(0)
