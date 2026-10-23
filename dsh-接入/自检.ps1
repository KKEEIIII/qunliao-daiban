# 自检.ps1 —— 检查整条链路是否还活着，出问题就推手机 + 弹窗；正常就安静写日志
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\自检.ps1            # 有问题才提醒
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\自检.ps1 -Force     # 无论好坏都推一条（测试用）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\自检.ps1 -Quiet    # 只写日志，不弹不推
param(
  [switch]$Force,
  [switch]$Quiet,
  # 采集周期 2026-10-15 晚起 = 每小时（原 30 分钟），阈值给 75 分钟（1 周期 + 15 分钟余量），
  # 否则每轮自检都会误报"采集器 60 分钟没跑过"。
  [int]$StaleMinutes = 75,        # 采集/插件超过多久没动作算异常
  [int]$ReminderStaleMinutes = 15, # 提醒器超过多久没动作算异常
  [string]$PluginLogPath = '',
  # 只给测试用：$BaseDir 在'被读进 ScriptBlock 执行'时是空的，所以基线目录允许显式传入
  [string]$BaseDir = ''      # 只给测试用：拿一份假日志验证"模型变慢/半失败"的判定，不动线上日志
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# 基线目录：正常运行时 = 本脚本所在目录；被 ScriptBlock 方式调用时由 -BaseDir 传入
if (-not $BaseDir) { $BaseDir = $BaseDir }
if (-not $BaseDir) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $BaseDir '运行状态.ps1')   # 记录本轮结果（run-hidden.vbs 拿不到退出码，见该文件说明）

$ws = Split-Path -Parent $BaseDir
$logDir = Join-Path $BaseDir 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir '自检.log'
  # 2026-10-20：告警自测会反复调用本脚本（每次都写一行 ===== 自检：红灯 =====），
  # 实测 81 条红灯里 78 条是演练 → 演练写入单独文件，正式日志只留真实结论。
  if ($env:DSH_SELFTEST_RUNNING -eq '1') { $logFile = Join-Path $logDir '自检-演练.log' }
$alertState = Join-Path $logDir '自检-已告警.json'

# ---------- 周期配置（控制台页可改）：推导"陈旧"阈值 ----------
# 2026-10-15 晚：采集周期从 30 分钟改成了可由用户在控制台自定义（默认 60 分钟）。
# 所以"多久没动作算陈旧"不能再写死 45，而是按 运行配置.json 推导（周期 ×1.5 + 5 分钟余量）。
# 显式传了 -StaleMinutes / -ReminderStaleMinutes（测试用）时以参数为准。
$runCfg = $null
$runCfgFile = Join-Path $BaseDir '运行配置.json'
if (Test-Path -LiteralPath $runCfgFile) {
  try { $runCfg = ((Get-Content -LiteralPath $runCfgFile -Raw -Encoding UTF8) -replace '^\uFEFF','' | ConvertFrom-Json) } catch { $runCfg = $null }
}
if ($runCfg) {
  if (-not $PSBoundParameters.ContainsKey('StaleMinutes')) {
    $c = 0; if ($runCfg.PSObject.Properties['collectMinutes']) { [int]::TryParse([string]$runCfg.collectMinutes, [ref]$c) | Out-Null }
    if ($c -gt 0) { $StaleMinutes = [int]($c * 1.5) + 5 }
  }
  if (-not $PSBoundParameters.ContainsKey('ReminderStaleMinutes')) {
    $r = 0; if ($runCfg.PSObject.Properties['remindMinutes']) { [int]::TryParse([string]$runCfg.remindMinutes, [ref]$r) | Out-Null }
    if ($r -gt 0) { $ReminderStaleMinutes = [int]($r * 3) + 2 }
  }
}

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$name, [string]$level, [string]$detail) {
  $checks.Add([pscustomobject]@{ name = $name; level = $level; detail = $detail })
}

# ---------- 0c. 版本：是不是最新版（2026-10-18 加） ----------
# 目的：让"装了旧版的人"自己看到「请安装最新版本」，不依赖他记得看文档。
# 做法：本机版本（版本.txt）vs GitHub 最新 Release 的 tag。
#   · 查不到（离线/网络受限）→ 不报错，只写"未能检查更新"（离线用户不该被吓）
#   · 结果写进 群聊待办\最新版本提示.txt → 看板页/控制台页会读它并显示横幅
$instVer = ''
$verTxtPath = Join-Path $ws '版本.txt'
if (-not (Test-Path -LiteralPath $verTxtPath)) {
  # 开发工作区里没有根目录 版本.txt（它只打进包里）→ 回退找 发布\ 下的
  $altVer = Join-Path $ws '发布\版本.txt'
  if (Test-Path -LiteralPath $altVer) { $verTxtPath = $altVer }
}
if (Test-Path -LiteralPath $verTxtPath) {
  $mv = [regex]::Match([System.IO.File]::ReadAllText($verTxtPath, [System.Text.Encoding]::UTF8), '(?m)^版本\s*:\s*(\S+)')
  if ($mv.Success) { $instVer = $mv.Groups[1].Value.Trim() }
}
function Convert-VerKey([string]$v) {
  $m = [regex]::Match($v, 'v?(\d{8})-(\d{4})')
  if ($m.Success) { return [long]($m.Groups[1].Value + $m.Groups[2].Value) }
  return [long]0
}
$latestVer = ''
try {
  # ⚠️ PS 5.1 默认可能还是 TLS1.0/1.1，GitHub 只收 TLS1.2 → 不设这行会一直"离线"
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  $savedProxyC = [System.Net.WebRequest]::DefaultWebProxy
  [System.Net.WebRequest]::DefaultWebProxy = $null
  try {
    $relResp = Invoke-RestMethod -Uri 'https://api.github.com/repos/KKEEIIII/qunliao-daiban/releases/latest' -Headers @{ 'User-Agent' = 'dsh-todo-selfcheck'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 6
    $latestVer = [string]$relResp.tag_name
  } finally { [System.Net.WebRequest]::DefaultWebProxy = $savedProxyC }
} catch { }
$hintFile = Join-Path $ws '群聊待办\最新版本提示.txt'
$hintLine = ''
$dlUrl = 'https://github.com/KKEEIIII/qunliao-daiban/releases/latest'
if ($latestVer -ne '' -and $instVer -ne '') {
  if ((Convert-VerKey $latestVer) -gt (Convert-VerKey $instVer)) {
    $hintLine = 'OUTDATED|' + $latestVer + '|' + $instVer + '|请安装最新版本：' + $latestVer + '（本机 ' + $instVer + '）｜下载：' + $dlUrl
    Add-Check '版本' 'yellow' ('本机 ' + $instVer + '，最新 ' + $latestVer + ' → 请安装最新版本（' + $dlUrl + '）')
  } else {
    $hintLine = 'LATEST|' + $latestVer + '|' + $instVer + '|已是最新版（' + $instVer + '）'
    Add-Check '版本' 'green' ('已是最新版（' + $instVer + '）')
  }
} else {
  $hintLine = 'UNKNOWN||' + $instVer + '|未能检查更新（离线或网络受限）；本机 ' + $instVer
  Add-Check '版本' 'green' ('本机 ' + $instVer + '（未能检查更新：离线或网络受限）')
}
try {
  $hintDir = Split-Path -Parent $hintFile
  if (Test-Path -LiteralPath $hintDir) { [System.IO.File]::WriteAllText($hintFile, $hintLine, (New-Object System.Text.UTF8Encoding($false))) }
} catch { }

# ---------- 1. DSH 进程与端口 ----------
$dsh = @()   # DSH 各版本进程名不同（2.x 是 DSH Desktop）→ 三个都查，别再写死一个
foreach ($pn in @('DeepSeek Harness', 'DSH Desktop', 'dsh')) { $dsh += @(Get-Process -Name $pn -ErrorAction SilentlyContinue) }
if ($dsh.Count -eq 0) {
  Add-Check 'DSH 进程' 'red' 'DSH 没在运行'
} else {
  $portOk = $false
  $WebPort = 0
  # (1) 环境变量优先（DSH 自己会话里有 DSH_WEB_URL，计划任务里拿不到）
  if ($env:DSH_WEB_URL -match ':(\d+)') { $WebPort = [int]$Matches[1] }
  # (2) 2026-10-20 加：从 DSH 进程实际监听的端口里找（权威来源）
  #     为什么：DSH 重启后 Web 端口会变（实测 19387 -> 64483），写死候选会让计划任务里
  #     永远报"进程在但 0 端口连不上"的红灯（那 3 条真实红灯就是这么来的）。
  if (-not $WebPort) {
    try {
      $dshPids = @($dsh | ForEach-Object { $_.Id })
      $listenPorts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $dshPids -contains $_.OwningProcess } |
        Select-Object -ExpandProperty LocalPort -Unique)
      foreach ($lp in $listenPorts) {
        try {
          $t2 = New-Object System.Net.Sockets.TcpClient
          $t2.Connect('127.0.0.1', [int]$lp)
          if ($t2.Connected) { $WebPort = [int]$lp; $t2.Close(); break }
          $t2.Close()
        } catch { }
      }
    } catch { }
  }
  # (3) 兜底：常见端口
  if (-not $WebPort) {
    foreach ($p2 in @(19387, 43120, 43121, 64483)) {
      try {
        $t3 = New-Object System.Net.Sockets.TcpClient
        $t3.Connect('127.0.0.1', $p2)
        if ($t3.Connected) { $WebPort = $p2; $t3.Close(); break }
        $t3.Close()
      } catch { }
    }
  }
  if ($WebPort -gt 0) {
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $c.Connect('127.0.0.1', $WebPort)
      $portOk = $c.Connected
      $c.Close()
    } catch { $portOk = $false }
  }
  if ($portOk) {
    Add-Check 'DSH 进程' 'green' ('运行中（{0} 个进程，端口 {1} 可连）' -f $dsh.Count, $WebPort)
  } elseif ($WebPort -gt 0) {
    Add-Check 'DSH 进程' 'red' ('进程在但端口 {0} 连不上' -f $WebPort)
  } else {
    Add-Check 'DSH 进程' 'yellow' '进程在，但没发现可连的 Web 端口（可能正在启动/重启；若持续请检查 DSH 窗口）'
  }
}

# ---------- 1b. DSH 版本：运行中的是不是磁盘上最新的一份（2026-10-23 加） ----------
# 为什么：本机曾同时存在两份安装（0.2.0-rc.2 旧 / 0.2.1-rc.2 新），启动文件夹那个指向旧版的
#   快捷方式开机先把旧版拉起来 → 用户感觉"开机自启永远是老版本"。这条直接把它报出来。
try {
  $dshProcs2 = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.Path })
  if ($dshProcs2.Count -gt 0) {
    $runPath2 = $dshProcs2[0].Path
    $runVer2 = [string](Get-Item -LiteralPath $runPath2 -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    $cands2 = New-Object System.Collections.Generic.List[string]
    $cands2.Add($runPath2)
    foreach ($root2 in @('D:\', 'E:\', 'C:\')) {
      if (-not (Test-Path -LiteralPath $root2)) { continue }
      foreach ($d2 in @(Get-ChildItem -LiteralPath $root2 -Directory -ErrorAction SilentlyContinue)) {
        $cands2.Add((Join-Path $d2.FullName 'DeepSeek Harness.exe'))
      }
    }
    $best2 = $null
    foreach ($c2 in $cands2) {
      if (-not (Test-Path -LiteralPath $c2 -PathType Leaf)) { continue }
      $it2 = Get-Item -LiteralPath $c2 -ErrorAction SilentlyContinue
      if (-not $it2) { continue }
      $mm2 = [regex]::Match([string]$it2.VersionInfo.FileVersion, '\d+(\.\d+){1,3}')
      $v2 = if ($mm2.Success) { [version]$mm2.Value } else { [version]'0.0.0' }
      $kk2 = [pscustomobject]@{ path = $c2; ver = $v2; vt = [string]$it2.VersionInfo.FileVersion; time = $it2.LastWriteTime }
      if ((-not $best2) -or ($kk2.ver -gt $best2.ver) -or (($kk2.ver -eq $best2.ver) -and ($kk2.time -gt $best2.time))) { $best2 = $kk2 }
    }
    if ($best2 -and ($best2.path -ne $runPath2)) {
      Add-Check 'DSH 版本' 'yellow' ('正在运行 ' + $runVer2 + '（' + $runPath2 + '），磁盘最新 ' + $best2.vt + '（' + $best2.path + '）→ 开机可能拉起旧版｜修：在最新版目录里跑 dsh-接入\开机自启DSH.ps1 -Enable，并检查启动文件夹里的 DeepSeek Harness.lnk')
    } else {
      Add-Check 'DSH 版本' 'green' ('运行中 ' + $runVer2 + '，就是磁盘上最新的一份')
    }
  }
} catch { }

# ---------- 2. 待办插件是否在跑 ----------
$pluginLog = if ($PluginLogPath) { $PluginLogPath } else { Join-Path $ws '群聊待办\插件日志.txt' }
if (-not (Test-Path -LiteralPath $pluginLog)) {
  # 2026-10-18：刚装完/还没重启 DSH 时日志本来就不存在 —— 别直接判红（见 6.6b 同样处理）。
  $pmForLog = Join-Path $ws 'dsh-msg-memo\package.json'
  $restartedForLog = $false
  try {
    $dshP = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'DSH|DeepSeek' })
    if ($dshP.Count -gt 0 -and (Test-Path -LiteralPath $pmForLog)) {
      $earliestForLog = ($dshP | Sort-Object StartTime | Select-Object -First 1).StartTime
      $restartedForLog = ($earliestForLog -gt (Get-Item -LiteralPath $pmForLog).LastWriteTime)
    }
  } catch { }
  if (-not $restartedForLog) {
    Add-Check '待办插件' 'yellow' '插件日志还不存在（DSH 还没重启过）→ 重启 DSH 后插件才会装载并写日志；装载后本项转绿'
  } else {
    Add-Check '待办插件' 'red' '插件日志不存在（插件没装载或没跑过）'
  }
} else {
  $lines = @(Get-Content -LiteralPath $pluginLog -Encoding UTF8)
  $last = $lines[-1]
  $mt = (Get-Item -LiteralPath $pluginLog).LastWriteTime
  $ageMin = [int]((Get-Date) - $mt).TotalMinutes
  # 插件每 10 分钟跑一次，成功/失败都会写日志；这里只看"新鲜度"，不依赖某一行还在不在（日志会被滚动）
  if ($ageMin -le (10 + $StaleMinutes)) {
    Add-Check '待办插件' 'green' ("最近活动 {0} 分钟前：{1}" -f $ageMin, $last)
  } elseif ($lines -match '插件已装载') {
    Add-Check '待办插件' 'yellow' ("已装载，但 {0} 分钟没有新记录（可能只是最近没有新消息）" -f $ageMin)
  } else {
    Add-Check '待办插件' 'red' '日志里从来没有"插件已装载"——插件没装上或 DSH 没重启'
  }
}

# ---------- 2b. 模型 token / 额度是否用尽 + 调用是否变慢/半失败 ----------
# 为什么要这条：token 用尽时插件每轮都会失败，但"插件最近活动"那条看着还是新鲜的（失败也写日志），
# 于是采集一直在跑、待办却一条都不出 —— 必须有一个专门的信号。
#
# ⚠️ 2026-10-15 修：原来失败只匹配 '本轮失败'，而插件实际写的是 **'模型调用失败'** →
#    "连续 N 轮全失败"这条红灯**永远算不出来**（当天上午连续 12 轮模型超时，自检一声没吭就是这个原因）。
#    现在失败正则覆盖全部三种失败行，并且新增"变慢"独立判定。
$TokenFailRounds = 10          # 看最近这么多轮
# ⚠️ 2026-10-15 收窄（另一台机器实测抓到的假阳性）：
#   原来含**裸词** `token` → "maximum context length is 65536 tokens"（提示词太长）也被判成
#    "token/额度用尽"，于是自检给出**错误处置建议（去充值）**、占用红灯通道、还推手机。
#    现在：要求是"token/额度/鉴权"这类**语义明确**的词；并且显式排除"上下文过长"类错误。
$TokenKeyword = '401|402|403|Unauthorized|invalid[_ ]?api[_ ]?key|insufficient|quota|balance|rate.?limit|额度|余额|欠费|令牌|apikey|api key|认证|鉴权'
# 明确**不是**额度问题的错误：命中这些就不算"明确指向 token"（免得误报让用户去充值）
$NotTokenKeyword = 'context length|maximum context|too many tokens|上下文|超出.{0,6}长度|prompt is too long|请求过长'
$FailPattern = '本轮失败|模型调用失败|模型输出不是 JSON'   # ← 三种失败行都要算失败
$plog = @(Get-Content -LiteralPath $pluginLog -Encoding UTF8 -ErrorAction SilentlyContinue)
# "轮次结论"行 = 成功（抽出 N 条…，行尾带耗时 ms）或失败（本轮失败：/模型调用失败/模型输出不是 JSON）
# 插件在"没有新采集记录"时不写日志，所以只能看这些
$rounds = @($plog | Where-Object { $_ -match '抽出 \d+ 条|' + $FailPattern })
if ($rounds.Count -eq 0) {
  # ⚠️ 2026-10-15 修假阳性（另一台机器实测）：这里原来是 **yellow**，而下面「模型劣化」分支
  #    只要看到 name 里含"模型"的黄灯就会**白天推手机**，于是**一台刚装好、还没跑过一轮的机器**
  #    每 2 小时弹一次窗、推一次手机，而且出厂 webhook 为空 → `Send-PhonePush` 返回 none →
  #    "推送失败不记去重状态"（那是为网络抖动设计的）→ **永不去重**，整天循环。
  #    "还没跑过一轮"是**全新机器的正常态**（插件没有新采集记录时会早退不写日志），不是故障 → 判绿。
  Add-Check '模型观测' 'green' '插件日志里还没有轮次结论（全新机器还没跑过一轮，属正常）'
} else {
  $recent = @($rounds | Select-Object -Last $TokenFailRounds)
  $fails = @($recent | Where-Object { $_ -match $FailPattern })
  $succ = @($recent | Where-Object { $_ -notmatch $FailPattern })
  $lastFail = if ($fails.Count -gt 0) { ($fails[-1] -replace '^\s*\[[^\]]+\]\s*', '') } else { '' }
  $explicit = ($lastFail -and ($lastFail -match $TokenKeyword) -and ($lastFail -notmatch $NotTokenKeyword))  # 明说是 token/额度问题（且不是"上下文过长"）
  $allFail = ($fails.Count -eq $recent.Count -and $fails.Count -ge 3) # 最近这些轮全失败

  # 最近 2 轮里就有"明确指向 token/额度/鉴权"的失败 → 不用等满 10 轮
  $recent2 = @($recent | Select-Object -Last 2)
  $explicit2 = @($recent2 | Where-Object { $_ -match $FailPattern -and $_ -match $TokenKeyword -and $_ -notmatch $NotTokenKeyword }).Count

  # ---- 成功轮次的耗时（只从成功行里取！失败行里的 180000ms 是超时设定值，算进去会把"慢"的统计带偏）----
  $times = @()
  foreach ($s in $succ) { if ($s -match '（(\d+)ms') { $times += [int]$Matches[1] } }
  $tmed = 0; $tslow = 0
  if ($times.Count -gt 0) {
    $sorted = @($times | Sort-Object)
    $tmed = [int]$sorted[[int][Math]::Floor($sorted.Count / 2)]
    $tslow = @($times | Where-Object { $_ -gt 60000 }).Count
  }
  $slowMed = ($times.Count -ge 3 -and $tmed -gt 60000)               # 多数成功轮都慢
  $slowSome = ($tslow -ge 3)                                         # 3 轮以上慢（个别慢不算）
  $failSome = ($fails.Count -ge 3 -and -not $allFail)                # 半失败（今天上午就是这种）

  # ⚠️ 2026-10-15 加：**看这些轮次行有多旧**（另一个 AI 指出的漏洞）。
  # 原判定只看"最近 N 条写得什么"，不看它们是什么时候写的。而插件在"没有新采集记录"时**不写日志**
  # → 用户换完 key / 充值完，若一直没新消息，日志最后 10 行**永远是旧的失败行** → 红灯一直亮：
  # 配了 webhook 每天推 4 次、没配的每轮都弹窗。所以超过 StaleMinutes 的失败行不再当"当前问题"。
  $lastRoundTs = $null
  if ($rounds.Count -gt 0) {
    $mm = [regex]::Match([string]$rounds[-1], '^\[([^\]]+)\]')
    if ($mm.Success) { $tp = [datetime]::MinValue; if ([datetime]::TryParse($mm.Groups[1].Value, [ref]$tp)) { $lastRoundTs = $tp } }
  }
  $roundsAgeMin = if ($null -ne $lastRoundTs) { [int]((Get-Date) - $lastRoundTs).TotalMinutes } else { -1 }
  $roundsStale = ($roundsAgeMin -ge 0 -and $roundsAgeMin -gt $StaleMinutes)

  if ($roundsStale) {
    # 最近一次轮次结论已经是 $roundsAgeMin 分钟前了 —— 那批失败行**不代表当前状态**：
    # 插件只在"有新采集记录"时才写日志，所以"很久没新行"本身是正常的（没新消息）。
    # 这时不该报红灯（会让用户以为还没修好），最多黄灯提示一下。
    Add-Check '模型观测' 'yellow' ("最近一次模型轮次是 {0} 分钟前（期间没有新采集记录，插件不写日志）→ 当前状态未知，暂不判定：{1}" -f `
        $roundsAgeMin, ($rounds[-1] -replace '^\s*\[[^\]]+\]\s*', ''))
  } elseif ($allFail -or ($explicit -and $fails.Count -ge 1) -or ($explicit2 -ge 2)) {
    $why = if ($explicit2 -ge 2) { ("最近 2 轮里有 {0} 轮明确是 token/鉴权错误" -f $explicit2) }
      elseif ($explicit) { '错误信息明确指向 token/额度/鉴权' }
      else { ("最近 {0} 轮全部失败" -f $fails.Count) }
    Add-Check '模型 token' 'red' ("模型调用失败（{0}）→ **token/额度可能用尽了**，待办不会再更新。最后一条失败：{1}｜处理：去 DSH 里换 key / 充值后重启 DSH" -f $why, $lastFail)
  } elseif ($failSome -or $slowMed -or $slowSome) {
    $bits = @()
    if ($failSome) { $bits += ("最近 {0} 轮里 {1} 轮失败" -f $recent.Count, $fails.Count) }
    if ($slowMed) { $bits += ("成功轮耗时中位数 {0}s（>60s）" -f [int]($tmed / 1000)) }
    elseif ($slowSome) { $bits += ("有 {0} 轮成功但超过 60s" -f $tslow) }
    $extra = if ($lastFail) { "｜最后一条失败：$lastFail" } else { '' }
    Add-Check '模型' 'yellow' ("模型调用在劣化：{0}（还没到红灯线；若接下来全失败会转红）{1}" -f ($bits -join '、'), $extra)
  } else {
    $speed = if ($times.Count -gt 0) { ("，成功轮耗时中位数 {0}s" -f ([Math]::Round($tmed / 1000, 1))) } else { '' }
    Add-Check '模型 token' 'green' ("最近 {0} 轮都成功{1}（最后一轮：{2}）" -f $recent.Count, $speed, ($rounds[-1] -replace '^\s*\[[^\]]+\]\s*', ''))
  }
}

# ---------- 2c. 上一条判定的"自测" ----------
# 为什么要：这类判定最容易写成"看着有逻辑、其实永远不触发"（2026-10-15 上午连 12 轮超时没报警，
# 真因就是失败正则写成 '本轮失败'、而插件写的是 '模型调用失败'）。测试-模型告警.ps1 用假日志
# 把 10 个场景各跑一遍真自检（用 -KeepGoing 在同一进程里跑，省掉 10 次子进程启动开销），这里只要它全过，就说明上面那条判定没被改坏。
#
# ⚠️ 2026-10-15 踩过一个大坑：测试脚本内部要"用真自检验证判定"，而它调用的就是我 →
#    **自检 → 测试 → 自检 → 测试 … 无限递归**，几分钟内起了上千个 powershell 进程（靠杀进程树才止住）。
#    现在两头都设了护栏：测试脚本自己会设 $env:DSH_SELFTEST_RUNNING='1'，
#    而这里看到这个环境变量就**不再回头去调测试**（也支持 DSH_SKIP_SELFTEST 强制跳过）。
$modelWatchTest = Join-Path $BaseDir '测试-模型告警.ps1'
$selftestNested = ($env:DSH_SELFTEST_RUNNING -eq '1') -or ($env:DSH_SKIP_SELFTEST -eq '1')
if ($selftestNested) {
  # 不动 $env:DSH_SKIP_SELFTEST 的值，直接删除 —— 子进程会继承，护栏才能一路传下去
  Remove-Item Env:DSH_SKIP_SELFTEST -ErrorAction SilentlyContinue
  Add-Check '告警自测' 'green' '（本轮由测试脚本调用，跳过自测以免递归）'
} elseif (Test-Path -LiteralPath $modelWatchTest) {
  try {
    $env:DSH_SKIP_SELFTEST = '1'          # 让测试内部再调自检时不再递归
    $tOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $modelWatchTest 2>&1
    $tCode = $LASTEXITCODE
    Remove-Item Env:DSH_SKIP_SELFTEST -ErrorAction SilentlyContinue
    $tTail = @($tOut | Where-Object { $_ -match '通过' } | Select-Object -Last 1)
    if ($tCode -eq 0) {
      Add-Check '告警自测' 'green' ("模型告警判定全部场景通过（{0}）" -f ($tTail -join '').Trim())
    } else {
      $fails = @($tOut | Where-Object { $_ -match '^FAIL' })
      Add-Check '告警自测' 'yellow' ("模型告警判定有问题（改动可能把它弄坏了）：{0}" -f (($fails | Select-Object -First 3) -join ' / '))
    }
  } catch {
    Remove-Item Env:DSH_SKIP_SELFTEST -ErrorAction SilentlyContinue
    Add-Check '告警自测' 'yellow' ("跑 测试-模型告警.ps1 失败：{0}" -f $_.Exception.Message)
  }
}

# ---------- 3. 采集器 / 微信窗口 ----------
$spoolDir = Join-Path $ws 'wx-采集器\spool'
$collectorLog = Join-Path $ws 'wx-采集器\logs\last-pass.txt'
if (Test-Path -LiteralPath $collectorLog) {
  $clog = @(Get-Content -LiteralPath $collectorLog -Encoding UTF8)
  # ⚠️ 2026-10-15 深夜修（外部审查 §7.7）：原来 `$clog -match '跳过…'` 扫的是**整个累积日志** →
  #   历史上出现过一次"窗口不可见跳过"就永久黄灯。现在只取**最后一个轮次标记之后**的行（=最新一轮）。
  $lastMark = -1
  for ($i = $clog.Count - 1; $i -ge 0; $i--) { if ($clog[$i] -match '===== 第') { $lastMark = $i; break } }
  $latestPass = if ($lastMark -ge 0) { @($clog[($lastMark)..($clog.Count - 1)]) } else { $clog }
  $lastC = $clog[-1]
  $cmt = (Get-Item -LiteralPath $collectorLog).LastWriteTime
  $cage = [int]((Get-Date) - $cmt).TotalMinutes
  if ($latestPass -match '跳过：微信窗口当前不可见') {
    Add-Check '采集器' 'yellow' ("上一轮跳过了：{0}" -f ($latestPass | Where-Object { $_ -match '跳过' } | Select-Object -Last 1))
  } elseif ($cage -le $StaleMinutes) {
    Add-Check '采集器' 'green' ("最近一轮 {0} 分钟前" -f $cage)
  } else {
    Add-Check '采集器' 'yellow' ("{0} 分钟没跑过（检查计划任务 微信待办-采集）" -f $cage)
  }
} else {
  Add-Check '采集器' 'yellow' '还没有采集日志'
}

$wx = @(Get-Process -Name Weixin -ErrorAction SilentlyContinue)
if ($wx.Count -eq 0) { Add-Check '微信' 'red' '微信没在运行（采集会全部跳过）' }
else { Add-Check '微信' 'green' ("运行中（{0} 个进程）" -f $wx.Count) }

# ---------- 4. 计划任务（不只看结果码，还要看"命令指向的脚本对不对"）----------
# 背景（2026-10-14 实测踩过）：两个采集任务的命令行都写了 8.3 别名 `采集器~1.PS1`，
# 而那个别名其实属于 `采集器-QQ.ps1` → **微信任务一直在跑 QQ 采集器**，
# 但 Last Result 始终是 0（执行成功）→ 自检全绿，这个 bug 瞒了很久。
# 所以这里必须校验四件事：
#   ① 命令里 -File 指向的文件真实存在 ② 解析出来的文件名符合预期（抓 8.3 别名指错）
#   ③ 两个采集任务没有指向同一个脚本 ④ 该任务"应该写"的日志确实在更新
$taskSpecs = @(
  [pscustomobject]@{ name = '微信待办-采集'; file = '采集器.ps1'; log = 'wx-采集器\logs\last-pass.txt'; stale = $StaleMinutes }
  [pscustomobject]@{ name = 'QQ待办-采集'; file = '采集器-QQ.ps1'; log = 'wx-采集器\logs\qq-last-pass.txt'; stale = $StaleMinutes }
  [pscustomobject]@{ name = '微信待办-提醒'; file = '提醒器.ps1'; log = $null; stale = 0 }   # 提醒器日志是"有事才写"，不能查新鲜度
  [pscustomobject]@{ name = '微信待办-自检'; file = '自检.ps1'; log = $null; stale = 0 }
  # 入站：手机通知转发进来（以前自检漏了这个任务）
  [pscustomobject]@{ name = '微信待办-转发接收'; file = '接收端.ps1'; log = 'dsh-接入\logs\转发接收.log'; stale = 30 }
)
$taskTargets = @{}
foreach ($spec in $taskSpecs) {
  $tn = $spec.name
  # ⚠️ 不要解析 schtasks 的文本输出：它是**本地化**的 —— 实测同一个脚本
  #    在 DSH 会话里跑拿到英文（`Last Result:`），被计划任务拉起时拿到中文（`上次结果:`），
  #    于是"4 个任务同时查不到"这种整片红灯的假故障（2026-10-14 17:53 就推过一次手机）。
  #    改用对象接口 Get-ScheduledTask / Get-ScheduledTaskInfo：与语言无关，也不受控制台代码页影响。
  $task = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
  if ($null -eq $task) {
    # 兜底：cmdlet 不可用（很老的系统）时退回 schtasks，并且**中英文都认**
    $eapQ = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $q = (& schtasks /query /tn $tn /fo LIST /v 2>&1 | Out-String) } catch { $q = '' }
    $ErrorActionPreference = $eapQ
    if ($q -notmatch 'Last Result:|上次结果:') {
      Add-Check "任务 $tn" 'red' '任务不存在（Get-ScheduledTask 和 schtasks 都查不到）'
      continue
    }
    $res = [regex]::Match($q, '(?:Last Result|上次结果):\s*(\S+)').Groups[1].Value
    $last = [regex]::Match($q, '(?:Last Run Time|上次运行时间):\s*(.+)').Groups[1].Value.Trim()
    $tr = [regex]::Match($q, '(?:Task To Run|要运行的任务):\s*(.+)').Groups[1].Value.Trim()
  } else {
    $info = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
    $res = if ($info) { [string]$info.LastTaskResult } else { '' }
    $last = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $info.LastRunTime.ToString('yyyy/MM/dd HH:mm:ss') } else { '从未运行' }
    # 动作拼成一行，交给下面同一套"-File 之后取路径"的逻辑
    $tr = (@($task.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() }) -join ' ; ').Trim()
  }

  # 已禁用的任务：不参与运行，也不该因为"日志旧"被误报（实测：转发接收被禁用后，自检一直黄灯说它日志旧）
  if ($task -and $task.State -eq 'Disabled') {
    Add-Check "任务 $tn" 'green' '已禁用（不参与运行，跳过检查）'
    continue
  }

  $problems = @()        # 红灯：配置类错误（指向错文件/两个任务撞车）→ 会推手机
  $softProblems = @()    # 黄灯：可能只是电脑休眠过/任务没跑 → 只记日志，不半夜吵人
  # ① ② ③ 校验命令指向的脚本
  # 两种形态都要认：
  #   a) powershell -File xxx.ps1 ...            （老形态）
  #   b) wscript.exe run-hidden.vbs xxx.ps1 ...  （2026-10-14 起：用 VBS 外壳消除控制台闪窗）
  # 所以先按 -File 取；取不到就退而抓动作里**第一个绝对路径的 .ps1**。两条都不认才报错。
  $pathM = [regex]::Match($tr, '-File\s+(.+?)(?=\s+-[A-Za-z]|\s*$)')
  $path = $pathM.Groups[1].Value.Trim().Trim('"')
  if (-not $path) {
    $path = [regex]::Match($tr, '([A-Za-z]:\\[^"]*?\.ps1)').Groups[1].Value.Trim()
  }
  if (-not $path) {
    $problems += '命令里找不到 -File 参数'
  } elseif (-not (Test-Path -LiteralPath $path)) {
    $problems += ("命令指向的文件不存在（{0}）" -f $path)
  } else {
    $resolved = (Get-Item -LiteralPath $path).FullName
    $leaf = Split-Path -Leaf $resolved
    if ($leaf -ne $spec.file) { $problems += ("指向的是 {0}，应该是 {1}（8.3 短名很容易指错）" -f $leaf, $spec.file) }
    if ($taskTargets.ContainsKey($resolved)) { $problems += ("和任务 {0} 指向同一个脚本" -f $taskTargets[$resolved]) }
    else { $taskTargets[$resolved] = $tn }
  }
  # ④ 该任务应写的日志是否在更新（每个采集任务每次跑都会重写自己的日志）
  if ($spec.log -and $spec.stale -gt 0) {
    $lp = Join-Path $ws $spec.log
    if (-not (Test-Path -LiteralPath $lp)) {
      if (($res -eq '267011') -or ($res -eq '0x41303') -or ($last -eq '从未运行')) { $softProblems += ("任务尚未到首次运行时间，还没有 {0}（正常）" -f $spec.log) } else { $problems += ("找不到它该写的日志 {0}" -f $spec.log) }
    } else {
      $lAge = [int]((Get-Date) - (Get-Item -LiteralPath $lp).LastWriteTime).TotalMinutes
      if ($lAge -gt $spec.stale) {
        # 这里刻意只报黄灯：可能只是电脑休眠/任务没跑；"跑错脚本"那种硬伤由上面的文件名校验抓（红灯）
        $softProblems += ("它该写的 {0} 已 {1} 分钟没更新（任务没跑？电脑休眠过？）" -f (Split-Path -Leaf $lp), $lAge)
      }
    }
  }

  if ($problems.Count -gt 0) {
    Add-Check "任务 $tn" 'red' (($problems -join '；') + ("〔最近运行 {0}，结果 {1}〕" -f $last, $res))
  } elseif ($softProblems.Count -gt 0) {
    Add-Check "任务 $tn" 'yellow' (($softProblems -join '；') + ("〔最近运行 {0}，结果 {1}〕" -f $last, $res))
  } elseif ($res -eq '0') {
    Add-Check "任务 $tn" 'green' ("最近运行 {0}，结果 0" -f $last)
  } elseif ($res -eq '267011' -or $res -eq '0x41303' -or $res -eq '267009' -or $res -eq '0x41301' -or $res -eq '0x00041301') {
    # 267009 = SCHED_S_TASK_RUNNING：自检查自己的时候几乎必然是"正在运行"，不是故障
    if (($res -eq '267011') -or ($res -eq '0x41303')) { Add-Check "任务 $tn" 'green' '已注册，尚未到首次运行时间（正常）' } else { Add-Check "任务 $tn" 'green' '查询时这一轮正在运行（正常）' }
  } elseif ([string]::IsNullOrWhiteSpace($res)) {
    Add-Check "任务 $tn" 'yellow' '查不到结果'
  } else {
    # "退出码非 0" 这一条对**自检任务自己**只报黄灯：它非 0 的含义就是"上一轮自检发现了红灯"，
    # 而那些红灯的原因这一轮**会照样被检查**（真没修好就还是红灯）。若这里也报红灯，
    # 一次瞬时故障就会让之后每一轮自检都红灯、每轮都推手机 —— 实测踩过这个自我放大的连锁。
    if ($tn -like '*自检*') {
      Add-Check "任务 $tn" 'yellow' ("最近运行 {0}，结果码 {1}（= 上一轮自检发现了红灯，原因看 ..\dsh-接入\logs\自检.log 尾部）" -f $last, $res)
    } else {
      Add-Check "任务 $tn" 'red' ("最近运行 {0}，结果码 {1}（非 0）" -f $last, $res)
    }
  }
}

# ---------- 4b. 开机自启指向（2026-10-23 加） ----------
# 为什么要有这条：实测出现过"任务被从 %TEMP% 的临时解压副本注册"，目录删掉后
#   开机启动静默失败（任务结果=1），而用户看到的现象是"开机打开的还是老版本/根本没启动"。
try {
  $bootTask = Get-ScheduledTask -TaskName 'DSH-开机自启' -ErrorAction SilentlyContinue
  if (-not $bootTask) {
    Add-Check '开机自启' 'green' '未启用（不影响采集/提醒；想开机免手动启动就运行 dsh-接入\开机自启DSH.ps1 -Enable）'
  } else {
    $barg = [string](($bootTask.Actions | Select-Object -First 1).Arguments)
    $wantPs1 = Join-Path $ws 'dsh-接入\开机自启DSH.ps1'
    $bHere = $barg -and $barg.Contains($wantPs1)
    $bm = [regex]::Match($barg, '"([^"]+\.vbs)"')
    $bVbsOk = if ($bm.Success) { Test-Path -LiteralPath $bm.Groups[1].Value } else { $false }
    if ($bHere -and $bVbsOk) {
      Add-Check '开机自启' 'green' ('指向本机当前版本（' + $bootTask.State + '）')
    } elseif (-not $bVbsOk) {
      Add-Check '开机自启' 'yellow' ('任务指向的 vbs 已不存在 → 开机启动会静默失败。指向：' + $barg + '｜修：跑 dsh-接入\开机自启DSH.ps1 -Enable')
    } else {
      Add-Check '开机自启' 'yellow' ('任务指向的不是当前版本（开机可能拉起旧版本）：' + $barg + '｜修：跑 dsh-接入\开机自启DSH.ps1 -Enable')
    }
  }
} catch { Add-Check '开机自启' 'yellow' ('检查失败：' + $_.Exception.Message) }

# ---------- 5. 提醒器 ----------
# ⚠️ 2026-10-15 改进：原来只看 `提醒器.log` 的修改时间，而这个日志**只在真的发出提醒时才写**
#   → 一整天没有待办到期时，它永远是"很久没动作"的黄灯（典型的假阳性：把"没事可做"说成"可能挂了"）。
#   提醒器现在会把每轮结果写进 运行状态.json（含"本轮无待提醒项"），所以以状态文件为主判据：
#   状态新鲜 = 它真的在按时跑（哪怕什么都没做）；日志时间只作为补充信息。
$remLog = Join-Path $BaseDir 'logs\提醒器.log'
$remRs = $null
try {
  $rsPath = Join-Path $BaseDir 'logs\运行状态.json'
  if (Test-Path -LiteralPath $rsPath) {
    $rsObj = ([System.IO.File]::ReadAllText($rsPath, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", '') | ConvertFrom-Json
    if ($rsObj.PSObject.Properties['提醒器']) { $remRs = $rsObj.PSObject.Properties['提醒器'].Value }
  }
} catch { }
$remAgeState = -1
if ($remRs) {
  $t = [datetime]::MinValue
  if ([datetime]::TryParse([string]$remRs.at, [ref]$t)) { $remAgeState = [int]((Get-Date) - $t).TotalMinutes }
}
if ($remAgeState -ge 0) {
  $note = if ([string]$remRs.note) { "（" + [string]$remRs.note + "）" } else { '' }
  if ($remAgeState -le $ReminderStaleMinutes) {
    Add-Check '提醒器' 'green' ("{0} 分钟前跑过一轮{1}" -f $remAgeState, $note)
  } else {
    Add-Check '提醒器' 'yellow' ("{0} 分钟没跑过（计划任务是每 5 分钟一次；超过 {1} 分钟可疑）" -f $remAgeState, $ReminderStaleMinutes)
  }
} elseif (Test-Path -LiteralPath $remLog) {
  $age = [int]((Get-Date) - (Get-Item -LiteralPath $remLog).LastWriteTime).TotalMinutes
  Add-Check '提醒器' 'yellow' ("没有运行状态记录，只有 {0} 分钟前的提醒日志（日志只在真的发出提醒时才写，所以这条判不准）" -f $age)
} else { Add-Check '提醒器' 'yellow' '还没有提醒日志、也没有运行状态记录' }

# ---------- 5b. 各脚本"上一轮到底成功没有" ----------
# 为什么要：任务是用 run-hidden.vbs 拉起的，VBS 不等待 → 拿不到退出码 → LastTaskResult 恒为 0，
# 于是"脚本悄悄挂了"这件事在任务层面**永远看不出来**。脚本自己把结果写进 运行状态.json，
# 这里读回来；只对"有记录且非 0"的报警（没记录 = 这轮还没跑过，不算故障）。
$rsFile = Join-Path $BaseDir 'logs\运行状态.json'
if (Test-Path -LiteralPath $rsFile) {
  try {
    $rs = ([System.IO.File]::ReadAllText($rsFile, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", '') | ConvertFrom-Json
    $bad = @()
    $stale = @()
    $seen = 0   # 有几个脚本留下了记录（用来区分'都成功'和'还都没跑过'）
    $neverRan = @()   # ⚠️ 2026-10-15 深夜新增：任务**跑过**却从没留下运行状态记录 = 疑似"一启动就崩"（外部复测 2136 版抓的盲区）
    # 名字 → 计划任务 + 该任务应写的日志（用来判断"跑过没留痕"；提醒器此前漏覆盖，外部审查点名，已补）
    $rsTaskMap = @{
      '采集器-微信' = @{ tn = '微信待办-采集'; log = 'wx-采集器\logs\last-pass.txt' }
      '采集器-QQ'   = @{ tn = 'QQ待办-采集';     log = 'wx-采集器\logs\qq-last-pass.txt' }
      '提醒器'      = @{ tn = '微信待办-提醒';   log = 'dsh-接入\logs\提醒器.log' }
    }
    foreach ($nm in @('采集器-微信', '采集器-QQ', '提醒器')) {   # 不看'自检'自己（会自我判红）
      # ⚠️ 已禁用的任务：残留的 code=1 记录不该每轮红灯（外部审查 §3.3.2）
      $tkState = $null
      if ($rsTaskMap[$nm]) {
        $tk0 = Get-ScheduledTask -TaskName $rsTaskMap[$nm].tn -ErrorAction SilentlyContinue
        if ($tk0) { $tkState = [string]$tk0.State }
      }
      if ($rs.PSObject.Properties[$nm]) {
        if ($tkState -eq 'Disabled') { continue }
        $seen++
        $v = $rs.PSObject.Properties[$nm].Value
        $at = [datetime]::MinValue
        $ok = [datetime]::TryParse([string]$v.at, [ref]$at)
        if ([int]$v.code -ne 0) { $bad += ("{0}={1}（{2}）" -f $nm, $v.code, $v.note) }
        elseif ($ok -and ((Get-Date) - $at).TotalHours -gt 6) { $stale += ("{0}（{1:HH:mm}）" -f $nm, $at) }
        continue
      }
      # 没有记录：查它的计划任务是否"已跑过却没留痕"（跑了 = 任务 LastRunTime 有效 或 它该写的日志存在）
      if (-not $rsTaskMap[$nm]) { continue }
      $tn = $rsTaskMap[$nm].tn
      $tk = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
      if (-not $tk -or $tk.State -eq 'Disabled') { continue }
      $tkInfo = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
      $ran = ($tkInfo -and $tkInfo.LastRunTime -and $tkInfo.LastRunTime.Year -gt 1999)
      $logPath = Join-Path $ws $rsTaskMap[$nm].log
      if (-not $ran -and -not (Test-Path -LiteralPath $logPath)) { continue }
      $neverRan += $nm
    }
    if ($bad.Count -gt 0) {
      Add-Check '运行状态' 'red' ("有脚本上一轮失败了：{0}｜看 dsh-接入\logs\ 下对应日志" -f ($bad -join '；'))
    } elseif ($neverRan.Count -gt 0) {
      # 任务确实跑过（LastRunTime 有效或日志文件在），但运行状态里从来没有它的记录 → 疑似脚本启动即崩
      # （如 QQ 采集器缺 VC++ 运行库时 DllNotFoundException 直接穿透）。用黄灯：不排除"用户手动跑过一两次"
      Add-Check '运行状态' 'yellow' ("这些任务跑过，但从未留下运行状态记录（脚本可能一启动就崩了）：{0}｜看 dsh-接入\logs\ 与 wx-采集器\logs\ 下对应日志" -f ($neverRan -join '、'))
    } elseif ($stale.Count -gt 0) {
      Add-Check '运行状态' 'yellow' ("这些脚本超过 6 小时没记录（可能没触发，也可能没跑）：{0}" -f ($stale -join '、'))
    } elseif ($seen -eq 0) {
      # ⚠️ 1550 版这里落进了 else → 把'还都没跑过'说成'都成功'（复测报告 A 条：与模型那条一样的假阳性）。
      # 注意：QQ 采集器在'没装 Maa、走屏幕模式'时也会写状态了（B 条），所以这里判黄不会变成去不掉的灯。
      Add-Check '运行状态' 'yellow' '采集器/提醒器都还没有运行记录（可能还没到首次触发时间；不是故障）'
    } else {
      Add-Check '运行状态' 'green' ("各脚本最近一轮都成功（{0}/3 个有记录）" -f $seen)
    }
  } catch {
    Add-Check '运行状态' 'yellow' ("运行状态.json 读不动：{0}" -f $_.Exception.Message)
  }
} else {
  # ⚠️ 2026-10-15 修（另一个 AI 复测 §4.3）：文件根本不存在时判 **green** 是"把未知说成成功"的
  # 同一种毛病（就是 A 条修掉的那个）。但也不能判红 —— 全新机器第一次跑自检时文件本来就没有。
  # 这里的处理：判黄，并**顺手写一条最小记录**去证明"写盘这条链路真的通"（而不是靠"假设它没问题"）。
  #
  # ⚠️ 复测 §5.2 纠正了我原先注释里的因果：我写的是"下一轮黄灯自然消失"，**这个说法不成立** ——
  #    这条黄灯说的是"三个业务脚本还没有记录"，光靠自检写的那条记录不会让它消失；
  #    消失的条件是**采集器/提醒器真的跑过一轮**（那时才走上面的 $seen 分支）。
  #    "自证"的价值在于：万一连这条记录都写不进去（比如目录只读），下一轮仍是这条黄灯，
  #    那时它就从"还没跑过"变成"写盘可能有问题"的信号了。
  Add-Check '运行状态' 'yellow' '还没有业务脚本的运行记录（采集器/提醒器还没跑过；不是故障）→ 本轮已写入一条最小记录自证写盘链路'
  try { Write-RunStatus -Name '自检链路验证' -Code 0 -Note '由自检写入的最小记录' } catch { }
}
# ---------- 6. 待办概览 ----------
$todoFile = Join-Path $ws '群聊待办\todos.json'
if (Test-Path -LiteralPath $todoFile) {
  # ⚠️ 2026-10-15 修（另一台机器实测暴露的**自检变瞎**）：
  # ① 原来 `Get-Content | ConvertFrom-Json` 没有 try/catch —— todos.json 万一被写坏（插件是非原子写），
  #    自检当场崩，而且穷在**所有告警逻辑之前** → 从此不再报任何问题（恰恰是最该报警的时候）。
  # ② 原来 `[datetime]::Parse(...)` 也没保护 —— 模型给的 due 只要有一条不可解析
  #    （'明天中午'/'待定'/'尽快'…全部抛 FormatException），同样让自检猝死。
  #    现在：解析失败的条目**不算逾期**，另外单独报一条黄灯（能看出来有几条脏 due）。
  $t = $null
  try { $t = (Get-Content -LiteralPath $todoFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
  catch { Add-Check '待办' 'yellow' ("todos.json 读不动（可能被写坏）：{0}" -f $_.Exception.Message) }
  if ($null -ne $t) {
    # 兼容"单元素数组被写成对象"和"数组形态"两种历史写法
    $items = if ($t.items -is [array]) { @($t.items) } elseif ($null -eq $t.items) { @() } else { @($t.items) }
    $items = @($items | Where-Object { $null -ne $_ })
    $open = @($items | Where-Object { [string]$_.status -in @('open', 'pending_confirm') })
    $overdue = @()
    $badDue = @()
    $nowTs = Get-Date
    foreach ($it in $open) {
      if (-not $it.due) { continue }
      $d = [datetime]::MinValue
      if ([datetime]::TryParse([string]$it.due, [ref]$d)) {
        if ($d -lt $nowTs) { $overdue += $it }
      } else {
        $badDue += $it
      }
    }
    $lv = if ($overdue.Count -gt 0) { 'yellow' } else { 'green' }
    Add-Check '待办' $lv ("共 {0} 条，未完成 {1} 条，逾期 {2} 条" -f $items.Count, $open.Count, $overdue.Count)
    if ($badDue.Count -gt 0) {
      Add-Check '待办时间' 'yellow' ("{0} 条 due 解析不了（不会算逾期、也不会提醒）：{1}" -f `
          $badDue.Count, (($badDue | Select-Object -First 3 | ForEach-Object { [string]$_.due }) -join ' / '))
    }
  }
} else { Add-Check '待办' 'green' '还没有待办（正常）' }

# ---------- 6.5 日常维护：清老采集文件 + 日志滚动 ----------
$removedSpoil = 0
$cut = (Get-Date).AddDays(-30)
$spoolDirForClean = Join-Path $ws 'wx-采集器\spool'
if (Test-Path -LiteralPath $spoolDirForClean) {
  Get-ChildItem -LiteralPath $spoolDirForClean -Filter 'messages-*.jsonl' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cut } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $removedSpoil++ }
}
# 老截图（保留最近 200 张）
$shotDirForClean = Join-Path $ws 'wx-采集器\shots'
$removedShots = 0
if (Test-Path -LiteralPath $shotDirForClean) {
  $old = Get-ChildItem -LiteralPath $shotDirForClean -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 200
  foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $removedShots++ }
}
# 日志超过 2MB 就只留最后 1500 行
$rolled = 0
foreach ($f in @($pluginLog, $remLog, $logFile)) {
  if (Test-Path -LiteralPath $f) {
    if ((Get-Item -LiteralPath $f).Length -gt 2MB) {
      (Get-Content -LiteralPath $f -Encoding UTF8 -Tail 1500) | Set-Content -LiteralPath $f -Encoding UTF8
      $rolled++
    }
  }
}
Add-Check '日常维护' 'green' ("清理 30 天前采集文件 {0} 个、老截图 {1} 张、滚动日志 {2} 个" -f $removedSpoil, $removedShots, $rolled)

# ---------- 6.6 脚本编码：安装目录里的 .ps1 必须都带 UTF-8 BOM ----------
# 为什么自检要管这个（2026-10-16 加）：PS 5.1 对**无 BOM** 的 .ps1 会按 GBK 读中文注释 →
# 乱码可能吃掉换行/花括号 → 整个脚本一运行就崩，报错还看不懂。包内脚本本来是打包时保证带 BOM 的，
# 但收件人**手工改过脚本**（或从别处复制覆盖）就会破坏它 —— 这里提前发现，比"任务悄悄不跑了"强。
$noBomScripts = @()
$bomPollution = @()
$vbsWithBom = @()
try {
  foreach ($sf in (Get-ChildItem -LiteralPath $ws -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|logs|spool|fixtures)\\' -and $_.Extension -in @('.ps1', '.json', '.mjs', '.js', '.md', '.txt', '.yml', '.vbs', '.cmd') })) {
    $sb = [System.IO.File]::ReadAllBytes($sf.FullName)
    $hasBom = ($sb.Length -ge 3 -and $sb[0] -eq 0xEF -and $sb[1] -eq 0xBB -and $sb[2] -eq 0xBF)
    if ($sf.Extension -eq '.ps1') {
      if (-not $hasBom) { $noBomScripts += $sf.Name }          # .ps1 **必须**有 BOM
    } elseif ($hasBom) {
      if ($sf.Extension -in @('.vbs', '.cmd')) { $vbsWithBom += $sf.Name }   # .vbs/.cmd 带 BOM = 致命
      else { $bomPollution += $sf.Name }                        # 其它文本带 BOM = 多余的（打包脱敏留下的印记）
    }
  }
} catch { }
# 2026-10-16 修（外部复测 §四.3："这句检查像误报"）：原来只查 .ps1 缺 BOM，文案却写成
# "全部 .ps1 都带 UTF-8 BOM"，读起来像"整个目录都不该有 BOM"——而安装目录里 .json/.md/.txt 带 BOM
# 本来就是打包留下的多余印记。现在**分开报、语义写明**（读取端都做了容错，所以只算脏印记不算故障）。
if ($vbsWithBom.Count -gt 0) {
  Add-Check '脚本编码' 'red' ("这些 .vbs/.cmd 带了 UTF-8 BOM —— WSH/cmd 按 ANSI 读，计划任务会'启动即失败'：{0}｜修：去掉 BOM（.vbs 只能纯 ASCII）" -f ($vbsWithBom -join '、'))
} elseif ($noBomScripts.Count -gt 0) {
  Add-Check '脚本编码' 'yellow' ("这些 .ps1 缺 UTF-8 BOM（PS 5.1 会按 GBK 读，中文注释可能把脚本读崩）：{0}｜修：重新解压一份干净包覆盖" -f ($noBomScripts -join '、'))
} elseif ($bomPollution.Count -gt 0) {
  Add-Check '脚本编码' 'green' ("必需的编码都对（.ps1 都有 BOM、.vbs/.cmd 都没 BOM）；另有 {0} 个文本文件（.json/.md/.txt 等）带多余 BOM，不影响运行，只是打包留下的小印记：{1}" -f $bomPollution.Count, (($bomPollution | Select-Object -First 5) -join '、'))
} else {
  Add-Check '脚本编码' 'green' '必需编码都对：.ps1 有 BOM（PS 5.1 必需）、.vbs/.cmd 无 BOM（WSH 必需）、其余文本无多余 BOM'
}

# ---------- 6.6b 插件清单编码 + bundle 是否真被 DSH 装载 ----------
# 2026-10-17 加（外部复测的阻断级缺陷）：DSH 读 bundle 的 package.json 是裸 JSON.parse，**不剥 BOM**；
# 带 BOM → SyntaxError → 整个 bundle 被静默跳过（DSH 界面无任何报错），用户只看到"插件日志不存在"。
# 所以这里单独查"清单 BOM"，并且把"bundles 里有它、却从来没生成过插件日志"当成红灯，直接给出修法。
$plugDir = Join-Path $ws 'dsh-msg-memo'
$badManifest = @()
foreach ($mn in @('package.json', 'cordis.patch.yml', 'config.json')) {
  $mp = Join-Path $plugDir $mn
  if (Test-Path -LiteralPath $mp) {
    $mb = [System.IO.File]::ReadAllBytes($mp)
    if ($mb.Length -ge 3 -and $mb[0] -eq 0xEF -and $mb[1] -eq 0xBB -and $mb[2] -eq 0xBF) { $badManifest += $mn }
  }
}
$plugLog = Join-Path $ws '群聊待办\插件日志.txt'
if ($badManifest.Count -gt 0) {
  Add-Check '插件清单' 'red' ('这些文件带 UTF-8 BOM → DSH 读 bundle 清单是裸 JSON.parse，会**静默跳过整个插件**（界面无报错）：' + ($badManifest -join '、') + '｜修：只删前 3 字节去掉 BOM，再重启 DSH')
} else {
  $bundled = $false
  foreach ($pn in @('desktop')) {
    $pf = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $pn + '\package.json')
    if (Test-Path -LiteralPath $pf) {
      $pt = ([System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8)) -replace '^\uFEFF', ''
      if ($pt -match 'dsh-msg-memo') { $bundled = $true }
    }
  }
  if ($bundled -and -not (Test-Path -LiteralPath $plugLog)) {
    # 2026-10-18（外部复测 P2-2）：全新安装后**必然**是"bundles 里有它、还没有插件日志"——
    #   日志要等 DSH 重启后才写。原来一律判红，把用户往"又踩 BOM 坑"上带。
    #   现在先看 DSH 有没有在安装（= package.json 的 mtime）之后重启过：
    #     没重启（或 DSH 没在跑）→ 黄灯，说清"重启后才会装载"；重启过仍无日志 → 才是红灯。
    $instMtime = $null
    $pmPath = Join-Path $plugDir 'package.json'
    if (Test-Path -LiteralPath $pmPath) { $instMtime = (Get-Item -LiteralPath $pmPath).LastWriteTime }
    $restarted = $false
    try {
      $dshProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'DSH|DeepSeek' })
      if ($dshProcs.Count -gt 0 -and $instMtime) {
        $earliest = ($dshProcs | Sort-Object StartTime | Select-Object -First 1).StartTime
        $restarted = ($earliest -gt $instMtime)
      }
    } catch { }
    if (-not $restarted) {
      Add-Check '插件清单' 'yellow' '插件已挂进 DSH 的 bundles，但 DSH 还没重启（重启后才会装载）→ 重启 DSH 一次，装载成功后本项自动转绿'
    } else {
      Add-Check '插件清单' 'red' '插件已写进 bundles、DSH 也重启过了，却从来没有 群聊待办\插件日志.txt → bundle 很可能被静默跳过（清单 BOM / 解析失败）｜修：检查 dsh-msg-memo 清单 BOM 后重启 DSH'
    }
  } elseif ($bundled) {
    Add-Check '插件清单' 'green' ('清单无 BOM；插件已装载过（插件日志最后写入 ' + (Get-Item -LiteralPath $plugLog).LastWriteTime + '）')
  } else {
    Add-Check '插件清单' 'yellow' 'DSH 的 dsh.profile.bundles 里没有 @local/dsh-msg-memo（插件没挂上）→ 重跑 安装.ps1 挂插件那一步'
  }
}

# ---------- 汇总 ----------
$reds = @($checks | Where-Object { $_.level -eq 'red' })
$yellows = @($checks | Where-Object { $_.level -eq 'yellow' })
$overall = if ($reds.Count -gt 0) { '红灯' } elseif ($yellows.Count -gt 0) { '黄灯' } else { '绿灯' }

Log ("===== 自检：{0} =====" -f $overall)
foreach ($c in $checks) { Log ("  [{0}] {1} - {2}" -f $c.level.ToUpper(), $c.name, $c.detail) }

$needAlert = $Force -or $reds.Count -gt 0

# ---- "模型调用劣化"这条黄灯也要推手机 ----
# 为什么破例：上午连续 12 轮超时（一半失败）时，自检只在日志里记了黄灯，用户完全不知道；
# 而"模型变慢/半失败"是**会自己恶化成完全不出待办**的前兆，值得提前知道。
# 但仍然只在**白天**推（8:00~23:00），半夜为"慢一点"吵醒人不划算；红灯不受这个限制。
$modelDegrade = @($checks | Where-Object { $_.level -eq 'yellow' -and $_.name -match '模型' })
$daytime = ((Get-Date).Hour -ge 8 -and (Get-Date).Hour -lt 23)
$degradeAlert = ($modelDegrade.Count -gt 0 -and $daytime)
if ($degradeAlert) { $needAlert = $true }

$body = ($checks | ForEach-Object { "{0}: {1}" -f $_.name, $_.detail }) -join "`n"
$title = "群聊待办自检 · $overall"

Write-RunStatus -Name '自检' -Code 0   # 只表示'自检脚本本身跑完了'；发现问题由各项检查表达（写 1 会自我判红、死循环）   # 放在 -Quiet 早退之前，否则 -Quiet 模式写不到
if ($Quiet) { Log '（-Quiet：不推送）'; exit 0 }

# 告警去重：同一批问题 6 小时内只提醒一次；绿灯时不打扰
$state = @{}
if (Test-Path -LiteralPath $alertState) {
  try { $s = Get-Content -LiteralPath $alertState -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $s.PSObject.Properties) { $state[$p.Name] = $p.Value } } catch {}
}
$sig = ($checks | Where-Object { $_.level -ne 'green' } | ForEach-Object { $_.name }) -join ','
$key = if ($sig) { $sig } else { 'all-green' }
$lastAt = $null
if ($state.ContainsKey($key)) { $lastAt = [datetime]$state[$key] }
$suppress = ($null -ne $lastAt) -and (((Get-Date) - $lastAt).TotalHours -lt 6) -and (-not $Force)

if (($needAlert -or $Force) -and -not $suppress) {
  # 弹窗（保底）+ 手机推送
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'FixedToolWindow'; $f.TopMost = $true; $f.Text = $title
  $f.ClientSize = New-Object System.Drawing.Size(460, 220)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(($wa.Right - 480), ($wa.Bottom - 260))
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.Dock = 'Fill'
  $tb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
  $tb.Text = $body
  $f.Controls.Add($tb); $f.Show()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 12) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120 }
  $f.Close(); $f.Dispose()

  # 手机推送（统一走 推送.ps1：企业微信机器人；ntfy 出站通道 2026-10-14 已弃用）
  $res = ''
  try {
    . (Join-Path $BaseDir '推送.ps1')
    $res = Send-PhonePush -Title $title -Text $body
    Log ('已推手机：' + $res)
  } catch { Log ('手机推送失败：' + $_.Exception.Message) }

  # ⚠️ 只有"真的推成功"才记进 6 小时去重状态。
  # 2026-10-15 修：原来不管成功失败都记（$state[$key] = now）→ 网络一抖、推送失败，
  # 这条告警却已被标记成"提醒过了" → **接下来 6 小时同类告警全被压住**，等于静默丢告警。
  # 失败时不记：2 小时后下一轮自检会再试一次（红灯本来就会重复推，值得）。
  $pushOk = ($res -ne '' -and $res -ne 'none' -and $res -ne 'disabled')
  if ($pushOk) {
    $state[$key] = (Get-Date).ToString('o')
    $obj = [ordered]@{}; foreach ($k in $state.Keys) { $obj[$k] = $state[$k] }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $alertState -Encoding UTF8
  } else {
    Log ("（推送没成功：$res —— 不记入去重状态，下一轮自检会再试）")
  }
} else {
  if ($suppress) { Log '（同样的问题 6 小时内已提醒过，本次不重复打扰）' }
  elseif (-not $needAlert -and $modelDegrade.Count -gt 0) { Log '（模型劣化：现在是夜间，只记日志、不推手机；白天遇到会推）' }
  elseif (-not $needAlert) { Log '（绿灯，不打扰）' }
}

if ($reds.Count -gt 0) { exit 1 } else { exit 0 }





