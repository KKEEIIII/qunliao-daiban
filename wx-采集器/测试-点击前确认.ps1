param()
$ErrorActionPreference = 'Stop'
$env:WX_LAYOUT_PROFILE = 'none'
$env:WX_LAYOUT_PROFILE_QQ = 'none'
. (Join-Path $PSScriptRoot 'wxlib.ps1')

# ============ 一、裁剪矩形（纯计算，不依赖微信） ============
$win = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 100; top = 50; width = 1118; height = 809 }
$row = [pscustomobject]@{ name = '212'; y = 351; nameY = 351; nameH = 15 }
$rect = Get-WxRowCropRect -Win $win -Row $row
if (-not $rect.valid) { throw '正常窗口的候选行裁剪必须有效' }
if ($rect.x -ne [int][Math]::Floor(1118 * 0.145)) { throw ('名字列左边界应按比例：{0}' -f $rect.x) }
if ($rect.y -ge 351) { throw '裁剪应从名字行上方开始（留出边距）' }
if (($rect.y + $rect.h) -le 351) { throw '裁剪必须覆盖名字行本身' }
if ($rect.w -lt 200) { throw ('名字列裁剪太窄：{0}' -f $rect.w) }

$tiny = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 0; top = 0; width = 80; height = 60 }
if ((Get-WxRowCropRect -Win $tiny -Row $row).valid) { throw '窗口过小时裁剪必须 fail-closed' }

$noHeight = Get-WxRowCropRect -Win $win -Row ([pscustomobject]@{ name = 'x'; y = 200 })
if (-not $noHeight.valid) { throw '缺 nameH 时应回退到默认行高而不是失效' }
if ($noHeight.h -lt 18) { throw ('缺 nameH 时裁剪高度应覆盖默认行高：{0}' -f $noHeight.h) }

# 行贴到窗口顶部时不能出现负坐标
$topRow = Get-WxRowCropRect -Win $win -Row ([pscustomobject]@{ name = 'top'; y = 2; nameY = 2; nameH = 15 })
if ($topRow.y -lt 0) { throw '贴顶行的裁剪起点不得为负' }

# ============ 二、实机部分（有微信窗口才跑） ============
$info = Get-WxWindowInfo
if (-not $info) {
  Write-Host '（跳过实机部分：当前没有微信窗口）'
  Write-Host '点击前确认回归通过（仅计算部分）'
  exit 0
}

$winW = [int]$info.width; $winH = [int]$info.height
$shot = Join-Path $env:TEMP ('wx-confirm-{0}.png' -f [guid]::NewGuid().ToString('N'))
try {
  $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale 1
  $lines = @(Invoke-WxOcr -Path $shot -Scale 1)
} finally {
  Remove-Item -LiteralPath $shot -Force -ErrorAction SilentlyContinue
}

# 裁剪右边界与采集器一致：列表/聊天分界线 - 边距（再与 0.37W 取小），
#   否则会把聊天面板的正文一起裁进来，复读文本被污染。
$cfgProbe = [pscustomobject]@{ sessionXFrom = 0.10; sessionXTo = 0.42; headerYTo = 0.16; nameXFrom = 0.145 }
$splitProbe = [int](Get-WxLayoutProfile -Win $info -Cfg $cfgProbe).splitX
$cropRight = [int][Math]::Min($splitProbe - 6, [int][Math]::Ceiling($winW * 0.37))
$x0 = [int]($winW * 0.10)
if ($cropRight - $x0 -lt 60) { throw ('裁剪区域过窄：{0}..{1}' -f $x0, $cropRight) }

# 只取「看起来是会话名」的行：在名字列内、不含预览分隔符、长度合理。
$cands = @($lines | Where-Object {
    $t = ([string]$_.text).Trim()
    $_.x -ge $x0 -and $_.x -lt $cropRight -and
    $_.y -gt [int]($winH * 0.14) -and $_.y -lt [int]($winH * 0.86) -and
    $t.Length -ge 2 -and $t.Length -le 30 -and -not $t.Contains('：')
  })
if ($cands.Count -eq 0) { throw '列表区域没读到任何会话行，无法验证复读确认' }

# 自读确认只对「够长的群名」有意义：短名（212、养场）在整窗 OCR 里本就常被读残，
#   复读出来更完整反而会与残名不一致 → 那种情况跳过是正确行为（fail-closed），不计入失败。
$longCands = @($cands | Where-Object { (([string]$_.text) -replace '\s', '').Length -ge 6 })
if ($longCands.Count -eq 0) { throw '列表里没有足够长的会话名，无法验证复读确认' }

$confirmed = 0
$lastRes = $null
foreach ($cand in $longCands) {
  $rowObj = [pscustomobject]@{ name = [string]$cand.text; y = [int]$cand.y; nameY = [int]$cand.y; nameH = [int]$cand.h; x = [int]$cand.x; x2 = [int]$cand.x2 }
  $res = Test-WxRowConfirmation -Win $info -Row $rowObj -Expected ([string]$cand.text) -XFrom 0.10 -XToPx $cropRight
  if ($res.ok) {
    $confirmed++
    $lastRes = $res
    Write-Host ('  自读确认通过：{0} → 复读={1}' -f $cand.text, ($res.passes -join ' / '))
  } else {
    Write-Host ('  自读未通过：{0} ← {1}' -f $cand.text, $res.reason)
  }
}
if ($confirmed -lt 1) { throw '至少应有一个长群名能通过复读确认，否则该功能会把所有群都拒掉' }

# 错目标名必须被拒绝（这是本功能的核心安全性）
$probe = $longCands[0]
$probeRow = [pscustomobject]@{ name = 'probe'; y = [int]$probe.y; nameY = [int]$probe.y; nameH = [int]$probe.h; x = [int]$probe.x; x2 = [int]$probe.x2 }
$badName = '绝对不存在的群名ZQX9'
$bad = Test-WxRowConfirmation -Win $info -Row $probeRow -Expected $badName -XFrom 0.10 -XToPx $cropRight
if ($bad.ok) { throw ('错误目标名竟然通过了确认：{0}' -f ($bad.passes -join ' / ')) }

# 「拿 A 行去确认 B 的名字」必须被拒绝（防串行）
if ($longCands.Count -ge 2) {
  $other = $longCands[1]
  $crossRow = [pscustomobject]@{ name = 'cross'; y = [int]$probe.y; nameY = [int]$probe.y; nameH = [int]$probe.h; x = [int]$probe.x; x2 = [int]$probe.x2 }
  $cross = Test-WxRowConfirmation -Win $info -Row $crossRow -Expected ([string]$other.text) -XFrom 0.10 -XToPx $cropRight
  if ($cross.ok) { throw ('A 行竟然通过了 B 名的确认：{0} vs {1}' -f $probe.text, $other.text) }
}

# 越界行（窗口外）必须 fail-closed，不能抛出去打断整轮采集
$farRow = [pscustomobject]@{ name = 'far'; y = $winH + 500; nameY = $winH + 500; nameH = 15 }
$far = Test-WxRowConfirmation -Win $info -Row $farRow -Expected '任意'
if ($far.ok) { throw '窗口外的行不应被确认' }

Write-Host ('点击前确认回归通过：裁剪计算 + 实机自读 {0}/{1} 长名 + 错名/串行拒绝' -f $confirmed, $longCands.Count)
