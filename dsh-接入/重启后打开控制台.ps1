# 重启后打开控制台.ps1 —— 装完 DSH 重启那一刻，把控制台页面**及时**推到用户面前
#
# 为什么需要它（用户明确要求"重启后控制台要及时调出，节省安装过程时间"）：
#   插件是 DSH **启动时**装载的，所以装完必须重启 DSH。用户重启后还要自己去找
#   "打开控制台.cmd"、双击、等页面 —— 这几步纯属浪费，而且很多人会忘。
#   安装器会在 ⑨.5 写一个"等待重启"标记文件，然后用 run-hidden.vbs 静默拉起本脚本：
#   它盯着 DSH 进程，一旦发现有**标记之后才启动**的 DSH 进程（= 用户重启了），
#   再等几秒让插件装载完，就把控制台起起来并打开页面，然后自己退出。
#
# 设计要点（都是踩过的坑）：
#   · 必须能自己退出：最多等 MaxWaitMin 分钟，超时写日志走人，绝不留常驻进程。
#   · 只弹一次：起完控制台就退出（不需要"每次重启都弹"）。
#   · 静默：由 run-hidden.vbs 拉起，不建控制台窗口、不抢焦点。
#   · 全程留痕：日志 dsh-接入\logs\重启后打开控制台.log，出问题能查。
param(
  [string]$MarkerFile = '',
  [int]$MaxWaitMin = 30,
  [int]$PollSec = 5,
  [int]$AfterRestartSec = 8      # DSH 起来后再等几秒，让插件装载完（太早开会话还没就绪）
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$logDir = Join-Path $here 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir '重启后打开控制台.log'

function WLog([string]$m) {
  $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
  try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
}

# 标记文件 = 安装器写完的时间点。没有标记就退（说明不是安装后第一次启动）
if ([string]::IsNullOrWhiteSpace($MarkerFile)) {
  $MarkerFile = Join-Path $logDir '等待重启.txt'
}
if (-not (Test-Path -LiteralPath $MarkerFile)) {
  WLog '没有"等待重启"标记 → 不是刚装完，退出'
  return
}
$markTime = (Get-Item -LiteralPath $MarkerFile).LastWriteTime
WLog ('开始等待 DSH 重启（标记时间 {0}，最多等 {1} 分钟）' -f $markTime.ToString('yyyy-MM-dd HH:mm:ss'), $MaxWaitMin)

function Get-DshProcesses {
  # DSH 主程序进程名不固定（DeepSeek Harness / electron 壳），按"可执行文件路径含 DSH 或进程名含 DeepSeek"识别
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ProcessName -match 'DeepSeek|deepseek' -or
      ($_.Path -and ($_.Path -match 'DEEPSSEEK|DeepSeek|deepseek-harness'))
    })
}

function Count-DshStartedAfter([datetime]$t) {
  # 只数"标记之后才启动"的进程。
  # 为什么要 >= 2：Electron 会单独重启某个渲染进程（实测见过单个渲染进程在安装后重启），
  #   那不是用户重启 DSH。真重启会一次起主进程 + 若干辅助进程。
  $n = 0
  foreach ($q in (Get-DshProcesses)) {
    try { if ($q.StartTime -gt $t) { $n++ } } catch { }
  }
  return $n
}

$deadline = (Get-Date).AddMinutes($MaxWaitMin)
$done = $false
while ((Get-Date) -lt $deadline) {
  $fresh = Count-DshStartedAfter $markTime
  if ($fresh -ge 2) {
    try {
      if ($true) {
        WLog ('检测到 DSH 已重启（标记后有 {0} 个新进程）→ 等 {1} 秒后打开控制台' -f $fresh, $AfterRestartSec)
        Start-Sleep -Seconds $AfterRestartSec
        $console = Join-Path (Split-Path -Parent $here) '群聊待办\控制台.ps1'
        if (-not (Test-Path -LiteralPath $console)) {
          WLog ('找不到控制台脚本：{0} → 退出' -f $console)
        } else {
          $vbs = Join-Path $here 'run-hidden.vbs'
          if (Test-Path -LiteralPath $vbs) {
            & wscript.exe $vbs $console -Hidden
            WLog '已通过 run-hidden.vbs 静默启动控制台（页面会自动打开）'
          } else {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $console + '"'), '-Hidden') -WindowStyle Hidden
            WLog 'run-hidden.vbs 不在，已用 Start-Process 静默启动控制台'
          }
          $done = $true
        }
        break
      }
    } catch { }
  }
  Start-Sleep -Seconds $PollSec
}

if ($done) {
  WLog '完成：控制台已打开，本脚本退出'
  # 标记删掉：同一次安装只弹一次，之后用户自己双击 打开控制台.cmd
  try { Remove-Item -LiteralPath $MarkerFile -Force -ErrorAction SilentlyContinue } catch { }
} else {
  WLog ('等了 {0} 分钟没看到 DSH 重启 → 退出（控制台可随时双击 群聊待办\打开控制台.cmd）' -f $MaxWaitMin)
}
