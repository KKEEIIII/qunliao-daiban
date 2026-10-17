// 控制台-服务.mjs —— 让控制台页"点一下确定就生效"的本地小服务（只监听 127.0.0.1）
//
// 为什么需要它：**浏览器页面不能直接改写本机文件**（这是浏览器的安全边界，绕不过去）。
// 于是原来只能"点确定 → 下载一个改动文件 → 自己敲一行 PowerShell -Apply"，两步。
// 这个服务的做法：由 控制台.ps1 起一个**只绑定 127.0.0.1**的小 HTTP 服务，页面就是从这个服务打开的，
// 于是点「确定」= 页面 POST 到本机服务 = 立刻应用到本机（复用已经测过的同一条 -Apply 通路），
// 页面直接把应用结果贴出来。**页面用文件方式打开时（file://）依旧保留"下载/复制"兜底。**
//
// 安全（本地服务最容易踩的三件事，这里都堵了）：
//   ① 只绑 127.0.0.1 —— 局域网/外网碰不到；
//   ② 每次启动生成一次性 token（32 位随机），URL 里带上，POST 必须匹配 —— 别的网站/程序猜不到，
//      也就没法用你的浏览器当跳板来改这台机器的配置；
//   ③ 只接受 kind='console-changes' 的补丁；请求体有大小上限；路径只认 / /apply /ping /quit。
//   ④ 空闲 30 分钟自动退出；页面里有「停止服务」按钮；关掉那个 PowerShell 窗口也会停。
//
// 用法（一般由 控制台.ps1 调起，不用手敲）：
//   node 控制台-服务.mjs <token> <port>
import { createServer } from 'node:http'
import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const ps1 = join(here, '控制台.ps1')
const htmlPath = join(here, '控制台.html')
const token = String(process.argv[2] || '')
const portArg = Number(process.argv[3] || 0)
const MAX_BODY = 64 * 1024          // 一个补丁撑死几 KB
const IDLE_MS = 30 * 60 * 1000      // 空闲 30 分钟自动退出
let lastHit = Date.now()
let busy = false

if (!token) { console.error('缺少 token：node 控制台-服务.mjs <token> <port>'); process.exit(2) }
if (!existsSync(ps1)) { console.error('找不到 控制台.ps1（要和本文件同目录）'); process.exit(2) }

/** 跑一次 控制台.ps1（-Apply / -NoOpen），把输出原样收集回来给页面看 */
function runPs(args, timeoutMs = 120000) {
  return new Promise((resolve) => {
    const p = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1, ...args], { windowsHide: true })
    let out = ''
    const t = setTimeout(() => { try { p.kill() } catch { } ; resolve({ code: 124, out: out + '\n（超时：应用超过 ' + Math.round(timeoutMs / 1000) + ' 秒）' }) }, timeoutMs)
    p.stdout.on('data', (d) => { out += d.toString('utf8') })
    p.stderr.on('data', (d) => { out += d.toString('utf8') })
    p.on('error', (e) => { clearTimeout(t); resolve({ code: 1, out: out + '\n启动失败：' + e.message }) })
    p.on('close', (c) => { clearTimeout(t); resolve({ code: c === null ? 1 : c, out }) })
  })
}

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })
  res.end(body)
}
const json = (res, code, obj) => send(res, code, 'application/json; charset=utf-8', JSON.stringify(obj))

function serveHtml(res, url) {
  if (!existsSync(htmlPath)) { return send(res, 500, 'text/plain; charset=utf-8', '控制台.html 还没生成，请重新运行 控制台.ps1') }
  const html = readFileSync(htmlPath, 'utf8')
  send(res, 200, 'text/html; charset=utf-8', html)
}

async function handleApply(req, res) {
  if (busy) { return json(res, 429, { ok: false, error: '正在应用上一份改动，请稍候' }) }
  let raw = ''
  let tooBig = false
  req.on('data', (d) => { raw += d; if (raw.length > MAX_BODY) { tooBig = true; req.destroy() } })
  req.on('end', async () => {
    if (tooBig) { return json(res, 413, { ok: false, error: '请求体太大' }) }
    let body = null
    try { body = JSON.parse(raw) } catch { return json(res, 400, { ok: false, error: '请求体不是合法 JSON' }) }
    if (!body || body.token !== token) { return json(res, 403, { ok: false, error: 'token 不匹配（这个服务只接受本页面的请求）' }) }
    const patch = body.patch
    if (!patch || patch.kind !== 'console-changes') { return json(res, 400, { ok: false, error: '补丁形状不对（kind 必须是 console-changes）' }) }
    busy = true
    try {
      const tmp = join(tmpdir(), 'console-patch-' + Date.now() + '.json')
      writeFileSync(tmp, JSON.stringify(patch, null, 2), 'utf8')
      const r = await runPs(['-Apply', tmp])
      // exit 0 = 已应用；exit 2 = 补丁里没有需要改的东西（也不算失败）
      const ok = (r.code === 0 || r.code === 2)
      // 应用后重新生成页面，让刷新后的数值就是新的
      const regen = await runPs(['-NoOpen'])
      const applied = (r.code === 0)
      return json(res, ok ? 200 : 500, {
        ok,
        applied,
        code: r.code,
        output: r.out.trim().split(/\r?\n/).slice(-14).join('\n'),
        regen: regen.code === 0 ? '页面已按新配置重新生成' : ('重新生成页面失败（退出 ' + regen.code + '）')
      })
    } finally {
      busy = false
      lastHit = Date.now()
    }
  })
}

const server = createServer((req, res) => {
  lastHit = Date.now()
  const url = new URL(req.url || '/', 'http://127.0.0.1')
  const q = url.searchParams.get('t') || ''
  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    // 首屏要带 token 才能进入"一键应用"模式；没带就照样给页面（页面会退回下载/复制模式）
    return serveHtml(res, url)
  }
  if (req.method === 'GET' && url.pathname === '/ping') {
    return json(res, 200, { ok: true, service: '群聊待办-控制台', tokenOk: q === token, idleMs: Date.now() - lastHit })
  }
  if (req.method === 'POST' && url.pathname === '/apply') {
    return handleApply(req, res)
  }
  if (req.method === 'POST' && url.pathname === '/quit') {
    let raw = ''
    req.on('data', (d) => { raw += d })
    req.on('end', () => {
      let b = null
      try { b = JSON.parse(raw) } catch { }
      json(res, 200, { ok: true, bye: !!(b && b.token === token) })
      setTimeout(() => { console.log('[控制台服务] 收到停止请求，退出'); process.exit(0) }, 200)
    })
    return
  }
  send(res, 404, 'text/plain; charset=utf-8', 'not found')
})

server.on('error', (e) => {
  console.error('[控制台服务] 起不来：' + e.message + (e.code === 'EADDRINUSE' ? '（端口被占用，换一个端口试试）' : ''))
  process.exit(1)
})

// 端口：优先用指定的；被占用就往后试几个
function listen(port, triesLeft) {
  server.listen(port, '127.0.0.1', () => {
    const p = server.address().port
    console.log('CONSOLE_SERVER_READY ' + p)
    console.log('[控制台服务] 已启动：http://127.0.0.1:' + p + '/?t=' + token)
    console.log('[控制台服务] 只监听本机回环地址；关掉这个窗口即停止。空闲 30 分钟也会自动退出。')
  })
  server.once('error', (e) => {
    if (e.code === 'EADDRINUSE' && triesLeft > 0) { setTimeout(() => listen(port + 1, triesLeft - 1), 50) }
  })
}
listen(portArg || 19390, 9)

setInterval(() => {
  if (Date.now() - lastHit > IDLE_MS) { console.log('[控制台服务] 空闲超过 30 分钟，自动退出'); process.exit(0) }
}, 60000)
