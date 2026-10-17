# 推送.ps1 —— 统一的手机推送模块（个人微信【优先】/ QQ / 企业微信机器人 / ntfy 多通道）
#
# 用法：. "$PSScriptRoot\推送.ps1";  Send-PhonePush -Title '标题' -Text '正文'
# 通道策略（2026-10-15 起）：**个人微信优先**（腾讯官方 iLink 机器人，经 dsh-wechat-plugin 的
#   dsh-wechat-send CLI 发出；只在 enabled=true 且发送成功时生效），失败才走企业微信机器人兜底，
#   再之后是 dingtalk / email / wecomApp / ntfy（按配置）。
# 配置：dsh-接入\提醒配置.json 里的 phonePush 段
#   {
#     "enabled": true,
#     "wechat": { "enabled": true, "nodePath": "...node.exe", "cliPath": "...dsh-wechat-plugin\\cli.js" },
#     "wecom":  { "webhook": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx" }
#   }

# ⚠️ 所有出站 HTTP 一律走 **直连**（绕开系统代理）+ 重试。
# 为什么必须这样、踩过什么坑 → 见 直连HTTP.ps1 顶部（一句话：这台机器的系统代理
# 127.0.0.1:<旧代理端口> 经常不在，走它会让**所有手机推送静默失败**）。这里 dot-source 复用。
. (Join-Path $PSScriptRoot '直连HTTP.ps1')

function Get-PushConfig {
  $cfgFile = Join-Path $PSScriptRoot '提醒配置.json'
  if (-not (Test-Path -LiteralPath $cfgFile)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8
    $cfg = $raw -replace '^\uFEFF', '' | ConvertFrom-Json
    return $cfg.phonePush
  } catch { return $null }
}

# 按 UTF-8 字节数安全截断字符串（中文不会在字符中间被切断）
function Limit-Utf8Bytes([string]$s, [int]$maxBytes) {
  if ($null -eq $s) { return '' }
  if ($maxBytes -le 0) { return '' }
  if ([Text.Encoding]::UTF8.GetByteCount($s) -le $maxBytes) { return $s }
  # ⚠️ 2026-10-15 修（另一个 AI 复测 §5.1）：原来逐个 `char` 累加，而 emoji 是**代理对**（占 2 个 char）
  #    → 可能在中间被切断，留下一个孤立的高代理项，显示成 `�`（实测坏尾 = U+D83C）。
  #    现在把代理对当一个单位处理，不会再切出半个字符。
  $sb = New-Object System.Text.StringBuilder
  $used = 0
  $i = 0
  while ($i -lt $s.Length) {
    $len = 1
    if ([char]::IsHighSurrogate($s[$i]) -and ($i + 1) -lt $s.Length -and [char]::IsLowSurrogate($s[$i + 1])) { $len = 2 }
    $unit = $s.Substring($i, $len)
    $b = [Text.Encoding]::UTF8.GetByteCount($unit)
    if (($used + $b) -gt $maxBytes) { break }
    [void]$sb.Append($unit)
    $used += $b
    $i += $len
  }
  return $sb.ToString()
}

# ============ 个人微信通道（腾讯官方 iLink 机器人）============
# 发送走 dsh-wechat-plugin 自带的 `dsh-wechat-send` CLI（node 跑 cli.js）。
# 为什么用它而不是自己连 iLink 接口：CLI 和插件**共用同一份配额计数**（一个回复窗口最多连发 10 条），
# 而且消息发不出去时会进插件的排队（pendingNotifications），你下次给机器人发消息时补发 —— 自己直连会绕过这一切。
# 注意：iLink 的"会话有效期"（你最后一条消息之后几分钟~二十几分钟）过了以后，主动推送会被拒收排队，
# 所以 Send-PhonePush 把它当"优先通道"而不是"唯一通道"：失败就走企业微信兜底。
function Send-WechatPush {
  param([string]$Title, [string]$Text, $WechatCfg)
  if (-not $WechatCfg -or $WechatCfg.enabled -ne $true) { return $false }
  $node = [string]$WechatCfg.nodePath
  $cli = [string]$WechatCfg.cliPath
  if ([string]::IsNullOrWhiteSpace($node) -or [string]::IsNullOrWhiteSpace($cli)) { return $false }
  if (-not (Test-Path -LiteralPath $node) -or -not (Test-Path -LiteralPath $cli)) {
    Write-Host '  微信推送跳过：node.exe 或 cli.js 不存在（插件还没装？）'
    return $false
  }
  if ($null -eq $Text) { $Text = '' }
  $msg = "【$Title】`n$Text"
  if ([Text.Encoding]::UTF8.GetByteCount($msg) -gt 1900) {
    $msg = "【$Title】`n" + (Limit-Utf8Bytes $Text 1800) + '…'
  }
  try {
    # 用 `&` 直调 + stderr 重定向到文件（不手工拼命令行、也不走管道重定向，中文/换行/引号都安全）
    $errFile = Join-Path $env:TEMP ('wechat-send-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    & $node $cli $msg 2> $errFile
    $code = $LASTEXITCODE
    if ($code -eq 0) {
      Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
      return $true
    }
    $errText = ''
    if (Test-Path -LiteralPath $errFile) {
      $errText = (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -replace "\r?\n", ' '
      Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("  微信推送失败(exit={0})：{1}" -f $code, $errText)
    return $false
  } catch {
    Write-Host ("  微信推送异常：" + $_.Exception.Message)
    return $false
  }
}

function Send-QqPush {
  # QQ 通道（2026-10-17 加）
  #
  # 为什么要自己写：`dsh-qq-plugin` 只把发送暴露成 **agent 工具**（send_to_qq / notify_qq），没有 CLI、
  # 也没有可调的 HTTP 路由；而提醒器要的是"没有 AI 回合也能发一条"。微信那边插件自带 dsh-wechat-send CLI，
  # QQ 这边缺这一层 —— 所以写了 `发QQ.mjs`：读插件已经存好的凭据（AppID/AppSecret/userOpenid），
  # 直连腾讯官方机器人 API（getAppAccessToken → /v2/users/<openid>/messages），不走 DSH、不需要 AI 回合。
  #
  # **零设置**：只要用户在 DSH 里扫码绑定过 QQ（插件会写 ~\.dsh\qq\state.json），这里就自动可用；
  # 想关掉就在 提醒配置.json 里把 phonePush.qq.enabled 设成 false。
  param([string]$Title, [string]$Text, $QqCfg)
  if ($null -ne $QqCfg -and $QqCfg.enabled -eq $false) { return $false }
  $script = Join-Path $PSScriptRoot '发QQ.mjs'
  if (-not (Test-Path -LiteralPath $script)) { return $false }
  # 自动检测：没绑定过 QQ 就静默跳过（不要每轮都报错）
  $stateFile = Join-Path $env:USERPROFILE '.dsh\qq\state.json'
  if (-not (Test-Path -LiteralPath $stateFile)) { return $false }
  try {
    $st = ([System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8)) -replace '^\uFEFF', '' | ConvertFrom-Json
    $accId = @($st.accounts.PSObject.Properties.Name) | Select-Object -First 1
    if (-not $accId) { return $false }
  } catch { return $false }

  $node = if ($null -ne $QqCfg -and $QqCfg.nodePath) { [string]$QqCfg.nodePath } else { '' }
  if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) {
    # 没配就自己找 DSH 自带的 node
    foreach ($cand in @((Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'))) {
      if (Test-Path -LiteralPath $cand) { $node = $cand; break }
    }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node -and $cmd) { $node = $cmd.Source }
  }
  if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) {
    Write-Host '  QQ 推送跳过：找不到 node.exe'
    return $false
  }

  if ($null -eq $Text) { $Text = '' }
  $msg = "【$Title】`n$Text"
  if ([Text.Encoding]::UTF8.GetByteCount($msg) -gt 1900) { $msg = "【$Title】`n" + (Limit-Utf8Bytes $Text 1800) + '…' }
  $errFile = Join-Path $env:TEMP ('qq-send-err-' + [guid]::NewGuid().ToString('N') + '.txt')
  try {
    & $node $script --text $msg 2> $errFile
    $code = $LASTEXITCODE
    if ($code -eq 0) {
      Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
      return $true
    }
    $errText = ''
    if (Test-Path -LiteralPath $errFile) {
      $errText = (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -replace "\r?\n", ' '
      Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host ("  QQ 推送失败(exit={0})：{1}" -f $code, $errText)
    return $false
  } catch {
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    Write-Host ("  QQ 推送异常：" + $_.Exception.Message)
    return $false
  }
}

function Send-WecomPush {
  param([string]$Title, [string]$Text, $WecomCfg)
  # ⚠️ 2026-10-15 修（另一个 AI 复测 §4.4 指出"截断无边界检查"，实际比报的还严重两层）：
  #   ① 外面判的是 **UTF-8 字节数**（企业微信 text 上限 2000 字节），里面却按 **字符数** `Substring(0,600)`
  #      → 中文 3 字节/字，600 字 ≈ 1800 字节，加上标题仍可能**超过 2000 字节**被接口拒收；
  #   ② `$Text` 短于 600 时 `Substring(0,600)` 直接抛 `ArgumentOutOfRangeException`，
  #      整条企业微信推送会挂在这（而不是发个短的）。
  #   改成按**字节**安全截断：中文不会被截成半个字，也不会超限。
  if ($null -eq $Text) { $Text = '' }
  if (-not $WecomCfg -or [string]::IsNullOrWhiteSpace($WecomCfg.webhook)) { return $false }
  try {
    # 为什么要有 mention 这一支：企业微信群机器人发的消息**手机端默认不弹通知**，
    # 只会在群列表里多一条未读（用户实测："没有弹窗，得点开看"）。
    # 而 text 类型支持 @（mentioned_list），**被 @ 到是会弹通知的** → 用 @ 换弹窗。
    # markdown 类型不支持 @，所以这里发 text（内容本来就是纯文字，损失不大）。
    $mention = ''
    if ($WecomCfg.PSObject.Properties['mention']) { $mention = [string]$WecomCfg.mention }
    if (-not [string]::IsNullOrWhiteSpace($mention)) {
      $mlist = @()
      # ⚠️ 2026-10-15 深夜修（外部审查）：用户写成中文"@所有人"时原来被当 userid 传出去 → 接口拒 →
      #   退回 markdown（消息能到但不弹通知）。现在三种写法都归一成 @all。
      if ($mention -eq '@all' -or $mention -eq 'all' -or $mention -eq '@所有人' -or $mention -eq '所有人') { $mlist = @('@all') } else { $mlist = @($mention -split '[,;，；]\s*' | Where-Object { $_ }) }
      $content = "【$Title】`n$Text"
      if ([Text.Encoding]::UTF8.GetByteCount($content) -gt 2000) {
        # 按字节留出预算：标题 + 换行 + 省略号提示，剩下的给正文
        $budget = 1900 - [Text.Encoding]::UTF8.GetByteCount("【$Title】`n") - [Text.Encoding]::UTF8.GetByteCount('…（太长已截断，看日志/待办文件）')
        if ($budget -lt 200) { $budget = 200 }   # 外部审查：标题极长时预算可为负 → 正文被静默清空，只发标题
        $content = "【$Title】`n" + (Limit-Utf8Bytes $Text $budget) + "…（太长已截断，看日志/待办文件）"
      }
      $payload = @{ msgtype = 'text'; text = @{ content = $content; mentioned_list = $mlist } } | ConvertTo-Json -Depth 5 -Compress
    } else {
      # markdown：标题加粗，正文原样；企业微信 markdown 上限 4096 字节
      $content = "**$Title**`n$Text"
      if ([Text.Encoding]::UTF8.GetByteCount($content) -gt 4000) {
        $budget = 3900 - [Text.Encoding]::UTF8.GetByteCount("**$Title**`n") - 3
        if ($budget -lt 200) { $budget = 200 }
        $content = "**$Title**`n" + (Limit-Utf8Bytes $Text $budget) + '…'
      }
      $payload = @{ msgtype = 'markdown'; markdown = @{ content = $content } } | ConvertTo-Json -Depth 5 -Compress
    }
    $r = Invoke-DirectHttp -Uri $WecomCfg.webhook -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 20
    if ($r.errcode -eq 0) { return $true }
    Write-Host ("  企业微信推送失败：errcode=" + $r.errcode + " " + $r.errmsg)
    # @ 失败（比如机器人不允许 @all）就退回 markdown 再试一次，至少消息能到
    if (-not [string]::IsNullOrWhiteSpace($mention)) {
      Write-Host '  （@ 方式失败，退回 markdown 再发一次）'
      $content2 = "**$Title**`n$Text"
      $p2 = @{ msgtype = 'markdown'; markdown = @{ content = $content2 } } | ConvertTo-Json -Depth 5 -Compress
      $r2 = Invoke-DirectHttp -Uri $WecomCfg.webhook -Body ([Text.Encoding]::UTF8.GetBytes($p2)) -TimeoutSec 20
      if ($r2.errcode -eq 0) { return $true }
    }
    return $false
  } catch {
    Write-Host ("  企业微信推送异常：" + $_.Exception.Message)
    return $false
  }
}

function Send-DingTalkPush {
  param([string]$Title, [string]$Text, $DingCfg)
  if (-not $DingCfg -or [string]::IsNullOrWhiteSpace($DingCfg.webhook)) { return $false }
  try {
    # 钉钉"自定义关键词"安全设置要求正文里必须出现关键词，没出现就补上
    $kw = '待办'
    if ($DingCfg.keyword) { $kw = [string]$DingCfg.keyword }
    $content = "**$Title**`n$Text"
    if (-not $content.Contains($kw)) { $content = "【$kw】`n" + $content }
    if ([Text.Encoding]::UTF8.GetByteCount($content) -gt 18000) { $content = $content.Substring(0, 4000) + '…' }
    $payload = @{ msgtype = 'markdown'; markdown = @{ title = $Title; text = $content } } | ConvertTo-Json -Depth 5 -Compress
    $r = Invoke-DirectHttp -Uri $DingCfg.webhook -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 20
    if ($r.errcode -eq 0) { return $true }
    Write-Host ("  钉钉推送失败：errcode=" + $r.errcode + " " + $r.errmsg)
    return $false
  } catch {
    Write-Host ("  钉钉推送异常：" + $_.Exception.Message)
    return $false
  }
}

function Send-EmailPush {
  param([string]$Title, [string]$Text, $MailCfg)
  if (-not $MailCfg -or $MailCfg.enabled -ne $true) { return $false }
  if ([string]::IsNullOrWhiteSpace($MailCfg.user) -or [string]::IsNullOrWhiteSpace($MailCfg.pass)) { return $false }
  try {
    $to = if ($MailCfg.to) { [string]$MailCfg.to } else { [string]$MailCfg.user }
    $port = if ($MailCfg.port) { [int]$MailCfg.port } else { 587 }
    $smtp = if ($MailCfg.smtp) { [string]$MailCfg.smtp } else { 'smtp.qq.com' }
    $msg = New-Object System.Net.Mail.MailMessage
    $msg.From = New-Object System.Net.Mail.MailAddress([string]$MailCfg.user, 'DSH 群聊待办')
    $msg.To.Add($to)
    $msg.Subject = $Title
    $msg.SubjectEncoding = [Text.Encoding]::UTF8
    $msg.Body = $Text
    $msg.BodyEncoding = [Text.Encoding]::UTF8
    $msg.IsBodyHtml = $false
    $client = New-Object System.Net.Mail.SmtpClient($smtp, $port)
    $client.EnableSsl = $true
    $client.Credentials = New-Object System.Net.NetworkCredential([string]$MailCfg.user, [string]$MailCfg.pass)
    $client.Timeout = 20000
    $client.Send($msg)
    $msg.Dispose()
    $client.Dispose()
    return $true
  } catch {
    Write-Host ("  邮件推送失败：" + $_.Exception.Message)
    return $false
  }
}

# ⚠️ 出站 ntfy 通道 2026-10-14 **已弃用**（用户决定）：手机提醒统一走企业微信 @所有人。
#    这段代码保留但配置里 topic 留空 → 永远不会被调到（主题实测过：老 topic 发得进读不回）。
#    别和"入站"混了：手机通知**转发进来**用的是 接收端.ps1 + 转发接收配置.json，那个还在跑。
function Send-NtfyPush {
  param([string]$Title, [string]$Text, $NtfyCfg)
  if (-not $NtfyCfg -or [string]::IsNullOrWhiteSpace($NtfyCfg.topic)) { return $false }
  try {
    $priority = 3
    if ($NtfyCfg.priority -eq 'high') { $priority = 4 }
    elseif ($NtfyCfg.priority -eq 'urgent') { $priority = 5 }
    elseif ($NtfyCfg.priority -eq 'low') { $priority = 2 }
    $tags = @('bell')
    if ($NtfyCfg.tags) { $tags = @($NtfyCfg.tags) }
    $payload = [ordered]@{
      topic = $NtfyCfg.topic; title = $Title; message = $Text; priority = $priority; tags = $tags
    } | ConvertTo-Json -Depth 4 -Compress
    $headers = @{}
    if ($NtfyCfg.token) { $headers['Authorization'] = 'Bearer ' + $NtfyCfg.token }
    # ⚠️ 2026-10-15 补 server 兜底（另一个 AI 复测 §4.2）：原来直接 `$NtfyCfg.server.TrimEnd('/')`，
    # 配置里只写 topic 没写 server 时，会拼出 'https:///topic' 这种非法 URL（或直接抛异常），
    # 报错信息还很难懂。现在：缺省用官方服务；真为空也不炸。
    $srv = [string]$NtfyCfg.server
    if ([string]::IsNullOrWhiteSpace($srv)) { $srv = 'https://ntfy.sh' }
    $null = Invoke-DirectHttp -Uri ($srv.TrimEnd('/')) -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -Headers $headers -TimeoutSec 20
    return $true
  } catch {
    Write-Host ("  ntfy 推送失败：" + $_.Exception.Message)
    return $false
  }
}

# ============ 企业微信【应用消息】（自建应用）============
# 为什么需要它：
#   ① **群机器人发不出"群公告"**（webhook 只支持 text/markdown/markdown_v2/image/news/file/voice/template_card）；
#   ② 机器人消息手机端经常不弹通知（只有 text + @all 才比较可靠）。
#   自建应用的**应用消息**是"以应用身份发给个人"，跟正常消息一样**必然弹通知**，这是最稳的一条路。
#
# 开启需要四个值（企业管理后台 → 应用管理 → 自建 → 创建应用）：
#   corpid  : 我的企业 → 企业信息 → 企业ID
#   secret  : 应用详情页 → Secret（点"查看"）
#   agentid : 应用详情页 → AgentId
#   touser  : 你的 userid（通讯录里点开自己 → 账号），**必填**
# ⚠️ 刻意不默认 @all：如果这是公司/学校的真实企业，@all 会把消息发给所有同事。
function Get-WecomAppToken {
  param($AppCfg)
  $stateDir = Join-Path $PSScriptRoot 'state'
  $cacheFile = Join-Path $stateDir 'wecom-app-token.json'
  # 缓存复用（access_token 有效期 7200 秒，这里留 5 分钟余量）
  if (Test-Path -LiteralPath $cacheFile) {
    try {
      $c = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($c.token -and $c.corpid -eq $AppCfg.corpid -and ([datetime]$c.expires) -gt (Get-Date).AddMinutes(5)) { return [string]$c.token }
    } catch { }
  }
  $uri = "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=$($AppCfg.corpid)&corpsecret=$($AppCfg.secret)"
  $r = Invoke-DirectHttpGet -Uri $uri -TimeoutSec 20
  if ($r.errcode -ne 0) { Write-Host ("  企业微信取 token 失败：errcode=" + $r.errcode + " " + $r.errmsg); return '' }
  try {
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
    @{ token = $r.access_token; expires = (Get-Date).AddSeconds([int]$r.expires_in).ToString('o'); corpid = [string]$AppCfg.corpid } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath $cacheFile -Encoding UTF8
  } catch { }
  return [string]$r.access_token
}

function Send-WecomAppPush {
  param([string]$Title, [string]$Text, $AppCfg)
  if (-not $AppCfg) { return $false }
  # 开关：默认关（2026-10-14 用户说"算了"，不再折腾可信IP）。参数都留着，想用时把 enabled 改 true 即可。
  if ($AppCfg.PSObject.Properties['enabled'] -and $AppCfg.enabled -ne $true) { return $false }
  if ([string]::IsNullOrWhiteSpace($AppCfg.corpid) -or [string]::IsNullOrWhiteSpace($AppCfg.secret) -or [string]::IsNullOrWhiteSpace($AppCfg.agentid)) { return $false }
  if ([string]::IsNullOrWhiteSpace($AppCfg.touser)) {
    Write-Host '  企业微信应用消息：没配 touser（你的 userid）→ 跳过。故意不默认 @all，免得发给全公司。'
    return $false
  }
  try {
    $token = Get-WecomAppToken -AppCfg $AppCfg
    if (-not $token) { return $false }
    $payload = @{
      touser                 = [string]$AppCfg.touser
      msgtype                = 'text'
      agentid                = [int]$AppCfg.agentid
      text                   = @{ content = "【$Title】`n$Text" }
      safe                   = 0
      enable_duplicate_check = 0
    } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-DirectHttp -Uri ("https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=$token") -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 20
    if ($r.errcode -eq 0) { return $true }
    Write-Host ("  企业微信应用消息失败：errcode=" + $r.errcode + " " + $r.errmsg + "（常见：60011 无权限 / 81013 userid 不对或不在应用可见范围）")
    return $false
  } catch {
    Write-Host ("  企业微信应用消息异常：" + $_.Exception.Message)
    return $false
  }
}

function Send-PhonePush {
  param([string]$Title, [string]$Text)
  $p = Get-PushConfig
  if (-not $p -or $p.enabled -eq $false) { return 'disabled' }
  # 微信(个人)优先：成功就只发微信，不再走其它通道（避免手机响两次）
  # 顺序：默认「微信 → QQ → 企业微信/邮件/ntfy」；把 phonePush.qq.prefer 设为 true 则 QQ 排第一。
  $qqFirst = ($null -ne $p.qq -and $p.qq.prefer -eq $true)
  if ($qqFirst -and (Send-QqPush -Title $Title -Text $Text -QqCfg $p.qq)) { return 'qq' }
  if (Send-WechatPush -Title $Title -Text $Text -WechatCfg $p.wechat) { return 'wechat' }
  # QQ 通道：绑过 QQ 就自动可用（零设置）；成功就返回，避免手机响两次
  if (-not $qqFirst -and (Send-QqPush -Title $Title -Text $Text -QqCfg $p.qq)) { return 'qq' }
  $ok = @()
  if (Send-WecomPush -Title $Title -Text $Text -WecomCfg $p.wecom) { $ok += 'wecom' }
  if (Send-DingTalkPush -Title $Title -Text $Text -DingCfg $p.dingtalk) { $ok += 'dingtalk' }
  if (Send-EmailPush -Title $Title -Text $Text -MailCfg $p.email) { $ok += 'email' }
  if (Send-WecomAppPush -Title $Title -Text $Text -AppCfg $p.wecomApp) { $ok += 'wecomApp' }
  if (Send-NtfyPush -Title $Title -Text $Text -NtfyCfg $p.ntfy) { $ok += 'ntfy' }
  if ($ok.Count -eq 0) { return 'none' }
  return ($ok -join '+')
}






