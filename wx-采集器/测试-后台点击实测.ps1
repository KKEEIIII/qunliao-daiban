# 单点真实验证微信后台点击。仅在两个目标名称及位置都与本轮 OCR 相符时切换，最后恢复原会话及窗口状态。
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wxlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'maafw-probe\maacap.ps1')
$hinfo = Get-WxWindowInfo
if (-not $hinfo) { throw '微信窗口不存在' }
$h = $hinfo.hwnd
$restoreState = if (-not $hinfo.visible) { 'hide' } elseif ($hinfo.minimized) { 'minimize' } else { 'none' }
$fg = [WxNative]::GetForegroundWindow()
$entered = $null
$ctrl = [IntPtr]::Zero
$originalName = '柯氏家族'
$targetName = '好的好的'
$shot = Join-Path $PSScriptRoot 'shots\_wx-click-check.png'
function Read-Point([string]$name) {
  $null = Save-WxWindowShot -Hwnd $h -Path $shot -Scale 1
  $info = Get-WxWindowInfo -Hwnd $h
  $lines = @(Invoke-WxOcr -Path $shot -Scale 1)
  $hits = @($lines | Where-Object { $_.x -gt 145 -and $_.x -lt 285 -and $_.y -gt 155 -and $_.y -lt ($info.height - 120) -and ($_.text -replace '\s','') -eq $name })
  if ($hits.Count -ne 1) { throw ('列表中找不到唯一目标：' + $name) }
  return [pscustomobject]@{ x=195; y=([int]$hits[0].y + 8); info=$info; rows=$lines }
}
function Read-Title {
  $null = Save-WxWindowShot -Hwnd $h -Path $shot -Scale 1
  $info = Get-WxWindowInfo -Hwnd $h
  $title = @(Invoke-WxOcr -Path $shot -Scale 1 | Where-Object { $_.y -gt 25 -and $_.y -lt 100 -and $_.x -ge 350 -and $_.x -lt ($info.width - 120) -and ($_.text -replace '\s','').Length -ge 3 } | Sort-Object y,x | Select-Object -First 1)
  if ($title.Count -eq 0) { return '' }
  return ($title[0].text -replace '\s','')
}
function Send-At([string]$name) {
  $p = Read-Point $name
  $w = Get-WxWindowInfo -Hwnd $h
  if ($w.width -ne $p.info.width -or $w.height -ne $p.info.height -or $w.left -ne $p.info.left -or $w.top -ne $p.info.top) { throw '窗口几何变化，停止点击' }
  if (-not (Invoke-MaaClick -Hwnd $h -X $p.x -Y $p.y -Controller $ctrl)) { throw ('Maa 未完成后台点击：'+$name) }
  Start-Sleep -Milliseconds 1800
  return (Read-Title)
}
$didSwitch = $false
try {
  if ($restoreState -ne 'none') { $entered = Enter-WxPseudoMinimize -Hwnd $h -RestoreState $restoreState; Start-Sleep -Milliseconds 1200 }
  $before = Read-Title
  if (-not $before.StartsWith($originalName)) { throw ('原聊天不是预设目标，未点击；识别=' + $before) }
  [void](Read-Point $targetName)
  $ctrl = Get-MaaController -Hwnd $h -Screencap ([uint64]0x12) -InputMethod ([uint64]4)
  if ($ctrl -eq [IntPtr]::Zero) { throw 'Maa 后台点击控制器不可用' }
  [void](Set-MaaShotOption -Controller $ctrl -Key 3 -IntValue 1 -AsBool)
  $didSwitch = $true
  $after = Send-At $targetName
  $focusUnchanged = ([WxNative]::GetForegroundWindow() -eq $fg)
  'CLICK titleBeforeMatched={0} titleAfterMatched={1} actualTitle={2} foregroundUnchanged={3} wasMinimized={4}' -f ($before.StartsWith($originalName)),($after -eq $targetName),$after,$focusUnchanged,$hinfo.minimized
} finally {
  if ($didSwitch -and $ctrl -ne [IntPtr]::Zero) {
    try {
      $restored = Send-At $originalName
      'RESTORE titleMatched={0}' -f ($restored.StartsWith($originalName))
    } catch { 'RESTORE_ERROR '+$_.Exception.Message }
  }
  if ($entered) { Exit-WxPseudoMinimize -Hwnd $h -OldExStyle $entered.oldExStyle -OldColorKey $entered.oldColorKey -OldAlpha $entered.oldAlpha -OldLayerFlags $entered.oldLayerFlags -HadLayerAttrs:([bool]$entered.hadLayerAttrs) -RestoreState $entered.restoreState }
  Close-MaaControllers
  $end = Get-WxWindowInfo -Hwnd $h
  if ($fg -ne [IntPtr]::Zero -and [WxNative]::GetForegroundWindow() -ne $fg) { [void](Set-WxForegroundRaw -Hwnd $fg); Start-Sleep -Milliseconds 200 }
  'WINDOW restoredMinimized={0} foregroundUnchanged={1}' -f $end.minimized,([WxNative]::GetForegroundWindow() -eq $fg)
}
