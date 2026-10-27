# 测试-时间锚点.ps1 —— 时间锚点（2026-10-27 新增）的离线回归测试
#
# 为什么要单独一个测试：时间解析是"看起来简单、实际上错得很安静"的那类代码 ——
#   多认一个正文里的时间段，就会让翻页**提前停**（漏消息）；少认一个格式，就是白翻 40 屏。
#   两种错都不会报错，只会体现在日志里的那几个数字上。所以这里全部用断言锁住。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\测试-时间锚点.ps1
# 退出码：0 = 全过；1 = 有失败项。
param()
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'wxlib.ps1')

$script:fail = 0
$script:pass = 0

function Check([string]$name, [object]$got, [object]$want) {
  $ok = $false
  if ($null -eq $want) {
    $ok = ($null -eq $got)
  } elseif ($want -is [datetime]) {
    if ($got -is [datetime]) { $ok = ($got.ToString('yyyy-MM-dd HH:mm') -eq $want.ToString('yyyy-MM-dd HH:mm')) }
  } else {
    $ok = ([string]$got -eq [string]$want)
  }
  if ($ok) {
    $script:pass++
    Write-Host ('  ✅ ' + $name)
  } else {
    $script:fail++
    $g = if ($null -eq $got) { '<null>' } elseif ($got -is [datetime]) { $got.ToString('yyyy-MM-dd HH:mm:ss') } else { [string]$got }
    $w = if ($null -eq $want) { '<null>' } elseif ($want -is [datetime]) { $want.ToString('yyyy-MM-dd HH:mm:ss') } else { [string]$want }
    Write-Host ('  ❌ ' + $name)
    Write-Host ('       期望 = ' + $w)
    Write-Host ('       实际 = ' + $g)
  }
}

function New-Time([int]$y, [int]$mo, [int]$d, [int]$h, [int]$mi) {
  return (New-Object datetime $y, $mo, $d, $h, $mi, 0)
}

# 本轮执行时间固定成 2026-10-27 10:03（真实需求文档里的例子就是这个时间）
$now = New-Time 2026 10 27 10 3
Write-Host ('=== 1) 时间行解析（基准 = 本轮执行时间 {0:yyyy-MM-dd HH:mm}）===' -f $now)

$cases = @(
  @{ t = '昨天19：22';               want = (New-Time 2026 10 26 19 22); why = '全角冒号' },
  @{ t = '昨天19:22';                want = (New-Time 2026 10 26 19 22); why = '半角冒号' },
  @{ t = '今天9:05';                 want = (New-Time 2026 10 27 9 5);   why = '今天+1 位小时' },
  @{ t = '前天22:54';                want = (New-Time 2026 10 25 22 54); why = '前天' },
  @{ t = '09:05';                    want = (New-Time 2026 10 27 9 5);   why = '只有时分→今天' },
  @{ t = '23:30';                    want = (New-Time 2026 10 26 23 30); why = '只有时分且比现在晚→昨天' },
  @{ t = '10月26日19:22';            want = (New-Time 2026 10 26 19 22); why = '月日+时分' },
  @{ t = '星期五23℃8';               want = (New-Time 2026 10 23 23 8);  why = 'OCR：冒号被读成℃、分钟掉一位（真实日志原样）' },
  @{ t = '星日07：53';               want = (New-Time 2026 10 25 7 53);  why = 'OCR：星期→星、星期日=最近的那个周日（真实锚点原样）' },
  @{ t = '昨天2333';                 want = (New-Time 2026 10 26 23 33); why = 'OCR 把冒号整个丢了（真实锚点原样）' },
  # ↓ 这几条是**关键反例**：正文里的时间段绝不能被当时时间戳，否则翻页会提前停、漏消息
  @{ t = '活动时间：19：00—21：00';  want = $null; why = '★正文里的时间段不许认（用户需求里的陷阱）' },
  @{ t = '10：10一11：50';            want = $null; why = '★真实日志里被当成"头部"的时间段' },
  @{ t = '会议时间：10：10一11：50';  want = $null; why = '★正文里夹着时间段' },
  @{ t = '19:00-21:00';              want = $null; why = '半角连字符的时间段' },
  @{ t = '好的';                     want = $null; why = '普通正文' },
  @{ t = '';                         want = $null; why = '空行' }
)
foreach ($c in $cases) {
  $got = ConvertFrom-ChatTimeText -Text $c.t -Now $now
  Check ($c.why + '：' + $c.t) $got $c.want
}

# 跨年：10 月解析「12月31日」应算去年（否则会得到"未来的时间"，翻页判据直接失效）
$got跨年 = ConvertFrom-ChatTimeText -Text '12月31日23:59' -Now $now
Check '跨年：10月看「12月31日」→ 去年' $got跨年 (New-Time 2025 12 31 23 59)

Write-Host ''
Write-Host '=== 2) 一屏正文 → times/newest/oldest（QQ 的 .lines 是对象，取 .text）==='
$lines = @(
  [pscustomobject]@{ text = '昨天19：22' },
  [pscustomobject]@{ text = '活动时间：19：00—21：00' },
  [pscustomobject]@{ text = '好的' },
  [pscustomobject]@{ text = '今天10:01' }
)
$tt = Get-ChatTimesFromLines -Lines $lines -Now $now
Check '时间戳个数（正文时间段不算）' $tt.count 2
Check 'newest' $tt.newest (New-Time 2026 10 27 10 1)
Check 'oldest' $tt.oldest (New-Time 2026 10 26 19 22)

$ttEmpty = Get-ChatTimesFromLines -Lines @('好的', '收到') -Now $now
Check '没有时间行时 newest = $null' $ttEmpty.newest $null
Check '没有时间行时 count = 0' $ttEmpty.count 0

Write-Host ''
Write-Host '=== 3) 锚点文件：2 列（旧）/3 列（新）兼容 ==='
$tmp = Join-Path $env:TEMP ('anchors-test-' + [guid]::NewGuid().ToString('N') + '.txt')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tab = [char]9
$oldLines = @(
  ('qq|示例群B' + $tab + '的：42'),
  ('qq|示例群B有集团（159）' + $tab + '旧 key 的第二行'),
  ('wx|<示例群号>' + $tab + '微信的第三行')
)
[System.IO.File]::WriteAllLines($tmp, $oldLines, $utf8)

$recs = @(Get-ChatAnchorRecords -AnchorFile $tmp -Key 'qq|示例群B' -Fuzzy '示例群B' -Whitelist @('示例群B'))
Check '旧 2 列文件：精确命中只回本 key 的记录' $recs.Count 1
Check '旧 2 列文件：time = $null（退化成纯文本锚点）' $recs[0].time $null
Check '旧 2 列文件：line 正确' $recs[0].line '的：42'

# 模糊命中（旧 key 是 OCR 群名时，靠白名单归属标识认出来）
# 注意：key 精确命中**优先**；这里用一个不存在的 key，所以两条属于 示例群B 的记录都应被当成模糊命中。
$recsF = @(Get-ChatAnchorRecords -AnchorFile $tmp -Key 'qq|不存在的key' -Fuzzy '示例群B' -Whitelist @('示例群B'))
Check '模糊命中：两条属于 示例群B 的旧记录都捞到' $recsF.Count 2
Check '模糊命中：包含旧 key 的那一行' (@($recsF | Where-Object { $_.line -eq '旧 key 的第二行' }).Count) 1

# 写 3 列
$saveTime = New-Time 2026 10 26 19 22
Save-ChatAnchors -AnchorFile $tmp -Key 'qq|示例群B' -Lines @('老行A', '老行B', '老行C', '老行D') -Take 3 `
  -ConsolidateFuzzy '示例群B' -ConsolidateWhitelist @('示例群B') -Time $saveTime
$rawAll = [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::UTF8)
Check '写完后：示例群B 的 3 行 + wx 的 1 行（同群旧 key 已被并掉）' $rawAll.Count 4
$newRecs = @(Get-ChatAnchorRecords -AnchorFile $tmp -Key 'qq|示例群B' -Fuzzy '' -Whitelist @())
Check '3 列写回：条数' $newRecs.Count 3
Check '3 列写回：时间' $newRecs[0].time $saveTime
Check '3 列写回：第一行文本' $newRecs[0].line '老行A'
Check '3 列写回：文件里确实是 3 个字段' (@(($rawAll | Where-Object { $_ -like 'qq|示例群B*' })[0] -split $tab).Count) 3
Check '旧的 2 列行 wx|<示例群号> 没被破坏' (@($rawAll | Where-Object { $_ -like 'wx|<示例群号>*' }).Count) 1

# Get-ChatAnchorLines 仍只回行文本（旧调用点的行为不变）
$onlyLines = @(Get-ChatAnchorLines -AnchorFile $tmp -Key 'qq|示例群B' -Fuzzy '示例群B' -Whitelist @('示例群B'))
Check 'Get-ChatAnchorLines 兼容：条数' $onlyLines.Count 3
Check 'Get-ChatAnchorLines 兼容：是字符串行文本' $onlyLines[0] '老行A'
Check 'Get-ChatAnchorLines 兼容：Test-ChatAnchorHit 能命中' (Test-ChatAnchorHit -Lines @('老行B') -Anchors $onlyLines) $true

# 不给 -Time → 仍写 2 列（旧行为）
Save-ChatAnchors -AnchorFile $tmp -Key 'qq|示例群B' -Lines @('新1', '新2', '新3') -Take 3 `
  -ConsolidateFuzzy '示例群B' -ConsolidateWhitelist @('示例群B')
$raw2 = [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::UTF8)
Check '不给 -Time：文件里仍是 2 列' (@(($raw2 | Where-Object { $_ -like 'qq|示例群B*' })[0] -split $tab).Count) 2
$recs2 = @(Get-ChatAnchorRecords -AnchorFile $tmp -Key 'qq|示例群B' -Fuzzy '' -Whitelist @())
Check '不给 -Time：读回来 time = $null' $recs2[0].time $null
Check '不给 -Time：读回来 line 正确' $recs2[0].line '新1'

# 时间列被手改坏 → 不能崩，退化成 time=$null
[System.IO.File]::WriteAllLines($tmp, @(('qq|示例群B' + $tab + '这不是时间' + $tab + '坏时间列')), $utf8)
$recsBad = @(Get-ChatAnchorRecords -AnchorFile $tmp -Key 'qq|示例群B' -Fuzzy '' -Whitelist @())
Check '时间列坏掉：不抛异常、time=$null' $recsBad[0].time $null
Check '时间列坏掉：line 仍然可读' $recsBad[0].line '坏时间列'

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) {
  Write-Host ('===== 全部通过（{0} 项）=====' -f $script:pass)
  exit 0
}
Write-Host ('===== 失败 {0} 项（通过 {1} 项）=====' -f $script:fail, $script:pass)
exit 1
