param()
$ErrorActionPreference = 'Stop'
$env:WX_LAYOUT_PROFILE = 'none'
$env:WX_LAYOUT_PROFILE_QQ = 'none'
. (Join-Path $PSScriptRoot 'wxlib.ps1')
$before = [WxGuardedInput]::Cursor()
if ([WxGuardedInput]::OwnsPoint([IntPtr]::Zero,0,0)) { throw '零句柄不能被视作输入目标' }
if ([WxNative]::SameRootWindow([IntPtr]::Zero, [WxNative]::GetForegroundWindow())) { throw '零窗口与前台窗口不得判为同一根窗口' }
if ([WxGuardedClick]::SameRootWindow([IntPtr]::Zero, [WxNative]::GetForegroundWindow())) { throw '点击守卫不得把零句柄视为有效根窗口' }
$currentRoot = [WxNative]::RootWindow([WxNative]::GetForegroundWindow())
if ($currentRoot -eq [IntPtr]::Zero -or -not [WxNative]::IsValidWindow($currentRoot)) { throw '前台根窗口句柄应当有效' }
if (-not [WxNative]::SameRootWindow($currentRoot, [WxNative]::GetForegroundWindow())) { throw '当前前台句柄与根窗口必须同根' }
$currentIdentity = Test-WxTargetWindowIdentity -Hwnd ([WxNative]::GetForegroundWindow())
$wechatWindow = if ($currentIdentity.valid) { [WxNative]::GetForegroundWindow() } else { [WxNative]::FindMain() }
if ($wechatWindow -eq [IntPtr]::Zero) { throw '窗口身份回归需要有运行中的微信窗口' }
$desktop = [IntPtr]::new(1)
if ((Test-WxTargetWindowIdentity -Hwnd $desktop).valid) { throw '无效窗口句柄不应通过微信窗口身份检查' }
if ([WxNative]::SameRootWindow($currentRoot, $desktop)) { throw '不同或失效窗口句柄不得与当前前台窗口混同' }
if ([WxGuardedClick]::SameRootWindow($currentRoot, $desktop)) { throw '点击守卫不得把不同或失效窗口判为同一窗口' }
if (-not [WxNative]::SameRootWindow([WxNative]::GetAncestor($currentRoot, 2), $currentRoot)) { throw '根句柄再次归一后应保持稳定' }
if ((Test-WxTargetWindowIdentity -Hwnd $wechatWindow).valid -ne $true) { throw '选定的微信主窗口应通过身份检查' }
if (-not [WxGuardedClick]::IsWechatWindow($wechatWindow)) { throw '点击守卫必须认可微信主窗句柄' }
if (-not [WxGuardedInput]::IsWechatWindow($wechatWindow)) { throw '滚轮守卫必须认可微信主窗句柄' }
$expectedForeground = [bool]$currentIdentity.valid
if ([WxNative]::ForegroundMatches($wechatWindow) -ne $expectedForeground) { throw '原生前台根窗口和微信身份联合检查结果不一致' }
if ([WxGuardedClick]::ForegroundMatches($wechatWindow) -ne $expectedForeground) { throw '点击守卫前台身份检测错误' }
if ([WxGuardedInput]::ForegroundMatches($wechatWindow) -ne $expectedForeground) { throw '滚轮守卫前台身份检测错误' }
if (-not $currentIdentity.valid) {
  if ([WxGuardedClick]::IsWechatWindow($currentRoot)) { throw '点击守卫误把非微信前台窗口当成微信' }
  if ([WxGuardedInput]::IsWechatWindow($currentRoot)) { throw '滚轮守卫误把非微信前台窗口当成微信' }
  if ([WxNative]::ForegroundMatches($currentRoot)) { throw '原生前台校验误把非微信窗口判为微信前台' }
  if ([WxGuardedClick]::ForegroundMatches($currentRoot)) { throw '点击守卫误把非微信窗口判为微信前台' }
  if ([WxGuardedInput]::ForegroundMatches($currentRoot)) { throw '滚轮守卫误把非微信窗口判为微信前台' }
}
foreach ($n in @(1,-1,12,-12)) {
  $blocked = $false
  try { Invoke-TargetWindowWheel -Hwnd ([IntPtr]::Zero) -X 0 -Y 0 -Notches $n | Out-Null }
  catch { $blocked = $_.Exception.Message -like '*INPUT_TARGET_LOST*' }
  if (-not $blocked) { throw ('无效目标未拒绝: ' + $n) }
  $wrongWindowBlocked = $false
  try { Invoke-TargetWindowWheel -Hwnd ([WxNative]::GetForegroundWindow()) -X 0 -Y 0 -Notches $n | Out-Null }
  catch { $wrongWindowBlocked = $_.Exception.Message -like '*INPUT_TARGET_LOST*' }
  if (-not $wrongWindowBlocked) { throw ('非微信前台窗口未被拒绝: ' + $n) }
}
$after = [WxGuardedInput]::Cursor()
if ($before[0] -ne $after[0] -or $before[1] -ne $after[1]) { throw '拒绝滚轮时仍然移动了鼠标' }
if ((Invoke-TargetWindowWheel -Hwnd ([IntPtr]::Zero) -X 0 -Y 0 -Notches 0) -ne 0) { throw '零滚动应无操作' }
if ([WxGuardedInput]::Wheel([IntPtr]::Zero,$after[0],$after[1],120)) { throw '原生发送边界未拒绝无效窗口' }
if (Invoke-TargetWindowClick -Hwnd ([IntPtr]::Zero) -X $after[0] -Y $after[1]) { throw '无效目标不应产生真实点击' }
if (Invoke-TargetWindowClick -Hwnd ([WxNative]::GetForegroundWindow()) -X $after[0] -Y $after[1]) { throw '非微信窗口句柄不得进入真实点击' }
$afterClick = [WxGuardedInput]::Cursor()
if ($after[0] -ne $afterClick[0] -or $after[1] -ne $afterClick[1]) { throw '拒绝无效点击后鼠标位置发生变化' }

# 最终标题身份采用保守规则：不得将语义不同的长前缀/数字群名判成同一聊天。
$unsafeIdentity = Get-ChatFinalIdentityInfo -Actual '示例群A群' -Expected '示例群A<示例群号>官方（50）'
if ($unsafeIdentity.same) { throw ('语义后缀不同的标题误判同群: ' + $unsafeIdentity.why) }
# 几何函数必须返回九个分布在保守聊天区域内的独立点；小窗/分界异常时 fail-closed。
$win = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 100; top = 50; width = 1200; height = 800; dpi = 96 }
$cfg = [pscustomobject]@{ headerYTo = 0.16; sessionXTo = 0.42 }
$points = @(Get-WxChatWheelPoints -Win $win -Cfg $cfg -SplitX 420)
if ($points.Count -ne 9) { throw ('滚轮候选数应为 9，实际 {0}' -f $points.Count) }
foreach ($p in $points) {
  $lx = [int]$p.x - $win.left; $ly = [int]$p.y - $win.top
  if ($lx -lt 0.48 * $win.width -or $lx -gt 0.70 * $win.width) { throw ('滚轮候选超出保守聊天面板横向带: ' + $lx) }
  if ($ly -lt 0.28 * $win.height -or $ly -gt 0.70 * $win.height) { throw ('滚轮候选落入标题或输入区: ' + $ly) }
}
$tiny = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 0; top = 0; width = 350; height = 240; dpi = 96 }
if (@(Get-WxChatWheelPoints -Win $tiny -Cfg $cfg).Count -ne 0) { throw '过小窗口应拒绝所有滚轮候选' }
$wideSplit = @(Get-WxChatWheelPoints -Win $win -Cfg $cfg -SplitX 900)
if ($wideSplit.Count -ne 0) { throw '聊天区过窄时必须 fail-closed' }
$identityCases = @(
  @{ a = '示例群A'; b = '示例群A3班'; same = $false },
  @{ a = 'A社群2025通知'; b = 'A社群2026通知'; same = $false },
  @{ a = '26人工2毋形及群'; b = '26人工2班<OCR 错字示例>（50）'; same = $true },
  @{ a = '示例群A群'; b = '示例群A<示例群号>官方（50）'; same = $false },
  @{ a = '示例群A二班'; b = '示例群A二班官方群'; same = $false },
  @{ a = '示例群A266'; b = '示例群A<示例群号>官方（50）'; same = $true }
)
foreach ($ic in $identityCases) {
  $got = Get-ChatFinalIdentityInfo -Actual $ic.a -Expected $ic.b
  if ($got.same -ne $ic.same) { throw ('标题身份冲突回归失败: {0} / {1} => {2}' -f $ic.a,$ic.b,$got.same) }
}
$invalidPseudo = $false
try { $null = Enter-WxPseudoMinimize -Hwnd ([IntPtr]::Zero) } catch { $invalidPseudo = $true }
if (-not $invalidPseudo) { throw '伪最小化必须拒绝零窗口句柄' }
if (-not (Test-WxHistoryCursorStable -Expected @(100,200) -Actual @(100,200))) { throw '相同光标位置应通过滚动状态校验' }
if (Test-WxHistoryCursorStable -Expected @(100,200) -Actual @(101,200)) { throw '用户移动光标后必须中止历史滚动' }
Write-Host '输入安全与几何回归通过：无效目标、九点边界、窄窗、数字冲突身份验证'
