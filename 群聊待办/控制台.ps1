# 控制台.ps1 —— 「群聊待办 · 控制台」入口（生成页面 / 一键应用改动）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\群聊待办\控制台.ps1                 # 默认：生成页面 + 起本地服务 + 打开页面（页面上点「确定」= 立刻生效）
#   （文件模式已停用：-NoServe 现在会被忽略并提示你改用服务版 —— 用户要求只保留"点确定即生效"）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\群聊待办\控制台.ps1 -NoOpen         # 只生成不打开（打包自测/自检工具用）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\群聊待办\控制台.ps1 -Apply "<补丁>" # 应用改动（页面导出的文件，或服务模式内部也走这条通路）
#
# 为什么要有"本地服务"模式（2026-10-16 用户要求"能不能点确定就直接应用，少一步"）：
#   浏览器页面**不能直接写本机文件**（浏览器安全边界，绕不过去）。所以原来只能"点确定 → 下载补丁 → 自己敲一行 -Apply"。
#   现在默认起一个**只监听 127.0.0.1** 的小服务（控制台-服务.mjs），页面从它打开 → 点「确定」直接 POST 应用，
#   并且复用**同一条**已测过的 -Apply 通路（JSON 由 Node 写、计划任务由本脚本改），页面上直接显示结果。
#   ⚠️ 2026-10-16 用户要求：**只保留服务版**。文件模式（下载/复制补丁 + 手动 -Apply）已停用；
#   若有人把 控制台.html 当文件双击打开，页面会直接提示"请用 打开控制台.cmd 打开"。
#
# 职责划分（沿用项目惯例）：
#   · JSON 配置一律 Node 写（控制台-应用.mjs）：规避 PS 5.1 ConvertTo-Json 的 BOM + 单元素数组两个丢数据坑
#   · 计划任务一律 PowerShell 对象接口改（Set-ScheduledTask）：不 parse 本地化文本
param(
  [switch]$NoOpen,
  [switch]$NoServe,        # 已停用（保留只为不报"未知参数"）：现在一律走服务版
  [switch]$Hidden,          # 隐藏启动（打开控制台.cmd 用）：不弹任何窗口，只留"地址文件 + 日志"留痕
  [switch]$NoBrowser,       # 起/复用服务但**不打开浏览器**（比如你已经有页面了，或脚本/测试里用）
  [string]$Apply = ''
)

$ErrorActionPreference = 'Stop'
$ws = Split-Path -Parent $PSScriptRoot
$todoDir = Join-Path $ws '群聊待办'
$accessDir = Join-Path $ws 'dsh-接入'

# ---- 找 node（与 生成看板.ps1 的 Find-NodeExe 同一份候选集：固定路径 + DSH Desktop 目录递归 + PATH。
#      外部审查发现两处不一致会导致"看板能用、控制台说找不到 node"，这里对齐；-PathType Leaf 防目录同名。）----
$node = $null
$nodeCands = @(
  (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
  (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
)
foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
  if (-not $base) { continue }
  foreach ($sub in @('Programs\DSH Desktop', 'DSH Desktop', 'DeepSeek Harness')) {
    $p = Join-Path $base $sub
    if (Test-Path -LiteralPath $p) {
      $nodeCands += @(Get-ChildItem -LiteralPath $p -Recurse -Filter 'node.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName })
    }
  }
}
foreach ($c in $nodeCands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $node = $c; break } }
if (-not $node) { $cmd = Get-Command node -ErrorAction SilentlyContinue; if ($cmd) { $node = $cmd.Source } }

# 没有 node 时的降级：把"想改什么 → 手改哪个文件哪个键"打印出来，而不是只报一句错（外部复测 2112 版建议）
function Show-ManualGuide {
  Write-Host ''
  Write-Host '┌────────────────────────────────────────────────────────────────────┐'
  Write-Host '│ 没有 Node：控制台页面用不了，但这些设置都能用记事本手改（改完即生效）│'
  Write-Host '└────────────────────────────────────────────────────────────────────┘'
  $base = $ws
  $rows = @(
    @{ 想改 = '采集/提醒/自检周期（分钟）'; 文件 = 'dsh-接入\运行配置.json'; 键 = 'collectMinutes / remindMinutes / selfcheckMinutes'; 注意 = '改完必须同步计划任务（任务计划程序里把对应任务的重复间隔改成一样的分钟数），否则自检会报错' },
    @{ 想改 = '企业微信 webhook（兜底通道）'; 文件 = 'dsh-接入\提醒配置.json'; 键 = 'phonePush.wecom.webhook'; 注意 = '留空 = 不要兜底' },
    @{ 想改 = '我的微信昵称（识别@我）'; 文件 = 'wx-采集器\config.json 和 dsh-msg-memo\config.json'; 键 = 'myAliases'; 注意 = '两份都要改，保持一致' },
    @{ 想改 = '微信群白名单'; 文件 = 'wx-采集器\config.json'; 键 = 'groupWhitelist'; 注意 = '留空 = 不过滤' },
    @{ 想改 = 'QQ 群白名单'; 文件 = 'wx-采集器\config-qq.json'; 键 = 'groupWhitelist'; 注意 = '留空 = 不过滤' }
  )
  foreach ($r in $rows) {
    Write-Host ''
    Write-Host ("◆ {0}" -f $r.想改)
    Write-Host ("  文件: {0}" -f (Join-Path $base $r.文件))
    Write-Host ("  改  : {0}" -f $r.键)
    Write-Host ("  注意: {0}" -f $r.注意)
  }
  Write-Host ''
  Write-Host '想用页面版：装 Node.js（nodejs.org），或在"任务计划程序"里改周期。'
}

if (-not $node) {
  Write-Host '❌ 找不到 node.exe（生成控制台页需要它）。'
  Show-ManualGuide
  exit 1
}

function Read-Json([string]$p, $default) {
  if (-not (Test-Path -LiteralPath $p)) { return $default }
  try { return ((Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace '^\uFEFF','' | ConvertFrom-Json) } catch { return $default }
}

# 取整数字段：缺键/非法/0 都回退默认值（外部复测 F2：`[int]$null` = 0 会把默认周期显示成 0 并卡死整份补丁）
function Get-CfgInt($obj, [string]$key, [int]$default) {
  $v = 0
  if ($obj -and $obj.PSObject.Properties[$key]) { if ([int]::TryParse([string]$obj.$key, [ref]$v)) { if ($v -gt 0) { return $v } } }
  return $default
}

# ================= 应用改动 =================
if ($Apply) {
  $patchPath = (Resolve-Path -LiteralPath $Apply -ErrorAction SilentlyContinue).Path
  if (-not $patchPath) { Write-Host ("找不到补丁文件：{0}" -f $Apply); exit 1 }
  Write-Host '=== 1/2 写配置（Node） ==='
  & $node (Join-Path $todoDir '控制台-应用.mjs') $patchPath
  $appCode = $LASTEXITCODE
  if ($appCode -eq 1) { Write-Host '❌ 配置写入失败（未写任何文件），计划任务未改动。'; exit 1 }
  if ($appCode -eq 2) { Write-Host '补丁里没有需要应用的改动（字段全空、或与现状相同）→ 配置与计划任务都没动。'; exit 0 }

  Write-Host '=== 2/2 改计划任务周期 ==='
  $patch = Read-Json $patchPath $null
  $taskChanged = 0
  if ($patch -and $patch.intervals) {
    $iv = $patch.intervals
    foreach ($k in @('collectMinutes', 'remindMinutes', 'selfcheckMinutes')) {
      if ($null -eq $iv.$k) { continue }
      $mins = [int]$iv.$k
      if ($k -eq 'collectMinutes') {
        foreach ($tn in @('微信待办-采集', 'QQ待办-采集')) {
          $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
          if (-not $t) { Write-Host ("  任务 {0} 不存在 → 跳过（装好任务后重新 -Apply 一次）" -f $tn); continue }
          $trigs = @($t.Triggers); foreach ($tr in $trigs) { if ($tr.Repetition) { $tr.Repetition.Interval = ('PT' + $mins + 'M') } }
          Set-ScheduledTask -TaskName $tn -Trigger $trigs | Out-Null
          Write-Host ("  任务 {0} 周期 → PT{1}M（{2} 分钟）" -f $tn, $mins, $mins)
          $taskChanged++
        }
      } else {
        $tn = if ($k -eq 'remindMinutes') { '微信待办-提醒' } else { '微信待办-自检' }
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if (-not $t) { Write-Host ("  任务 {0} 不存在 → 跳过（装好任务后重新 -Apply 一次）" -f $tn); continue }
        $trigs = @($t.Triggers); foreach ($tr in $trigs) { if ($tr.Repetition) { $tr.Repetition.Interval = ('PT' + $mins + 'M') } }
        Set-ScheduledTask -TaskName $tn -Trigger $trigs | Out-Null
        Write-Host ("  任务 {0} 周期 → PT{1}M（{2} 分钟）" -f $tn, $mins, $mins)
        $taskChanged++
      }
    }
  } else {
    Write-Host '  （补丁里没有周期改动，任务不动）'
  }

  # ---- 开机自启（可选项，用户要就开）----
  if ($patch -and ($null -ne $patch.autostartDsh)) {
    $helper = Join-Path $accessDir '开机自启DSH.ps1'
    if (Test-Path -LiteralPath $helper) {
      if ([bool]$patch.autostartDsh) {
        Write-Host '=== 3/3 开机自启：开 ==='
        & $helper -Enable
      } else {
        Write-Host '=== 3/3 开机自启：关 ==='
        & $helper -Disable
      }
    } else { Write-Host '  （找不到 开机自启DSH.ps1，跳过开机自启设置）' }
  }

  if ($taskChanged -gt 0) {
    Write-Host '✅ 完成。改动已生效（任务周期立即生效；自检阈值随 运行配置.json 下一轮自动跟上）。'
  } else {
    Write-Host '✅ 配置已应用；补丁里没有周期改动（或本机还没有注册对应计划任务），任务未动。'
  }
  exit 0
}

# ================= 收集状态 → 生成页面 =================
$runCfg = Read-Json (Join-Path $accessDir '运行配置.json') @{ collectMinutes = 60; remindMinutes = 5; selfcheckMinutes = 120 }
$tasks = @{}
foreach ($tn in @('微信待办-采集', 'QQ待办-采集', '微信待办-提醒', '微信待办-自检')) {
  $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
  if ($t -and @($t.Triggers).Count -gt 0 -and $t.Triggers[0].Repetition) { $tasks[$tn] = [string]$t.Triggers[0].Repetition.Interval }
}
$wxProc = @(Get-Process -Name 'Weixin' -ErrorAction SilentlyContinue)
$qqProc = @(Get-Process -Name 'QQ' -ErrorAction SilentlyContinue)
$bot = @{ bound = $false; account = '' }
$stateFile = Join-Path $env:USERPROFILE '.dsh\wechat\state.json'
if (Test-Path -LiteralPath $stateFile) {
  $st = Read-Json $stateFile $null
  if ($st -and $st.accounts) {
    $keys = @($st.accounts | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name })
    if ($keys.Count -gt 0) { $bot = @{ bound = $true; account = $keys[0] } }
  }
}
$pushCfg = Read-Json (Join-Path $accessDir '提醒配置.json') $null
$wecom = @{ configured = $false; webhook = ''; mention = '' }
if ($pushCfg -and $pushCfg.phonePush -and $pushCfg.phonePush.wecom) {
  $w = $pushCfg.phonePush.wecom
  $wecom = @{ configured = -not [string]::IsNullOrWhiteSpace([string]$w.webhook); webhook = [string]$w.webhook; mention = [string]$w.mention }
}
$wxCfg = Read-Json (Join-Path $ws 'wx-采集器\config.json') $null
$qqCfg = Read-Json (Join-Path $ws 'wx-采集器\config-qq.json') $null

# 开机自启状态（两种机制都要认：计划任务 DSH-开机自启 / HKCU Run 项 DSH-AutoStart 兜底）
$autostart = @{ enabled = $false; taskName = 'DSH-开机自启'; exe = '' }
$asTask = Get-ScheduledTask -TaskName 'DSH-开机自启' -ErrorAction SilentlyContinue
if ($asTask -and $asTask.State -ne 'Disabled') { $autostart.enabled = $true }
if (-not $autostart.enabled) {
  try {
    $rv = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DSH-AutoStart' -ErrorAction Stop).'DSH-AutoStart'
    if ($rv) { $autostart.enabled = $true }
  } catch { }
}
$dshProc = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -notmatch 'app\.asar' } | Select-Object -First 1
if ($dshProc -and $dshProc.Path) { $autostart.exe = $dshProc.Path }

# QQ 通道（dsh-qq-plugin，与微信插件同作者）：装了没 / 绑了没
$qqChan = @{ pluginInstalled = $false; bound = $false; account = '' }
if (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules\dsh-qq-plugin')) { $qqChan.pluginInstalled = $true }
$qqStateFile = Join-Path $env:USERPROFILE '.dsh\qq\state.json'
if (Test-Path -LiteralPath $qqStateFile) {
  $qs = Read-Json $qqStateFile $null
  $accts = $null
  if ($qs -and $qs.PSObject.Properties['accounts']) { $accts = @($qs.accounts) }
  elseif ($qs -and $qs.PSObject.Properties['bindings']) { $accts = @($qs.bindings) }
  if ($accts -and $accts.Count -gt 0) {
    $qqChan.bound = $true
    $first = $accts[0]
    foreach ($k in @('appId', 'accountId', 'id')) { if ($first.PSObject.Properties[$k] -and $first.$k) { $qqChan.account = [string]$first.$k; break } }
  }
}

$todos = @{}
$todosDoc = Read-Json (Join-Path $todoDir 'todos.json') $null
if ($todosDoc) {
  $items = if ($todosDoc.PSObject.Properties.Name -contains 'items') { @($todosDoc.items) } else { @($todosDoc) }
  foreach ($it in $items) { $s = [string]$it.status; if (-not $todos.ContainsKey($s)) { $todos[$s] = 0 }; $todos[$s]++ }
}

$state = [ordered]@{
  generatedAt = (Get-Date).ToString('o')
  config      = @{ collectMinutes = Get-CfgInt $runCfg 'collectMinutes' 60; remindMinutes = Get-CfgInt $runCfg 'remindMinutes' 5; selfcheckMinutes = Get-CfgInt $runCfg 'selfcheckMinutes' 120 }
  tasks       = @{ collectWx = $tasks['微信待办-采集']; collectQq = $tasks['QQ待办-采集']; remind = $tasks['微信待办-提醒']; selfcheck = $tasks['微信待办-自检'] }
  apps        = @{ wechat = ($wxProc.Count -gt 0); qq = ($qqProc.Count -gt 0) }
  wechatBot   = $bot
  wecom       = $wecom
  aliases     = @($wxCfg.myAliases)
  whitelistWx = @($wxCfg.groupWhitelist)
  whitelistQq = @($qqCfg.groupWhitelist)
  todos       = @{ open = ([int]$todos['open'] + [int]$todos['pending_confirm']); done = [int]$todos['done']; ignored = [int]$todos['ignored'] }
  autostart   = $autostart
  qqChannel   = $qqChan
  # 待办管家规则：填好**本机真实路径** → 用户从页面整段复制发给微信机器人即可
  # （外部复测发现包内模板路径是占位符、且曾被漏发 → 页面永远给"这台机器可用"的版本）
  rulesText   = @(
    '【待办管家使用规则 —— 固定规则，请严格遵守】'
    '（这条消息之后，所有"完成/忽略/待办"类请求都按下述方式处理）'
    ''
    ('待办文件：' + (Join-Path $todoDir 'todos.json'))
    ('node：' + $node)
    ('脚本：' + (Join-Path $todoDir '改状态.mjs'))
    ''
    '规则：'
    '1. 我说"还有哪些待办"/"待办清单"/"未完成" → 运行：<node> <脚本> list，把输出原样发给我（编号就是它印的编号）。'
    '2. 我说"完成…"/"做完了…"（后面带编号或关键词，如"完成 3""完成报名表"）→ 提取查询词，运行：<node> <脚本> done <查询词>。'
    '   退出码 0 → 把输出发我；退出码 2（有歧义）→ 把候选列表发我，等我选；退出码 1 → 把原因发我。'
    '3. 我说"忽略…" → 同上用 ignored；"重新打开…" → 用 open。'
    '4. 严禁用 PowerShell 或任何别的方式直接改写 todos.json 和 MEMO.md（会写坏）；改动只准通过上面那个脚本。'
    '5. 回复简短（两三行以内），说人话，不用解释过程。'
  ) -join "`n"
}
$tmp = Join-Path $env:TEMP ('console-state-' + [guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
& $node (Join-Path $todoDir '控制台.mjs') $tmp
$genCode = $LASTEXITCODE
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if ($genCode -ne 0) { Write-Host '❌ 控制台页生成失败'; exit 1 }
$htmlPath = Join-Path $todoDir '控制台.html'
if ($NoOpen) { Write-Host ("控制台.html 已生成：{0}" -f $htmlPath); exit 0 }

# ---------- 只走"一键应用"本地服务（文件模式已停用，见文件头说明） ----------
$serveScript = Join-Path $todoDir '控制台-服务.mjs'
if ($NoServe) { Write-Host '⚠️ -NoServe（文件模式）已停用：现在一律用"点确定即生效"的服务版。' }
if (-not $node) {
  Write-Host '❌ 本机没有 Node.js → 控制台页生成不了（页面本身要靠 Node 渲染），也就没有服务版可用。'
  Write-Host '   装一下 Node.js（一路下一步）再跑本脚本：https://nodejs.org/zh-cn/download'
  exit 1
}
if (-not (Test-Path -LiteralPath $serveScript)) {
  Write-Host ('❌ 缺少 {0} —— 包可能不完整，请重新解压一份干净的部署包。' -f $serveScript)
  exit 1
}

# ---------- 先看有没有"已经在跑"的服务：有就直接用它，别再起第二个 ----------
# 为什么（用户实测 2026-10-16："一次好像开了两个网页"）：双击两次入口 → 起了两个服务、开了两个页面，
# 旧的那个页签没人管，点确定还会报"token 不匹配"。这里读上一次写下的地址文件 ping 一下：
# 活着就复用（不再新建服务、不再多一个 token），页面那边也有"旧页签自动认领"的提示。
$addrFile = Join-Path $todoDir '控制台-服务地址.txt'
if (Test-Path -LiteralPath $addrFile) {
  $prev = ([System.IO.File]::ReadAllText($addrFile, [System.Text.Encoding]::UTF8)).Trim()
  if ($prev -match '^http://127\.0\.0\.1:(\d+)/\?t=([0-9a-fA-F]{32})$') {
    $prevUrl = $prev
    try {
      $resp0 = Invoke-WebRequest -Uri ($prevUrl -replace '/\?t=', '/ping?t=') -UseBasicParsing -TimeoutSec 2
      if ($resp0.StatusCode -eq 200) {
        Write-Host ''
        Write-Host '=== 已经有一个控制台服务在跑，直接用它（不再起第二个）==='
        Write-Host ("  地址：{0}" -f $prevUrl)
        Write-Host '  想重开一个干净的：点页面右下角「停止服务」，或删掉 群聊待办\控制台-服务地址.txt 再来一次。'
        if (-not $NoBrowser) { Start-Process $prevUrl } else { Write-Host '  （-NoBrowser：只复用服务，没有打开浏览器）' }
        exit 0
      }
    } catch { }
  }
}

# 挑一个空闲端口（先自己试绑，避免和服务内部的重试逻辑错位）
$port = 0
foreach ($p in 19390..19399) {
  try {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
    $probe.Start(); $probe.Stop(); $port = $p; break
  } catch { try { $probe.Stop() } catch { } }
}
if ($port -eq 0) { Write-Host '❌ 19390-19399 端口全被占用 → 起不了服务。先关掉占用这些端口的程序，或重启一次电脑再试。'; exit 1 }

$token = [guid]::NewGuid().ToString('N')
$url = "http://127.0.0.1:{0}/?t={1}" -f $port, $token
# 服务可能以**隐藏方式**启动（打开控制台.cmd 就是那么干的，用户要求"窗口别碍事"）→ 窗口看不见，所以地址必须留痕：
# ① 写一份"当前地址"文件（万一浏览器没打开，看这里）② 追加一行日志
try {
  $logDir = Join-Path $accessDir 'logs'
  if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
  Add-Content -LiteralPath (Join-Path $logDir '控制台服务.log') -Encoding UTF8 -Value ("[{0}] 启动服务：{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $url)
  [System.IO.File]::WriteAllText((Join-Path $todoDir '控制台-服务地址.txt'), ($url + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
} catch { }
Write-Host ''
Write-Host '=== 控制台服务（一键应用）==='
Write-Host ("  地址：{0}" -f $url)
if ($Hidden) { Write-Host '  （隐藏启动：没有可见窗口；地址见 群聊待办\控制台-服务地址.txt，日志见 dsh-接入\logs\控制台服务.log）' }
Write-Host '  只监听本机回环地址（127.0.0.1）；页面上点「确定」= 立刻应用，不用下载、不用敲命令。'
Write-Host '  停止：页面右下角「停止服务」/ 应用成功后自动停（页面默认就是"用完自动关页+停服务"）/ 空闲自动退出。'
Write-Host ''
$proc = Start-Process -FilePath $node -ArgumentList @($serveScript, $token, "$port") -WorkingDirectory $todoDir -NoNewWindow -PassThru
# 等服务真的起来（最多 15 秒）再开浏览器，免得开出一个打不开的空白页
$up = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/ping?t={1}" -f $port, $token) -UseBasicParsing -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $up = $true; break }
  } catch { }
  if ($proc.HasExited) { break }
}
if ($up) { if ($NoBrowser) { Write-Host '  （-NoBrowser：服务已就绪，没有打开浏览器）' } else { Start-Process $url } } else { Write-Host '❌ 服务没起来（看上面的报错）—— 请把这段输出发回给作者。'; exit 1 }
Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
Write-Host ''
Write-Host '控制台服务已停止。（页面仍可用：以文件方式打开时，点确定会下载/复制补丁，再手动 -Apply）'
