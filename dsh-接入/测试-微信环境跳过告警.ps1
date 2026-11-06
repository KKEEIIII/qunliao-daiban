# 离线回归：运行状态中的微信环境跳过必须触发自检黄灯。
$ErrorActionPreference = 'Stop'
function Assert($ok, $message) { if (-not $ok) { throw $message } }
$source = Join-Path $PSScriptRoot '自检.ps1'
$sourceText = [System.IO.File]::ReadAllText($source, [System.Text.Encoding]::UTF8)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'Self-check syntax errors'
$start = $sourceText.IndexOf("`$rsFile = Join-Path `$BaseDir 'logs\运行状态.json'")
$end = if ($start -ge 0) { $sourceText.IndexOf('# ---------- 6.', $start) } else { -1 }
Assert ($start -ge 0 -and $end -gt $start) 'Run-status self-check block not located'
$block = $sourceText.Substring($start, $end - $start)
Assert ($block -match '\$envSkips = @\(\)') 'Environment skip accumulator not present'
Assert ($block -match '\$envSkips\.Count -gt 0') 'Environment skip is not reported yellow'
Assert ($block -match '\[string\]\$v\.note -match ''\^环境跳过：''') 'Legacy environment-skip note fallback missing'
foreach ($p in @($source, $PSCommandPath)) {
  $b = [System.IO.File]::ReadAllBytes($p)
  Assert ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) ('Missing BOM: ' + $p)
}
Write-Host 'PASS: WeChat env-skip status is detected and yellow, including legacy note-only status.'
