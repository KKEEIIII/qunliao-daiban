#!/usr/bin/env node
/**
 * 发QQ.mjs —— 「群聊待办」的 QQ 定时推送器（直连腾讯官方机器人 API）
 *
 * 为什么要自己写这个（而不是调 dsh-qq-plugin）：
 *   dsh-qq-plugin 只把"发送"暴露成 **agent 工具**（send_to_qq / notify_qq），没有 CLI、也没有 HTTP 路由；
 *   而计划任务（提醒器.ps1）需要在**没有 AI 回合**的情况下直接发一条消息。
 *   微信通道那边插件自带 `dsh-wechat-send` CLI，所以能直接在计划任务里调；QQ 这边缺这一层。
 *
 * 做法（和微信 CLI 同思路：读已保存的凭据 → 直连官方 API，不需要 DSH 在跑）：
 *   1) 读 ~/.dsh/qq/state.json          → appId、userOpenid（绑定后由插件写入）
 *   2) 读 ~/.dsh/.credentials.yaml      → appSecret（DSH 凭据库，只取 dsh-qq-plugin/app-<appId> 这一段）
 *   3) POST https://bots.qq.com/app/getAppAccessToken        （appId + clientSecret → access_token）
 *   4) POST https://api.sgroup.qq.com/v2/users/<openid>/messages  （Authorization: QQBot <token>）
 *   全部只用 HTTPS，**不需要 WebSocket**，所以计划任务里跑一次就走。
 *
 * 用法：
 *   node 发QQ.mjs --text "要发的内容"           # 正常发送
 *   node 发QQ.mjs --text "..." --dry-run        # 只检查凭据/取 token，不发消息
 *   node 发QQ.mjs --text "..." --json           # 输出 JSON（给 PS 解析）
 *   echo "内容" | node 发QQ.mjs                 # 从 stdin 读正文
 *
 * 退出码：0 成功；2 没绑定（缺凭据）；3 取 token 失败；4 发送被拒（含频次限制）；5 参数/其它错误
 */
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

const HOME = process.env.DSH_HOME || join(homedir(), '.dsh')
const STATE_FILE = join(HOME, 'qq', 'state.json')
const CRED_FILE = join(HOME, '.credentials.yaml')
const TOKEN_CACHE = join(HOME, 'qq', 'access-token-cache.json')

function say(msg) { if (!ARGV.json) console.log(msg) }
const ARGV = { text: '', dry: false, json: false }
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i]
  if (a === '--text' || a === '-t') ARGV.text = String(process.argv[++i] ?? '')
  else if (a === '--dry-run') ARGV.dry = true
  else if (a === '--json') ARGV.json = true
  else if (a === '--help' || a === '-h') {
    console.log('用法：node 发QQ.mjs --text "内容" [--dry-run] [--json]')
    process.exit(0)
  }
}

function finish(code, payload) {
  if (ARGV.json) console.log(JSON.stringify({ code, ...payload }))
  else if (payload.error) console.error('❌ ' + payload.error)
  else if (payload.detail) console.log('✅ ' + payload.detail)
  process.exit(code)
}

/** 从 state.json 里拿第一个启用的账号（appId + userOpenid）。 */
function readAccount() {
  if (!existsSync(STATE_FILE)) return { error: '没有 ~/.dsh/qq/state.json（QQ 渠道还没绑定）' }
  let state
  try { state = JSON.parse(readFileSync(STATE_FILE, 'utf8').replace(/^\uFEFF/, '')) } catch (e) {
    return { error: 'state.json 解析失败：' + e.message }
  }
  const accounts = state?.accounts || {}
  const appId = Object.keys(accounts).find((id) => accounts[id]?.enabled !== false)
  if (!appId) return { error: 'state.json 里没有可用账号（QQ 还没绑定）' }
  const acc = accounts[appId]
  const openid = String(acc.userOpenid || '').trim()
  if (!openid) return { error: '账号 ' + appId + ' 没有 userOpenid（请重新扫码绑定）' }
  return { appId, openid }
}

/**
 * 从 .credentials.yaml 里取 appSecret。
 * 只做一个"够用"的块解析：找到 `dsh-qq-plugin/app-<appId>:` 这一段，取其中的 appSecret。
 * （PS 没有 yaml 解析器；node 这边也用正则，避免再依赖一个第三方包。）
 */
function readAppSecret(appId) {
  if (!existsSync(CRED_FILE)) return { error: '没有 ~/.dsh/.credentials.yaml' }
  const text = readFileSync(CRED_FILE, 'utf8').replace(/^\uFEFF/, '')
  const lines = text.split(/\r?\n/)
  const head = new RegExp('^\\s*dsh-qq-plugin/app-' + appId + '\\s*:')
  let inBlock = false
  let baseIndent = 0
  let secret = ''
  for (const line of lines) {
    if (!inBlock) {
      if (head.test(line)) {
        inBlock = true
        baseIndent = (line.match(/^\s*/) || [''])[0].length
      }
      continue
    }
    const indent = (line.match(/^\s*/) || [''])[0].length
    if (line.trim() !== '' && indent <= baseIndent) break   // 出了这个块
    const m = line.match(/^\s*appSecret\s*:\s*(.+?)\s*$/)
    if (m) { secret = m[1].replace(/^['"]|['"]$/g, ''); break }
  }
  if (!secret) return { error: '凭据里没有 dsh-qq-plugin/app-' + appId + ' 的 appSecret（请重新扫码绑定）' }
  return { secret }
}

/** 取 access_token（带本地缓存，提前 60 秒过期）。 */
async function getAccessToken(appId, secret) {
  try {
    if (existsSync(TOKEN_CACHE)) {
      const c = JSON.parse(readFileSync(TOKEN_CACHE, 'utf8'))
      if (c.appId === appId && c.expiresAt > Date.now() + 60_000 && c.token) return { token: c.token, cached: true }
    }
  } catch { }
  const res = await fetch('https://bots.qq.com/app/getAppAccessToken', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ appId, clientSecret: secret }),
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok || !body.access_token) {
    return { error: '取 access_token 失败：HTTP ' + res.status + ' ' + JSON.stringify(body).slice(0, 200) }
  }
  const ttl = Number(body.expires_in || 7200)
  try {
    mkdirSync(join(HOME, 'qq'), { recursive: true })
    writeFileSync(TOKEN_CACHE, JSON.stringify({ appId, token: body.access_token, expiresAt: Date.now() + ttl * 1000 }))
  } catch { }
  return { token: body.access_token, cached: false }
}

function splitText(text, max = 1500) {
  // QQ 单条消息有长度限制，太长就分条（按换行切，尽量不打断句子）
  const out = []
  let buf = ''
  for (const line of text.split(/\r?\n/)) {
    if ((buf + '\n' + line).length > max && buf) { out.push(buf); buf = line }
    else buf = buf ? buf + '\n' + line : line
  }
  if (buf) out.push(buf)
  return out.length ? out : ['']
}

async function main() {
  let text = ARGV.text
  if (!text) {
    try {
      const chunks = []
      for await (const c of process.stdin) chunks.push(c)
      text = Buffer.concat(chunks).toString('utf8')
    } catch { }
  }
  text = String(text || '').trim()
  if (!text) return finish(5, { error: '没有内容可发（用 --text 或 stdin）' })

  const acc = readAccount()
  if (acc.error) return finish(2, { error: acc.error })
  const sec = readAppSecret(acc.appId)
  if (sec.error) return finish(2, { error: sec.error })

  const tk = await getAccessToken(acc.appId, sec.secret)
  if (tk.error) return finish(3, { error: tk.error })

  if (ARGV.dry) {
    return finish(0, { detail: '凭据与 token 都用得上（dry-run，没有真的发消息）', appId: acc.appId, openidTail: acc.openid.slice(-6), tokenCached: tk.cached })
  }

  const parts = splitText(text)
  const sent = []
  for (let i = 0; i < parts.length; i++) {
    const res = await fetch('https://api.sgroup.qq.com/v2/users/' + encodeURIComponent(acc.openid) + '/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'QQBot ' + tk.token },
      body: JSON.stringify({ content: parts[i], msg_type: 0, msg_seq: (Date.now() % 100000) + i }),
    })
    const body = await res.json().catch(() => ({}))
    if (!res.ok) {
      const hint = res.status === 429 ? '（腾讯限流：主动消息有频次限制）' : ''
      return finish(4, { error: '发送被拒：HTTP ' + res.status + ' ' + JSON.stringify(body).slice(0, 240) + hint, sent: sent.length })
    }
    sent.push(body)
  }
  return finish(0, { detail: '已发到 QQ（' + sent.length + ' 条）', appId: acc.appId, openidTail: acc.openid.slice(-6) })
}

main().catch((e) => finish(5, { error: '意外错误：' + (e?.message || String(e)) }))
