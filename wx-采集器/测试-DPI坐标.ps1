# 离线 fixture 测试必须与本机真实档案无关：
#   否则"这台机器标定过"会让 fixture 的解析结果漂移（2026-10-29 实测：档案说列表宽 318，
#   而 fixture 的时间列在 x=337 → 6 个会话被切成 5 个）。设成 none = 完全按比例，结果确定。
$env:WX_LAYOUT_PROFILE = 'none'
$env:WX_LAYOUT_PROFILE_QQ = 'none'
# 测试-DPI坐标.ps1 —— DPI 缩放 / 坐标空间 / 宽窗口布局 的回归（2026-10-29）
#
# 为什么要有这个测试（外部实测报告：维修报告-DPI缩放坐标错乱.md + issue-点开会话失败报告.md）：
#   150% 缩放的机器上"一个群都点不开"，根因是**三套坐标系混用**：
#     · GetWindowRect 返回虚拟坐标（进程没声明 DPI 感知）
#     · PrintWindow 永远按物理像素渲染
#     · SetCursorPos / Maa 的 PostClick 吃物理坐标 / 客户区坐标
#   三者在 100% 时数值恰好相等，所以"开发机好好的、用户机器全残"。
#   这份测试把四件事钉住：
#     A. 虚拟→物理的换算算术（150% / 125% / 100%、感知开/关）
#     B. 本进程确实声明上了 DPI 感知
#     C. Get-WxPhysicalRect 与窗口 DPI 自洽（感知生效时不该再乘系数）
#     D. OCR 一行都没认出来时，采集器不许抛错（空 SessionLines）
#     E. 宽窗口下聊天面板的群名不许被切进"会话列表"（会被当成可点的会话行 → 点标题）
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\测试-DPI坐标.ps1
# 退出码：0 = 全过；1 = 有失败项。
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$collector = Join-Path $here '采集器.ps1'
$logFile = Join-Path $here 'logs\last-pass-test.txt'   # fixture 运行写隔离日志（2026-11-06）
. (Join-Path $here 'wxlib.ps1')

$script:fail = 0
$script:pass = 0
function Ok([string]$n) { $script:pass++; Write-Host ('  ✅ ' + $n) }
function No([string]$n, [string]$why) { $script:fail++; Write-Host ('  ❌ ' + $n + ' —— ' + $why) }

# ============================ A. 虚拟 → 物理 的换算算术 ============================
Write-Host '=== A. Convert-WxRectByDpi：虚拟坐标 → 物理像素 ==='
# 真机实测数字（外部报告）：150% 缩放下物理约 1206x1538 的窗口被 GetWindowRect 报成 804x1025
$r150 = Convert-WxRectByDpi -Rect @(462, 0, 804, 1025) -Dpi 144 -Aware $false
if ($r150.width -eq 1206 -and $r150.height -eq 1538 -and $r150.left -eq 693 -and [Math]::Abs($r150.factor - 1.5) -lt 1e-9) {
  Ok '150% 不感知：804x1025 @(462,0) → 1206x1538 @(693,0)（×1.5）'
} else {
  No '150% 不感知换算' ('实际 ' + $r150.width + 'x' + $r150.height + ' @(' + $r150.left + ',' + $r150.top + ') factor=' + $r150.factor)
}
$r150a = Convert-WxRectByDpi -Rect @(462, 0, 804, 1025) -Dpi 144 -Aware $true
if ($r150a.width -eq 804 -and $r150a.factor -eq 1.0 -and -not $r150a.corrected) {
  Ok '150% 已感知：原样返回（不重复乘系数）'
} else { No '150% 已感知应原样返回' ('实际 ' + $r150a.width + ' factor=' + $r150a.factor) }

$r125 = Convert-WxRectByDpi -Rect @(877, 362, 294, 387) -Dpi 120 -Aware $false
if ($r125.width -eq 368 -and $r125.height -eq 484 -and [Math]::Abs($r125.factor - 1.25) -lt 1e-9) {
  Ok '125% 不感知：294x387 → 368x484（×1.25，本机实测过的真实数字）'
} else { No '125% 不感知换算' ('实际 ' + $r125.width + 'x' + $r125.height + ' factor=' + $r125.factor) }

$r100 = Convert-WxRectByDpi -Rect @(693, 0, 798, 1022) -Dpi 96 -Aware $false
if ($r100.width -eq 798 -and $r100.factor -eq 1.0 -and -not $r100.corrected) {
  Ok '100%：不换算（零行为变化）'
} else { No '100% 应零变化' ('实际 ' + $r100.width + ' factor=' + $r100.factor) }

$rOdd = Convert-WxRectByDpi -Rect @(0, 0, 100, 200) -Dpi 0 -Aware $false
if ($rOdd.width -eq 100 -and $rOdd.factor -eq 1.0) {
  Ok '取不到窗口 DPI（=0）时不瞎换算'
} else { No 'DPI=0 应不换算' ('实际 factor=' + $rOdd.factor) }

# ============================ B. 本进程是否真的声明上了 ============================
Write-Host '=== B. 本进程的 DPI 感知声明 ==='
if ($script:WxDpiAware) {
  Ok ('已声明（' + $script:WxDpiNote + '）→ GetWindowRect 返回物理像素')
} else {
  No 'DPI 感知未生效' ('note=' + $script:WxDpiNote + '；此时坐标仍是虚拟值，125%/150% 下会点歪')
}

# ============================ C. 物理矩形与窗口 DPI 自洽 ============================
Write-Host '=== C. Get-WxPhysicalRect 自洽性 ==='
$probe = Get-WxWindowInfo
if ($null -eq $probe) {
  Ok '跳过：当前没有微信窗口（无法取窗口 DPI）'
} else {
  $raw = [WxNative]::RectOf($probe.hwnd)
  if ($probe.dpiAware) {
    if ($probe.width -eq $raw[2] -and $probe.height -eq $raw[3]) {
      Ok ('感知生效：物理矩形 == GetWindowRect 原值（{0}x{1}，DPI {2}）' -f $probe.width, $probe.height, $probe.dpi)
    } else {
      No '感知生效时不该再乘系数' ('RectOf=' + $raw[2] + 'x' + $raw[3] + ' 但返回 ' + $probe.width + 'x' + $probe.height)
    }
  } else {
    $exp = Convert-WxRectByDpi -Rect $raw -Dpi $probe.dpi -Aware $false
    if ($probe.width -eq $exp.width -and $probe.height -eq $exp.height) {
      Ok ('感知未生效，但已按窗口 DPI 校正（{0}x{1}，DPI {2}）' -f $probe.width, $probe.height, $probe.dpi)
    } else {
      No '未感知时应按 DPI 校正' ('期望 ' + $exp.width + 'x' + $exp.height + '，实际 ' + $probe.width + 'x' + $probe.height)
    }
  }
}

# ============================ D. 空 OCR 行不许抛错 ============================
Write-Host '=== D. OCR 一行都没认出来时（空 SessionLines）不许崩 ==='
$emptyFx = Join-Path $env:TEMP 'wx-dpi-test-empty.json'
$emptyObj = [ordered]@{ width = 894; height = 647; hwnd = 0; rows = @() }
[System.IO.File]::WriteAllText($emptyFx, ($emptyObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$outD = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $emptyFx -Peek 2>&1 | Out-String
$codeD = $LASTEXITCODE
if ($codeD -eq 0 -and $outD -notmatch 'Cannot bind argument') {
  Ok '空数组：退出码 0，没有 "Cannot bind argument ... empty array"'
} else {
  No '空数组仍抛错' ('exit=' + $codeD + '；输出片段：' + ($outD -split "`n" | Select-Object -First 4) -join ' / ')
}

# ============================ E. 宽窗口：群名不许被切进"会话列表" ============================
Write-Host '=== E. 宽窗口（1114x807）：聊天面板群名不许被当成会话行 ==='
# 真机 OCR 原样：群名被拆成同一 y 上的两段，且第一段 x=404 落在旧的 0.42 分界线（468）左边。
# 老代码会把这两段当"会话"，其中 x=404 那行的 y 正好在标题栏 → "点开会话"点在标题上，永远点不开。
$wideRows = @(
  [ordered]@{ x = 404; y = 58; h = 20; text = '26 示例群A 2 班 <示例群号>' }
  [ordered]@{ x = 600; y = 58; h = 19; text = '（官方）（52）' }
  [ordered]@{ x = 188; y = 120; h = 19; text = 'DeepSeek' }
  [ordered]@{ x = 370; y = 120; h = 17; text = '昨天 22：16' }
  [ordered]@{ x = 188; y = 175; h = 19; text = '月 1 组' }
  [ordered]@{ x = 370; y = 175; h = 17; text = '昨天 21：07' }
  [ordered]@{ x = 188; y = 230; h = 19; text = '养 0 场' }
  [ordered]@{ x = 188; y = 285; h = 19; text = '26 人工 2 班班级群' }
  [ordered]@{ x = 470; y = 160; h = 18; text = '某同学：@所有人后天的英语考试' }
)
$wideFx = Join-Path $env:TEMP 'wx-dpi-test-wide.json'
$wideObj = [ordered]@{ width = 1114; height = 807; hwnd = 0; rows = $wideRows }
[System.IO.File]::WriteAllText($wideFx, ($wideObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $wideFx -Peek 2>&1
$lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
$ses = ($lines | Where-Object { $_ -match '会话列表识别到' } | Select-Object -Last 1)
$mCount = [regex]::Match([string]$ses, '识别到 (\d+) 个会话')
$mNames = [regex]::Match([string]$ses, '个会话：(.*)$')
$cnt = if ($mCount.Success) { [int]$mCount.Groups[1].Value } else { -1 }
$names = if ($mNames.Success) { $mNames.Groups[1].Value } else { '' }
$bad = @()
if ($cnt -ne 4) { $bad += ('会话数 {0} ≠ 4' -f $cnt) }
if ($names -match '<示例群号>') { $bad += '群名（<示例群号>）被当成了会话行' }
if ($names -match '倌方|（官方）') { $bad += '群名尾巴被当成了会话行' }
foreach ($k in @('DeepSeek', '月 1 组', '养 0 场', '26 人工 2 班班级群')) {
  if ($names -notlike ('*' + $k + '*')) { $bad += ('少了「' + $k + '」') }
}
if ($bad.Count -eq 0) {
  Ok ('4 个真实会话都在，群名两段都没混进来：' + $names)
} else {
  No '宽窗口分界线' (($bad -join '；') + '｜实际：' + $names)
}

# ============================ F. 150% 真机数据：群名 x=486（默认分界 563 会切掉它）============================
Write-Host '=== F. 150% 真机数据（1341x970）：群名 x=486 必须被认成聊天区 ==='
# 这组数字是 2026-10-29 150% 实测的 OCR 原样。两个坑都在里面：
#   ① 窗口左上角图标碎片 y=64 x=29 —— 曾经把"群名左边界"拖到 29，导致自校准放弃；
#   ② 会话行右侧时间 x=405 y=148 —— 在"没开聊天"时曾会被当成群名，把时间列踢出会话列表。
$p150Rows = @(
  [ordered]@{ x = 29; y = 64; h = 53; text = '0' }
  [ordered]@{ x = 409; y = 71; h = 26; text = 'O' }
  [ordered]@{ x = 486; y = 72; h = 21; text = '26 人 工 2 班 班 级 群 （ 50 ）' }
  [ordered]@{ x = 189; y = 144; h = 23; text = 'DeepSeek' }
  [ordered]@{ x = 405; y = 148; h = 12; text = '1 1 ： 05' }
  [ordered]@{ x = 188; y = 242; h = 21; text = '养 0 场' }
  [ordered]@{ x = 405; y = 245; h = 12; text = '1 1 ： 00' }
  [ordered]@{ x = 188; y = 339; h = 19; text = '月 1 组' }
  [ordered]@{ x = 370; y = 342; h = 14; text = '昨 天 21 ： 07' }
  [ordered]@{ x = 188; y = 437; h = 20; text = '26 人 工 2 班 班 级 群' }
  [ordered]@{ x = 370; y = 440; h = 14; text = '昨 天 20 ： 28' }
  [ordered]@{ x = 566; y = 232; h = 18; text = '郭 子 毅' }
  [ordered]@{ x = 584; y = 276; h = 22; text = '大 家 如 果 对 食 堂 的 菜 品 有 意 见 的 可 以 提 出' }
)
$p150Fx = Join-Path $env:TEMP 'wx-dpi-test-150.json'
$p150Obj = [ordered]@{ width = 1341; height = 970; hwnd = 0; rows = $p150Rows }
[System.IO.File]::WriteAllText($p150Fx, ($p150Obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $p150Fx -Peek 2>&1
$lines2 = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
$ses2 = [string]($lines2 | Where-Object { $_ -match '会话列表识别到' } | Select-Object -Last 1)
$mN2 = [regex]::Match($ses2, '个会话：(.*)$')
$names2 = if ($mN2.Success) { $mN2.Groups[1].Value } else { '' }
$bad2 = @()
# 日志里的会话名是去掉空格后的形态（'26 人工 2 班班级群'），断言按这个形态写
foreach ($k in @('DeepSeek', '养 0 场', '月 1 组', '26 人工 2 班班级群')) {
  if ($names2 -notlike ('*' + $k + '*')) { $bad2 += ('丢了「' + $k + '」') }
}
# 群名那行（带人数括号、x=486）绝不能出现在会话列表里 —— 出现就说明分界线没自校准
if ($names2 -match '50') { $bad2 += '群名（50）被当成会话行 → 分界线没自校准' }
if ($bad2.Count -eq 0) {
  Ok ('4 个会话正确、群名没混进来：' + $names2)
} else {
  No '150% 宽窗口分界线' (($bad2 -join '；') + '｜实际：' + $names2)
}

# ============================ G. 布局档案：像素常数 × DPI 系数 ============================
Write-Host '=== G. 布局档案：同一份档案在 100/125/150% 下自动换算 ==='
# 这是"换缩放不用重新标定"的核心：档案里只存 96DPI 下的像素常数，运行时乘 DPI 系数。
# 真机量到的常数：125% 下分界 398px → /1.25 = 318；150% 下 480px → /1.5 = 320（互相印证 ≈319）。
$profFx = Join-Path $env:TEMP 'wx-layout-test.txt'
[System.IO.File]::WriteAllLines($profFx, @('listWidthPx=320', 'titleStripPx=96', 'listCapPx=420'), (New-Object System.Text.UTF8Encoding($false)))
$cfgT = [pscustomobject]@{ sessionXTo = 0.42; headerYTo = 0.16; nameXFrom = 0.145 }
$badG = @()
foreach ($case in @(
    @{ w = 894; h = 647; dpi = 96; want = 320; name = '100%' },
    @{ w = 1114; h = 807; dpi = 120; want = 400; name = '125%' },
    @{ w = 1341; h = 970; dpi = 144; want = 480; name = '150%' },
    @{ w = 1786; h = 1293; dpi = 192; want = 640; name = '200%' }
  )) {
  $win = [pscustomobject]@{ width = $case.w; height = $case.h; dpi = $case.dpi }
  $pr = Get-WxLayoutProfile -Win $win -Cfg $cfgT -ProfilePath $profFx
  if ([int]$pr.splitX -ne [int]$case.want) { $badG += ('{0}：分界 {1} ≠ {2}' -f $case.name, $pr.splitX, $case.want) }
  if ($pr.splitSource -ne 'profile') { $badG += ('{0}：来源应为 profile，实际 {1}' -f $case.name, $pr.splitSource) }
}
# 没有档案时必须与老行为完全一致（比例兜底，零回归）
$winNo = [pscustomobject]@{ width = 894; height = 647; dpi = 96 }
$prNo = Get-WxLayoutProfile -Win $winNo -Cfg $cfgT -ProfilePath (Join-Path $env:TEMP '不存在的档案.txt')
if ([int]$prNo.splitX -ne 375) { $badG += ('没档案时应退回比例 375，实际 {0}' -f $prNo.splitX) }
if ($prNo.splitSource -ne 'ratio') { $badG += ('没档案时来源应为 ratio，实际 {0}' -f $prNo.splitSource) }
if ($badG.Count -eq 0) { Ok '320px@96DPI → 100%:320 / 125%:400 / 150%:480 / 200%:640；没档案时退回比例 375（零回归）' }
else { No '布局档案换算' ($badG -join '；') }

# ============================ H. 名字列自校准（角标 vs 真名）============================
Write-Host '=== H. 名字列自校准：真名叫 212 的会话不许被当角标丢掉 ==='
$badH = @()
# 894 宽（100%）：角标簇 100~115，名字列 156 起 → 分界应落在 115~156 之间
$rowsH1 = @(
  [pscustomobject]@{ x = 100; y = 10; h = 14; text = '1' }
  [pscustomobject]@{ x = 115; y = 10; h = 14; text = '7' }
  [pscustomobject]@{ x = 156; y = 12; h = 20; text = '212' }
  [pscustomobject]@{ x = 157; y = 40; h = 20; text = '月 1 组' }
)
$nx1 = Get-WxNameXMinFromRows -SessionLines $rowsH1 -WinW 894 -Cfg $cfgT
if ($nx1 -le 115 -or $nx1 -ge 156) { $badH += ('894 宽：分界 {0} 不在 115~156 之间' -f $nx1) }
# 1341 宽（150%）：角标 138，名字列 188 起。旧的比例 0.145*1341=194 会把 188 的真名判成角标（实测 bug）
$rowsH2 = @(
  [pscustomobject]@{ x = 138; y = 10; h = 14; text = '2' }
  [pscustomobject]@{ x = 188; y = 12; h = 20; text = '212' }
  [pscustomobject]@{ x = 189; y = 40; h = 20; text = 'DeepSeek' }
)
$nx2 = Get-WxNameXMinFromRows -SessionLines $rowsH2 -WinW 1341 -Cfg $cfgT
if ($nx2 -ge 188) { $badH += ('150%：分界 {0} ≥ 名字列 188 → 真名会被当角标' -f $nx2) }
if ($nx2 -le 138) { $badH += ('150%：分界 {0} ≤ 角标 138 → 角标会被当名字' -f $nx2) }
if ($badH.Count -eq 0) { Ok ('894 宽 → {0}；1341 宽 → {1}（都卡在角标与名字之间）' -f $nx1, $nx2) }
else { No '名字列自校准' ($badH -join '；') }

# ============================ I. 失败自搜索的候选顺序 ============================
Write-Host '=== I. 失败自搜索：候选分界线由可信到激进 ==='
$winI = [pscustomobject]@{ width = 1341; height = 970; dpi = 144 }
$cands = @(Get-WxSplitCandidates -Win $winI -Cfg $cfgT -ContentSplit 470)
$badI = @()
if ($cands.Count -lt 2) { $badI += ('候选太少（{0} 个）' -f $cands.Count) }
if ($cands[0] -ne 470) { $badI += ('第一个候选应是内容自锚定值 470，实际 {0}' -f $cands[0]) }
if (($cands | Select-Object -Unique).Count -ne $cands.Count) { $badI += '候选有重复' }
if ($badI.Count -eq 0) { Ok ('候选 {0} 个：{1}（第一个=内容自锚定，其后含比例/档案值及 ±10%/20%）' -f $cands.Count, ($cands -join ', ')) }
else { No '失败自搜索候选' ($badI -join '；') }

# ============================ J. QQ 布局档案 ============================
Write-Host '=== J. QQ 布局档案：chatXFrom=0.3 的比例假设换成像素常数 ==='
$profQ = Join-Path $env:TEMP 'qq-layout-test.txt'
[System.IO.File]::WriteAllLines($profQ, @('listWidthPx=312', 'listTopPx=58', 'titleStripPx=110'), (New-Object System.Text.UTF8Encoding($false)))
$cfgQ = [pscustomobject]@{ chatXFrom = 0.3; listYFrom = 0.15; chatYFrom = 0.13 }
$badJ = @()
# 真机：1445 宽 / DPI 120 → 实测列表宽 390（旧比例 0.3*1445=433，偏右 43px）
$qqP = Get-QqLayoutProfile -Win ([pscustomobject]@{ width = 1445; height = 1071; dpi = 120 }) -Cfg $cfgQ -ProfilePath $profQ
if ([int]$qqP.chatX -ne 390) { $badJ += ('1445 宽 125%：chatX 应为 390，实际 {0}' -f $qqP.chatX) }
if ([Math]::Abs([int]$qqP.listY - 73) -gt 1) { $badJ += ('列表上沿应为 58*1.25≈73（±1），实际 {0}' -f $qqP.listY) }
# 没档案 → 与老行为一致
$qqN = Get-QqLayoutProfile -Win ([pscustomobject]@{ width = 1445; height = 1071; dpi = 120 }) -Cfg $cfgQ -ProfilePath (Join-Path $env:TEMP '不存在-qq.txt')
if ([Math]::Abs([int]$qqN.chatX - 433) -gt 1) { $badJ += ('没档案时应退回 0.3*1445≈433（±1），实际 {0}' -f $qqN.chatX) }
if ($badJ.Count -eq 0) { Ok '125% 下 chatX 390（比例模型会给 433，偏右 43px）；没档案时退回 433（零回归）' }
else { No 'QQ 布局档案' ($badJ -join '；') }

# ============================ 汇总 ============================
Write-Host ''
if ($script:fail -eq 0) {
  Write-Host ("===== 全部通过（{0} 项）=====" -f $script:pass)
  exit 0
} else {
  Write-Host ("===== 有失败：通过 {0} 项，失败 {1} 项 =====" -f $script:pass, $script:fail)
  exit 1
}
