# 离线回归：仅加载函数 AST，所有输入/截图均为替身。
$ErrorActionPreference = 'Stop'
$env:WX_LAYOUT_PROFILE_QQ = 'none'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'maafw-probe/qqread.ps1')
. (Join-Path $PSScriptRoot 'wxlib.ps1')
function Assert($ok, $message) { if (-not $ok) { throw $message } }
$source = Join-Path $PSScriptRoot '采集器-QQ.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Collector syntax errors'
foreach ($name in @('Norm','Get-QqLogicalGroups','Get-QqLogicalKey','Test-QqLogicalGroupFound','Get-QqMissingLogicalGroups','Get-QqMissingAliases','Format-QqLogicalGroup','Test-QqMatch','Read-QqTarget')) {
  $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  Assert ($null -ne $fn) ('Missing collector helper: ' + $name)
  . ([scriptblock]::Create($fn.Extent.Text))
}
$logicalWhitelist = @('<示例群号>','示例群A前缀','示例群A','示例群A','示例群F','示例部门小组')
$logicalRules = @([pscustomobject]@{ match = @('<示例群号>','示例群A前缀','示例群A','示例群A') })
$logicalGroups = @(Get-QqLogicalGroups -Whitelist $logicalWhitelist -Rules $logicalRules)
Assert (@($logicalGroups | Where-Object { $_.key -eq '<示例群号>' -and $_.aliases.Count -eq 4 }).Count -eq 1) 'QQ alias rule should create one logical group'
Assert ((Get-QqLogicalKey -Alias '示例群A' -Groups $logicalGroups) -eq '<示例群号>') 'QQ alias should resolve to canonical logical key'
$logicalFound = @{'<示例群号>' = $true}
Assert (Test-QqMatch -name '26示例部门小组' -pattern '示例部门小组') 'QQ collector must accept numeric title prefix'
Assert (-not (Test-QqMatch -name '26示例部门小组' -pattern '示例群F')) 'QQ collector must reject cross-group title'
Assert (Test-QqLogicalGroupFound -Alias '示例群A' -Groups $logicalGroups -Found $logicalFound) 'Alias should count as found after one confirmed read'
Assert (@(Get-QqMissingLogicalGroups -Groups $logicalGroups -Found $logicalFound | Where-Object { $_.key -eq '<示例群号>' }).Count -eq 0) 'Found logical group should not be reported missing'
$ctx=[pscustomobject]@{captureW=1440;captureH=1080;win=[pscustomobject]@{hwnd=[IntPtr]123;x=1;y=2;w=10;h=10};cfg=[pscustomobject]@{rowHeight=57;firstRowY=120;sessionXFrom=.08;sessionXTo=.35;listYFrom=.15;chatXFrom=.3;chatXTo=.8;chatYFrom=.2}}
$rows=@([pscustomobject]@{x=200;y=130;text='顶部目标群'},[pscustomobject]@{x=200;y=170;text='预览消息'},[pscustomobject]@{x=200;y=215;text='第二目标群'})
$got=@(Get-QqSessionRows -Ctx $ctx -Rows $rows -RowHeightOverride 85 -FirstRowYOverride 180)
Assert ($got[0].name -eq '顶部目标群') 'Top name was clipped'
Assert ($got[0].y -eq 180) 'Override was scaled twice'
Assert ($got[1].y -eq 265) 'Pitch override was scaled twice'
# 配置值来自基准 720px 截图；换到 1080px 截图时应按比例变成 180/85.5，不能固定在 120/57。
$ctx1080=[pscustomobject]@{captureW=1920;captureH=1080;cfg=[pscustomobject]@{rowHeight=57;firstRowY=120;sessionXFrom=.08;sessionXTo=.35;listYFrom=.15}}
$rows1080=@([pscustomobject]@{x=250;y=180;text='顶部目标群'},[pscustomobject]@{x=250;y=266;text='预览消息'})
$scaled=@(Get-QqSessionRows -Ctx $ctx1080 -Rows $rows1080)
Assert ($scaled[0].y -eq 180 -and $scaled[1].y -eq 266) 'QQ default geometry did not scale with capture height'
function Get-WxPhysicalRect { param($Hwnd) return [pscustomobject]@{left=300;top=400;width=960;height=720} }
function Enable-QqFocus { param($Ctx) return $true }
function Invoke-QqScrollList { param($Ctx,$Direction,$Times,$SettleMs) return $false }
$script:qqShotN=0
function Get-QqShot { param($Ctx,$Path) $script:qqShotN++; return [pscustomobject]@{rows=@([pscustomobject]@{x=100;y=100;text=('scroll'+$script:qqShotN)});ok=$true} }
$script:sent=@()
function Test-QqWheelPoint { param($Ctx,[int]$X,[int]$Y) return $true }
function Invoke-TargetWindowWheel {param($Hwnd,$X,$Y,$Notches,$StepDelayMs) $script:sent+=,[pscustomobject]@{h=$Hwnd;x=$X;y=$Y;n=$Notches}; return $Notches}
Assert ((Invoke-QqWheel -Ctx $ctx -Notches -3 -SettleMs 0) -eq -3) 'List return sign'
Assert ($script:sent[0].n -eq 3 -and $script:sent[0].h -eq 123) 'List direction or hwnd'
Assert ($ctx.win.x -eq 300 -and $script:sent[0].x -eq 439 -and $script:sent[0].y -eq 667) 'Multi-point list candidate / stale rectangle'
Assert ((Invoke-QqChatWheel -Ctx $ctx -Notches 2 -SettleMs 0) -eq 2) 'Chat return sign'
Assert ($script:sent[1].n -eq -2 -and $script:sent[1].x -eq 694 -and $script:sent[1].y -eq 715) 'Chat multi-point candidate and direction'
function Invoke-TargetWindowWheel { throw 'INPUT_TARGET_LOST' }
$threw=$false; try { Invoke-QqWheel -Ctx $ctx -Notches 1 -SettleMs 0 } catch { $threw=$true }
Assert $threw 'Wheel swallowed safety failure'
# Read-QqTarget executes with mock dependencies. No collector entrypoint is run.
$cfg=[pscustomobject]@{qqHistoryScreens=2;qqHistoryUntilAnchor=$false}
$wl=@('目标甲群','目标乙群'); $shotDir=$env:TEMP; $stateDir=$env:TEMP; $rowClickX=200
function Log {param($m)}
function Invoke-QqRowClick {param($Row,$SettleMs) return $script:clickOk}
function Get-QqShot {param($Ctx,$Path) return [pscustomobject]@{ok=$true;rows=@('mock')} }
function Get-QqChatView {param($Ctx,$Rows) $script:page++; $hdr=if($script:page -eq 1){$script:firstHeader}else{$script:nextHeader}; return [pscustomobject]@{header=$hdr;text='正文消息';chars=4;lines=@('正文消息')} }
function Get-ChatStableKey {param($Name,$Whitelist) return $Name}
function Get-ChatAnchorRecords {param($AnchorFile,$Key,$Fuzzy,$Whitelist) return @()}
function Test-ChatAnchorHit {param($Lines,$Anchors) return $false}
function Get-PassNow {Get-Date}
function Get-ChatTimesFromLines {param($Lines,$Now) return [pscustomobject]@{newest=$null;oldest=$null}}
function Test-QqMatch {param($name,$pattern) return $name -eq $pattern}
function Invoke-QqChatWheel {param($Ctx,$Notches,$SettleMs) $script:wheelCalls++; if($script:failWheel){throw 'INPUT_TARGET_LOST'}; return $Notches}
# 采集器里的"能不能用真实滚轮"判断依赖前台窗口；离线测试按"允许"处理，保持原断言语义。
function Test-QqWheelAllowed { return $true }
function Merge-ChatScreens {throw 'Must never merge mismatched pages'}
$target=[pscustomobject]@{index=1;y=180;name='目标甲群';guess='目标甲群'}
$script:clickOk=$true; $script:firstHeader='目标甲群';$script:nextHeader='目标乙群';$script:failWheel=$false;$script:page=0;$script:wheelCalls=0
$threw=$false; try {Read-QqTarget -Target $target -Settle 0} catch {$threw=$true; Assert ($_.Exception.Message -like '*INPUT_TARGET_LOST*') 'Unexpected mismatch exception'}
Assert ($threw -and $script:wheelCalls -eq 1) 'Mismatch must abort without restoration'
$script:page=0;$script:wheelCalls=0;$script:firstHeader='目标乙群'
$result=Read-QqTarget -Target $target -Settle 0
Assert ($null -eq $result -and $script:wheelCalls -eq 0) 'Wrong initial title accepted'
$script:firstHeader='目标甲群';$script:page=0;$script:failWheel=$true
$threw=$false;try {Read-QqTarget -Target $target -Settle 0}catch{$threw=$true}
Assert ($threw -and $script:wheelCalls -eq 1) 'Safety failure restored or merged history'
$script:clickOk=$false;$script:page=0
$threw=$false;try {Read-QqTarget -Target $target -Settle 0}catch{$threw=$true}
Assert ($threw -and $script:page -eq 0) 'Failed click read stale panel'
foreach($p in @($source,(Join-Path $root 'maafw-probe/qqread.ps1'),$PSCommandPath)) {$b=[IO.File]::ReadAllBytes($p);Assert ($b[0]-eq 239 -and $b[1]-eq 187 -and $b[2]-eq 191) 'Missing BOM'}
# 环境条件不满足 → 记"跳过"（code=0），不要记成"崩溃"（code=1）：
# 否则自检每小时红一次，真正的故障被淹掉。真实故障仍必须是崩溃。
$skipFn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-QqEnvSkip'},$true)
Assert ($null -ne $skipFn) 'Test-QqEnvSkip not found'
. ([scriptblock]::Create($skipFn.Extent.Text))
Assert (Test-QqEnvSkip 'INPUT_TARGET_LOST: QQ 无法取得前台，后台滚动未生效，未发送真实滚轮') 'Foreground refusal must be a skip'
Assert (Test-QqEnvSkip 'INPUT_TARGET_LOST: 滚动点不在目标窗口上（被其他窗口遮挡），未发送滚轮') 'Occluded wheel point must be a skip'
Assert (-not (Test-QqEnvSkip 'INPUT_TARGET_LOST: QQ 窗口或截图尺寸无效')) 'Invalid capture size must stay a crash'
Assert (-not (Test-QqEnvSkip 'System.OutOfMemoryException')) 'Real exceptions must stay a crash'
Assert (-not (Test-QqEnvSkip '')) 'Empty message is not a skip'
Write-Host 'PASS: QQ top-row geometry, live rectangle, wheel direction/failure, page identity, click failure, skip-vs-crash (offline).'
