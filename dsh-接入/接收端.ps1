# 接收端.ps1 —— 把手机转发过来的通知（QQ/微信）变成标准采集记录，落进同一个 spool
#
# 链路：手机通知 → 转发 App → ntfy 主题 → 本脚本定时拉取 → wx-采集器/spool/*.jsonl
#       → dsh-msg-memo 插件抽待办 → 群聊待办/todos.json → 提醒器（电脑+手机）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\接收端.ps1            # 拉一次
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\接收端.ps1 -Peek      # 只看会收到什么，不写 spool
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\接收端.ps1 -TestPush  # 往入站主题发一条假通知，验证链路
param(
  [switch]$Peek,
  [switch]$TestPush,
  [int]$FirstRunDays = 1
)

$ErrorActionPreference = 'Stop'
# 出站 HTTP 一律直连（绕开这台机器上经常不在的系统代理）—— 见 直连HTTP.ps1 顶部说明
. (Join-Path $PSScriptRoot '直连HTTP.ps1')
$root = Split-Path -Parent $PSScriptRoot
$cfgPath = Join-Path $PSScriptRoot '转发接收配置.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Host "找不到 $cfgPath"; exit 1 }
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ⚠️ 2026-10-15 修「假开关」（外部复测从 1550 版起报了 3 次）：
# 配置里有 `enabled`，而本脚本**从不读它** —— 于是 `_设置说明` 里那句"把 enabled 改 true 就启用"
# 是误导（它本来就是 true，改它没有任何效果；要真停用只能去禁用计划任务）。
# 现在 enabled 真的生效了：
#   · false → 本脚本直接退出（不拉取、不写 spool）
#   · -Peek / -TestPush 仍然照跑（这两个是"检查链路用的"，不该被开关挡住）
if ($cfg.PSObject.Properties['enabled'] -and -not [bool]$cfg.enabled -and -not $Peek -and -not $TestPush) {
  Write-Host '转发接收已停用（转发接收配置.json 的 enabled=false）→ 本轮不拉取。要看链路请加 -Peek 或 -TestPush'
  exit 0
}

$logFile = Join-Path $root $cfg.logFile
$statePath = Join-Path $root $cfg.stateFile
$spoolDir = Join-Path $root $cfg.spoolDir
foreach ($p in @((Split-Path -Parent $logFile), (Split-Path -Parent $statePath), $spoolDir)) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  Write-Host $line
}
function Norm([string]$s) { if ($null -eq $s) { return '' } return ($s -replace '\s', '') }

# ---------- 测试：往入站主题推一条假通知 ----------
if ($TestPush) {
  $payload = @{
    topic = $cfg.inboundTopic
    title = '【测试群】张三'
    message = '@<用户名> 明天中午前把材料交一下'
    priority = 3
    tags = @('phone')
  } | ConvertTo-Json -Compress
  $r = Invoke-DirectHttp -Uri $cfg.server -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 20
  Log ("已向入站主题发测试通知：id=" + $r.id)
  exit 0
}

# ---------- 读游标 ----------
$state = [pscustomobject]@{ lastId = ''; seen = @() }
if (Test-Path -LiteralPath $statePath) {
  try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$seen = @{}
foreach ($id in @($state.seen)) { $seen[$id] = $true }

# ---------- 拉取 ----------
# ntfy 的 since 只接受：消息 id / "all" / 时间戳。首次运行用 all（受服务端缓存时长限制）
$since = if ($state.lastId) { $state.lastId } else { 'all' }
$url = ($cfg.server.TrimEnd('/')) + '/' + $cfg.inboundTopic + '/json?poll=1&since=' + $since
Write-Host ("拉取：" + $url)
# 直连（绕开系统代理）：这台机器的系统代理（127.0.0.1:<旧代理端口>）经常不在，
# 走它会报"无法连接到远程服务器" → 入站转发整条链路静默失效。见 推送.ps1 里 Invoke-DirectHttp 的说明。
# ⚠️ 2026-10-15 深夜修（外部审查）：原来这里自己 new WebClient（直连但无重试、无真超时），
#   与"拉取已改用直连"的账本不符。现在统一走 直连HTTP.ps1 的 Get-DirectHttpText（直连+重试+真超时）。
try {
  $text = Get-DirectHttpText -Uri $url -TimeoutSec 20
} catch {
  Log ("拉取失败（网络 / 主题名 / since 参数）：" + $_.Exception.Message)
  exit 0
}

$messages = @()
foreach ($line in ($text -split "`n")) {
  if ($line -notmatch '"event":"message"') { continue }
  try { $messages += ($line | ConvertFrom-Json) } catch {}
}
Log ("拉到 " + $messages.Count + " 条通知（过滤前）")

# ---------- 过滤 ----------
$aliases = @()
if ($cfg.filter.aliases) { foreach ($a in $cfg.filter.aliases) { if ((Norm $a).Length -gt 0) { $aliases += (Norm $a) } } }
$keywords = @($cfg.filter.keywords | Where-Object { $_ })
$whitelist = @($cfg.filter.chatWhitelist | Where-Object { $_ })

$records = @()
foreach ($m in $messages) {
  $id = [string]$m.id
  if ($seen.ContainsKey($id)) { continue }
  $title = [string]$m.title
  $msg = [string]$m.message
  $hay = Norm ($title + ' ' + $msg)

  $skip = $false
  $skipWhy = ''
  if ($whitelist.Count -gt 0) {
    $hit = $false
    foreach ($w in $whitelist) { if ($hay -like ('*' + (Norm $w) + '*')) { $hit = $true } }
    if (-not $hit) { $skip = $true; $skipWhy = '不在白名单' }
  }
  # 注意：switch 里的 continue 只会跳过 switch，不会跳过外层 foreach —— 所以这里用标志位
  if (-not $skip) {
    if ($cfg.filter.mode -eq 'mention') {
      $ok = if ($aliases.Count -eq 0) { $hay.Contains('@') } else { $false }
      foreach ($a in $aliases) { if ($hay.Contains('@' + $a)) { $ok = $true } }
      if (-not $ok) { $skip = $true; $skipWhy = '没@我' }
    } elseif ($cfg.filter.mode -eq 'keyword') {
      $ok = $false
      foreach ($k in $keywords) { if ($hay.Contains((Norm $k))) { $ok = $true } }
      if (-not $ok) { $skip = $true; $skipWhy = '没关键词' }
    }
  }
  if ($skip) {
    Log ("  [跳过·" + $skipWhy + "] " + $title + " | " + $msg)
    $seen[$id] = $true
    continue
  }

  # 有些填法（纯文本 POST）没有 title —— 从正文里猜群名，别让 chat 空着
  if ([string]::IsNullOrWhiteSpace($title)) {
    $g = [regex]::Match($msg, '^【([^】]{1,24})】')
    if ($g.Success) { $title = $g.Groups[1].Value.Trim() }
    elseif ($msg -match '^([^:：]{1,20})[:：]') { $title = $Matches[1].Trim() }
    else { $title = '手机通知' }
  }

  # 拆出"发送者：正文"（手机通知常见格式）
  $sender = ''
  $body = $msg
  $mm = [regex]::Match($msg, '^([^:：]{1,24})[:：]\s*(.+)$')
  if ($mm.Success) { $sender = $mm.Groups[1].Value.Trim(); $body = $mm.Groups[2].Value.Trim() }

  $ts = (Get-Date).ToString('o')
  if ($m.time) { try { $ts = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$m.time)).ToLocalTime().ToString('o') } catch {} }

  $records += [ordered]@{
    kind = 'chat'; ts = $ts; source = 'phone-notify'
    chat = $title; expected = $title; verified = $true; changed = $true
    sender = $sender
    text = ($title + "`n" + $(if ($sender) { $sender + '：' + $body } else { $body }))
    lines = @(
      [ordered]@{ x = 0; y = 0; t = $title },
      [ordered]@{ x = 0; y = 30; t = $(if ($sender) { $sender + '：' + $body } else { $body }) }
    )
    raw = [ordered]@{ id = $id; title = $title; message = $msg; time = $m.time }
  }
  $seen[$id] = $true
  Log ("  [收下] " + $title + " | " + $msg)
}

if ($Peek) { Log '（-Peek：不写 spool）'; exit 0 }

# ---------- 写 spool ----------
$written = 0
if ($records.Count -gt 0) {
  $file = Join-Path $spoolDir ('messages-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
  foreach ($rec in $records) {
    # ⚠️ 2026-10-15 修：这里原来是 `Add-Content -Encoding UTF8` —— **全项目最后一个还在产 BOM 的写点**。
    # PS 5.1 在**新建文件**时会写 BOM → 入站转发新建的每个当日 spool，**第一条记录依然带 BOM**。
    # 今天不丢数据只是因为插件读侧兜了一层去 BOM；任何别的/新加的读者都会丢掉首条。
    # 与两个采集器保持一致：AppendAllText + UTF8Encoding($false)。
    $line = ($rec | ConvertTo-Json -Depth 8 -Compress)
    [System.IO.File]::AppendAllText($file, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $written++
  }
  Log ("已写入 " + $written + " 条到 " + $file)
} else {
  Log '没有需要写入的通知'
}

# ---------- 存游标（lastId + 最近 300 个已处理 id）----------
$newLastId = if ($messages.Count -gt 0) { [string]$messages[-1].id } else { [string]$state.lastId }
$seenIds = @($seen.Keys) | Select-Object -Last 300
[pscustomobject]@{ lastId = $newLastId; seen = $seenIds; updatedAt = (Get-Date).ToString('o') } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
Log ("完成（游标 lastId=" + $newLastId + "）")





