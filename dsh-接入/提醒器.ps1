# 提醒器.ps1 —— 读 群聊待办\todos.json，到点弹 Windows 气泡 + 声音（可同时推手机）
#
# 由计划任务每 5 分钟调一次（不依赖 DSH 是否开着）。
# 只读 todos.json、只写回"已提醒"标记，不发消息、不碰微信。
# 手机推送：企业微信机器人（@所有人，这样手机才会弹通知）。ntfy 出站通道已弃用（2026-10-14）
param(
  [switch]$DryRun,        # 只打印会提醒什么，不真的弹
  [int]$MaxPerRun = 2,    # 单次最多弹几条，避免刷屏（外部复测：一轮3条+慢推送可能逼近锁超时→重复提醒，降为2）
  [switch]$Test,          # 弹一条测试通知
  [switch]$TestPhone      # 只发一条手机推送，测试通道
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot '运行状态.ps1')   # 记录本轮结果（run-hidden.vbs 拿不到退出码，见该文件说明）

$root = Split-Path -Parent $PSScriptRoot
$todoDir = Join-Path $root '群聊待办'
$todoFile = Join-Path $todoDir 'todos.json'
$stateFile = Join-Path $todoDir 'reminder-state.json'
$logFile = Join-Path $root 'dsh-接入\logs\提醒器.log'
$cfgFile = Join-Path $PSScriptRoot '提醒配置.json'

$logDir = Split-Path -Parent $logFile
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

# ---- 去重状态：**每提醒一条就立刻落盘**，不要等整轮跑完 ----
# 实测踩过（2026-10-14）：状态原本只在脚本末尾写一次，如果这一轮跑得慢（或同时有另一个实例），
# 下一次计划任务会读到旧状态 → 同一条待办被重复提醒（实测同一条弹了两次、"每日汇总"也弹了两次）。
function Save-ReminderState {
  if ($DryRun) { return }   # 试运行不写，避免把提醒吃掉
  try {
    $obj = [ordered]@{}
    foreach ($k in $state.Keys) { $obj[$k] = $state[$k] }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
  } catch { Log ("去重状态写盘失败（下次可能重复提醒）：" + $_.Exception.Message) }
}

# ---- 单实例锁：两个实例同时跑必然重复提醒 ----
# ⚠️ 2026-10-15 深夜加固（外部复测）：① 接管阈值 5 → 15 分钟（任务周期就是 5 分钟，慢轮 3 条 ×
#    20 秒推送重试逼近阈值 → 下一轮抢锁 → 重复提醒）；② 锁文件写**归属令牌**，释放时校验归属，
#    慢轮收尾不会误删新实例的锁。
$lockFile = Join-Path $todoDir 'reminder.lock'
$script:lockToken = [guid]::NewGuid().ToString('N')
function Release-ReminderLock {
  if (-not (Test-Path -LiteralPath $lockFile)) { return }
  try {
    $t = (Get-Content -LiteralPath $lockFile -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
    if ($t -eq $script:lockToken) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
    # 不是自己的锁 → 不删（避免慢轮收尾把新实例的锁误删）
  } catch { }
}
function Acquire-ReminderLock {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $fs = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
      $sw.Write($script:lockToken); $sw.Flush(); $sw.Close(); $fs.Close(); $fs.Dispose()
      return $true
    } catch {
      # 锁已存在：如果太久没动（>15 分钟 = 3 个任务周期），认为上次崩了没收尾，抢过来
      $ageMin = 999
      if (Test-Path -LiteralPath $lockFile) { $ageMin = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalMinutes }
      if ($ageMin -gt 15) { Release-ReminderLock; continue }
      return $false
    }
  }
  return $false
}

# ---------- 配置：手机推送 ----------
$pushCfg = $null
if (Test-Path -LiteralPath $cfgFile) {
  try {
    $pushCfg = ((Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8) -replace '^\uFEFF', '' | ConvertFrom-Json).phonePush
  } catch { Log ("提醒配置读取失败：" + $_.Exception.Message) }
}
# 手机推送统一走 推送.ps1（企业微信机器人；ntfy 出站通道已弃用）
. (Join-Path $PSScriptRoot '推送.ps1')
$script:pushInfo = '未启用'
if ($pushCfg -and $pushCfg.enabled -ne $false) {
  # ⚠️ 2026-10-15 修（另一个 AI 复测 §4.5 报成"重复条件"，实际是**串键**）：
  # 原来 79/80 两行的条件**一模一样**，第二行显然想写 `dingtalk` 却复制成了 `wecom` →
  # 后果：配了钉钉通道时，日志里那句"手机推送：企业微信 + wecom"永远看不到钉钉，
  # 排障时会以为钉钉没接上（而 推送.ps1:251 其实会去发它）。
  $parts = @()
  if ($pushCfg.wechat -and $pushCfg.wechat.enabled -eq $true) { $parts += '微信(个人)' }
  if ($pushCfg.wecom -and $pushCfg.wecom.webhook) { $parts += '企业微信' }
  if ($pushCfg.dingtalk -and $pushCfg.dingtalk.webhook) { $parts += '钉钉' }
  if ($pushCfg.ntfy -and $pushCfg.ntfy.topic) { $parts += 'ntfy' }
  if ($pushCfg.email -and $pushCfg.email.enabled) { $parts += '邮件' }
  if ($pushCfg.wecomApp -and $pushCfg.wecomApp.enabled) { $parts += '企业微信应用' }
  if ($parts.Count -gt 0) { $script:pushInfo = ($parts -join ' + ') }
}

# 桌面提醒：Toast 用的 AUMID（必须先注册，否则 Win11 静默丢弃）+ 是否同时弹右下角小窗保底
$script:Aumid = 'DSH.Todo'
$script:PopupOnReminder = $true
if ($pushCfg) {
  if ($pushCfg.PSObject.Properties.Name -contains 'aumid' -and $pushCfg.aumid) { $script:Aumid = [string]$pushCfg.aumid }
  if ($pushCfg.PSObject.Properties.Name -contains 'popupOnReminder') { $script:PopupOnReminder = [bool]$pushCfg.popupOnReminder }
}

if ($TestPhone) {
  Log ("测试手机推送 → " + $script:pushInfo)
  $res = Send-PhonePush -Title '群聊待办 · 测试' -Text '手机推送通道测试：收到这条就说明通了 ✅'
  Log ("推送结果：" + $res + "（wechat=个人微信；wecom=企业微信机器人）")
  Write-RunStatus -Name '提醒器' -Code 0
  exit 0
}


function Show-Toast([string]$title, [string]$text) {
  # WinRT Toast：需要先注册 AUMID（注册表 HKCU\Software\Classes\AppUserModelId\<aumid>），否则 Win11 会静默丢弃
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $esc = { param($s) (([string]$s) -replace '&', '&amp;') -replace '<', '&lt;' -replace '>', '&gt;' }
    $t = '<toast><visual><binding template="ToastGeneric"><text>' + (& $esc $title) + '</text><text>' +
      (& $esc $text) + '</text></binding></visual><audio src="ms-winsoundevent:Notification.Default"/></toast>'
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($t)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:Aumid).Show($toast)
    return $true
  } catch {
    Log ("Toast 失败（回退气泡）：" + $_.Exception.Message)
    return $false
  }
}

function Show-Popup([string]$title, [string]$text, [int]$Seconds = 10) {
  # 保底通道：右下角置顶小窗，一定会看到（不依赖通知设置/勿扰）
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'FixedToolWindow'
  $f.TopMost = $true
  $f.ShowInTaskbar = $true
  $f.Text = $title
  $f.ClientSize = New-Object System.Drawing.Size(420, 130)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.StartPosition = 'Manual'
  $f.Location = New-Object System.Drawing.Point(($wa.Right - 440), ($wa.Bottom - 170))
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = $text
  $lbl.Dock = 'Fill'
  $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
  $lbl.Padding = New-Object System.Windows.Forms.Padding(10)
  $f.Controls.Add($lbl)
  $f.Show()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 120
  }
  $f.Close()
  $f.Dispose()
}

function Show-Bubble([string]$title, [string]$text) {
  $shown = Show-Toast -title $title -text $text
  if (-not $shown) {
    # Toast 不可用时退回气泡
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipTitle = $title
    $ni.BalloonTipText = $text
    $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $ni.ShowBalloonTip(10000)
    [System.Media.SystemSounds]::Exclamation.Play()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 6) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 150
    }
    $ni.Visible = $false
    $ni.Dispose()
  }
  if ($script:PopupOnReminder) { Show-Popup -title $title -text $text -Seconds 10 }
}

if ($Test) {
  Log '测试通知'
  Show-Bubble '群聊待办 · 测试' '这是一条测试提醒（由提醒器发出）。'
  Write-RunStatus -Name '提醒器' -Code 0
  exit 0
}

# 这两条出现在**加锁之前**（所以不涉及锁残留），但为了"运行状态"这条可观测链路完整，
# 也各写一条记录：没有 todos.json / todos.json 为空 都属于"本来就没东西可做"，记 code=0 而附上原因。
if (-not (Test-Path -LiteralPath $todoFile)) {
  Log "没有 $todoFile，跳过"
  Write-RunStatus -Name '提醒器' -Code 0 -Note '没有 todos.json（还没跑过插件？）'
  exit 0
}

# ⚠️ 2026-10-15 深夜修（外部复测缺陷1：todos.json 被写坏/写一半时，这里 ConvertFrom-Json 无 try/catch
#   + EAP=Stop → 当场终止：日志零新增、运行状态零更新、退出码 0 → 每 5 分钟静默死、自检也看不见）。
#   现在解析失败也要留痕（code=1 + 明确 note），并**不**退出——尽量用上次的提醒状态继续？不行：
#   数据都读不出来，只能报错留痕并退出（留痕保证自检下一轮报红）。备份坏文件供排查。
$todos = $null
try {
  $todos = Get-Content -LiteralPath $todoFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Log ("todos.json 解析失败（文件可能被写坏/写了一半）：" + $_.Exception.Message)
  try { Copy-Item -LiteralPath $todoFile -Destination ($todoFile + '.broken-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force -ErrorAction SilentlyContinue } catch { }
  Write-RunStatus -Name '提醒器' -Code 1 -Note 'todos.json 解析失败（可能写坏），本轮全部提醒跳过'
  exit 1
}
if ($null -eq $todos) {
  Log 'todos.json 为空'
  Write-RunStatus -Name '提醒器' -Code 0 -Note 'todos.json 为空'
  exit 0
}
$items = @($todos)
if ($todos.PSObject.Properties.Name -contains 'items') { $items = @($todos.items) }

$state = @{}
if (Test-Path -LiteralPath $stateFile) {
  try {
    $s = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $s.PSObject.Properties) { $state[$p.Name] = $p.Value }
  } catch { $state = @{} }
}

if (-not (Acquire-ReminderLock)) {
  Log '另一个提醒器实例还在跑 → 本轮跳过（避免重复提醒）'
  Write-RunStatus -Name '提醒器' -Code 0
  exit 0
}

# ⚠️ 2026-10-15：加锁之后的**全部**逻辑包在 try/finally 里 ——
# 任何未预料的异常都不许把锁留在原地（锁残留 = 之后每轮都被判成「另一实例在跑」= 永久停摆，且 exit 0 看不出异常）。
try {

$now = Get-Date
$today = $now.ToString('yyyy-MM-dd')
$toFire = @()

foreach ($it in $items) {
  if ($null -eq $it) { continue }
  $status = [string]$it.status
  if ($status -in @('done', 'ignored', 'expired')) { continue }
  if ([string]::IsNullOrWhiteSpace([string]$it.due)) { continue }
  $due = $null
  try { $due = [datetime]::Parse([string]$it.due) } catch { continue }
  $id = [string]$it.id
  if ([string]::IsNullOrWhiteSpace($id)) { continue }

  $mins = ($due - $now).TotalMinutes
  $slots = @()
  # 距到期 24 小时内：T-24h / T-1h / 到期
  if ($mins -le 1440 -and $mins -gt 60) { $slots += @{ key = 't24'; label = '还有约 1 天到期' } }
  if ($mins -le 60 -and $mins -gt 0) { $slots += @{ key = 't1'; label = ('还有 {0} 分钟到期' -f [int]$mins) } }
  if ($mins -le 0) { $slots += @{ key = ('due-' + $today); label = '已到期' } }

  foreach ($s in $slots) {
    $k = "$id|$($s.key)"
    if ($state.ContainsKey($k)) { continue }
    $toFire += [pscustomobject]@{ id = $id; key = $k; title = [string]$it.title; label = $s.label; due = $due }
  }
}

# 每日 09:00 之后的一次汇总
$digestKey = "digest|$today"
if (-not $state.ContainsKey($digestKey) -and $now.Hour -ge 9) {
  # ⚠️ 2026-10-15 修（另一台机器实测暴露的**静默停摆**）：
  # 这里原来直接 `[datetime]::Parse(...)`，而上面的逐条循环是 try/catch 保护的、这一处漏了。
  # 模型给的 due 只要有一条不可解析（'明天中午'/'待定'/'尽快'/'本周五前'…全部抛 FormatException），
  # 本块就崩 → 崩点在"加锁之后、释放之前" → **reminder.lock 残留** →
  # 之后每一轮都被判成"另一个实例还在跑"→ exit 0（任务看着成功）、一条提醒都不发。
  # 而且 `$now.Hour -ge 9` 意味着每天 9 点后必然复现，症状就是"早上还行、9 点后彻底不提醒"。
  # 现在改用 TryParse（解析不了的直接不算"今天到期"，不再崩）。
  $dueToday = @($items | Where-Object {
      if ($null -eq $_) { return $false }
      if (-not $_.due) { return $false }
      if ([string]$_.status -in @('done', 'ignored', 'expired')) { return $false }
      $d = [datetime]::MinValue
      if (-not [datetime]::TryParse([string]$_.due, [ref]$d)) { return $false }
      return ($d.Date -eq $now.Date)
    })
  if ($dueToday.Count -gt 0) {
    $toFire += [pscustomobject]@{ id = $digestKey; key = $digestKey; title = ('今天有 {0} 条待办到期' -f $dueToday.Count); label = '每日汇总'; due = $now }
  }
}

  if ($toFire.Count -eq 0) {
    # ⚠️ 2026-10-15 修（另一个 AI 复测 §4 抓到的真 bug）：
    # 这条 `exit 0` 在 try 块内部。PowerShell 的 `exit` **会执行 finally，但不会继续执行
    # try/finally 之后的语句** —— 所以锁放掉了（这点对），但脚本末尾那句
    # `Write-RunStatus -Name '提醒器'` **永远不会被执行到**。
    # 而"没有待提醒项"恰恰是**绝大多数轮次**走的路径 → 提醒器这一项对故障检测**永久失明**
    # （它挂了也不会有任何记录，6 小时"陈旧"判定也永远不触发）。
    # 这正是 1620 版为了修"锁残留"把它包进 try/finally 时，顺手把状态写入挤到了 exit 之后 ——
    # 典型的"修 A 引入 B"。所以：exit 之前先把状态写上。
    Write-RunStatus -Name '提醒器' -Code 0 -Note '本轮无待提醒项'
    Release-ReminderLock
    exit 0
  }

Log ("需要提醒 {0} 条" -f $toFire.Count)
$n = 0
foreach ($f in $toFire) {
  if ($n -ge $MaxPerRun) { break }
  $text = "{0}（{1}，{2} 截止）" -f $f.title, $f.label, $f.due.ToString('MM-dd HH:mm')
  if ($DryRun) {
    Log ("[试运行] " + $text)
  } else {
    Show-Bubble '群聊待办' $text
    Log ("已提醒：" + $text)
    # 手机端文案带一句"完成回写"引导（微信机器人支持自然语言回"完成"标记待办）
    $pushText = $text + '｜微信回复“完成+编号/关键词”可标记完成'
    $pushRes = Send-PhonePush -Title '群聊待办' -Text $pushText
    if ($pushRes -eq 'disabled') { Log '  （手机推送已关闭：phonePush.enabled=false）' }
    elseif ($pushRes -eq 'none') { Log '  ⚠️ 手机推送：一个通道都没成功（检查 提醒配置.json 的 webhook/key）' }
    else { Log ("  手机推送成功：" + $pushRes) }
  }
  $state[$f.key] = (Get-Date).ToString('o')
  Save-ReminderState        # ← 立刻落盘：这样即使本轮后续卡住/被中断，也不会重复提醒
  $n++
}

# 只写自己的去重状态（试运行不写，避免把提醒吃掉）
# 注意：**不要回写 todos.json**！PowerShell 5.1 的 ConvertTo-Json 会把"只有一个元素的数组"
# 写成对象、丢掉数组外壳，插件读回来就当成空 → 已有待办会被清空（已实测丢过数据）。
Save-ReminderState
} finally {
  Release-ReminderLock
}
Write-RunStatus -Name '提醒器' -Code 0   # → dsh-接入\logs\运行状态.json
Log '完成'







