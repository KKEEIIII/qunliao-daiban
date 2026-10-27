# 测试-分辨率适配.ps1 —— 不同分辨率 / DPI / 缩放下的适配回归（2026-10-27）
#
# 为什么要有这个测试：
#   两台机器之间、或者换了 Windows 缩放 / 拉大窗口 / 改了微信字号之后，**像素常量全都不对**。
#   项目里以前只有 QQ 侧做了自适应（行距自校准、区域比例、按抓图高度折算），微信侧还留着
#   "rowGap=35、点击 +8px"这种定值。这次把微信侧也改成自校准，就用这份测试把它钉住：
#     ① 同一份 OCR（fixtures\wechat-list.json）整体缩放到 0.5×~2×，会话数必须恒为 6、群名不变；
#     ② 关掉 autoRowGap 时必须**看得出来会错**（负向对照）—— 证明不是"本来就不会错"；
#     ③ QQ 侧：聊天区边界（比例）、噪声过滤、时间分隔行在两种抓图分辨率下都要对。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\测试-分辨率适配.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\测试-分辨率适配.ps1 -KeepTemp   # 保留临时 fixture
# 退出码：0 = 全过；1 = 有失败项。
param([switch]$KeepTemp)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$collector = Join-Path $here '采集器.ps1'
$logFile = Join-Path $here 'logs\last-pass.txt'
$cfgPath = Join-Path $here 'config.json'
$fxPath = Join-Path $here 'fixtures\wechat-list.json'
. (Join-Path $here 'wxlib.ps1')

$script:fail = 0
$script:pass = 0
function Ok([string]$n) { $script:pass++; Write-Host ('  ✅ ' + $n) }
function No([string]$n, [string]$why) { $script:fail++; Write-Host ('  ❌ ' + $n + ' —— ' + $why) }

# ============================ A. 微信：同一份 OCR 缩放到多种分辨率 ============================
Write-Host '=== A. 微信会话列表：同一份 OCR 缩放到 0.5×~2×，解析结果必须一致 ==='
$fx = Get-Content -LiteralPath $fxPath -Raw -Encoding UTF8 | ConvertFrom-Json
# fixture 实测的行距分布（见下）：同一会话内部最大间隔 29px，会话之间最小间隔 53px。
# 所以"正确的行距阈值"必须落在这两个数之间（按缩比缩放）。
$INTRA_MAX = 29.0
$INTER_MIN = 53.0
$EXPECT_NAMES = @('示例群A', '示例群G', '人工', '212')

$tmpFiles = @()
$multiOk = $true
foreach ($s in @(0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0)) {
  $W = [int][Math]::Round([double]$fx.width * $s)
  $H = [int][Math]::Round([double]$fx.height * $s)
  $rows = @($fx.rows | ForEach-Object {
      [pscustomobject]@{
        x    = [int][Math]::Round([double]$_.x * $s)
        y    = [int][Math]::Round([double]$_.y * $s)
        h    = [int][Math]::Max(6, [Math]::Round([double]$_.h * $s))
        text = [string]$_.text
      }
    })
  $obj = [ordered]@{ width = $W; height = $H; hwnd = 0; rows = $rows }
  $tmp = Join-Path $env:TEMP ("wx-fixture-{0}x.json" -f ($s.ToString('0.00').Replace('.', '_')))
  [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  $tmpFiles += $tmp

  & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $tmp -Peek 2>&1 | Out-Null
  if (-not (Test-Path -LiteralPath $logFile)) { No ("{0}× 跑了采集器" -f $s) '没有日志文件'; $multiOk = $false; continue }
  $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
  $sessionLine = ($lines | Where-Object { $_ -match '会话列表识别到' } | Select-Object -Last 1)
  $layoutLine = ($lines | Where-Object { $_ -match '会话行距自适应' } | Select-Object -Last 1)
  if (-not $sessionLine) { No ("{0}× 跑出了会话列表" -f $s) '日志里没有"会话列表识别到"'; $multiOk = $false; continue }
  $mC = [regex]::Match($sessionLine, '识别到 (\d+) 个会话')
  $mN = [regex]::Match($sessionLine, '个会话：(.*)$')
  $cnt = if ($mC.Success) { [int]$mC.Groups[1].Value } else { -1 }
  $names = if ($mN.Success) { $mN.Groups[1].Value } else { '' }

  $bad = @()
  if ($cnt -ne 6) { $bad += ('会话数 {0} ≠ 6' -f $cnt) }
  foreach ($k in $EXPECT_NAMES) { if ($names -notlike ('*' + $k + '*')) { $bad += ('少了「' + $k + '」') } }

  $gap = 0.0
  if (-not $layoutLine) { $bad += '没有"会话行距自适应"日志' }
  else {
    $mg = [regex]::Match($layoutLine, '会话行距自适应：([0-9.]+)px')
    if ($mg.Success) { $gap = [double]$mg.Groups[1].Value } else { $bad += '行距日志解析不了' }
    # 阈值必须落在"会话内最大间隔"和"会话间最小间隔"之间（按缩比缩放）
    if ($gap -le ($INTRA_MAX * $s)) { $bad += ('阈值 {0:N1} ≤ 会话内最大间隔 {1:N1}（会话会被拆开）' -f $gap, ($INTRA_MAX * $s)) }
    if ($gap -ge ($INTER_MIN * $s)) { $bad += ('阈值 {0:N1} ≥ 会话间最小间隔 {1:N1}（会话会被并起来）' -f $gap, ($INTER_MIN * $s)) }
  }
  if ($bad.Count -eq 0) {
    Ok ("{0}×（{1}x{2}）：6 个会话，阈值 {3:N1}px 落在 [{4:N1}, {5:N1}] 之间" -f $s, $W, $H, $gap, ($INTRA_MAX * $s), ($INTER_MIN * $s))
  } else {
    $multiOk = $false
    No ("{0}×（{1}x{2}）" -f $s, ($bad -join '；') + '｜实际：' + $names)
  }
}

# ---- 负向对照：关掉自适应后用同一个 2× 分辨率再跑一遍，必须"看得出来会错" ----
Write-Host '  --- 负向对照：关掉 autoRowGap 后，2× 分辨率应当解析错误 ---'
$cfgObj = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cfgObj | Add-Member -NotePropertyMembers @{ autoRowGap = $false } -Force
$tmpCfg = Join-Path $env:TEMP 'wx-config-noautorowgap.json'
# 注意：这里只用 PowerShell 写**临时测试配置**（马上被 PS 自己读回），不涉及线上 JSON 数据。
[System.IO.File]::WriteAllText($tmpCfg, ($cfgObj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
$tmp2x = $tmpFiles[6]   # 2.0× 那一份
& powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $tmp2x -Peek -ConfigPath $tmpCfg 2>&1 | Out-Null
$lines2 = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
$line2 = ($lines2 | Where-Object { $_ -match '会话列表识别到' } | Select-Object -Last 1)
$m2 = if ($line2) { [regex]::Match($line2, '识别到 (\d+) 个会话') } else { $null }
$cnt2 = if ($m2 -and $m2.Success) { [int]$m2.Groups[1].Value } else { -1 }
if ($cnt2 -eq 6) {
  No '负向对照：关掉自适应后 2× 应当是错的' ('结果仍是 6 个会话 —— 说明这套测试根本发现不了回归，或者 fixture 缩放没生效')
} elseif ($cnt2 -lt 0) {
  No '负向对照：关掉自适应后仍能跑出结果' '日志里没有会话数'
} else {
  Ok ('负向对照：关掉自适应后 2× 解析成 {0} 个会话（≠6，正是固定 35px 的错法）' -f $cnt2)
}

# ============================ B. QQ：聊天区边界 + 噪声过滤 + 时间分隔行 ============================
Write-Host ''
Write-Host '=== B. QQ 聊天区：两种抓图分辨率下，边界/噪声过滤/时间分隔行都要一致 ==='
. (Join-Path (Split-Path -Parent $here) 'maafw-probe\qqread.ps1')
$qqCfg = Get-Content -LiteralPath (Join-Path $here 'config-qq.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function New-Ctx([double]$W, [double]$H) { return [pscustomobject]@{ captureW = $W; captureH = $H; cfg = $qqCfg } }

foreach ($dim in @(@{ w = 1440.0; h = 1065.0; tag = '原始分辨率 1440x1065' }, @{ w = 968.0; h = 720.0; tag = 'Maa 默认缩放 968x720' })) {
  $W = [double]$dim.w; $H = [double]$dim.h; $tag = [string]$dim.tag
  $rows = @(
    [pscustomobject]@{ x = [double]($W * 0.50); y = [double]($H * 0.30); h = [double]($H * 0.016); text = '今天下午三点在会议室开例会' },
    [pscustomobject]@{ x = [double]($W * 0.525); y = [double]($H * 0.18); h = [double]($H * 0.014); text = '09:05' },
    [pscustomobject]@{ x = [double]($W * 0.525); y = [double]($H * 0.40); h = [double]($H * 0.014); text = '昨天19：22' },
    [pscustomobject]@{ x = [double]($W * 0.40); y = [double]($H * 0.46); h = [double]($H * 0.012); text = '0031' },
    [pscustomobject]@{ x = [double]($W * 0.50); y = [double]($H * 0.94); h = [double]($H * 0.016); text = '这条在聊天区下方（应被区域边界排除）' },
    [pscustomobject]@{ x = [double]($W * 0.95); y = [double]($H * 0.30); h = [double]($H * 0.016); text = '这条在右侧侧栏（应被 chatXTo 排除）' }
  )
  $t = Get-QqChatText -Ctx (New-Ctx $W $H) -Rows $rows
  $bad = @()
  if ($t.text -notlike '*今天下午三点在会议室开例会*') { $bad += '正文丢了' }
  if ($t.text -notlike '*09:05*') { $bad += '纯时间分隔行 09:05 被噪声过滤吃掉了（时间锚点会失效）' }
  if ($t.text -notlike '*昨天19：22*') { $bad += '中文时间分隔行丢了' }
  if ($t.text -like '*0031*') { $bad += '界面噪声 0031 没被过滤' }
  if ($t.text -like '*聊天区下方*') { $bad += 'chatYTo 边界没生效' }
  if ($t.text -like '*右侧侧栏*') { $bad += 'chatXTo 边界没生效' }
  # 过滤之后仍然要能解析出时间（这才是"对接"：噪声过滤 × 时间锚点）
  $times = Get-ChatTimesFromLines -Lines @($t.lines) -Now (Get-Date '2026-10-27 10:03')
  if ($times.count -lt 2) { $bad += ('过滤后只剩 {0} 个时间戳（期望 ≥2）' -f $times.count) }
  if ($bad.Count -eq 0) { Ok ($tag + '：正文完整、噪声已过滤、时间分隔行保留、时间戳解析 ' + $times.count + ' 个') }
  else { No $tag ($bad -join '；') }

  # 聊天头部：x≥0.26W、y∈[0.05H,0.16H]，两种分辨率下都要能读到同一个群名
  $hrows = @(
    [pscustomobject]@{ x = [double]($W * 0.30); y = [double]($H * 0.09); text = '示例群B（159）'; h = [double]($H * 0.016) },
    [pscustomobject]@{ x = [double]($W * 0.30); y = [double]($H * 0.30); text = '这不是头部'; h = [double]($H * 0.016) },
    [pscustomobject]@{ x = [double]($W * 0.10); y = [double]($H * 0.09); text = '左侧列表名'; h = [double]($H * 0.016) }
  )
  $hdr = Get-QqChatHeader -Ctx (New-Ctx $W $H) -Rows $hrows
  if ($hdr -eq '示例群B（159）') { Ok ($tag + '：聊天头部按比例取到「' + $hdr + '」') }
  else { No ($tag + '：聊天头部') ('期望 示例群B（159），实际「' + $hdr + '」') }
}

# ============================ C. 微信：OCR 把「会话名 + 时间」并成一行 ============================
# 2026-10-27 11:04 定时任务里真实出现：群名被解析成「26 人工 2 毋开纟及群昨天 23： 00」。
# 这个脏名字会进 state / spool / 锚点 key；这里用一份合成 fixture 把它钉住。
Write-Host ''
Write-Host '=== C. 微信：群名和右侧时间被 OCR 并成一行时，群名要把时间剥掉 ==='
$mergedFx = [ordered]@{
  width = 894; height = 647; hwnd = 0
  rows  = @(
    @{ x = 157; y = 119; h = 18; text = '26 示例群A 2 班灬昨天 23： 00' },
    @{ x = 157; y = 147; h = 15; text = '某同学：@全体成员' },
    @{ x = 156; y = 282; h = 18; text = '示例群G一勇往直前' },
    @{ x = 157; y = 310; h = 15; text = '示例成员B：[动画表情]' },
    @{ x = 157; y = 445; h = 15; text = '07：30' }
  )
}
$tmpM = Join-Path $env:TEMP 'wx-fixture-mergedname.json'
[System.IO.File]::WriteAllText($tmpM, ($mergedFx | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$tmpFiles += $tmpM
& powershell -NoProfile -ExecutionPolicy Bypass -File $collector -Once -OcrRows $tmpM -Peek 2>&1 | Out-Null
$lines3 = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
$l3 = ($lines3 | Where-Object { $_ -match '会话列表识别到' } | Select-Object -Last 1)
$names3 = ''
if ($l3 -and $l3 -match '个会话：(.*)$') { $names3 = $Matches[1] }
$bad3 = @()
if (-not $l3) { $bad3 += '没有"会话列表识别到"日志' }
if ($names3 -notlike '*26 示例群A 2 班灬*') { $bad3 += ('群名没解析出来（实际：' + $names3 + '）') }
if ($names3 -like '*昨天*') { $bad3 += '群名里还带着时间戳' }
if ($names3 -notlike '*示例群G一勇往直前*') { $bad3 += '第二条会话被带坏' }
if ($names3 -notlike '*07：30*') { $bad3 += '整条就是时间的行被误删/改成空名（应保留原样）' }
if ($bad3.Count -eq 0) { Ok '并成一行时群名剥掉时间、其它会话不受影响、纯时间行保持原样' }
else { No '群名去时间' ($bad3 -join '；') }

if (-not $KeepTemp) { foreach ($f in $tmpFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }; Remove-Item -LiteralPath $tmpCfg -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:fail -eq 0) {
  Write-Host ('===== 全部通过（{0} 项）=====' -f $script:pass)
  exit 0
}
Write-Host ('===== 失败 {0} 项（通过 {1} 项）=====' -f $script:fail, $script:pass)
exit 1
