# 离线回归：测试自检对 QQ 完整轮次覆盖率、环境跳过与连续漏读的判定。
$ErrorActionPreference = 'Stop'
function Assert($ok, $message) { if (-not $ok) { throw $message } }
$source = Join-Path $PSScriptRoot '自检.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'Self-check syntax errors'
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-QqCoverageHealth' }, $true)
Assert ($null -ne $fn) 'Get-QqCoverageHealth not found'
. ([scriptblock]::Create($fn.Extent.Text))
$tmp = Join-Path $env:TEMP ('qq-coverage-test-' + [guid]::NewGuid().ToString('N') + '.jsonl')
$now = [datetime]'2026-11-04T16:00:00+08:00'
try {
  # A 成功后漏读两轮；环境跳过夹在中间，不算成功也不打断漏读 streak；B 每轮成功。
  $lines = @(
    '{"schema":1,"at":"2026-11-04T00:00:00+08:00","status":"complete","groups":["A","B"],"success":["A","B"],"missed":[]}',
    '{"schema":1,"at":"2026-11-04T04:00:00+08:00","status":"complete","groups":["A","B"],"success":["B"],"missed":["A"]}',
    '{"schema":1,"at":"2026-11-04T08:00:00+08:00","status":"env-skip","groups":["A","B"],"success":[],"missed":[]}',
    '{"schema":1,"at":"2026-11-04T12:00:00+08:00","status":"complete","groups":["A","B"],"success":["B"],"missed":["A"]}',
    '{"schema":1,"at":"2026-11-04T15:00:00+08:00","status":"failure","groups":["A","B"],"success":[],"missed":[]}'
  )
  [System.IO.File]::WriteAllLines($tmp, $lines, (New-Object System.Text.UTF8Encoding($false)))
  $r = Get-QqCoverageHealth -Path $tmp -WindowHours 24 -MissStreakThreshold 2 -Now $now
  Assert ($r.level -eq 'yellow') 'Partial coverage and consecutive misses must be yellow'
  Assert ($r.detail -match 'A 1/3（33%）') 'Environment skip/failure must not enter denominator'
  Assert ($r.detail -match 'A 连续漏读 2 轮') 'Consecutive misses must ignore environment skips'
  Assert ($r.detail -match 'B 3/3（100%）') 'Fully successful group rate is wrong'

  $onlyFailure = '{"schema":1,"at":"2026-11-04T15:00:00+08:00","status":"failure","groups":["A"],"success":[],"missed":[]}'
  [System.IO.File]::WriteAllText($tmp, $onlyFailure, (New-Object System.Text.UTF8Encoding($false)))
  $r = Get-QqCoverageHealth -Path $tmp -WindowHours 24 -MissStreakThreshold 2 -Now $now
  Assert ($r.level -eq 'yellow' -and $r.detail -match '没有完整 QQ 覆盖轮次') 'Failure alone must not fabricate partial coverage'

  $allGood = '{"schema":1,"at":"2026-11-04T15:00:00+08:00","status":"complete","groups":["A"],"success":["A"],"missed":[]}'
  [System.IO.File]::WriteAllText($tmp, $allGood, (New-Object System.Text.UTF8Encoding($false)))
  $r = Get-QqCoverageHealth -Path $tmp -WindowHours 24 -MissStreakThreshold 2 -Now $now
  Assert ($r.level -eq 'green' -and $r.detail -match 'A 1/1（100%）') 'Complete coverage must be green'

  [System.IO.File]::WriteAllText($tmp, '{bad json', (New-Object System.Text.UTF8Encoding($false)))
  $r = Get-QqCoverageHealth -Path $tmp -WindowHours 24 -MissStreakThreshold 2 -Now $now
  Assert ($r.level -eq 'yellow' -and $r.detail -match '无法解析') 'Malformed history should be yellow, not silent'

  foreach ($p in @($source, $PSCommandPath)) {
    $b = [System.IO.File]::ReadAllBytes($p)
    Assert ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) ('Missing BOM: ' + $p)
  }
  Write-Host 'PASS: QQ coverage rate, skip/failure denominator, miss streak, malformed history, BOM.'
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
