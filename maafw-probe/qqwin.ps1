# qqwin.ps1 —— QQ 窗口选择（公共库）
#
# 为什么要"截图验证"：QQ 主进程下有好几个同名同类的 Chrome_WidgetWin_1 / 标题 "QQ" 的窗口，
# 其中只有一个是真面板（960x641 悬浮面板），另外几个是 800x600 / 699x614 的诱饵
# （SplashScreen / 隐藏的宿主窗口）。上次探针就是选到诱饵 656646，导致 WGC 报
# CreateForWindow GraphicsCaptureItem failed、点击测试结论无效。
#
# 选法：候选 = 该进程下 class/title 匹配 且 可见 的顶层窗口，按面积降序，
#       逐个用 MaaFramework 后台截一次，检查"非空白"（颜色数 + OCR 行数），第一个通过的就是真窗口。
#
# 用法：
#   . "$PSScriptRoot\qqwin.ps1"
#   $w = Find-QqWindow -Config $cfg               # 只按面积选（不调 MaaFramework）
#   $w = Find-QqWindow -Config $cfg -Verify       # 逐个截图验证，返回真实窗口

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function Test-ShotNotBlank {
  <#
    .SYNOPSIS  判断一张 PNG 是否是"有内容"的画面（诱饵窗口截出来是纯色/空白）
    .OUTPUTS   @{ ok; colors; nonBlack; ocrLines; w; h; bytes; reason }
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MinColors = 100,
    [double]$MinNonBlack = 0.02,
    [int]$MinOcrLines = 1,
    [switch]$RunOcr
  )
  if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ ok = $false; colors = 0; nonBlack = 0; ocrLines = -1; w = 0; h = 0; bytes = 0; reason = '文件不存在' } }
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $bytes = (Get-Item -LiteralPath $Path).Length
  $bmp = [System.Drawing.Bitmap]::FromFile($Path)
  $w = $bmp.Width; $h = $bmp.Height
  $colors = New-Object 'System.Collections.Generic.HashSet[int]'
  $nb = 0; $tot = 0
  $stepX = [Math]::Max(1, [int]($w / 120)); $stepY = [Math]::Max(1, [int]($h / 120))
  for ($y = 0; $y -lt $h; $y += $stepY) {
    for ($x = 0; $x -lt $w; $x += $stepX) {
      $px = $bmp.GetPixel($x, $y); $tot++
      [void]$colors.Add($px.ToArgb())
      if ($px.R -gt 20 -or $px.G -gt 20 -or $px.B -gt 20) { $nb++ }
    }
  }
  $bmp.Dispose()
  $ratio = if ($tot -gt 0) { $nb / $tot } else { 0 }
  $ocrLines = -1
  if ($RunOcr -and (Get-Command Invoke-WxOcr -ErrorAction SilentlyContinue)) {
    try { $ocrLines = @(Invoke-WxOcr -Path $Path -Scale 1).Count } catch { $ocrLines = -1 }
  }
  $ok = ($colors.Count -ge $MinColors) -and ($ratio -ge $MinNonBlack)
  if ($ok -and $RunOcr -and $MinOcrLines -gt 0) { $ok = ($ocrLines -ge $MinOcrLines) }
  $reason = if ($ok) { 'ok' } else { "颜色数=$($colors.Count) 非黑=$([math]::Round($ratio,3)) OCR行=$ocrLines" }
  return [pscustomobject]@{ ok = $ok; colors = $colors.Count; nonBlack = [math]::Round($ratio, 3); ocrLines = $ocrLines; w = $w; h = $h; bytes = $bytes; reason = $reason }
}

function Get-QqWindowCandidates {
  <#
    .SYNOPSIS  列出 QQ 进程下所有匹配的顶层窗口（按面积降序），带可见性/最小化/矩形
  #>
  param(
    [string]$ProcessName = 'QQ',
    [string]$WindowClass = 'Chrome_WidgetWin_1',
    [string]$WindowTitle = 'QQ',
    [switch]$IncludeHidden
  )
  $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return @() }
  $pids = @($procs | ForEach-Object { [UInt32]$_.Id })
  $out = @()
  foreach ($line in [WxNative]::ListTopWindows($pids)) {
    $p = $line -split '\|'
    if ($WindowClass -and $p[7] -ne $WindowClass) { continue }
    if ($WindowTitle -and $p[8] -ne $WindowTitle) { continue }
    $vis = ($p[1] -eq 'True')
    if (-not $IncludeHidden -and -not $vis) { continue }
    $out += [pscustomobject]@{
      hwnd      = [IntPtr][int64]$p[0]
      hwndHex   = ('0x{0:X}' -f [int64]$p[0])
      visible   = $vis
      minimized = ($p[2] -eq 'True')
      x         = [int]$p[3]
      y         = [int]$p[4]
      w         = [int]$p[5]
      h         = [int]$p[6]
      area      = [int]$p[5] * [int]$p[6]
      cls       = $p[7]
      title     = $p[8]
    }
  }
  return @($out | Sort-Object area -Descending)
}

function Find-QqWindow {
  <#
    .SYNOPSIS  找 QQ 真·主面板窗口
    .DESCRIPTION
      候选按面积降序；-Verify 时对每个候选调 MaaFramework（Get-MaaShot）后台截一次，
      非空白（颜色数 ≥ MinColors 且 非黑比例 ≥ MinNonBlack）才算数。
      返回对象里带 verify 字段说明验证结果；全部失败时返回 $null。
    .PARAMETER ProbeDir  存验证截图的目录（默认临时目录）
  #>
  param(
    [Parameter(Mandatory = $true)]$Config,
    [switch]$Verify,
    [string]$ProbeDir,
    [int]$MinColors = 100,
    [double]$MinNonBlack = 0.02,
    [switch]$KeepShots
  )
  $procName = if ($Config.processName) { $Config.processName } else { 'QQ' }
  $cls = if ($Config.windowClass) { $Config.windowClass } else { 'Chrome_WidgetWin_1' }
  $title = if ($Config.windowTitle) { $Config.windowTitle } else { 'QQ' }

  # 优先可见窗口；可见的一个都没有时，退一步看隐藏窗口（至少能报告"QQ 收托盘了"）
  $cands = @(Get-QqWindowCandidates -ProcessName $procName -WindowClass $cls -WindowTitle $title)
  if ($cands.Count -eq 0) { return $null }
  # 取面积前 5 个做验证，避免在诱饵上浪费时间
  $cands = @($cands | Select-Object -First 5)

  if (-not $Verify) {
    $c = $cands[0]
    $c | Add-Member -NotePropertyName verify -NotePropertyValue 'skipped' -Force
    return $c
  }

  $cap = Join-Path $PSScriptRoot 'maacap.ps1'
  # ⚠️ 2026-10-15 修：这里原来是 `throw`，会**穿透** 采集器-QQ.ps1 的 try/finally（那边没有 catch）
  #    → 整个采集器当场退出码 1，脚本里"退回屏幕模式"的分支永远执行不到；
  #    而安装器还承诺"MaaFramework 没装 → QQ 采集会退回屏幕模式"。
  #    改成返回 $null，让上层已有的 `if (-not $win) { return @{ok=$false; reason=…} }` 生效（另一台机器实测复现）。
  if (-not (Test-Path -LiteralPath $cap)) {
    Write-Host "  [qqwin] 找不到 $cap（MaaFramework 封装）→ 交回上层处理（会退回屏幕模式）"
    return $null
  }
  . $cap
  if (-not (Initialize-Maa)) {
    Write-Host '  [qqwin] MaaFramework 初始化失败（maa\bin 缺失？）→ 交回上层处理（会退回屏幕模式）'
    return $null
  }

  $dir = if ($ProbeDir) { $ProbeDir } else { [System.IO.Path]::GetTempPath() }
  $first = $null
  foreach ($c in $cands) {
    $png = Join-Path $dir ("qqwin-verify-{0}.png" -f $c.hwndHex)
    $shot = Get-MaaShot -Hwnd $c.hwnd -Path $png
    $v = [pscustomobject]@{ ok = $false; colors = 0; nonBlack = 0; ocrLines = -1; w = $shot.w; h = $shot.h; bytes = $shot.bytes; reason = '截图失败' }
    if ($shot.ok) { $v = Test-ShotNotBlank -Path $png -MinColors $MinColors -MinNonBlack $MinNonBlack }
    Write-Host ("  [验证] {0} {1}x{2} 可见={3} → {4}" -f $c.hwndHex, $c.w, $c.h, $c.visible, $(if ($v.ok) { "✅ 真实窗口（颜色数=$($v.colors) 非黑=$($v.nonBlack)）" } else { "❌ 空白（$($v.reason)）" }))
    $c | Add-Member -NotePropertyName verify -NotePropertyValue $v -Force
    $c | Add-Member -NotePropertyName shotPath -NotePropertyValue $png -Force
    if ($v.ok) { $first = $c; break }
    if (-not $KeepShots) { Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue }
  }
  if ($first) {
    if (-not $KeepShots) {
      $keep = Join-Path $dir 'qqwin-verify.png'
      Copy-Item -LiteralPath $first.shotPath -Destination $keep -Force -ErrorAction SilentlyContinue
      $first.shotPath = $keep
    }
    return $first
  }
  return $null
}
