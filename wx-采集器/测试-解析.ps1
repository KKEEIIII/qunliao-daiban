# 测试-解析.ps1 —— 采集器 parser 的回归测试（离线喂 OCR fixture，不碰任何窗口）
#
# 背景：parser 是整个项目最容易退化的部分（"未读角标冒充会话名"那个 bug 就让识别结果在
# 0/2/6 个会话之间乱跳）。这里用真实的 OCR 快照（fixture）做断言，改动 parser 后一跑就知道有没有退化。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\测试-解析.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\测试-解析.ps1 -UpdateFixture   # 重新抓一份快照
param([switch]$UpdateFixture)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$collector = Join-Path $here '采集器.ps1'
$fxDir = Join-Path $here 'fixtures'
$logFile = Join-Path $here 'logs\last-pass.txt'
if (-not (Test-Path -LiteralPath $fxDir)) { New-Item -ItemType Directory -Force -Path $fxDir | Out-Null }

# 加载库函数（下面"群名匹配方向"的断言要用 Test-ChatRuleMatch）
. (Join-Path $here 'wxlib.ps1')

function Write-Line([string]$s) { Write-Host $s }

# ---------- 可选：重新抓一份快照 ----------
if ($UpdateFixture) {
  Write-Line '重新抓取 fixture（会用真实微信窗口）…'
  $fx = Join-Path $fxDir 'wechat-list.json'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -DumpRowsJson $fx 2>&1 | ForEach-Object { Write-Line ("  " + $_) }
  Write-Line ('已更新 ' + $fx)
}

$expectedPath = Join-Path $fxDir 'expected.json'
if (-not (Test-Path -LiteralPath $expectedPath)) {
  Write-Line ('缺少期望文件 ' + $expectedPath); exit 2
}
$exp = Get-Content -LiteralPath $expectedPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fixture = Join-Path $fxDir $exp.fixture
if (-not (Test-Path -LiteralPath $fixture)) { Write-Line ('缺少 fixture ' + $fixture); exit 2 }

Write-Line ('=== 用 fixture 离线跑 parser：' + $exp.fixture + ' ===')
$before = if (Test-Path -LiteralPath $logFile) { (Get-Content -LiteralPath $logFile -Encoding UTF8 | Measure-Object -Line).Lines } else { 0 }
& powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $fixture -Peek 2>&1 | Out-Null
$lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
$sessionLine = ($lines | Where-Object { $_ -match '会话列表识别到' } | Select-Object -Last 1)

$fail = 0
if (-not $sessionLine) {
  Write-Line '❌ 没找到"会话列表识别到"这行日志（parser 可能崩了）'
  $lines | ForEach-Object { Write-Line ('    ' + $_) }
  exit 1
}
$mCount = [regex]::Match($sessionLine, '识别到 (\d+) 个会话')
$mNames = [regex]::Match($sessionLine, '个会话：(.*)$')
$count = if ($mCount.Success) { [int]$mCount.Groups[1].Value } else { -1 }
$names = if ($mNames.Success) { $mNames.Groups[1].Value } else { '' }
Write-Line ('  识别到 ' + $count + ' 个会话：' + $names)

# 断言 1：会话数量（下限防"漏"、上限防"拆散"：rowGap 调小会把每个 OCR 行都变成会话）
if ($count -lt [int]$exp.minSessions) {
  Write-Line ('❌ 断言失败：会话数 ' + $count + ' < 期望下限 ' + $exp.minSessions); $fail++
} elseif ($exp.maxSessions -and $count -gt [int]$exp.maxSessions) {
  Write-Line ('❌ 断言失败：会话数 ' + $count + ' > 期望上限 ' + $exp.maxSessions + '（会话行被拆散了）'); $fail++
} else {
  Write-Line ('✅ 会话数 ' + $count + ' 在 [' + $exp.minSessions + ',' + $exp.maxSessions + '] 区间内')
}
# 断言 2：必须认出来的群名关键词
foreach ($k in @($exp.mustContain)) {
  if ($names -like ('*' + $k + '*')) { Write-Line ('✅ 包含关键词 "' + $k + '"') }
  else { Write-Line ('❌ 断言失败：没认出 "' + $k + '"'); $fail++ }
}
# 断言 3：不该出现的（角标/时间被当成会话名）
foreach ($bad in @($exp.mustNotBeName)) {
  $parts = $names -split '\s*\|\s*'
  $badHit = @($parts | Where-Object { $_.Trim() -eq $bad })
  if ($badHit.Count -gt 0) { Write-Line ('❌ 断言失败："' + $bad + '" 被当成了会话名'); $fail++ }
  else { Write-Line ('✅ 没有把 "' + $bad + '" 当成会话名') }
}

# 断言 4：群名匹配的**数字前缀方向**（2026-10-15 加）
# 背景：这一行当天被改错过一次（改成"名字数字以规则数字开头"），导致注释里那个真实 OCR 残名
# `示例群A266`（规则 `示例群A<示例群号>（官方）`）反而匹配不上 —— 而第 ③ 步的滑窗
# 编辑距离要求"名字比规则长"，救不回来。这条断言锁住正确方向，防止再被改反。
# 语义：**规则里的数字串，以名字里的数字串开头**（OCR 把长数字读残：<示例群号> → 266）。
Write-Line ''
Write-Line '--- 群名匹配（数字前缀方向）---'
$matchCases = @(
  @{ n = '示例群A266';            p = '示例群A<示例群号>（官方）'; want = $true;  why = '真实 OCR 残名（<示例群号> 被读成 266）—— 这条锁住数字前缀方向' },
  @{ n = '示例群A266';            p = '示例群A<示例群号>';         want = $true;  why = '同上，不带后缀' },
  @{ n = '示例群A<示例群号>（官方）'; p = '示例群A<示例群号>（官方）'; want = $true;  why = '完整名字（第①步包含）' },
  # 下面这条是**已知限制**，故意断言为 False —— 免得以后有人以为"加了容错就该命中"，
  # 从而把编辑距离容差放宽（放宽会误匹配不相干的群）。正确做法是把白名单写短一点。
  @{ n = '<OCR 错字示例>';           p = '示例群A班级群';         want = $false; why = '已知限制：残名比规则短 1 字符，滑窗要求"名字≥规则"，进不去' }
)
foreach ($c in $matchCases) {
  $got = Test-ChatRuleMatch -Name $c.n -Pattern $c.p
  if ($got -eq $c.want) { Write-Line ('✅ 匹配方向：' + $c.why) }
  else { Write-Line ('❌ 数字前缀方向可能被改反了：「' + $c.n + '」对「' + $c.p + '」期望 ' + $c.want + ' 实际 ' + $got); $fail++ }
}

# 断言 5：误入非聊天界面的检测（2026-10-15 加）
# 为什么：点进「群助手 / 服务通知」这类列表型界面后，后面所有行坐标都会错位、整轮白跑。
# ⚠️ 关键是**第二类用例**：正常群名也可能带 "(数字)"（那是群人数），
#    绝不能因为"尾部有括号数字"就判成非聊天界面 —— 误判会把正常群踢掉，比不检测更糟。
Write-Line ''
Write-Line '--- 非聊天界面检测（误入群助手/服务通知）---'
$script:NonChatMarkers = @('群助手', '服务通知', '订阅号消息', '公众号', '微信团队')
$nonChatCases = @(
  @{ h = '群助手（25）';                 want = $true;  why = '群助手（带条数）' },
  @{ h = '群助手';                       want = $true;  why = '群助手（无条数）' },
  @{ h = '服务通知（38）';               want = $true;  why = '服务通知' },
  @{ h = '理综6班-勇往直前（25）';        want = $false; why = '正常群名（括号里是群人数）—— 绝不能误判' },
  @{ h = '示例群A<示例群号>（官方）';   want = $false; why = '正常群名' },
  @{ h = '宗6班一勇往直前（25）';         want = $false; why = 'OCR 错字的正常群名' },
  @{ h = '';                             want = $false; why = '空标题（走"未识别"分支，不算非聊天界面）' }
)
foreach ($c in $nonChatCases) {
  $got = Test-WxNonChatHeader -Header $c.h
  if ($got -eq $c.want) { Write-Line ('✅ 非聊天检测：' + $c.why) }
  else { Write-Line ('❌ 非聊天检测错：「' + $c.h + '」期望 ' + $c.want + ' 实际 ' + $got + '（' + $c.why + '）'); $fail++ }
}

Write-Line ''
if ($fail -eq 0) { Write-Line '===== 全部通过 ====='; exit 0 }
Write-Line ('===== 失败 ' + $fail + ' 项 ====='); exit 1



