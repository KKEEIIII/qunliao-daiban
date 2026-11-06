param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wxlib.ps1')

function Assert([bool]$condition, [string]$message) {
  if (-not $condition) { throw $message }
  Write-Host ('PASS ' + $message)
}

$initial = @('标题', '新消息一', '新消息二')
$matching = @('标题', '新消息一', '新消息二')
$different = @('标题', '历史消息', '旧消息')
Assert (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines $initial -ActualTitle '26人工2班<示例群号>（50）' -ActualLines $initial) 'same title and same first page accepted'
Assert (-not (Test-WxHistoryPageMatches -ExpectedTitle '示例群A群' -ExpectedLines $initial -ActualTitle '示例群A<示例群号>官方' -ActualLines $initial)) 'ambiguous long title prefix is rejected on history pages'
Assert (-not (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines $initial -ActualTitle '示例群G' -ActualLines $initial)) 'wrong chat rejected even with text match'
Assert (-not (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines $initial -ActualTitle '26人工2班<示例群号>' -ActualLines $different)) 'different content rejected as restored page'
Assert (-not (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines @('only one') -ActualTitle '26人工2班<示例群号>' -ActualLines @('only one'))) 'single OCR line cannot certify page match'
Assert (-not (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines $initial -ActualTitle '26人工3班<示例群号>' -ActualLines $initial)) 'different class number rejected'
Assert (-not (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines $initial -ActualTitle '' -ActualLines $initial)) 'empty title rejected'
Assert (Test-WxHistoryPageMatches -ExpectedTitle '26人工2班<示例群号>' -ExpectedLines $initial -ActualTitle '26人工2班<示例群号>（50）' -ActualLines $matching) 'normalized title and body accepted'

$dir = Join-Path $env:TEMP ('wx-rollup-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
  $path = Join-Path $dir 'history-rollup.json'
  $key = 'wx|26人工2班<示例群号>'
  $rollup = [pscustomobject]@{}
  $rollup | Add-Member -NotePropertyMembers @{ ([string]$key) = [pscustomobject]@{ backlog = $true; succeeded = $false; lastWheelSuccess = '2026-11-06T08:00:00+08:00' } } -Force
  $json = $rollup | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
  $reloaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ([bool]$reloaded.$key.backlog -and -not [bool]$reloaded.$key.succeeded) 'failed backlog remains pending after JSON round trip'
  Assert ([string]$reloaded.$key.lastWheelSuccess -eq '2026-11-06T08:00:00+08:00') 'failed pass does not advance successful-wheel watermark'
  $reloaded | Add-Member -NotePropertyMembers @{ ([string]$key) = [pscustomobject]@{ backlog = $false; succeeded = $true; lastWheelSuccess = '2026-11-06T09:00:00+08:00' } } -Force
  [IO.File]::WriteAllText($path, ($reloaded | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  $done = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (-not [bool]$done.$key.backlog -and [bool]$done.$key.succeeded) 'completed backlog persists only on success'
} finally {
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
