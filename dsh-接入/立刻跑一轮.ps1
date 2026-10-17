# 立刻跑一轮.ps1 —— 让待办插件马上跑一轮，不用等 10 分钟周期
#
# 原理：插件每 5 秒看一眼 <工作区>\群聊待办\.run-now；文件一出现就立刻跑一轮并把它删掉。
# 用途：改完 prompt-extra.txt、或刚手动跑完采集器之后，想立刻看抽取结果。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\立刻跑一轮.ps1
#   ... -Wait     # 顺便等它跑完，把结果打印出来（最多等 150 秒）
param(
  [switch]$Wait,
  [int]$TimeoutSec = 150
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$todoDir = Join-Path $root '群聊待办'
$trigger = Join-Path $todoDir '.run-now'
$logFile = Join-Path $todoDir '插件日志.txt'

if (-not (Test-Path -LiteralPath $todoDir)) { New-Item -ItemType Directory -Force -Path $todoDir | Out-Null }

$logLinesBefore = 0
if (Test-Path -LiteralPath $logFile) { $logLinesBefore = @(Get-Content -LiteralPath $logFile -Encoding UTF8).Count }

New-Item -ItemType File -Force -Path $trigger | Out-Null
Write-Host ("已放好触发文件：{0}" -f $trigger)
Write-Host '插件最多 5 秒内开始跑一轮（要求 DSH 在运行、且插件已装载新版本）。'

if (-not $Wait) {
  Write-Host ''
  Write-Host '想等结果就加 -Wait；或直接看日志：'
  Write-Host ("  Get-Content '{0}' -Tail 5 -Encoding UTF8" -f $logFile)
  exit 0
}

Write-Host ''
Write-Host ("等待插件跑完（最多 {0} 秒）…" -f $TimeoutSec)
$sw = [Diagnostics.Stopwatch]::StartNew()
$done = $false
$noResult = $false
$sawTrigger = $false
$triggerAt = Get-Date
$lastCount = $logLinesBefore
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
  Start-Sleep -Seconds 2

  # ⚠️ 这个"已等够时间"的判断必须放在最前面：不能写在下面那些 continue 之后，
  #    否则"没有新日志行"的那些迭代会直接 continue 掉，判断永远轮不到（实测踩过）。
  if ($sawTrigger -and ((Get-Date) - $triggerAt).TotalSeconds -gt 12) { $done = $true; $noResult = $true; break }

  if (-not (Test-Path -LiteralPath $logFile)) { continue }
  $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
  if ($lines.Count -le $lastCount) { continue }
  $newLines = $lines[$lastCount..($lines.Count - 1)]
  $lastCount = $lines.Count
  foreach ($ln in $newLines) {
    Write-Host ("  " + $ln)
    # 引号可能是全角也可能是半角，所以只匹配关键汉字，别把引号写进正则
    if ($ln -match '收到.+立刻跑一轮.+触发') { $sawTrigger = $true; $triggerAt = Get-Date }
  }
  # 出现这些行就算这一轮有明确结果了
  if (@($newLines | Where-Object { $_ -match '抽出 \d+ 条|本轮失败|没有新的采集记录|立刻跑一轮结束' }).Count -gt 0) { $done = $true; break }
}
if ($noResult) {
  Write-Host ("`n✅ 插件在 {0:N0} 秒前就收到触发并开始跑了；没写结果行 = 本轮没有新的采集记录（正常）" -f $sw.Elapsed.TotalSeconds)
}
elseif ($done) { Write-Host ("`n✅ 这一轮跑完了（{0:N0} 秒）" -f $sw.Elapsed.TotalSeconds) }
else {
  Write-Host ("`n⚠️ 等了 {0} 秒还没看到结果行。可能：DSH 没重启（老插件不会理触发文件）/ 模型调用很慢。" -f $TimeoutSec)
  Write-Host ("   触发文件是否还在：{0}" -f (Test-Path -LiteralPath $trigger))
}
