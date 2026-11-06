# 微信后台截图实测：不点击、不滚动、不发送消息；结束时恢复窗口原始状态。
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wxlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'maafw-probe\maacap.ps1')
$w = Get-WxWindowInfo
if (-not $w) { throw '未找到微信窗口' }
$h = $w.hwnd
$original = if (-not $w.visible) { 'hide' } elseif ($w.minimized) { 'minimize' } else { 'none' }
$foreground = [WxNative]::GetForegroundWindow()
$entered = $null
$dir = Join-Path $PSScriptRoot 'shots'
$print = Join-Path $dir '_wx-real-print.png'
$maa = Join-Path $dir '_wx-real-maa.png'
try {
  if ($original -ne 'none') {
    $entered = Enter-WxPseudoMinimize -Hwnd $h -RestoreState $original
    Start-Sleep -Milliseconds 1500
  }
  $now = Get-WxWindowInfo -Hwnd $h
  if (-not $now.visible -or $now.minimized -or $now.width -lt 200 -or $now.height -lt 200) { throw '伪最小化后窗口仍不可截图' }
  $shot = Save-WxWindowShot -Hwnd $h -Path $print -Scale 1
  $pr = @(Invoke-WxOcr -Path $print -Scale 1)
  $prUseful = @($pr | Where-Object { $_.text -and $_.text.Length -ge 2 }).Count
  $ctrl = Get-MaaController -Hwnd $h -Screencap ([uint64]0x12)
  $maaResult = $null
  $mrUseful = 0
  if ($ctrl -ne [IntPtr]::Zero) {
    [void](Set-MaaShotOption -Controller $ctrl -Key 3 -IntValue 1 -AsBool)
    $maaResult = Get-MaaShot -Hwnd $h -Path $maa -Controller $ctrl
    if ($maaResult.ok) { $mrUseful = @((Invoke-WxOcr -Path $maa -Scale 1) | Where-Object { $_.text -and $_.text.Length -ge 2 }).Count }
  }
  $foregroundSame = ([WxNative]::GetForegroundWindow() -eq $foreground)
  'BEFORE state={0} fg=0x{1:X} size={2}x{3}' -f $original,$foreground.ToInt64(),$w.width,$w.height
  'CAPTURE state={0} print={1}x{2} ocrUseful={3} maaOk={4} maaSize={5}x{6} maaOcrUseful={7} fgUnchanged={8}' -f $original,$shot.winW,$shot.winH,$prUseful,[bool]($maaResult -and $maaResult.ok),$(if($maaResult){$maaResult.w}else{0}),$(if($maaResult){$maaResult.h}else{0}),$mrUseful,$foregroundSame
} finally {
  if ($entered) {
    Exit-WxPseudoMinimize -Hwnd $h -OldExStyle $entered.oldExStyle -OldColorKey $entered.oldColorKey -OldAlpha $entered.oldAlpha -OldLayerFlags $entered.oldLayerFlags -HadLayerAttrs:([bool]$entered.hadLayerAttrs) -RestoreState $entered.restoreState
  }
  Close-MaaControllers
  $end = Get-WxWindowInfo -Hwnd $h
  'AFTER visible={0} minimized={1} fgUnchanged={2}' -f $end.visible,$end.minimized,([WxNative]::GetForegroundWindow() -eq $foreground)
}
