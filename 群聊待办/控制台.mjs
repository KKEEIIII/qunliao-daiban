// 控制台.mjs —— 生成自包含的「群聊待办 · 控制台」页面（群聊待办/控制台.html）
//
// ⚠️ 2026-10-16 用户要求：**只保留"一键应用"（本地服务版）** —— 下载 JSON 补丁的老"文件模式"已停用。
// 设计：
//   · 页面由 控制台-服务.mjs（只监听 127.0.0.1，带一次性 token）提供；
//     点「确定」= POST 给本机服务 = 立刻应用，服务内部复用 控制台.ps1 -Apply 那条通路
//     （JSON 由 Node 写、计划任务由 PowerShell 改 —— 各用各的安全写法）
//   · 页面上所有"当前状态"（微信/QQ 是否在跑、机器人绑定、任务周期、白名单…）由 控制台.ps1
//     在生成时收集好，经临时 JSON 传进来 → 页面数据永远是最新一版
//   · 数据用 base64(UTF-8) 内嵌，file:// 下中文不乱码
//
// ⚠️⚠️ 2026-10-16 血的教训（用户实测"点确定没反应"）：
//   页面脚本是写在**模板字符串**里的，模板字符串会**吃掉一层反斜杠**：
//     `s.split(/[\n,，]+/)` 里的 \n 会变成**真换行** → 正则字面量被劈成两行 → 整段脚本 SyntaxError
//     → 所有按钮都没绑上事件 → "点确定毫无反应"（而且页面静态文字全都正常，肉眼看不出来）。
//   所以本文件里的页面脚本：**一个反斜杠都不许出现**（要换行用 String.fromCharCode(10)，
//   要正则就写不含转义的字符比较）。改完必须跑 `_自检最新包.ps1` / 打包自测里的
//   「内联脚本 node --check + 渲染后 gen 已填充」两道断言 —— 它们就是为这个坑加的。
//
// 用法（一般不用直接跑，由 控制台.ps1 调用）：
//   node 控制台.mjs <状态JSON路径>
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const statePath = process.argv[2]
if (!statePath) {
  console.error('用法：node 控制台.mjs <状态JSON路径>（一般由 控制台.ps1 调用）')
  process.exit(1)
}
const S = JSON.parse(readFileSync(statePath, 'utf8').replace(/^\uFEFF/, ''))
const out = join(here, '控制台.html')

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

// ⚠️ 2026-10-16 加：**单元素数组会被压成字符串**。
// 状态 JSON 由 控制台.ps1 用 ConvertTo-Json 生成，而 PS 把 @('张三') 写成 "张三"（不是数组）→
// 页面里再 .join(', ') 就会 TypeError → **整页脚本又死一次**（和"点确定没反应"同一类症状）。
// 收件人很可能只填一个昵称，所以这里一律强制成数组。
const asArr = (v) => {
  if (Array.isArray(v)) { return v.map((x) => String(x)) }
  if (v === null || v === undefined || v === '') { return [] }
  return [String(v)]
}

const cfg = S.config || { collectMinutes: 60, remindMinutes: 5, selfcheckMinutes: 120 }
const t = S.tasks || {}
const apps = S.apps || {}
const bot = S.wechatBot || {}
const wecom = S.wecom || {}
const todos = S.todos || {}
const auto = S.autostart || { enabled: false }
const qq = S.qqChannel || { pluginInstalled: false, bound: false, account: '' }

const badge = (ok, yes, no) => `<span class="pill ${ok ? 'ok' : 'bad'}">${ok ? yes : no}</span>`

const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>群聊待办 · 控制台</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --line:#e3e6ea; --text:#1f2328; --dim:#6b7280; --accent:#2f6feb; --ok:#12805c; --bad:#b42318; --warn:#8a5a00; }
  * { box-sizing: border-box; }
  body { margin:0; padding:24px 16px 150px; background:var(--bg); color:var(--text);
         font:15px/1.6 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif; }
  .wrap { max-width: 880px; margin: 0 auto; }
  h1 { font-size:22px; margin:0 0 4px; }
  .sub { color:var(--dim); font-size:13px; margin-bottom:18px; }
  h2 { font-size:16px; margin:26px 0 10px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px 16px; margin-bottom:10px; }
  .row { display:flex; align-items:flex-start; gap:10px; padding:7px 0; border-bottom:1px dashed var(--line); flex-wrap:wrap; }
  .row:last-child { border-bottom:0; }
  .k { flex:0 0 170px; color:var(--dim); font-size:13.5px; }
  .v { flex:1 1 300px; min-width:0; word-break:break-all; }
  .pill { display:inline-block; padding:1px 9px; border-radius:99px; font-size:12.5px; border:1px solid var(--line); color:var(--dim); margin-right:6px; }
  .pill.ok { color:var(--ok); border-color:#b7e2cf; background:#eefaf4; }
  .pill.bad { color:var(--bad); border-color:#f4c7c3; background:#fef3f2; }
  input[type=number] { width:110px; padding:6px 8px; border:1px solid var(--line); border-radius:8px; font-size:14px; }
  input[type=text], textarea { width:100%; padding:7px 9px; border:1px solid var(--line); border-radius:8px; font-size:13.5px; font-family:inherit; }
  textarea { min-height:56px; resize:vertical; }
  .hint { color:var(--dim); font-size:12.5px; margin-top:3px; }
  .note { color:#3d4450; font-size:13.5px; margin-top:8px; padding-left:10px; border-left:3px solid var(--line); }
  table.tok { width:100%; border-collapse:collapse; font-size:13.5px; margin-top:8px; }
  table.tok th, table.tok td { border:1px solid var(--line); padding:6px 8px; text-align:left; }
  table.tok th { background:#f0f2f5; font-weight:600; }
  details summary { cursor:pointer; color:var(--dim); font-size:13.5px; }
  details .inner { padding:8px 0 0 4px; font-size:13.5px; }
  ol, ul { margin:6px 0; padding-left:22px; }
  li { margin:4px 0; }
  code { background:#f0f2f5; border-radius:5px; padding:1px 6px; font-size:12.5px; }
  pre { white-space:pre-wrap; background:#f0f2f5; border:1px solid var(--line); border-radius:8px; padding:10px 12px; font-size:12.5px; margin:8px 0 0; }
  .bar { position:fixed; left:0; right:0; bottom:0; background:#1f2328; color:#fff;
          padding:10px 16px; display:flex; gap:14px; align-items:center; justify-content:center; font-size:14px; flex-wrap:wrap; }
  .bar button { font-size:15px; padding:7px 22px; border-radius:8px; border:0; cursor:pointer; background:var(--accent); color:#fff; font-weight:600; }
  .bar button.ghost { background:transparent; border:1px solid #5a6270; color:#d7dbe0; font-weight:400; }
  .bar .tip { color:#aeb4bd; font-size:12.5px; flex:1 1 100%; text-align:center; }
  .bar .tip.hot { color:#ffd479; font-weight:600; }
  .bar .tip.bad { color:#ff9d95; font-weight:600; }
  .changed { outline:2px solid rgba(47,111,235,.35); outline-offset:-2px; }
  .switchrow { display:flex; align-items:flex-start; gap:10px; padding:8px 0; }
  .switchrow input[type=checkbox] { width:18px; height:18px; margin-top:3px; }
  .warnbox { background:#fff6e5; border:1px solid #f0dcb0; color:#7a4d00; border-radius:10px;
             padding:12px 14px; margin-bottom:12px; font-size:13.5px; line-height:1.75; }
  .warnbox.off { display:none; }
  #subServer { display:none; }
  body.server #subServer { display:inline; }
</style>
</head>
<body>
<div class="wrap">
  <div id="banner" class="warnbox off"></div>
  <h1>群聊待办 · 控制台</h1>
__VERBAR__
  <div class="sub">生成于 <span id="gen">-</span> ·
    <span id="subServer">改完点右下角「<b>确定</b>」→ <b>立刻应用</b>到本机（本页由本地控制台服务提供，仅监听 127.0.0.1；用完自动关页 + 自动停服务）</span>
  </div>

  <h2>① 设置（一页改完）</h2>
  <div class="card">
    <div class="row"><span class="k">采集周期（分钟）</span><span class="v"><input type="number" id="collect" min="15" max="720" value="${cfg.collectMinutes}"> <span class="hint">微信 + QQ 截图 OCR 的间隔。当前任务实际是 ${esc(t.collectWx || '未创建')}。建议 30~120；QQ 一轮要点开会话，别设太短。</span></span></div>
    <div class="row"><span class="k">提醒周期（分钟）</span><span class="v"><input type="number" id="remind" min="1" max="60" value="${cfg.remindMinutes}"> <span class="hint">到点检查的间隔。当前任务实际是 ${esc(t.remind || '未创建')}。建议 5。</span></span></div>
    <div class="row"><span class="k">自检周期（分钟）</span><span class="v"><input type="number" id="selfcheck" min="30" max="1440" value="${cfg.selfcheckMinutes}"> <span class="hint">健康检查的间隔。当前任务实际是 ${esc(t.selfcheck || '未创建')}。建议 60~240。</span></span></div>
    <div class="note">应用补丁时会同时更新计划任务和 <code>dsh-接入\\运行配置.json</code>（自检的"日志陈旧"判定跟着它走，两处永远一致）。</div>
  </div>

  <div class="card">
    <div class="row"><span class="k">企业微信 Webhook</span><span class="v"><input type="text" id="webhook" value="${esc(wecom.webhook || '')}" placeholder="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…"> <span class="hint">兜底通道（也是唯一"必弹"的通道）。企业微信 → 建群 → 群机器人 → 复制 Webhook。留空 = 不启用兜底。</span></span></div>
    <div class="row"><span class="k">我的微信昵称</span><span class="v"><input type="text" id="aliases" value="${esc(asArr(S.aliases).join(', '))}" placeholder="张三, 张三丰"> <span class="hint">逗号分隔。用来识别"@我"（两处配置同时写，不会漏）。</span></span></div>
    <div class="row"><span class="k">微信群白名单</span><span class="v"><textarea id="wxwl" placeholder="留空 = 不过滤。逗号或每行一个，如：<示例群号>, 班级群">${esc(asArr(S.whitelistWx).join(', '))}</textarea></span></div>
    <div class="row"><span class="k">QQ 群白名单</span><span class="v"><textarea id="qqwl" placeholder="逗号或每行一个，如：2026级计算机2班（官方）123456">${esc(asArr(S.whitelistQq).join(', '))}</textarea> <span class="hint">⚠️ 后台（Maa）模式下<b>至少填一个</b>，留空会每轮跳过。</span></span></div>
  </div>

  <div class="card">
    <div class="switchrow">
      <input type="checkbox" id="autostart" ${auto.enabled ? 'checked' : ''}>
      <label for="autostart"><b>开机自动启动 DSH（最小化）</b>
        <div class="hint">当前：${auto.enabled ? badge(true, '已开启') : badge(false, '未开启')}${auto.exe ? '　主程序：' + esc(auto.exe) : ''}</div>
        <div class="hint"><b>无感程度</b>：登录 Windows 后 DSH 自动在<b>后台最小化</b>启动 —— 不抢焦点、不弹任何窗口；任务栏上会留一个 DSH 图标（这个收不掉，除非改 DSH 自己的启动方式）；采集 / 抽取 / 提醒 / 自检照常在后台跑，和手动打开完全一样。勾上点「确定」即启用，取消勾选再点「确定」即关闭（只删这一条计划任务，不动 DSH 本身）。</div>
      </label>
    </div>
  </div>

  <h2>② 现在跑得怎么样</h2>
  <div class="card">
    <div class="row"><span class="k">微信客户端（采集）</span><span class="v">${badge(apps.wechat, '运行中 ✓', '未运行 ✗ —— 微信采集本轮会跳过（不报错，就是采不到）')}</span></div>
    <div class="row"><span class="k">QQ 客户端（采集）</span><span class="v">${badge(apps.qq, '运行中 ✓', '未运行 ✗ —— QQ 采集本轮会跳过')}</span></div>
    <div class="row"><span class="k">微信机器人（提醒/回写）</span><span class="v">${bot.bound
      ? badge(true, '已绑定 ' + esc(bot.account)) + '<span class="hint">在微信里说"完成 3"标记完成、说"还有哪些待办"看清单。提醒主通道。</span>'
      : badge(false, '未绑定') + '<span class="hint">装 dsh-wechat-plugin 后到 DSH 设置 → 微信 → 扫码（见下面 ③）</span>'}</span></div>
    <div class="row"><span class="k">企业微信（兜底通道）</span><span class="v">${wecom.configured ? badge(true, '已配置 webhook（' + esc(wecom.mention || 'markdown') + '）') : badge(false, '未配置 —— 微信发不出时没有兜底')}</span></div>
    <div class="row"><span class="k">QQ 通道（可选）</span><span class="v">${qq.bound ? badge(true, '已绑定 ' + esc(qq.account)) : (qq.pluginInstalled ? badge(false, '插件已装、还没扫码绑定') : badge(false, '未安装 dsh-qq-plugin'))}<span class="hint">见下面 ③ 里的 QQ 说明</span></span></div>
    <div class="row"><span class="k">待办统计</span><span class="v">未完成 ${todos.open ?? 0} 条 · 已完成 ${todos.done ?? 0} 条 · 已忽略 ${todos.ignored ?? 0} 条</span></div>
    <div class="row"><span class="k">开机自启</span><span class="v">${auto.enabled ? badge(true, '已开启') : badge(false, '未开启')}</span></div>
  </div>

  <h2>③ 绑定指引（手动，各一次就好）</h2>
  <div class="card">
    <details open><summary><b>微信机器人（提醒主通道 + "完成"回写）</b></summary><div class="inner">
      <ol>
        <li>DSH 侧栏 → 插件 → 添加插件 → 填 <code>dsh-wechat-plugin</code>（带 <code>-plugin</code>）→ 立即启用 → 重启 DSH</li>
        <li>DSH <b>设置 → 微信 → 开始扫码</b> → 手机微信扫码确认（一个微信号只能绑一台电脑）</li>
        <li>在微信里给机器人发 <code>你好</code>，收到回复即通</li>
        <li>发 <code>/new 待办管家</code> 建专用会话，再把下面这段<b>整段复制</b>发过去（路径已按这台机器填好）：</li>
      </ol>
      <pre>${esc(S.rulesText || '（生成页面的 控制台.ps1 太旧，重新运行一次即可出现规则文本）')}</pre>
      <div class="note">提醒会以机器人身份直接发到你微信（像普通聊天一样弹横幅）→ <b>别把机器人对话设成免打扰</b>。</div>
    </div></details>

    <details><summary><b>QQ 通道（可选；与微信插件同一个作者）</b></summary><div class="inner">
      <p>项目是 <code>dsh-qq-plugin</code>（仓库 <code>xcisxc29/dsh-qq-plugin</code>）—— 走<b>腾讯官方 QQ 机器人平台</b>，扫码绑定，和微信版同源同作者；QQ 允许主动推送，<b>没有</b>微信 iLink 那种"会话有效期"限制。</p>
      <ol>
        <li>插件 → 添加插件 → 填 <code>dsh-qq-plugin</code> → 立即启用 → 重启 DSH</li>
        <li>DSH <b>设置 → QQ → 开始扫码</b> → 手机 QQ 扫码并确认（<b>不需要</b>先去腾讯开放平台注册 AppID/AppSecret，扫码就是注册）</li>
        <li>在 QQ 里给机器人发 <code>你好</code>，收到回复即通；装好后 DSH 里<b>任何会话</b>都能用 <code>notify_qq</code> 推给你</li>
      </ol>
      <div class="note">⚠️ <b>如实说明（脚本提醒这一环）</b>：微信版带命令行 <code>dsh-wechat-send</code>，所以「到点提醒」能由本项目的计划任务直接发到微信；
      而 <b>QQ 版目前没有提供命令行</b>（只有设置页的 HTTP 接口和 agent 的 <code>notify_qq</code> 工具）。
      因此<b>到点自动提醒暂时不会走 QQ</b>。想要的话有两条路：
      <ul>
        <li>让「到点提醒」继续走微信 / 企业微信（现在就能用），QQ 只当"随时问电脑"的遥控器；</li>
        <li>去 <code>xcisxc29/dsh-qq-plugin</code> 提一个需求：给一条命令行/HTTP 发送接口（像微信版的 <code>dsh-wechat-send</code>）—— 提了之后本项目可以像微信那样一行接上。</li>
      </ul></div>
    </div></details>
  </div>

  <h2>④ 注意事项（都在这里，别跳过）</h2>
  <div class="card">
    <p><b>先说花钱这件事：token 用量只跟"群里有多少新消息"走，跟开着这个功能本身无关。</b>
    下面是按本机实测数据折算的量级（折算口径：1 个汉字 ≈ 0.6~0.7 token，与项目自带量测工具一致）：</p>
    <table class="tok">
      <tr><th>信息量</th><th>大致用量（输入 + 输出）</th><th>说明</th></tr>
      <tr><td>每条新群消息</td><td><b>约 70~80 token</b></td><td>群消息 OCR 文本平均约 115 字；只送"预筛留下的候选"（约九成），空白/太短/无意义消息在本地就筛掉了</td></tr>
      <tr><td>每轮模型调用（固定开销）</td><td><b>约 1.7 千 token</b></td><td>规则说明 + 已知待办清单 + 包装；一轮里消息越多，这部分被摊得越薄</td></tr>
      <tr><td>一天 50 条消息</td><td>约 <b>2~2.5 万 token</b></td><td>≈ 十来轮调用（每 10 分钟一轮，<b>没有新消息的轮次根本不调模型、不花钱</b>）</td></tr>
      <tr><td>一天 200 条消息</td><td>约 <b>6~7 万 token</b></td><td>活跃的班级群/工作群大概就是这个量级</td></tr>
      <tr><td>一天 500 条消息</td><td>约 <b>12~13 万 token</b></td><td>很活跃的多个群；想省就把白名单收紧、采集周期调长</td></tr>
      <tr><td>对比：我在 DSH 里读一次上下文</td><td><b>二十万 token 量级</b></td><td>也就是：<b>一轮待办抽取 ≈ 你跟我说一句话的几十分之一</b>（而且大部分是缓存命中，更便宜）</td></tr>
    </table>
    <div class="note">实测锚点（本机 4 天 75 条记录，一次性拼成一轮）：prompt 9519 字 ≈ <b>6346 token</b>，其中消息正文 7017 字、固定规则部分约 2500 字。
    旧版（不分批、不压缩）同样内容要 16987 字 ≈ 11325 token —— 现在省了 44%。</div>
  </div>
  <div class="card">
    <ul>
      <li><b>微信/QQ 客户端可能会动一下窗口。</b>微信采集默认走"伪最小化"（不打扰你，读完还原）；QQ 走 Maa 后台截图+后台点击，正常情况下不动你的窗口。但如果 QQ 主面板不在「群聊」列表、或在屏幕外/最小化，那一轮会采不到 —— <b>把要盯的群置顶最省事</b>。</li>
      <li><b>电脑要开机、别睡眠</b>（锁屏没关系）。DSH 关着时采集/提醒/自检仍按计划任务跑，但"抽成待办"要 DSH 在跑 —— 上面那个「开机自动启动 DSH」就是为这个准备的。</li>
      <li><b>被提醒吵不到你，多半是这三件事：</b>把机器人对话设了免打扰；手机没给微信通知权限；微信 iLink 的"会话有效期"过了（提醒会排队，你下次给机器人发条消息就补发 —— 企微兜底就是为这个准备的）。</li>
      <li><b>QQ 后台采集需要 VC++ 2015-2022 运行库</b>（安装器会检测并提示；缺了 QQ 自动退回屏幕模式并留日志，不会崩）。</li>
      <li><b>卸载</b>：跑包里的 <code>卸载.ps1</code>（默认<b>不动数据</b>）；想彻底清掉（含内置的约 89MB Maa 运行库）—— 确认数据不要了，把整个安装目录删掉即可，项目不会往目录外写文件。</li>
    </ul>
  </div>
</div>

<div class="bar" id="bar">
  <button id="export">确定</button>
  <button class="ghost" id="reset">放弃改动</button>
  <button class="ghost" id="stopSrv" style="display:none">停止服务</button>
  <span class="tip" id="acWrap" style="display:none"><label style="cursor:pointer"><input type="checkbox" id="autoclose" checked style="vertical-align:-2px"> 应用成功后自动关闭本页并停止服务（想连着改多项就取消勾选）</label></span>
  <span id="barText" class="tip">还没改动</span>
  <span class="tip">点「确定」= 生成改动文件（不会直接改本机）；然后按页面顶部那行命令应用它</span>
</div>

<script id="console-data" type="application/json">__DATA__</script>
<script>
(function () {
  // 是不是"服务模式"：页面由 控制台-服务.mjs（只监听 127.0.0.1）提供时，点确定可以直接应用；
  // ⚠️ 文件模式已停用：不是从本地服务打开时（file:// 等），页面直接提示"请用 打开控制台.cmd 打开"。
  var TOKEN = '';
  try { TOKEN = new URLSearchParams(location.search).get('t') || ''; } catch (e) { TOKEN = ''; }
  var SERVER = (location.protocol === 'http:' || location.protocol === 'https:') && !!TOKEN;
  var data = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(document.getElementById('console-data').textContent.trim()), function (c) { return c.charCodeAt(0); })));
  var genEl = document.getElementById('gen');
  genEl.textContent = data.generatedAt || '-';
  var NOCHANGE = '还没改动';
  // 服务停了要**当场告诉用户**（不能再等"点了确定才发现连不上"）：
  // 打开页面先 ping 一次；之后每 5 分钟心跳一次（顺带让服务在"页面还开着"时不至于空转超时退出）。
  var serviceDead = false;
  var staleMarked = false;
  // "旧页签"：同一个端口上服务重开过 → 旧页签带的 token 已经失效。ping 会回 tokenOk:false，据此认出来。
  // （用户实测过"一次开了两个网页"，根因就是旧页签没人管；关标签页只能由用户做，但页面可以自己说清。）
  function markStale() {
    if (staleMarked) { return; }
    staleMarked = true;
    var b = document.getElementById('banner');
    if (b) {
      b.className = 'warnbox';
      b.innerHTML = '<b>⚠️ 这一页是上一次打开的控制台，已经失效了 —— 请关掉它</b><br>'
        + '原因：控制台服务重新启动过，token 换了；这一页点「确定」不会生效（会报 token 不匹配）。<br>'
        + '<b>怎么办</b>：按 Ctrl+W 关掉这一页，用最新打开的那个页签；或者双击 <code>群聊待办/打开控制台.cmd</code> 重开。<br>'
        + '（这一页不用管了 —— 直接关掉即可；下载补丁的老方式已停用。）';
    }
    setBar('⚠️ 这是旧的页签（token 已失效）—— 关掉它就行', 'bad');
    // 尽力而为：如果这个页签是脚本打开的，能自己关掉；用户手动开的会被浏览器拒绝（那就靠上面的提示）
    try { window.close(); } catch (e) { }
    setTimeout(function () { try { window.close(); } catch (e) { } }, 500);
  }
  function markDead() {
    if (serviceDead) { return; }
    serviceDead = true;
    var b = document.getElementById('banner');
    if (!b) { return; }
    b.className = 'warnbox';
    b.innerHTML = '<b>⚠️ 本地控制台服务已停止 —— 这一页现在不能"一键应用"了</b><br>'
      + '常见原因：上次应用完成后**自动停止**了（默认行为）/ 空闲 30 分钟自动退出 / 手动点了「停止服务」。<br>'
      + '<b>恢复一键应用</b>：双击 <code>群聊待办/打开控制台.cmd</code>，会重新打开一个能一键应用的页面。<br>'
      + '（这一页不用管了 —— 直接关掉即可；想改设置就用最新打开的那一页，或双击 打开控制台.cmd。）';
  }
  function pingService() {
    return fetch('ping?t=' + TOKEN).then(function (r) {
      if (!r.ok) { markDead(); return false }
      return r.json().then(function (j) {
        if (j && j.ok === true && j.tokenOk === false) { markStale(); return false }   // 旧页签
        return true
      }).catch(function () { return true })
    }).catch(function () { markDead(); return false })
  }
  if (SERVER) {
    document.body.className = 'server';
    var stopBtn = document.getElementById('stopSrv');
    stopBtn.style.display = 'inline-block';
    stopBtn.addEventListener('click', function () {
      setBar('正在停止本地服务……', 'hot');
      fetch('quit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: TOKEN }) })
        .then(function () { setBar('本地服务已停止；要再一键应用，双击 群聊待办/打开控制台.cmd 重新起一个', 'hot'); })
        .catch(function () { setBar('停止请求失败（服务可能已经退出了）', 'bad'); });
    });
    // "用完自动收摊"（用户要求）：应用成功后自动关页 + 停服务。默认开，想连着改多项就取消勾选（选择记在浏览器里）。
    var acWrap = document.getElementById('acWrap');
    var acBox = document.getElementById('autoclose');
    acWrap.style.display = 'block';
    try { if (localStorage.getItem('consoleAutoclose') === '0') { acBox.checked = false; } } catch (e) { }
    acBox.addEventListener('change', function () {
      try { localStorage.setItem('consoleAutoclose', acBox.checked ? '1' : '0'); } catch (e) { }
      setBar(acBox.checked ? '已开启：应用成功后自动关闭本页并停止服务' : '已关闭：应用成功后页面留着，可以接着改', 'hot');
    });
    pingService();
    setInterval(pingService, 5 * 60 * 1000);
  }
  // 列表字段一律经 joinList：老状态里可能是字符串（PS 的单元素数组压平），直接 .join 会让整页脚本死掉
  function joinList(v) { return Array.isArray(v) ? v.join(', ') : (v === null || v === undefined ? '' : String(v)); }
  var baseline = {
    collect: data.config.collectMinutes, remind: data.config.remindMinutes, selfcheck: data.config.selfcheckMinutes,
    webhook: data.wecom.webhook || '', aliases: joinList(data.aliases),
    wxwl: joinList(data.whitelistWx), qqwl: joinList(data.whitelistQq),
    autostart: (data.autostart && data.autostart.enabled) ? '1' : '0'
  };
  var ids = ['collect', 'remind', 'selfcheck', 'webhook', 'aliases', 'wxwl', 'qqwl'];
  function val(id) {
    var el = document.getElementById(id);
    return el.type === 'checkbox' ? (el.checked ? '1' : '0') : el.value.trim();
  }
  function setBar(text, cls) {
    var el = document.getElementById('barText');
    el.textContent = text;
    el.className = 'tip' + (cls ? ' ' + cls : '');
  }
  function changedCount() {
    var n = 0;
    ids.forEach(function (id) {
      var el = document.getElementById(id);
      if (val(id) !== String(baseline[id] || '').trim()) { n++; el.classList.add('changed'); } else el.classList.remove('changed');
    });
    var ast = document.getElementById('autostart');
    if (val('autostart') !== baseline.autostart) { n++; ast.classList.add('changed'); } else ast.classList.remove('changed');
    return n;
  }
  function syncBar() {
    var n = changedCount();
    if (n) { setBar('有 ' + n + ' 处改动待应用 —— 点「确定」生成改动文件', 'hot'); } else { setBar(NOCHANGE, ''); }
  }
  ids.concat(['autostart']).forEach(function (id) {
    document.getElementById(id).addEventListener('input', syncBar);
    document.getElementById(id).addEventListener('change', syncBar);
  });

  // 分隔符切分：**不写正则**（页面脚本在模板字符串里，反斜杠会被吃掉一层，换行转义会变成真换行把正则劈开）
  function splitList(s) {
    var out = [], cur = '';
    var LF = String.fromCharCode(10), CR = String.fromCharCode(13);
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (ch === ',' || ch === '，' || ch === '、' || ch === ';' || ch === '；' || ch === LF || ch === CR) { out.push(cur); cur = ''; }
      else { cur += ch; }
    }
    out.push(cur);
    return out.map(function (x) { return x.trim(); }).filter(Boolean);
  }

  document.getElementById('reset').addEventListener('click', function () {
    ids.forEach(function (id) { document.getElementById(id).value = baseline[id]; });
    document.getElementById('autostart').checked = baseline.autostart === '1';
    syncBar();
  });

  document.getElementById('export').addEventListener('click', function () {
    if (changedCount() === 0) { setBar('还没有改动 —— 先改上面任意一项，再点「确定」', 'bad'); return; }
    var iv = {
      collectMinutes: parseInt(document.getElementById('collect').value, 10),
      remindMinutes: parseInt(document.getElementById('remind').value, 10),
      selfcheckMinutes: parseInt(document.getElementById('selfcheck').value, 10)
    };
    var bad = [];
    if (!(iv.collectMinutes >= 15)) { bad.push('采集周期'); }
    if (!(iv.remindMinutes >= 1)) { bad.push('提醒周期'); }
    if (!(iv.selfcheckMinutes >= 30)) { bad.push('自检周期'); }
    if (bad.length > 0) { setBar('这些必须填正整数（周期有下限）：' + bad.join('、'), 'bad'); return; }
    var p = {
      kind: 'console-changes', version: 2, exportedAt: new Date().toISOString(),
      intervals: iv,
      wecomWebhook: document.getElementById('webhook').value.trim(),
      aliases: splitList(document.getElementById('aliases').value),
      whitelistWx: splitList(document.getElementById('wxwl').value),
      whitelistQq: splitList(document.getElementById('qqwl').value),
      autostartDsh: document.getElementById('autostart').checked
    };
    // ⚠️ 2026-10-16 用户要求：**只保留"一键应用"**（本地服务版）。文件模式（下载/复制补丁 + 手动 -Apply）已停用。
    // 所以这里只有一条路：POST 给本地服务。服务不在/是旧页签时，前面已经挂了横幅说明怎么恢复。
    if (!SERVER) {
      setBar('⚠️ 这一页不是从本地服务打开的（文件模式已停用）—— 请双击 群聊待办/打开控制台.cmd 打开控制台', 'bad');
      return;
    }
    if (serviceDead || staleMarked) {
      setBar('⚠️ 本地服务已停止/本页已过期 —— 请双击 群聊待办/打开控制台.cmd 重新打开（这一页可以直接关掉）', 'bad');
      return;
    }
    setBar('正在应用到本机……（这一小会儿别关窗口）', 'hot');
    fetch('apply', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: TOKEN, patch: p })
    }).then(function (r) { return r.json(); }).then(function (j) {
      if (j && j.ok) {
        var acOn = document.getElementById('autoclose').checked;
        var head = (j.applied ? '✅ 已应用并生效' : '补丁里没有需要改的东西（什么都没动）');
        if (acOn) {
          // 用完自动收摊：先停服务，再关页；关不掉（浏览器不允许非脚本打开的页签自杀）就明确告诉用户手动关
          setBar(head + ' —— 2 秒后自动关闭本页并停止服务', 'hot');
          setTimeout(function () {
            fetch('quit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: TOKEN }) }).catch(function () { });
            setTimeout(function () { try { window.close(); } catch (e) { } }, 400);
            setTimeout(function () {
              var b = document.getElementById('banner');
              if (b) {
                b.className = 'warnbox';
                b.innerHTML = '<b>✅ 已经应用完成，本地服务也已停止</b><br>'
                  + '浏览器不允许网页自己关掉这个标签页（它不是由脚本打开的）—— 手动关掉这一页即可。<br>'
                  + '想再改设置：双击 <code>群聊待办/打开控制台.cmd</code> 重新打开。';
              }
              setBar('✅ 已应用完成、服务已停止 —— 手动关掉这个页签就行', 'hot');
            }, 1300);
          }, 2000);
        } else {
          setBar(head + ' —— 页面马上刷新显示新配置（服务继续运行，可以接着改）', 'hot');
          setTimeout(function () { location.reload(); }, 1800);
        }
      } else {
        var why = (j && (j.error || ('退出码 ' + j.code))) || '未知原因';
        setBar('❌ 应用失败：' + why + ' —— 可以再点一次「确定」重试；仍不行就关掉这一页、双击 打开控制台.cmd 重开', 'bad');
        if (j && j.code === 2) { setBar('（补丁里没有需要改的东西 —— 什么都没动）', 'hot'); }
      }
    }).catch(function (e) {
      markDead();
      setBar('❌ 连不上本地服务（' + e.message + '）—— 请双击 群聊待办/打开控制台.cmd 重新打开控制台', 'bad');
    });
  });

  syncBar();
})();
</script>
</body>
</html>
`

const payload = {
  generatedAt: S.generatedAt, config: cfg, wecom: wecom, aliases: asArr(S.aliases),
  whitelistWx: asArr(S.whitelistWx), whitelistQq: asArr(S.whitelistQq), rulesText: S.rulesText || '',
  autostart: { enabled: !!(S.autostart && S.autostart.enabled) }
}
const b64 = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64')
// 2026-10-18：版本横幅（读自检写的 群聊待办/最新版本提示.txt；已最新/离线 → 空）
function versionBarHtml() {
  try {
    const p = join(here, '最新版本提示.txt')
    if (!existsSync(p)) return ''
    const fs = readFileSync(p, 'utf8').trim().split('|')
    if (fs.length >= 4 && fs[0] === 'OUTDATED') {
      const safe = fs[3].replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      return '<div style="margin:10px 0 0;padding:10px 12px;border-radius:10px;background:#fff6e5;border:1px solid #f0dcb0;color:#7a4d00;font-size:13.5px;">⚠️ ' + safe + '</div>'
    }
  } catch { }
  return ''
}
writeFileSync(out, html.replace('__DATA__', b64).replace('__VERBAR__', versionBarHtml()), 'utf8')
console.log('控制台.html 已生成：' + out)
