# 测试-标题识别.ps1 —— 聊天头部识别：群名 vs 时间分隔行（离线，不碰窗口）
#
# 背景（2026-11-04 真机日志）：
#   点开会话后头部最靠上的一行是时间分隔行「07：51」，Get-ChatHeader 把它当成群名 →
#   校验必然失败（日志原话「点开的是「07：51」，不是本意群 → 重新定位再点一次」），
#   于是同一个群被点两次、还可能这一轮就漏采。
#   根因不是"点歪了"，而是"时间被当成了标题"。
#
# 这里用 AST 抽出真实函数来测，避免复制一份实现造成两边漂移。
$env:WX_LAYOUT_PROFILE = 'none'
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'wxlib.ps1')

$collector = Join-Path $here '采集器.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
  Write-Host '  ❌ 采集器.ps1 有语法错误'
  exit 1
}
foreach ($name in @('Norm', 'Test-WxTimeLabel', 'Get-ChatHeader')) {
  $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { Write-Host ('  ❌ 找不到函数 ' + $name); exit 1 }
  . ([scriptblock]::Create($fn.Extent.Text))
}

$script:fail = 0
function Ok([string]$m) { Write-Host ('  ✅ ' + $m) }
function No([string]$m) { Write-Host ('  ❌ ' + $m); $script:fail++ }
function Assert-Equal($got, $want, [string]$m) {
  if ([string]$got -eq [string]$want) { Ok $m } else { No ('{0}（期望「{1}」，实际「{2}」）' -f $m, $want, $got) }
}

# Get-ChatHeader 依赖 $script:win / $cfg / Get-WxLayoutProfile
$script:win = [pscustomobject]@{ width = 1118; height = 809; dpi = 120 }
$cfg = [pscustomobject]@{ sessionXFrom = 0.1; sessionXTo = 0.42; chatXFrom = 0.42; headerYTo = 0.16 }
function Get-WxLayoutProfile { param($Win, $Cfg) return [pscustomobject]@{ titleY = 129 } }
function Row([int]$x, [int]$y, [string]$t) { return [pscustomobject]@{ x = $x; y = $y; h = 19; text = $t } }

Write-Host '=== A. 时间/日期标签的判定 ==='
Assert-Equal (Test-WxTimeLabel '07：51') $true '「07：51」是时间'
Assert-Equal (Test-WxTimeLabel '7:51') $true '「7:51」是时间'
Assert-Equal (Test-WxTimeLabel '昨天 23：00') $true '「昨天 23：00」是日期时间'
Assert-Equal (Test-WxTimeLabel '星期三') $true '「星期三」是日期'
Assert-Equal (Test-WxTimeLabel '10月31日 21:04') $true '「10月31日 21:04」是日期时间'
Assert-Equal (Test-WxTimeLabel '周三开会') $false '「周三开会」是真群名，不能误杀'
Assert-Equal (Test-WxTimeLabel '26 示例群A 2 班 <示例群号>（官方）') $false '真群名不是时间'
Assert-Equal (Test-WxTimeLabel '') $true '空行不算标题'

Write-Host ''
Write-Host '=== B. 头部区只有时间行 → 返回空（认不出，交给上层安全跳过） ==='
$onlyTime = @((Row 470 40 '07：51'))
Assert-Equal (Get-ChatHeader $onlyTime) '' '只有时间行时不拿时间来冒充群名'

Write-Host ''
Write-Host '=== C. 时间行在群名上方 → 必须取群名（真机复现的那个形态） ==='
$timeAbove = @((Row 470 40 '07：51'), (Row 470 75 '26 示例群A 2 班 <示例群号>'), (Row 700 75 '（官方）'))
$a = [string](Get-ChatHeader $timeAbove)
if ($a -like '*26 示例群A 2 班 <示例群号>*' -and $a -notlike '*07*') {
  Ok ('取到群名「' + $a + '」，没有把时间当标题')
} else {
  No ('时间行在群名上方时取错了：「' + $a + '」')
}

Write-Host ''
Write-Host '=== D. 群名被拆成同一 y 上两段 → 拼起来（原有行为不能退化） ==='
$twoParts = @((Row 404 72 '26 示例群A 2 班 <示例群号>'), (Row 640 72 '（官方）（52）'))
Assert-Equal (Get-ChatHeader $twoParts) '26 示例群A 2 班 <示例群号>（官方）（52）' '两段群名按 x 拼接'

Write-Host ''
Write-Host '=== E. 标题下方（仍在标题条范围内）有时间分隔行 → 仍取标题 ==='
# 注：x=29 那种窗口图标碎片在会话列表区，Get-ChatHeader 只收聊天区的行，构造那种数据不符合真实输入。
$titleThenTime = @((Row 470 72 '26 示例群A 2 班 <示例群号>'), (Row 700 72 '（官方）'), (Row 470 118 '昨天 23：00'))
$e = [string](Get-ChatHeader $titleThenTime)
if ($e -like '26 示例群A 2 班 <示例群号>*' -and $e -notlike '*昨天*') { Ok ('取到标题「' + $e + '」，没混进时间行') }
else { No ('标题条内有时间行时取错了：「' + $e + '」') }

Write-Host ''
Write-Host '=== F. 会话列表的未读角标（1 个字）与群名同一行 → 不许拼进标题 ==='
# 2026-11-04 真实 fixture（1118x809, DPI120）原样：
#   y=59 x=340 「O」← 列表里未读角标，被 0.30W 阈值放过；y=59 x=404 才是群名。
#   旧代码把两者拼成「O26 人工 2 班<OCR 错字示例>（50）」→ 标题校验必失败 → 整轮漏采。
$badgeRow = @((Row 340 59 'O'), (Row 404 59 '26 人工 2 班<OCR 错字示例>（50）'))
$f = [string](Get-ChatHeader $badgeRow)
Assert-Equal $f '26 人工 2 班<OCR 错字示例>（50）' '角标不拼进群名'

Write-Host ''
if ($script:fail -eq 0) {
  Write-Host '===== 全部通过 ====='
  exit 0
}
Write-Host ('===== 失败 {0} 项 =====' -f $script:fail)
exit 1
