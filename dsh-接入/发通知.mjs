// 发通知.mjs —— 用企业微信机器人给用户发一条通知（"有问题通过企业微信发给我"）
//
// 为什么存在：DSH 沙箱里 PowerShell/curl 的外网 HTTP 都被挡，但 node 的 fetch 直连可用；
// 用 node 跑这个脚本就能从任意会话把消息发到手机企业微信。
// 用法：
//   node dsh-接入\发通知.mjs "标题" "正文"
//   正文留空则只发标题；退出码 0=发送成功（errcode=0）。
// 读取同一份 dsh-接入\提醒配置.json 的 phonePush.wecom.webhook，默认 @all（和推送.ps1 同一套约定）。
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const cfgPath = join(here, '提醒配置.json')
const title = (process.argv[2] || '').trim()
const text = (process.argv[3] || '').trim()

if (!title) {
  console.error('用法：node 发通知.mjs "标题" ["正文"]')
  process.exit(1)
}

let cfg
try {
  cfg = JSON.parse(readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, ''))
} catch (e) {
  console.error('读 提醒配置.json 失败：' + e.message)
  process.exit(1)
}
const w = cfg.phonePush && cfg.phonePush.wecom
if (!w || !w.webhook) {
  console.error('提醒配置.json 里没有 phonePush.wecom.webhook')
  process.exit(1)
}

const content = text ? `【${title}】\n${text}` : `【${title}】`
const payload = { msgtype: 'text', text: { content, mentioned_list: ['@all'] } }

try {
  const res = await fetch(w.webhook, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(20000),
  })
  const j = await res.json().catch(() => ({}))
  console.log('errcode=' + j.errcode + ' ' + (j.errmsg || ''))
  process.exit(j.errcode === 0 ? 0 : 1)
} catch (e) {
  console.error('发送失败：' + e.message)
  process.exit(1)
}
