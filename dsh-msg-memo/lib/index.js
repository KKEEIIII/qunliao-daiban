/**
 * dsh-msg-memo —— 把微信截图采集器的结果变成待办
 *
 * 链路：采集器（截图+OCR）→ <workspace>/wx-采集器/spool/messages-*.jsonl
 *       → 本插件定时读增量 → ctx.llm 抽待办 → <workspace>/群聊待办/todos.json + MEMO.md
 *       → 提醒器.ps1（计划任务）读 todos.json 弹 Windows 气泡 + 推手机
 *
 * 只依赖 ctx.llm（和 ctx.logger），不引入任何第三方包，避免 DSH 升级带来的 peerDependencies 问题。
 *
 * @module @local/dsh-msg-memo
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-msg-memo'

/** 硬依赖：模型的流式接口。 */
export const inject = ['llm']

const here = dirname(fileURLToPath(import.meta.url))
const pluginRoot = join(here, '..')

/** 最近一次 buildPrompt 里"消息段"的体积统计（给离线试跑工具用） */
let promptStats = { raw: 0, groups: 0, deduped: 0, chars: 0 }

/** 离线量一次 prompt 体积：不调模型、不写任何文件 */
export function buildPromptForTest(records, cfg = {}, existing = []) {
  const cfgMerged = { ...DEFAULTS, ...cfg }
  const prompt = buildPrompt(records, cfgMerged, existing)
  return { prompt, stats: promptStats, chars: prompt.length }
}

/**
 * 旧版 prompt（压缩改造之前的样子）：一条记录一个对象、已知待办带 evidence、pretty-print。
 * **只给测试/对比用**，主流程不会走到这里 —— 留着是为了随时量出"压缩到底省了多少"。
 */
export function buildPromptLegacy(records, cfg = {}, existing = []) {
  let extra = ''
  try {
    const p = join(pluginRoot, 'prompt-extra.txt')
    if (existsSync(p)) extra = readFileSync(p, 'utf8').trim()
  } catch { /* 忽略 */ }
  const items = records.map((r) => {
    if (r.kind === 'chat') {
      return { chat: r.chat, expected: r.expected, verified: r.verified, text: String(r.text ?? '').slice(0, 4000) }
    }
    return { chat: r.chat, preview: r.preview }
  })
  const priorOpen = (Array.isArray(existing) ? existing : [])
    .filter((it) => !['done', 'ignored'].includes(String(it?.status)))
    .slice(-40)
    .map((it) => ({ title: String(it?.title ?? ''), 群: String(it?.chat ?? it?.source?.chat ?? '') }))
  const out = [
    '你是待办抽取器。下面是从微信/QQ「截图 + OCR」采集到的群聊新消息。',
    'OCR 可能有错字、字间多余空格，请按语义纠正后再判断；不要照抄错字。',
    '',
    '输出要求：只输出一个 JSON 对象，不要解释、不要 markdown 代码块，格式必须是：',
    '{"todos":[{"title":"事项","who":"负责人或空","due":"ISO8601 或 null","due_kind":"absolute|relative|none",' +
      '"priority":"high|normal|low","confidence":0.0,"chat":"来源群","sender":"发言人","evidence":"原文句子"}]}',
    '',
    ...(priorOpen.length > 0
      ? ['已知未完成待办（**已经在清单里了，不要把同一件事再输出一次**）：', JSON.stringify(priorOpen, null, 0), '']
      : []),
    '规则：',
    '1. 只有明确的任务、承诺、请求或带时间点的约定才算待办；闲聊、表情、通知、转发链接、广告不算。',
    '2. 相对时间（"明天下午三点""下周一"）按下面的当前时间换算成绝对时间（时区 Asia/Shanghai）；换不出来的 due 填 null。',
    '3. confidence 如实填 0~1：拿不准就低，不要一律给高分。',
    '4. 同一条待办只输出一次；没有待办就输出 {"todos":[]}。',
    '5. 与"已知未完成待办"实质相同的，**不要输出**。',
    ...(extra ? ['', extra] : []),
    '',
    `当前时间：${nowIso()}`,
    '',
    '消息（JSON）：',
    JSON.stringify(items, null, 1),
  ].join('\n')
  return { prompt: out, chars: out.length }
}

const DEFAULTS = {
  workspaceDir: process.cwd(),
  intervalMs: 600000,
  firstRunDelayMs: 20000,
  provider: 'deepseek-account',
  model: 'deepseek-flash',
  maxRecordsPerRun: 40,
  timeoutMs: 180000,
  // 本地预筛：组 prompt 前先用规则挑出"候选行"，其余只存档不送模型（省 token、少隐私外传、可核对）
  prefilter: true,
  // 被筛掉的原文存这里，随时可以捞回来看（默认 off 的审计开关见 prefilterDumpDropped）
  prefilterLog: 'prefilter-dropped.jsonl',
  prefilterDumpDropped: true,
  prefilterSnapshot: 'prefilter-log.jsonl',
}

function loadConfig() {
  const p = join(pluginRoot, 'config.json')
  if (!existsSync(p)) return {}
  try {
    // 去 BOM：用户用记事本/PowerShell 手改 config.json 时经常带上 BOM，不去的话 JSON.parse 抛错 → 静默回默认值
    return JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''))
  } catch (error) {
    console.warn('[dsh-msg-memo] config.json 解析失败，用默认值：', error?.message ?? error)
    return {}
  }
}

function readJson(path, fallback) {
  if (!existsSync(path)) return fallback
  try {
    // 去 BOM：PowerShell 的 Set-Content -Encoding UTF8 会写 BOM，JSON.parse 遇到 BOM 会直接抛错，
    // 一旦回退成 fallback，已有待办就会被当成空、下一轮合并时全部丢掉（实测踩过）。
    return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''))
  } catch {
    return fallback
  }
}

function writeJson(path, value) {
  writeFileSync(path, JSON.stringify(value, null, 2), 'utf8')
}

const norm = (s) => String(s ?? '').replace(/\s+/g, '')

// ───────────────────────── 本地预筛（三级抽取的第 ① 级：不烧 token 的规则层）─────────────────────────
// 目的：spool 里绝大多数是闲聊/通知/图片预览，全量送模型既贵又没必要。
// 做法：先用规则挑出"看起来像我可能要行动的事"的候选行，只把候选送模型；其余只存不送。
// 代价：**漏掉的永远不会进模型**。所以每个候选都记命中理由，被丢掉的原文写进
//       群聊待办/prefilter-dropped.jsonl（可核对、可反悔），并在插件日志里写明筛掉几条 + 漏筛风险。
const PREFILTER_PATTERNS = {
  // 点名"我"：这里只放**通用**信号（@我/@all/@全体…）。
  // ⚠️ **不要把自己的昵称写死在这里**：换个人用（昵称不是 <用户名>）就永远认不出 @他，
  //    预筛会把"点名他的待办"整条丢掉。具体昵称由 mentionList() 从 config 里读。
  mention: ['@我', '@all', '@全体成员', '@所有人', '全体成员', '所有人'],
  // 时间词：有截止时间才有"待办"的样子
  time: [
    '今天', '明天', '后天', '今晚', '今早', '上午', '下午', '晚上', '中午', '早上',
    '周一', '周二', '周三', '周四', '周五', '周六', '周日', '周天', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六',
    '下周', '本周', '这周', '下个', '截至', '截止', '之前', '以前', '开始', '前完成', '前提交', '号前', '点前', '前发', '前交',
  ],
  // 任务动词：有人要做事。
  // ⚠️ 这里**不要放太泛的单字**（交/报/开/到/带/发/请/回…）：实测 `回` 一个字就把
  // `示例群B / 抖高到部倩倩 / 0 / 回` 这种纯闲聊判成候选，预筛等于没筛（98% 都命中）。
  // 宁可宽一点漏进模型，也不要"看起来很勤快但实际没筛掉东西"。
  action: [
    '参加', '报名', '回复', '领回', '领取', '填写', '填表', '提交', '汇总', '统计', '核对', '确认',
    '记得', '别忘', '务必', '请假', '值班', '加班', '准备', '安排', '负责', '截止', '截至',
    '会议', '培训', '活动', '通知', '要求', '名单', '作业', '材料', '报名表',
  ],
  // 时间形态（正则，跑在"压掉空格"的文本上）
  timeRe: [
    /\d{1,2}\s*[：:]\s*\d{2}/,              // 14:30 / 14：30
    /\d{1,2}\s*月\s*\d{1,2}\s*[日号]/,      // 10月19日 / 10月19号
    /\d{1,2}\s*[日号]/,                     // 19日 / 19号
    /\d{1,2}\s*点/,                         // 16点 / 7点半
    /[上下前后]\s*[午晚早]/,                // 下午 / 上午 / 晚上
  ],
  // 纯通知/广告：即使命中上面的词也不值得打扰模型
  negative: ['撤回了一条消息', '拍了拍'],
  // 只有"整条就是这个"才算噪声：正文里**出现** [图片] 不能当噪声丢掉 ——
  // 实测待办常长这样：「@所有人 明天前报名 [图片]」，按"包含即丢"会直接把待办扔了。
  noiseTags: ['[图片]', '[表情]', '[链接]', '[视频]', '[语音]', '[小程序]', '[文件]'],
}

/**
 * "点名我"的候选词 = 通用词（@我/@all/…）+ **用户自己的昵称**。
 * 昵称优先读插件 config.json 的 `myAliases`，其次读微信/QQ 采集器 config 里的同名字段
 * （用户通常只在采集器那边填过一次）。结果缓存，避免每条记录都读盘。
 * **这是"能给不同人用"的关键**：换个人只要把 myAliases 填对就行，不用改代码。
 */
let _aliasCache = null
function mentionList(cfg) {
  if (_aliasCache) return _aliasCache
  const set = new Set(PREFILTER_PATTERNS.mention)
  const add = (v) => {
    if (Array.isArray(v)) { for (const x of v) add(x); return }
    const s = String(v ?? '').trim()
    if (s.length >= 2) { set.add(s); set.add('@' + s) }
  }
  add(cfg?.myAliases)
  const ws = cfg?.workspaceDir ?? process.cwd()
  for (const rel of ['wx-采集器\\config.json', 'wx-采集器\\config-qq.json']) {
    try {
      const p = join(ws, rel)
      if (existsSync(p)) add(JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, '')).myAliases)
    } catch { /* 读不到就算了 */ }
  }
  _aliasCache = [...set]
  return _aliasCache
}

// 一条记录是否值得送模型：返回 { keep, hits }
function isCandidateRecord(record, cfg) {
  const text = String(record?.text ?? record?.preview ?? '').replace(/\s+/g, '')
  if (!text) return { keep: false, hits: ['empty'] }
  const lower = text.toLowerCase()
  const hits = []
  for (const [key, words] of Object.entries(PREFILTER_PATTERNS)) {
    if (key === 'timeRe' || key === 'negative' || key === 'noiseTags') continue
    // mention 用"通用词 + 用户昵称"这份动态清单
    const list = key === 'mention' ? mentionList(cfg) : words
    if (list.some((w) => lower.includes(String(w).toLowerCase()))) hits.push(key)
  }
  if (PREFILTER_PATTERNS.timeRe.some((re) => re.test(text))) hits.push('timeRe')
  // 纯噪声：撤回提示、拍一拍，或整条只剩一个图片/表情/链接占位符
  const bare = PREFILTER_PATTERNS.noiseTags.reduce((s, tag) => s.split(tag).join(''), text)
  if (PREFILTER_PATTERNS.negative.some((w) => text.includes(w)) || !bare) return { keep: false, hits: ['noise'] }
  // 只采预览行（会话列表那一行）的群：预览很短，漏一条就整群看不到 → 名单纯粹的预览行一律放过。
  if (record?.kind === 'preview' && hits.length === 0) return { keep: true, hits: ['preview-only'] }
  return { keep: hits.length > 0, hits }
}

/**
 * 本地预筛：把新记录分成"送模型"和"只存档"两份。
 *
 * 注意 `verified=false` 的聊天正文**不算预筛命中**，单独放 `droppedUnverifiedRecords`：
 * 它由 compactRecords 统一拦下（那边会计数、会写进 prompt 说明）。
 * 如果这里先把它当"预筛筛掉"，compactRecords 永远数不到它，审计里也只剩一个空的 hits（实测踩过）。
 * @returns {{kept:any[], dropped:any[], droppedUnverifiedRecords:any[], decisions:Array<{record:any,hits:string[]}>, enabled:boolean}}
 */
function prefilterRecords(records, cfg) {
  const on = cfg?.prefilter !== false
  const droppedUnverifiedRecords = []
  if (!on) {
    return {
      kept: records,
      dropped: [],
      droppedUnverifiedRecords,
      decisions: records.map((r) => ({ record: r, hits: ['prefilter-off'] })),
      enabled: false,
    }
  }
  const kept = []
  const dropped = []
  const decisions = []
  for (const r of records) {
    if (String(r?.kind ?? 'chat') === 'chat' && r?.verified === false) {
      droppedUnverifiedRecords.push(r)
      decisions.push({ record: r, hits: ['unverified'] })
      continue
    }
    const { keep, hits } = isCandidateRecord(r, cfg)
    decisions.push({ record: r, hits })
    if (keep) kept.push(r)
    else dropped.push(r)
  }
  return { kept, dropped, droppedUnverifiedRecords, decisions, enabled: true }
}

/** 把被筛掉的原文追加到 JSONL（可核对 / 可捞回），写不了就算了，不影响主流程 */
function appendPrefilterAudit(path, dropped, hitsOf) {
  if (!path || dropped.length === 0) return 0
  try {
    const lines = dropped.map((r) =>
      JSON.stringify({
        ts: nowIso(),
        chat: String(r?.chat ?? ''),
        kind: String(r?.kind ?? ''),
        source: String(r?.source ?? ''),
        chars: String(r?.text ?? r?.preview ?? '').length,
        hits: hitsOf(r),
        text: String(r?.text ?? r?.preview ?? '').slice(0, 2000),
      }),
    )
    appendFileSync(path, lines.join('\n') + '\n', 'utf8')
    return dropped.length
  } catch {
    return 0
  }
}

// 归一化到"只留中日韩文字+字母数字"，用于"同一条消息被 OCR 读成两种样子"时的模糊去重。
// 例：'示例群A（52）' 与 '示例群A' 归一后是 '级人工智能班' vs '级人工智能班'
const normLoose = (s) =>
  String(s ?? '')
    .replace(/[^\u4e00-\u9fff\u3040-\u30ffa-zA-Z0-9]/g, '')
    .replace(/\d+/g, '')

function editDistance(a, b) {
  const n = a.length
  const m = b.length
  if (n === 0) return m
  if (m === 0) return n
  let prev = Array.from({ length: m + 1 }, (_, j) => j)
  let cur = new Array(m + 1)
  for (let i = 1; i <= n; i += 1) {
    cur[0] = i
    for (let j = 1; j <= m; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    }
    const tmp = prev
    prev = cur
    cur = tmp
  }
  return prev[m]
}

// 同一个群的宽松判定：允许一个是另一个的前缀（OCR/不同来源会把群名截断，如 '示例部门' vs '示例部门示例群C'）
function sameChatLoose(chatA, chatB) {
  const ca = normLoose(chatA)
  const cb = normLoose(chatB)
  return ca.length >= 2 && cb.length >= 2 && (ca === cb || ca.startsWith(cb) || cb.startsWith(ca))
}

function sameDueExact(dueA, dueB) {
  return !!dueA && !!dueB && String(dueA) === String(dueB)
}

// 只有"同一个群 + 标题几乎一样"才算重复（宁可留一条重复的，也不要把两件不同的事并掉）。
// 标定记录（10 个用例 9 通过；唯一的漏判是"OCR 错字 + 模型改写"双重变形，属可接受）：
//   ✅ 合并：'参加示例部门见面会及培训' vs '参加示例部门见面及培训'（差 1 字）
//   ✅ 合并：'示例部门生见面会' vs '示例部门见面会'（OCR 错 1 字）
//   ✅ 合并：同群 + 截止时间完全相同 + 标题差 ≤3 字
//   ✅ 不合并：同群但两件不同的事（'参加示例活动A' vs '…会议（新区232）'，即使 due 相同）
function isNearDuplicate(titleA, chatA, dueA, titleB, chatB, dueB) {
  if (!sameChatLoose(chatA, chatB)) return false
  const ta = normLoose(titleA)
  const tb = normLoose(titleB)
  if (ta.length < 4 || tb.length < 4) return false
  if (ta === tb) return true
  const d = editDistance(ta, tb)
  if (d <= 2) return true // 只差 1~2 个字：OCR 抖动的典型量
  return sameDueExact(dueA, dueB) && d <= 3
}

// "同一件事、但新说法更具体"：同群 + 截止时间相同 + 旧标题是新标题的子串（新标题多了时间/地点）。
// 实测：模型会按提示词规则 5 把带新细节的同一条事再输出一次，标题从
//   '参加示例部门生见面会及第一次培训' → '参加示例部门生见面会及第一次培训（普照楼231，10月19日16点）'
// 这种情况不该新增一条，而应**就地升级**旧条目（保留更具体的说法，详情不丢）。
function findSupersetTarget(title, chat, due, items) {
  const na = normLoose(title)
  if (na.length < 4) return -1
  return items.findIndex((it) => {
    if (['done', 'ignored'].includes(String(it?.status))) return false
    if (!sameChatLoose(chat, it?.chat ?? it?.source?.chat ?? '')) return false
    if (!sameDueExact(due, it?.due)) return false
    const nb = normLoose(it?.title)
    return nb.length >= 4 && na.length > nb.length && na.includes(nb)
  })
}

function nowIso() {
  const d = new Date()
  const off = -d.getTimezoneOffset()
  const sign = off >= 0 ? '+' : '-'
  const pad = (n) => String(Math.abs(n)).padStart(2, '0')
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}${sign}${pad(off / 60)}:${pad(off % 60)}`
  )
}

/** 收集 spool 里游标之后的新记录 */
function collectNewRecords(paths, cursor, limit) {
  const out = []
  const next = { ...cursor }
  let files = []
  try {
    files = readdirSync(paths.spoolDir).filter((f) => f.startsWith('messages-') && f.endsWith('.jsonl'))
  } catch {
    return { records: [], next }
  }
  files.sort()
  for (const file of files) {
    const full = join(paths.spoolDir, file)
    let lines = []
    try {
      // 去 BOM：采集器用 `Add-Content -Encoding UTF8` 写 spool，文件**新建**时 PS 5.1 会带 BOM →
      // 首行的 JSON.parse 必然失败 → **整条记录被静默丢掉**（实测 messages-20261013 / 20261015 都是这样，
      // 后者只有 2 行，等于整个文件白采）。去 BOM 后这些记录还能正常进模型。
      const text = readFileSync(full, 'utf8').replace(/^\uFEFF/, '')
      lines = text.split('\n').filter((l) => l.trim() !== '')
    } catch {
      continue
    }
    const from = Number(cursor[file] ?? 0)
    const slice = lines.slice(from)
    next[file] = lines.length
    for (const line of slice) {
      try {
        out.push(JSON.parse(line))
      } catch {
        /* 坏行跳过 */
      }
      if (out.length >= limit) break
    }
    if (out.length >= limit) break
  }
  return { records: out, next }
}

/**
 * 逐个会话合并去重：同一个群在一轮里会被采集器**反复重采**（每轮都留着上次点开的那个会话，
 * 下次又读一遍同一屏），实测一天里 36 条记录有 6 条正文**逐字相同**、另有十几条只差一两个 OCR 字。
 * 全量喂模型等于白烧 token，还容易让模型把同一件事写成两条待办。
 *
 * 这里**只压掉"去掉空白后逐字相同"的重复文本**（安全），合并后按群给一条：
 *   { chat, texts:[…不同的说法…], kinds:[…], sources:[…], n }
 * 注意**不改写文本**：OCR 错字原样保留，模型照旧能看到原文（evidence 要逐字引用）。
 * 真正相近但不相同的说法（`某同学` vs `郭了毅`）不在这里合并 —— 交给模型 + 插件的模糊去重。
 */
function compactRecords(records) {
  const groups = new Map()
  let droppedUnverified = 0
  for (const r of records) {
    const chat = String(r?.chat ?? '').trim() || '(未知群)'
    const kind = String(r?.kind ?? 'chat')
    const text = String(r?.text ?? r?.preview ?? '').trim()
    if (!text) continue   // 空正文（OCR 没读到）不占用名额
    // 聊天正文只有 verified=true 才敢送模型：正文的群名是靠"点开后的聊天头部"认出来的，
    // 头部没认出来（verified=false）时这条正文可能属于**另一个群**（历史踩过：点串行 → 规则用错群），
    // 送进去等于制造"张冠李戴"的错误待办。预览行（会话列表那一行）自带群名，不看 verified。
    if (kind === 'chat' && r?.verified === false) {
      droppedUnverified += 1
      continue
    }
    const key = norm(chat)
    let g = groups.get(key)
    if (!g) {
      g = { chat, kind, texts: [], n: 0, deduped: 0, seen: new Set() }
      groups.set(key, g)
    }
    g.n += 1
    const marker = norm(text)
    if (g.seen.has(marker)) {
      g.deduped += 1
      continue
    }
    g.seen.add(marker)
    g.texts.push(text.slice(0, 4000))
  }
  const out = [...groups.values()].map((g) => {
    const { seen, ...rest } = g
    return rest
  })
  return {
    groups: out,
    raw: records.length,
    deduped: out.reduce((n, g) => n + g.deduped, 0),
    droppedUnverified,
    chars: out.reduce((n, g) => n + g.texts.join('').length, 0),
  }
}

/**
 * 组 prompt 用的"消息"段：一行一个群（`texts` 用内联数组，避免 JSON.stringify(indent) 给每个字符串
 * 都塞换行 + 缩进 —— 实测那条缩进本身就能占掉几百个字符）。
 *
 * ⚠️ **不要往这个 JSON 里塞"这条重复了 N 次"之类的标记**：实测加上 `重复n:1` 之后，
 * 模型把那条消息当成"已经处理过的冗余内容"直接不抽了（一条明明符合规则的待办被跳过）。
 * 去重是本地的事；要不要告诉模型，只写进下面那句说明里。
 */
function compactify(records, cfg) {
  const c = compactRecords(records)
  const items = c.groups.map((g) => {
    const head = JSON.stringify({ chat: g.chat, kind: g.kind })
    const texts = g.texts.map((t) => JSON.stringify(t)).join(',')
    return `${head.slice(0, -1)},"texts":[${texts}]}`
  })
  return {
    items,
    stats: {
      raw: c.raw,
      groups: c.groups.length,
      deduped: c.deduped,
      droppedUnverified: c.droppedUnverified,
      chars: c.chars,
    },
  }
}

function buildPrompt(records, cfg, existing) {
  // 额外规则放在 prompt-extra.txt：每轮都重新读，改完立刻生效，不用重启 DSH
  let extra = ''
  try {
    const p = join(pluginRoot, 'prompt-extra.txt')
    if (existsSync(p)) extra = readFileSync(p, 'utf8').trim()
  } catch {
    /* 忽略 */
  }
  const { items, stats: compactStats } = compactify(records, cfg)
  // "群名没确认"的正文是在**预筛那一步**就拦下的（见 prefilterRecords），compactify 根本看不到它们，
  // 所以这个计数必须由调用方传进来 —— 否则 prompt 里那句提示永远是 0（实测踩过）。
  compactStats.droppedUnverified = Number(cfg?.droppedUnverified ?? 0)
  promptStats = compactStats   // 给"预筛-试跑.mjs"看本轮消息段的真实体积（不影响主流程）
  // 把"还没完成的待办"告诉模型：同一件事换种说法也要认出来，别再抽一遍。
  // （实测：同一个群重采一次，模型会把"参加示例部门见面会及培训"改写成"参加示例部门新生见面会暨第一次培训"）
  // 只给 title/群/due：**不带 evidence**（那是给人看的核对材料，一条上百字，40 条就是几千字白烧）。
  const priorOpen = (Array.isArray(existing) ? existing : [])
    .filter((it) => !['done', 'ignored'].includes(String(it?.status)))
    .slice(-40)
    .map((it) => ({
      title: String(it?.title ?? ''),
      群: String(it?.chat ?? it?.source?.chat ?? ''),
      ...(it?.due ? { due: String(it.due) } : {}),
    }))
  const out = [
    '你是待办抽取器。下面是从微信/QQ「截图 + OCR」采集到的群聊新消息。',
    'OCR 可能有错字、字间多余空格，请按语义纠正后再判断；不要照抄错字。',
    '',
    '输出要求：只输出一个 JSON 对象，不要解释、不要 markdown 代码块，格式必须是：',
    '{"todos":[{"title":"事项","who":"负责人或空","due":"ISO8601 或 null","due_kind":"absolute|relative|none",' +
      '"priority":"high|normal|low","confidence":0.0,"chat":"来源群","sender":"发言人","evidence":"原文句子",' +
      '"reason":"为什么认为这是待办（一句话，人工核对用）"}]}',
    '',
    ...(priorOpen.length > 0
      ? [
          '已知未完成待办（**已经在清单里了，不要把同一件事再输出一次**；换种说法、OCR 错字、简称都算同一件事）：',
          JSON.stringify(priorOpen, null, 0),
          '',
        ]
      : []),
    '规则：',
    '1. 只有明确的任务、承诺、请求或带时间点的约定才算待办；闲聊、表情、通知、转发链接、广告不算。',
    '2. 相对时间（"明天下午三点""下周一"）按下面的当前时间换算成绝对时间（时区 Asia/Shanghai）；换不出来的 due 填 null。',
    '3. confidence 如实填 0~1：拿不准就低，不要一律给高分。',
    '4. 同一条待办只输出一次；没有待办就输出 {"todos":[]}。',
    '5. 与"已知未完成待办"实质相同的，**不要输出**；除非消息里给出了新的时间、地点或要求（那种情况请在 evidence 里写清新旧差别）。',
    ...(extra ? ['', extra] : []),
    '',
    `当前时间：${nowIso()}`,
    '',
    `消息（JSON，一行一个会话；共 ${items.length} 个会话，来自本轮 ${compactStats.raw} 条采集记录` +
      `${compactStats.deduped ? `；同一会话里逐字重复的内容已合并（去掉 ${compactStats.deduped} 条重复）` : ''}` +
      `${compactStats.droppedUnverified ? `；另有 ${compactStats.droppedUnverified} 条正文因群名没认出来（verified=false）未列入，别当成"这个群没消息"` : ''}）：`,
    ...items,
  ].join('\n')
  return out
}

/** 从模型输出里抠出 JSON 对象 */
function extractJson(text) {
  let t = String(text ?? '').trim()
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/)
  if (fence) t = fence[1].trim()
  const start = t.indexOf('{')
  const end = t.lastIndexOf('}')
  if (start < 0 || end <= start) return null
  try {
    return JSON.parse(t.slice(start, end + 1))
  } catch {
    return null
  }
}

async function callModel(ctx, cfg, prompt) {
  let text = ''
  const started = Date.now()
  const stream = ctx.llm.stream({
    provider: cfg.provider,
    model: cfg.model,
    messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] }],
  })
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`模型调用超时（${cfg.timeoutMs}ms）`)), cfg.timeoutMs).unref?.(),
  )
  const consume = (async () => {
    for await (const chunk of stream) {
      if (chunk?.type === 'text-delta' && typeof chunk.text === 'string') text += chunk.text
    }
    return text
  })()
  const result = await Promise.race([consume, timeout])
  return { text: result ?? text, ms: Date.now() - started }
}

function mergeTodos(existing, incoming, records, onSkip) {
  // 注意：PowerShell 的 ConvertTo-Json 会把"只有一个元素的数组"写成对象（丢掉数组外壳）。
  // 所以这里必须容忍 existing.items 是单个对象的情况，否则会把它当成空、把已有待办全丢掉。
  const raw = existing?.items
  const prior = Array.isArray(raw) ? raw : (raw && typeof raw === 'object' ? [raw] : [])
  const items = [...prior]
  const seen = new Set(items.map((it) => norm(it?.title) + '|' + norm(it?.chat ?? it?.source?.chat ?? '')))
  let added = 0
  const today = new Date()
  const stamp = `${today.getFullYear()}${String(today.getMonth() + 1).padStart(2, '0')}${String(today.getDate()).padStart(2, '0')}`
  let seq = items.filter((it) => String(it.id ?? '').startsWith(`tg-${stamp}`)).length
  for (const t of incoming) {
    const title = String(t?.title ?? '').trim()
    if (!title) continue
    const chat = String(t?.chat ?? '').trim()
    const key = norm(title) + '|' + norm(chat)
    if (seen.has(key)) continue
    const dueOf = t?.due && String(t.due) !== 'null' ? String(t.due) : null
    // 同一件事、新说法更具体（多了时间/地点）→ 就地升级旧条目，不新增
    const supIdx = findSupersetTarget(title, chat, dueOf, items)
    if (supIdx >= 0) {
      const oldTitle = String(items[supIdx].title ?? '')
      items[supIdx].title = title
      if (t?.evidence) items[supIdx].evidence = String(t.evidence)
      if (dueOf) items[supIdx].due = dueOf
      if (t?.reason) items[supIdx].reason = String(t.reason)   // 新说法给的理由更全，跟着一起升级
      onSkip?.(`同一条待办补充了细节，已就地更新（不新增）：${oldTitle} → ${title}（群 ${chat}）`)
      continue
    }
    // 模糊去重：同一个群里"同一件事"被 OCR/模型读成两种说法时，不要重复建待办
    // （实测：一度出现 '参加示例部门见面会及培训' 与 '参加示例部门生见面会及第一次培训' 两条）
    const nearDup = items.some(
      (it) =>
        !['done', 'ignored'].includes(String(it?.status)) &&
        isNearDuplicate(
          title,
          chat,
          dueOf,
          it?.title,
          it?.chat ?? it?.source?.chat ?? '',
          it?.due ?? null,
        ),
    )
    if (nearDup) {
      onSkip?.(`近重复跳过（同群已有几乎相同的事项）：${title}（群 ${chat}）`)
      continue
    }
    seen.add(key)
    seq += 1
    const due = t?.due && String(t.due) !== 'null' ? String(t.due) : null
    const confidence = typeof t?.confidence === 'number' ? t.confidence : 0.5
    items.push({
      id: `tg-${stamp}-${String(seq).padStart(3, '0')}`,
      title,
      who: String(t?.who ?? ''),
      due,
      due_kind: String(t?.due_kind ?? (due ? 'absolute' : 'none')),
      priority: String(t?.priority ?? 'normal'),
      confidence,
      status: confidence < 0.6 ? 'pending_confirm' : 'open',
      source: { chat, sender: String(t?.sender ?? ''), ts: nowIso(), msgId: '' },
      evidence: String(t?.evidence ?? ''),
      // 模型给的"为什么认为是待办"（prompt-extra.txt 规则 9）：落进 todos.json 供人工核对，
      // 注意**不回喂给模型**（buildPrompt 的已知待办清单只带 title/群），免得白烧 token。
      reason: String(t?.reason ?? ''),
      createdAt: nowIso(),
    })
    added += 1
  }
  return { items, added }
}

function renderMemo(items) {
  const now = new Date()
  const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const endToday = new Date(startToday.getTime() + 86400000)
  const endWeek = new Date(startToday.getTime() + 7 * 86400000)
  const pad2 = (n) => String(n).padStart(2, '0')
  const localDate = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`
  const buckets = { 逾期: [], 今天: [], 本周: [], 以后: [], 待确认: [], 已完成: [] }
  for (const it of items) {
    if (['done', 'ignored'].includes(String(it.status))) {
      buckets.已完成.push(it)
      continue
    }
    if (String(it.status) === 'pending_confirm' || (typeof it.confidence === 'number' && it.confidence < 0.6)) {
      buckets.待确认.push(it)
      continue
    }
    const due = it.due ? new Date(it.due) : null
    if (!due || Number.isNaN(due.getTime())) buckets.以后.push(it)
    else if (due < startToday) buckets.逾期.push(it)
    else if (due < endToday) buckets.今天.push(it)
    else if (due < endWeek) buckets.本周.push(it)
    else buckets.以后.push(it)
  }
  const line = (it) => {
    const due = it.due ? new Date(it.due) : null
    const when = due && !Number.isNaN(due.getTime())
      ? `${String(due.getHours()).padStart(2, '0')}:${String(due.getMinutes()).padStart(2, '0')}`
      : ''
    const ev = it.evidence ? `\n      > ${String(it.evidence).replace(/\n/g, ' ')}` : ''
    // 模型判断理由（prompt-extra.txt 规则 9）：人工核对"这条到底该不该是待办"时最有用
    const why = it.reason ? `\n      ? ${String(it.reason).replace(/\n/g, ' ')}` : ''
    return `- [ ] **${it.title}**${when ? ` ｜ ${when}` : ''}${it.source?.chat ? ` ｜ ${it.source.chat}` : ''}` +
      `${it.source?.sender ? ` · ${it.source.sender}` : ''}${why}${ev}`
  }
  const out = [`# 群聊待办 · ${localDate(startToday)}`, '', `> 由 DSH 自动从群聊消息抽取；共 ${items.length} 条`, '']
  for (const key of ['逾期', '今天', '本周', '以后', '待确认', '已完成']) {
    const list = buckets[key]
    if (!list || list.length === 0) continue
    const icon = key === '逾期' ? '❗' : key === '今天' ? '⏰' : key === '本周' ? '📅' : key === '待确认' ? '❓' : key === '已完成' ? '✅' : '🗓'
    out.push(`## ${icon} ${key}（${list.length}）`)
    out.push(...list.map(line))
    out.push('')
  }
  return out.join('\n')
}

/**
 * 归档：把"已完成/已忽略且够老"的待办挪到 群聊待办/archive/todos-YYYY-MM.json，
 * 让 todos.json 与 MEMO.md 不会无限膨胀（每轮都跑，不需要额外的计划任务）。
 *
 * 注意：这里**同时重写 MEMO.md**，否则 MEMO 会继续列着已经归档掉的条目（renderMemo 就在本模块里，直接用）。
 * 判定用的时间戳取 closedAt → createdAt → source.ts 里第一个能解析的；
 * 都没有时间戳的（老数据）不归档，避免误删刚做完的东西。
 *
 * @returns 归档条数
 */
function archiveOldTodos(todoDir, afterDays, log) {
  const days = Number.isFinite(Number(afterDays)) ? Number(afterDays) : 7
  if (days <= 0) return 0 // <=0 表示关闭归档
  const todosFile = join(todoDir, 'todos.json')
  const memoFile = join(todoDir, 'MEMO.md')
  const existing = readJson(todosFile, { items: [] })
  const raw = existing?.items
  const items = Array.isArray(raw) ? raw : raw && typeof raw === 'object' ? [raw] : []
  if (items.length === 0) return 0

  const cutoff = Date.now() - days * 86400000
  const keep = []
  const move = []
  for (const it of items) {
    const closed = ['done', 'ignored'].includes(String(it?.status))
    const ts = it?.closedAt ?? it?.createdAt ?? it?.source?.ts
    const t = ts ? new Date(ts).getTime() : Number.NaN
    if (closed && Number.isFinite(t) && t < cutoff) move.push(it)
    else keep.push(it)
  }
  if (move.length === 0) return 0

  const d = new Date()
  const month = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
  const archDir = join(todoDir, 'archive')
  if (!existsSync(archDir)) mkdirSync(archDir, { recursive: true })
  const archFile = join(archDir, `todos-${month}.json`)
  const prev = readJson(archFile, { items: [] })
  const prevItems = Array.isArray(prev?.items) ? prev.items : []
  writeJson(archFile, { month, archivedAt: nowIso(), items: [...prevItems, ...move] })
  writeJson(todosFile, { items: keep, updatedAt: nowIso() })
  writeFileSync(memoFile, renderMemo(keep), 'utf8')
  log?.(`归档 ${move.length} 条已完成/已忽略待办 → archive/todos-${month}.json（todos.json 剩 ${keep.length} 条）`)
  return move.length
}

/**
 * 跑一轮：读增量 → 抽待办 → 落盘
 * @returns 本轮报告
 */
async function runOnce(ctx, cfg) {
  const paths = {
    spoolDir: join(cfg.workspaceDir, 'wx-采集器', 'spool'),
    todoDir: join(cfg.workspaceDir, '群聊待办'),
    cursor: join(cfg.workspaceDir, '群聊待办', '.spool-cursor.json'),
  }
  if (!existsSync(paths.todoDir)) mkdirSync(paths.todoDir, { recursive: true })
  const logFile = join(cfg.workspaceDir, '群聊待办', '插件日志.txt')
  const log = (msg) => {
    ctx.logger?.info?.(`[dsh-msg-memo] ${msg}`)
    try {
      appendFileSync(logFile, `[${new Date().toLocaleString('zh-CN')}] ${msg}\n`, 'utf8')
    } catch {
      /* 日志写不了就算了 */
    }
  }

  const cursor = readJson(paths.cursor, {})
  // 每轮先归档：已完成/已忽略且超过 archiveAfterDays 的条目挪走（<=0 关闭）
  try {
    archiveOldTodos(paths.todoDir, cfg.archiveAfterDays ?? 7, log)
  } catch (error) {
    log(`归档失败（不影响采集）：${error?.message ?? error}`)
  }
  const { records, next } = collectNewRecords(paths, cursor, cfg.maxRecordsPerRun)
  if (records.length === 0) return { skipped: true, reason: '没有新的采集记录' }

  // ── 第 ① 级：本地预筛（不烧 token）───────────────────────────────────────────
  // 只有"看起来要行动"的行才送模型；其余只存档。注意：被筛掉的内容永远不会进模型，
  // 所以既要落审计文件，也要在日志里留一条带字数的记录（将来发现漏抽，能据此把阈值放宽）。
  const pre = prefilterRecords(records, cfg)
  const droppedFile = cfg.prefilterLog ? join(paths.todoDir, String(cfg.prefilterLog)) : ''
  // 审计文件里要同时留痕"预筛筛掉的"和"群名没认出来没送的"两类 ——
  // 后者只记一条空 hits 会让人看不懂为什么被丢。
  if ((pre.dropped.length > 0 || pre.droppedUnverifiedRecords.length > 0) && cfg.prefilterDumpDropped !== false) {
    const hitsOf = (r) => pre.decisions.find((d) => d.record === r)?.hits ?? []
    appendPrefilterAudit(droppedFile, pre.dropped, hitsOf)
    appendPrefilterAudit(droppedFile, pre.droppedUnverifiedRecords, () => ['unverified'])
  }
  const droppedChars = pre.dropped.reduce((n, r) => n + String(r?.text ?? r?.preview ?? '').length, 0)
  const unverifiedNote = pre.droppedUnverifiedRecords.length
    ? `、另有 ${pre.droppedUnverifiedRecords.length} 条正文因群名未确认不送模型`
    : ''

  if (pre.kept.length === 0) {
    // 全被筛掉：**必须推进游标**，否则这些行会一轮一轮地重复出现、每轮都白跑一遍预筛。
    writeJson(paths.cursor, next)
    log(
      `本地预筛：${pre.enabled ? '' : '（预筛已关闭）'}本轮 ${records.length} 条全部不是候选` +
        `（省下 ${droppedChars} 字${unverifiedNote}），未调用模型`,
    )
    return {
      skipped: true,
      reason: '本地预筛后没有候选',
      prefiltered: records.length,
      kept: 0,
      droppedUnverified: pre.droppedUnverifiedRecords.length,
    }
  }

  log(
    `本轮处理 ${records.length} 条采集记录（本地预筛保留 ${pre.kept.length} 条候选、` +
      `筛掉 ${pre.dropped.length} 条 ${droppedChars} 字${unverifiedNote}），调用模型 ${cfg.provider}/${cfg.model} …`,
  )
  const todosFile = join(paths.todoDir, 'todos.json')
  const existing = readJson(todosFile, { items: [] })
  // 把已有待办一起喂给模型：让它自己认出"同一件事换种说法"，从源头少抽重复
  const priorItems = Array.isArray(existing?.items)
    ? existing.items
    : existing?.items && typeof existing.items === 'object'
      ? [existing.items]
      : []
  const prompt = buildPrompt(pre.kept, { ...cfg, droppedUnverified: pre.droppedUnverifiedRecords.length }, priorItems)
  let text = ''
  let ms = 0
  try {
    const r = await callModel(ctx, cfg, prompt)
    text = r.text
    ms = r.ms
  } catch (error) {
    log(`模型调用失败（${error?.message ?? error}）`)
    return { error: 'llm-failed', message: String(error?.message ?? error) }
  }
  const parsed = extractJson(text)
  if (!parsed) {
    log(`模型输出不是 JSON，已跳过（${ms}ms）：${String(text).slice(0, 300)}`)
    return { error: 'json-parse', raw: String(text).slice(0, 500) }
  }
  const incoming = Array.isArray(parsed.todos) ? parsed.todos : []
  const { items, added } = mergeTodos(existing, incoming, pre.kept, log)
  writeJson(todosFile, { items, updatedAt: nowIso() })
  writeFileSync(join(paths.todoDir, 'MEMO.md'), renderMemo(items), 'utf8')
  writeJson(paths.cursor, next)
  log(
    `抽出 ${incoming.length} 条，新增 ${added} 条，累计 ${items.length} 条（${ms}ms；` +
      `预筛保留 ${pre.kept.length}/${records.length}` +
      `${promptStats.droppedUnverified ? `，${promptStats.droppedUnverified} 条正文因群名未确认未送模型` : ''}）`,
  )
  return {
    added,
    total: items.length,
    extracted: incoming.length,
    ms,
    prefiltered: records.length,
    kept: pre.kept.length,
    droppedUnverified: promptStats.droppedUnverified ?? 0,
  }
}

/**
 * @param ctx - 插件上下文
 * @param config - 可选的覆盖配置
 */
export function apply(ctx, config = {}) {
  const cfg = { ...DEFAULTS, ...loadConfig(), ...config }
  // ⚠️ 防"空 workspaceDir"（2026-10-15 别的机器上真机复现过）：
  // 安装器早期版本会把 config.json 的 workspaceDir 留成空串 `""`，而 `{...DEFAULTS, ...loadConfig()}`
  // 里空串**不会**回退到默认值（`??` 和展开都不把 "" 当缺省）→ `join('', '群聊待办')` 变成**相对路径** →
  // 插件的日志/待办被写到 **DSH 进程的工作目录**（实测出现在 DSH 安装目录下），用户永远找不到待办。
  // 这里做一层防御：空/空白一律回退到 process.cwd()，并把最终值写回 cfg 供后续所有 join 使用。
  if (!String(cfg.workspaceDir ?? '').trim()) {
    cfg.workspaceDir = process.cwd()
    try {
      ctx.logger?.warn?.(
        `[dsh-msg-memo] config.json 的 workspaceDir 是空的 → 回退到 ${cfg.workspaceDir}。` +
          `请把它改成你的工作区绝对路径（安装器会自动填），否则待办会写到 DSH 的工作目录里去。`,
      )
    } catch { /* 忽略 */ }
  }
  const bootLog = join(cfg.workspaceDir, '群聊待办', '插件日志.txt')
  try {
    if (!existsSync(join(cfg.workspaceDir, '群聊待办'))) mkdirSync(join(cfg.workspaceDir, '群聊待办'), { recursive: true })
    appendFileSync(bootLog, `[${new Date().toLocaleString('zh-CN')}] 插件已装载：每 ${Math.round(cfg.intervalMs / 1000)}s 扫一次，首次 ${Math.round(cfg.firstRunDelayMs / 1000)}s 后运行，模型 ${cfg.provider}/${cfg.model}\n`, 'utf8')
  } catch {
    /* 忽略 */
  }
  let busy = false   // 一轮还在跑时不要再起一轮（定时器和"立刻跑一轮"可能撞车）
  const tick = () => {
    if (busy) {
      ctx.logger?.info?.('[dsh-msg-memo] 上一轮还在跑，跳过这次触发')
      return
    }
    busy = true
    const p = runOnce(ctx, cfg)
      .catch((error) => {
        ctx.logger?.warn?.(`[dsh-msg-memo] 本轮失败：${error?.message ?? error}`)
        try {
          appendFileSync(bootLog, `[${new Date().toLocaleString('zh-CN')}] 本轮失败：${error?.message ?? error}\n`, 'utf8')
        } catch {
          /* 忽略 */
        }
      })
      .finally(() => {
        busy = false
      })
    return p   // 返回 Promise：触发路径可以据此写一行明确的结果
  }
  ctx.effect(() => {
    const first = setTimeout(tick, Math.max(1000, cfg.firstRunDelayMs))
    const timer = setInterval(tick, Math.max(30000, cfg.intervalMs))
    first.unref?.()
    timer.unref?.()
    return () => {
      clearTimeout(first)
      clearInterval(timer)
    }
  }, 'dsh-msg-memo: 定时抽取待办')

  // ---- 立刻跑一轮：外部只要新建 <工作区>/群聊待办/.run-now，最多 5 秒内就会跑一轮并把它删掉 ----
  // 用途：改完 prompt-extra.txt / 调完采集器后不用再干等 10 分钟周期。
  // 用法：powershell -File .\dsh-接入\立刻跑一轮.ps1 [-Wait]
  const runNowFile = join(cfg.workspaceDir, '群聊待办', '.run-now')
  ctx.effect(() => {
    const watcher = setInterval(() => {
      try {
        if (!existsSync(runNowFile)) return
        rmSync(runNowFile, { force: true })   // 先删掉：避免同一请求被反复触发
        try {
          appendFileSync(bootLog, `[${new Date().toLocaleString('zh-CN')}] 收到"立刻跑一轮"触发（.run-now）\n`, 'utf8')
        } catch {
          /* 忽略 */
        }
        const p = tick()
        if (p && typeof p.then === 'function') {
          // 明确写一行结果：否则"本轮没有新记录"时（runOnce 早退、不写日志）外部根本看不出跑没跑
          p.then((r) => {
            const msg = r?.skipped
              ? `立刻跑一轮结束：没有新的采集记录（${r.reason ?? '跳过'}）`
              : `立刻跑一轮结束：抽出 ${r?.extracted ?? 0} 条，新增 ${r?.added ?? 0} 条，累计 ${r?.total ?? '?'} 条`
            try { appendFileSync(bootLog, `[${new Date().toLocaleString('zh-CN')}] ${msg}\n`, 'utf8') } catch { /* 忽略 */ }
          }).catch(() => { /* 失败已由 tick 记过 */ })
        } else {
          try { appendFileSync(bootLog, `[${new Date().toLocaleString('zh-CN')}] 收到触发，但上一轮还在跑，已跳过\n`, 'utf8') } catch { /* 忽略 */ }
        }
      } catch (error) {
        ctx.logger?.warn?.(`[dsh-msg-memo] 触发文件处理失败：${error?.message ?? error}`)
      }
    }, 5000)
    watcher.unref?.()
    return () => clearInterval(watcher)
  }, 'dsh-msg-memo: 立刻跑一轮（触发文件 .run-now）')

  ctx.logger?.info?.(`[dsh-msg-memo] 已装载：每 ${Math.round(cfg.intervalMs / 1000)}s 扫一次 ${cfg.workspaceDir}\\wx-采集器\\spool，模型 ${cfg.provider}/${cfg.model}`)

  // 暴露一个服务，方便以后加"立刻跑一轮"的入口
  return { run: () => runOnce(ctx, cfg), config: cfg }
}
