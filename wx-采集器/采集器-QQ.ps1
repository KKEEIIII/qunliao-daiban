# 采集器-QQ.ps1 —— QQ 会话「后台截图 + OCR」采集器（两种抓图方式）
#
# 抓图方式（config-qq.json 的 captureMode）：
#   maa   —— MaaFramework 后台截图（FramePool|PrintWindow）+ AnchoredTouch 后台点击
#            不抢前台、不需要置顶；可以"一次截图 + 逐行点开"自动轮读白名单群
#   screen—— 老办法：短暂置顶 + 屏幕截取（Chromium 窗口 PrintWindow 全黑，只能这样）
#   auto  —— 优先 maa，失败回退 screen（默认）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\采集器-QQ.ps1 -Once
#   ... -Once -ReadOpen        # 只读当前打开的那个群（不用点击）
#   ... -Once -DumpRows        # 打印窗口内所有 OCR 行
#   ... -Once -Peek            # 不写 spool、不更新状态
#   ... -Once -MaaMode         # 强制走 MaaFramework 后台模式
#
# 依赖：MaaFramework 装在 ..\maafw-probe\maa\bin（P/Invoke 调 MaaFramework.dll）
param(
  [switch]$Once,
  [int]$Interval = 1800,
  [switch]$DumpRows,
  [switch]$NoRead,
  [switch]$ReadOpen,
  [switch]$Peek,
  [switch]$SaveShots,
  [switch]$MaaMode,          # 强制 MaaFramework 后台模式
  [switch]$ScreenMode,       # 强制屏幕截取模式
  [string]$ConfigPath = '',  # 指定配置文件（默认 config-qq.json）。回归测试用来试不同抓图分辨率，不动线上配置
  [switch]$NoAutoClick       # Maa 模式下也只读当前打开的群（不逐行点开）
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'wxlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'dsh-接入\运行状态.ps1')   # 记录本轮结果

# ⚠️ 2026-10-26：必须声明 DPI 感知（本机 125% 缩放）。
# 不声明时进程拿到的是**逻辑坐标**（窗口 1012x752 @ (730,277)），而屏幕截图/真实鼠标点击
# 落在**物理坐标**空间（窗口实际 1265x940 @ (912,346)）→ 两套坐标混用，"自动点返回"会
# 落到相邻的会话行上（实测连点三次都点到"要早起要好好学习"）。
# 只影响 QQ 采集器这个进程，微信采集器是另一个进程、不受影响。
if (-not ('QqDpi' -as [type])) {
  Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class QqDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
}
[void][QqDpi]::SetProcessDPIAware()

$cfgPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $here 'config-qq.json' }
           elseif ([System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath }
           else { Join-Path $here $ConfigPath }
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$shotDir = Join-Path $here 'shots'
$logDir = Join-Path $here 'logs'
$stateDir = Join-Path $here 'state'
$spoolDir = Join-Path $here 'spool'
foreach ($d in @($shotDir, $logDir, $stateDir, $spoolDir)) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$logFile = Join-Path $logDir 'qq-last-pass.txt'
$stateFile = Join-Path $stateDir 'qq-session-state.json'
$maaDir = Join-Path (Split-Path -Parent $here) 'maafw-probe'

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}
function Norm([string]$s) { if ($null -eq $s) { return '' } return (($s -replace '\s', '') -replace '[：:，。、．（）()]', '') }

# R1（2026-10-27 用户要求）：采集器必须知道**命令执行时间** ——
#   聊天区里的时间分隔行是 "昨天19:22 / 今天9:05 / 星期五23:38" 这种**相对时间**，
#   必须用"本轮执行时间"当基准才能解析成绝对时间（拿 Get-Date 当"现在"去算，
#   在跨零点/长时间运行时会算错一天）。每轮开始时由 Invoke-QqPass 设一次，整轮不变。
function Get-PassNow {
  if ($script:PassNow) { return $script:PassNow }
  return (Get-Date)
}

# OCR 认错字 → 白名单用"滑窗 + 编辑距离"匹配
function Get-Levenshtein([string]$a, [string]$b) {
  $n = $a.Length; $m = $b.Length
  if ($n -eq 0) { return $m }
  if ($m -eq 0) { return $n }
  $prev = New-Object 'int[]' ($m + 1)
  $cur = New-Object 'int[]' ($m + 1)
  for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
  for ($i = 1; $i -le $n; $i++) {
    $cur[0] = $i
    for ($j = 1; $j -le $m; $j++) {
      $cost = 0
      if ($a[$i - 1] -ne $b[$j - 1]) { $cost = 1 }
      $cur[$j] = [Math]::Min($prev[$j] + 1, [Math]::Min($cur[$j - 1] + 1, $prev[$j - 1] + $cost))
    }
    $tmp = $prev; $prev = $cur; $cur = $tmp
  }
  return $prev[$m]
}
# 2026-10-26：白名单匹配统一走 wxlib 的 Test-ChatNameMatch（包含 / 数字前缀 / 开头文字容错 / 滑窗距离）。
# 白名单现在同时支持"短关键词"（示例群F/示例部门/某学校/示例群B/示例群I/<示例群号>）和完整群名。
function Test-QqMatch([string]$name, [string]$pattern) {
  return (Test-ChatNameMatch -Name (Norm $name) -Pattern (Norm $pattern))
}
# 粗筛（只用来挑"值得点开看看"的行；真正的白名单判定一律用点开后的聊天头部）
# 短词也能粗筛：包含优先，其次开头 min(6, 长度) 个字编辑距离≤1（"示例部门" ← "示例部门"）。
function Test-QqPrefix([string]$name, [string]$pattern) {
  $a = Norm $name; $b = Norm $pattern
  if ([string]::IsNullOrWhiteSpace($b) -or $a.Length -lt 2) { return $false }
  if ($a.Contains($b)) { return $true }
  $pn = [Math]::Min(6, $b.Length)
  $nn = [Math]::Min($pn, $a.Length)
  if ($nn -ge 2 -and (Get-Levenshtein $a.Substring(0, $nn) $b.Substring(0, $pn)) -le 1) { return $true }
  return $false
}

# 行距 + 首行位置 自动校准（2026-10-26）
# 为什么需要：config 里的 rowHeight=57 / firstRowY=120 是按 1079x720 标定的；用户把 QQ 窗口
# 拉大/改缩放后，抓图仍是 969x720，但列表实际行距会变（实测拉高窗口后行距≈77，用 57 去套
# 会把名字归错行 → 白名单群"看不见" → 整轮只认到 5 行、示例群B/示例群I漏采）。
# 做法：按 config 的比例（120/57 ≈ 2.1）同步缩放首行位置，扫描一组候选行距，
#       用"行名命中白名单最多"自证，取分最高者。
function Get-QqGridAuto {
  param(
    [Parameter(Mandatory = $true)]$Ctx,
    [Parameter(Mandatory = $true)]$Rows,
    [string[]]$Whitelist = @(),
    [int]$MaxRows = 12
  )
  $best = $null; $bestScore = -1; $bestChars = -1; $bestDev = [double]::MaxValue
  # 2026-10-26 链路适配：行距/首行**按抓图分辨率自动缩放**，让同一套配置在
  #   968x720（Maa 默认缩放）和 1267x942（ScreenshotUseRawSize 原始分辨率）下都能对齐。
  #   依据：抓图高度 H 变化时，会话行高与首行位置按 H/720 等比变化
  #   （实测 720 高时行距 57、首行名字 y≈103；942 高时行距≈79、首行名字 y≈134，
  #    79/57=1.386、134/103=1.301，与 942/720=1.308 基本一致）。
  #   候选 = 基准行距 57*(H/720) 附近 ±14px 细扫 + 旧固定表（兼容老分辨率）。
  #   同分时优先"最接近基准行距"，避免选到半行距（38 那种能凑出同样命中数但整体错半行）。
  $sf = [double]$Ctx.captureH / 720.0
  if ($sf -le 0) { $sf = 1.0 }
  # 2026-10-26 链路适配（关键）：**先找出真正的"群名行"，再量行距**，不要盲扫候选表。
  #   实测原始分辨率(1267x942)下同一 x 带里的 OCR 行是这样排的：
  #     y=156 h=18 '示例部门一示例群C'   ← 群名行（字号大）
  #     y=185 h=14 '部长黄新新：…'      ← 预览行（字号小，紧跟群名）
  #     y=237 h=17 '某学校新司_示例群D'  ← 下一个群名行
  #     y=265 h=14 '仰新闻栏目导…'      ← 预览行
  #   即"行内间隔≈30、行间间隔≈80"。所以按"间隔 ≥ 40*缩放"贪心取点，得到的就是群名行序列。
  #   之前不区分这个、直接扫候选表，会选出 46px 这种"半行距"，网格整体错位半行
  #   → 点"示例部门示例机构"却打开"示例学校新闻"（实测）。
  $nameYs = @()
  try {
    $sx1 = [double]$Ctx.captureW * 0.08
    $sx2 = [double]$Ctx.captureW * 0.40
    $band = @($Rows | Where-Object { $_.x -ge $sx1 -and $_.x -le $sx2 -and $_.y -gt ([double]$Ctx.captureH * 0.08) } | Sort-Object y)
    $minGap = 40.0 * $sf
    $lastY = -1e9
    foreach ($r in $band) {
      if (([double]$r.y - $lastY) -ge $minGap) { $nameYs += [int]$r.y; $lastY = [double]$r.y }
    }
  } catch { }
  $measPitch = 0.0
  if ($nameYs.Count -ge 3) {
    $gaps = @()
    for ($i = 1; $i -lt $nameYs.Count; $i++) { $gaps += ($nameYs[$i] - $nameYs[$i - 1]) }
    $sorted = @($gaps | Sort-Object)
    $measPitch = [double]$sorted[[int][math]::Floor($sorted.Count / 2)]
  }
  $p0 = if ($measPitch -ge 24) { [int][math]::Round($measPitch) } else { [int][math]::Round(57.0 * $sf) }
  $candPitch = @()
  for ($d = -6; $d -le 6; $d++) { $p = $p0 + $d; if ($p -ge 24) { $candPitch += $p } }
  $candPitch += @(38, 42, 46, 50, 54, 57, 61, 65, 69, 73, 77, 81, 86, 92, 98, 104)
  $candPitch = @($candPitch | Sort-Object -Unique)
  $candFirst = @()
  if ($nameYs.Count -gt 0) {
    foreach ($d in @(0, -6, 6, -12, 12)) { $f = $nameYs[0] + $d; if ($f -ge 20) { $candFirst += $f } }
  }
  if ($candFirst.Count -eq 0) { foreach ($p in $candPitch) { $candFirst += [int][math]::Round($p * (120.0 / 57.0)) } }
  foreach ($p in $candPitch) {
    foreach ($first in $candFirst) {
      if ($first -lt 20) { continue }
      $rr = Get-QqSessionRows -Ctx $Ctx -Rows $Rows -MaxRows $MaxRows -RowHeightOverride $p -FirstRowYOverride $first
      $score = 0; $chars = 0
      foreach ($r in $rr) {
        $chars += ([string]$r.name).Length
        foreach ($g in $Whitelist) { if (Test-QqPrefix -name $r.name -pattern $g) { $score++; break } }
      }
      $dev = [Math]::Abs($p - $p0)
      if ($score -gt $bestScore -or
        ($score -eq $bestScore -and $dev -lt $bestDev) -or
        ($score -eq $bestScore -and $dev -eq $bestDev -and $chars -gt $bestChars)) {
        $bestScore = $score; $bestChars = $chars; $bestDev = $dev
        $best = [pscustomobject]@{ rows = $rr; pitch = $p; first = $first }
      }
    }
  }
  if (-not $best) { $best = [pscustomobject]@{ rows = @(); pitch = 57; first = 120 } }

  # 2026-10-27 加固：自动量出来的行距**离配置基准太远**时，信配置、不信自动。
  # 实测事故（10-26）：窗口 1152x852、抓图 1440x1065，配置比例算出的行距是
  #   57*(1065/720)=84px（同屏量到的群名行间隔 79~84，与之一致），
  #   但自动量成了 61px —— 网格每行少算 20 多 px，第 5、6 行起点击位置就落到隔壁行，
  #   运气不好点开的是别的会话（或者点空），于是 示例群B 这类靠下的群**记录正文几乎全空**
  #   （10-26 那 13 条记录里 10 条只有群名、没有内容）。
  # 判据保守：只有"自动值偏离基准 >25%"才否决，正常波动（不同 DPI/窗口大小）不受影响。
  $baseCfgPitch = 0.0
  try {
    $rowH = [double]$(if ($Ctx.cfg.rowHeight) { $Ctx.cfg.rowHeight } else { 57 })
    $baseCfgPitch = $rowH * ([double]$Ctx.captureH / 720.0)
  } catch { }
  $pitchRejected = $false
  if ($baseCfgPitch -ge 24 -and $best.pitch -gt 0) {
    $off = [Math]::Abs([double]$best.pitch - $baseCfgPitch) / $baseCfgPitch
    # 阈值 15%（原 25% 太松：实测抓图高 1024 时基准是 81px，自动量的 61px 偏差 24.7%，
    #   正好卡在 25% 门槛下面逃过否决，而实际群名行间隔就是 79~81 —— 基准是对的）。
    if ($off -gt 0.15) {
      # 只换行距，**首行仍用自动量出来的那个**（列表可能被滚到半行位置，
      #   配置里的 firstRowY 只在"列表在顶部"时才对；上一版把它一起换掉，
      #   结果网格整体落到「预览行」上，示例群B 直接找不到）。
      $newPitch = [int][Math]::Round($baseCfgPitch)
      # 首行候选：左栏**每一行 OCR**都试一遍（不只是自动量出来的 nameYs ——
      #   nameYs 本身就可能因为贪心选点而落在预览行上，这正是 61px 那次错的来源）。
      $altFirst = @()
      try {
        $bx1 = [double]$Ctx.captureW * 0.02
        $bx2 = [double]$Ctx.captureW * 0.42
        $by0 = [double]$Ctx.captureH * 0.08
        $altFirst = @($Rows | Where-Object { $_.x -ge $bx1 -and $_.x -le $bx2 -and $_.y -ge $by0 } | Sort-Object y | ForEach-Object { [int]$_.y } | Select-Object -Unique)
      } catch { }
      if ($altFirst.Count -eq 0) { $altFirst = @($nameYs) }
      if ($altFirst.Count -eq 0) { $altFirst = @([int]$best.first) }
      $better = $null; $betterScore = -1
      foreach ($f0 in $altFirst) {
        if ($f0 -lt 20) { continue }
        $rr = Get-QqSessionRows -Ctx $Ctx -Rows $Rows -MaxRows $MaxRows -RowHeightOverride $newPitch -FirstRowYOverride $f0
        $sc = 0
        foreach ($r in $rr) {
          foreach ($g in $Whitelist) { if (Test-QqPrefix -name $r.name -pattern $g) { $sc++; break } }
        }
        if ($sc -gt $betterScore) { $betterScore = $sc; $better = [pscustomobject]@{ rows = $rr; pitch = $newPitch; first = [int]$f0 } }
      }
      # 只有"不比自动结果差"就采纳（2026-10-27 再修：原来要求"严格更好"，
      #   实测两边命中数都是 4 时反而保留了错的 61px —— 61 相对实测行距 80 差 19px/行，
      #   第 2 行就把 示例群B 跳过去了：示例群B 实际在 y=214，而 61 网格排的是 178/239/300…）。
      if ($better -and $betterScore -ge $bestScore) {
        $best = $better; $bestScore = $betterScore; $pitchRejected = $true
      }
    }
  }
  return [pscustomobject]@{ rows = $best.rows; pitch = $best.pitch; first = $best.first; offset = [int][math]::Round($best.pitch / 2); score = $bestScore; rejected = $pitchRejected; basePitch = [int][Math]::Round($baseCfgPitch) }
}

Add-Type -AssemblyName System.Drawing

function Find-QqMainWindow {
  # 只按"可见 + 最大"选，不够可靠（有诱饵窗口）→ Maa 模式会用截图验证
  $procs = @(Get-Process -Name $cfg.processName -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return $null }
  $pids = @($procs | ForEach-Object { [UInt32]$_.Id })
  $cands = @()
  foreach ($line in [WxNative]::ListTopWindows($pids)) {
    $p = $line -split '\|'
    if ($p[7] -ne $cfg.windowClass) { continue }
    if ($p[8] -ne $cfg.windowTitle) { continue }
    if ($p[1] -ne 'True') { continue }
    $cands += [pscustomobject]@{ hwnd = [IntPtr][int64]$p[0]; vis = $p[1]; w = [int]$p[5]; h = [int]$p[6] }
  }
  if ($cands.Count -eq 0) { return $null }
  return ($cands | Sort-Object { $_.w * $_.h } -Descending | Select-Object -First 1)
}

function Get-ScreenRows([int]$Left, [int]$Top, [int]$W, [int]$H, [string]$Tag) {
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($Left, $Top, 0, 0, (New-Object System.Drawing.Size($W, $H)))
  $g.Dispose()
  $shot = Join-Path $shotDir ("qq-" + $Tag + ".png")
  $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return [pscustomobject]@{ shot = $shot; rows = (Invoke-WxOcr -Path $shot -Scale $cfg.scale) }
}

function Get-StateMap([string]$file) {
  $st = @{}
  if (Test-Path -LiteralPath $file) {
    try {
      $s = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $s.PSObject.Properties) { $st[$p.Name] = $p.Value }
    } catch { $st = @{} }
  }
  return $st
}
function Save-StateMap($map, [string]$file) {
  $obj = [ordered]@{}
  foreach ($k in $map.Keys) { $obj[$k] = $map[$k] }
  ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $file -Encoding UTF8
}
function Write-Record($rec, [string]$tag) {
  $file = Join-Path $spoolDir ('messages-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
  # 同 采集器.ps1：Add-Content -Encoding UTF8 新建文件会带 BOM → 插件首行 JSON.parse 失败 → 丢记录。
  $line = ($rec | ConvertTo-Json -Depth 8 -Compress)
  [System.IO.File]::AppendAllText($file, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

# ============ MaaFramework 后台模式 ============
function Invoke-QqMaaPass {
  $script:MaaFailed = $true
  if (-not (Test-Path -LiteralPath (Join-Path $maaDir 'qqread.ps1'))) {
    Log ("跳过：找不到 Maa 封装（" + $maaDir + "）"); return 0
  }
  . (Join-Path $maaDir 'maacap.ps1')
  . (Join-Path $maaDir 'qqwin.ps1')
  . (Join-Path $maaDir 'qqread.ps1')

  $ctx = $null
  # ⚠️ 2026-10-15 深夜修（外部复测 2136 版抓的）：Start-QqRead 在 Maa 加载失败（如缺 VC++ 运行库）时
  #   会抛 DllNotFoundException，而它原来在 try 之外 → 异常穿透到脚本顶层 → 退出码 1、不写运行状态、
  #   自检报绿灯（最坏失败模式）。现在任何初始化异常都按"Maa 不可用"处理 → 走回退屏幕模式。
  try {
    $ctx = Start-QqRead -Config $cfg -ProbeDir $maaDir
  } catch {
    Log ('Maa 初始化异常（如缺 VC++ 运行库？），回退屏幕模式：' + $_.Exception.Message)
    Log '  ⚠️ 注意：屏幕模式（openChatOnly=true）只读"当前打开的会话"，不是全量轮读；想后台全量采集请先解决 Maa（最常见是装 VC++ 运行库）'
    return 0
  }
  if (-not $ctx.ok) {
    Log ('Maa 不可用：' + $ctx.reason)
    Log '  ⚠️ 注意：屏幕模式（openChatOnly=true）只读"当前打开的会话"，不是全量轮读；想后台全量采集请先解决 Maa'
    return 0
  }
  $script:MaaFailed = $false
  try {
    $W = $ctx.captureW; $H = $ctx.captureH
    Log ("Maa 后台模式：窗口 {0}｜抓图 {1}x{2}｜输入法 {3}" -f $ctx.win.hwndHex, $W, $H, $ctx.inputMethod)

    # ---------- 可选：把 QQ 挪出屏幕再采集（"眼不见为净"，最后一定还原）----------
    # 为什么：Maa 用的是 Windows.Graphics.Capture 的 CreateForWindow ——
    #   **最小化的窗口抓不到**（实测 CreateForCaptureItem failed ret=-2147024809，画面全黑）；
    #   但只要窗口"处于显示状态"，即使**完全在屏幕之外**也能抓到
    #   （2026-10-15 实测：挪到 x=2760 后 Maa 截图 1008x720 全黑=0%，内容正常）。
    # 所以想"看不见 QQ"又不放弃采集，就用"挪出屏幕"，而不是最小化。
    # ⚠️ 默认关闭（qqOffscreen.enabled）—— 它会移动你的窗口；开启后每次采集都会挪+还原。
    $offCfg = if ($cfg.PSObject.Properties.Name -contains 'qqOffscreen') { $cfg.qqOffscreen } else { $null }
    $offSaved = $null
    if ($offCfg -and [bool]$offCfg.enabled) {
      $scr = 1920
      try {
        $vm = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
        if ($vm -and $vm.CurrentHorizontalResolution) { $scr = [int]$vm.CurrentHorizontalResolution }
      } catch { }
      $offSaved = Move-QqOffscreen -Hwnd $ctx.win.hwnd -ScreenWidth $scr
      if ($offSaved) {
        Save-QqMoveState -Saved $offSaved
        Log ("  已把 QQ 挪出屏幕（x={0}）→ 采集完会还原到 ({1},{2})" -f $offSaved.offX, $offSaved.left, $offSaved.top)
        Start-Sleep -Milliseconds 800
      } else {
        Log '  （qqOffscreen 已开启，但窗口本就不可见/最小化 → 跳过挪动）'
      }
    }

    # 按群规则：某群"只采带这些关键词的"（QQ 默认 all = 全部消息）
    $chatRules = $null
    if ($cfg.PSObject.Properties.Name -contains 'chatRules') { $chatRules = $cfg.chatRules }

    # ② 先把会话列表滚回**顶部**再读：列表停在中间位置时，网格行和实际行对不齐
    #    （实测：滚到中间后行名会归错行 → 白名单匹配从 4~5 个掉到 2 个，后面全乱）。
    #    这里用真实滚轮向上滚足量（滚轮对 QQ 有效，Maa 的 PostScroll 无效）。
    $wl = @($cfg.groupWhitelist | Where-Object { $_ })

    # 预检（2026-10-26）：**滚到顶部之前**先抓一张图，看有没有「返回/群助手」标记。
    # 为什么必须提前：实测滚轮会把「群助手」浮层滚掉 —— 滚完再检测就永远读不到那一行，
    # 日志永远是"没读到返回"，于是既不自动退回，还会把群助手里的会话当成白名单群采下来
    # （实测误采了 "2026某学校二手跳蚤市场"）。
    $preBackRow = $null; $preAsstRow = $null
    $preW = 0.0; $preH = 0.0
    try {
      # 预检（2026-10-26 后台无感改造）：**优先用 Maa 抓图**，因为它不抢焦点、不需要窗口在前台。
      #   之前用屏幕截图是因为 968x720 的抓图里读不到「〈 返回」那一行（OCR 从昵称直接跳到
      #   第一条会话，y=20~130 整段被跳过）。现在抓图是原始分辨率（1267x942），顶部那行能读到了，
      #   所以默认走抓图；只有抓图完全没看到任何返回/群助手线索、且窗口恰好已在前台时，
      #   才补一次屏幕截图（不为它去抢焦点）。
      $win = $ctx.win
      $preRows = @(); $preW = 0.0; $preH = 0.0; $preSrc = ''
      try {
        $sPre = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-pre-maa.png')
        $preRows = @($sPre.rows); $preW = [double]$ctx.captureW; $preH = [double]$ctx.captureH; $preSrc = '抓图'
      } catch { }
      $scanPre = {
        param($rows, $hgt)
        $bk = $null; $asst = $null
        foreach ($r in ($rows | Sort-Object y)) {
          if ($r.y -gt ($hgt * 0.35)) { continue }
          $tp = ([string]$r.text -replace '\s', '')
          if ($tp -like '*返回*') { $bk = $r; break }
        }
        if (-not $bk) {
          foreach ($r in ($rows | Sort-Object y)) {
            if ($r.y -gt ($hgt * 0.35)) { continue }
            $tp = ([string]$r.text -replace '\s', '')
            if ($tp -like '*群助手*') { $asst = $r; break }
          }
        }
        return @($bk, $asst)
      }
      $hitPre = & $scanPre $preRows $preH
      $preBackRow = $hitPre[0]; $preAsstRow = $hitPre[1]
      # 抓图没线索、且窗口已在前台 → 用屏幕截图再确认一次（不主动抢焦点）
      if (-not $preBackRow -and -not $preAsstRow -and [WxNative]::GetForegroundWindow() -eq $win.hwnd) {
        try {
          $prePass = Get-ScreenRows -Left $win.x -Top $win.y -W $win.w -H $win.h -Tag 'pre'
          $hitPre2 = & $scanPre @($prePass.rows) ([double]$win.h)
          if ($hitPre2[0] -or $hitPre2[1]) {
            $preBackRow = $hitPre2[0]; $preAsstRow = $hitPre2[1]
            $preW = [double]$win.w; $preH = [double]$win.h; $preSrc = '屏幕'
          }
        } catch { }
      }
      if ($preBackRow) { Log ("  预检：滚轮前读到「返回」（{0} y={1}）→ 本轮先退回群聊列表" -f $preSrc, $preBackRow.y) }
      elseif ($preAsstRow) { Log ("  预检：滚轮前见「群助手」标记（{0}）→ 本轮先退回群聊列表" -f $preSrc) }
    } catch { Log ('  预检失败（不影响主流程）：' + $_.Exception.Message) }

    $toTop = if ($cfg.PSObject.Properties['normalizeListToTop']) { [bool]$cfg.normalizeListToTop } else { $true }
    if ($toTop -and -not ($NoAutoClick -or $ReadOpen) -and -not $preBackRow -and -not $preAsstRow) {
      $topNotches = [int]$(if ($cfg.topNotches) { $cfg.topNotches } else { 18 })
      [void](Invoke-QqWheel -Ctx $ctx -Notches (-$topNotches) -SettleMs 500)
      Log ("  已把会话列表滚到顶部（向上 {0} 格）" -f $topNotches)
    }

    $listShot = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-maa-list.png')
    $view0 = Get-QqChatView -Ctx $ctx -Rows $listShot.rows

    # 诊断（2026-10-15 加）：把"滚动之后"上部有没有「返回/群助手」标记记进日志。
    # 为什么需要：实测"采集器跑之前"抓图能看到 〈返回，而采集器**跑完之后**就看不到了 ——
    # 怀疑是"滚到顶部"这一步把群助手子列表滚掉了，导致后面的返回检测永远没机会触发。
    # 这行日志一次就能定论（有标记=我的判据有问题；没标记=滚动把它弄没了）。
    try {
      $dbgTop = @()
      foreach ($r in ($listShot.rows | Sort-Object y)) {
        if ($r.y -gt ($ctx.captureH * 0.22)) { continue }
        $t2 = ([string]$r.text -replace '\s', '')
        if ($t2 -like '*返回*' -or $t2 -like '*群助手*') { $dbgTop += ("y=" + $r.y + "[" + $t2 + "]") }
      }
      if ($dbgTop.Count -gt 0) { Log ('  [诊断] 滚动后上部仍见标记：' + ($dbgTop -join ' ')) }
      else { Log '  [诊断] 滚动后上部没有「返回/群助手」标记' }
    } catch { }

    # 状态自检：当前打开的会话或列表里得看得到白名单群的影子，否则判定"QQ 不在群聊列表"
    # 行距自适应：QQ 缩放会改变行间距（实测 57 → 72），硬编码的行距会让网格错位、名字归错行
    $maxRows = [int]$(if ($cfg.autoReadMaxRows) { $cfg.autoReadMaxRows } else { 12 })
    $auto = Get-QqGridAuto -Ctx $ctx -Rows $listShot.rows -Whitelist $wl -MaxRows $maxRows
    $rowsAll = $auto.rows
    $script:QqPitch = $auto.pitch
    $script:QqFirstY = $auto.first
    $nameOffset = $auto.offset
    Log ("  行距自适应 = {0}px（点击偏移用 {1}，白名单命中 {2} 个{3}）" -f $auto.pitch, $auto.offset, $auto.score, $(if ($auto.rejected) { "，自动量的值偏离配置基准 $($auto.basePitch)px 太多已否决" } else { '' }))
    $wlVisible = @($wl | Where-Object { $g = $_; @($rowsAll | Where-Object { Test-QqPrefix -name $_.name -pattern $g }).Count -gt 0 })
    $curIsWl = $false
    foreach ($g in $wl) { if (Test-QqMatch -name $view0.header -pattern $g) { $curIsWl = $true } }
    Log ("当前打开='" + $view0.header + "'｜列表行 " + $rowsAll.Count + "｜列表里可见白名单群 " + $wlVisible.Count + " 个（" + ($wlVisible -join '、') + "）")
    # 界面漂了（例如误点进"群助手"子列表）→ 尝试返回，**并且验证是否真的回去了**
    #
    # ⚠️ 2026-10-15 加固（原来连续失败 7 次，日志全是「没看到"返回"，不作自动点击」→ 整轮跳过）：
    #
    # 实测根因（抓图比对得出，不是猜）：进入「群助手」子列表时，会话列顶部会出现一行
    #     ← 返回        群助手
    #   位置在**搜索框下面**（本机抓图 1008x720 时约 y≈98，即面板高度 ~14%）。
    #   但 **Maa 的 OCR 读不出这一行**（实测 y=12~96 那几行 OCR 返回空字符串）→
    #   "找『返回』两个字"这个判据**永远不成立** → 从不点击 → 整轮白跑。
    #
    # 现在三层判据（任一命中就点，点完**重新截图验证**，不假装成功）：
    #   ① 真读到「返回」文字（保留原判据，最可靠）
    #   ② 会话列上部出现「群助手」标记行（子列表特征，实测可见）
    #   ③ 列表行异常少（≤2 行）且看不到任何白名单群 → 盲点一次（需 enabled=true）
    # 位置：默认按**行坐标**定位，比写死像素稳；可用 backXRatio / clickYRatio 覆盖。
      # 检测必须走**原始 OCR 行**（$shotRows）：解析后的会话行里没有"返回"按钮那一行；
      # 而且 QQ 的 OCR 行字段是 .text（字符串），不是微信侧的 .texts（数组）——
      # 这两点曾让"找返回两个字"的判据**恒为假**（2026-10-15 实测定位）。
      $shotRows = @($listShot.rows)
    # ⚠️ 2026-10-15 第二次加固：**有标记就返回，不再要求"列表里看不到白名单群"**。
    # 实测：群助手浮层打开时主列表的白名单群**仍然可见**（同一轮既见 〈返回 又见 可见白名单群 2 个），
    # 所以原来那个门槛会让整个检测块不执行 —— 这才是它 7 次失败的最后一层原因。
    # 现在：**检测无条件执行**（有标记就返回，不管列表里看不看得到白名单群）；
    # 只有没看到任何标记时的盲点才仍然要求看不到白名单群（见下面 ③）。
    if ($true) {
      $bkCfg = if ($cfg.PSObject.Properties.Name -contains 'qqBackAssistant') { $cfg.qqBackAssistant } else { $null }
      $bkEnabled = if ($bkCfg) { [bool]$bkCfg.enabled } else { $false }
      $bkMarkers = @('群助手', '返回')
      $bYRatio = if ($bkCfg -and $bkCfg.clickYRatio) { [double]$bkCfg.clickYRatio } else { 0.136 }
      $bXRatio = if ($bkCfg -and $bkCfg.backXRatio) { [double]$bkCfg.backXRatio } else { 0.03 }

      # ① 原判据：真读到"返回"文字
      # ⚠️ 2026-10-26 修：原来门槛是 y ≤ H*0.20（720 高时 =144px），而实测「〈 返回」贴在
      #   搜索框下面、y≈198（≈H*0.275）→ 每次都被 continue 掉，日志永远是"没读到返回"，
      #   于是停在群助手也不会自动退回，还把群助手里的会话当白名单群采了（误采二手市场群）。
      #   放宽到 H*0.35（≈252px）：仍只扫列表上部，不会误判底部普通会话。
      $backRow = $null
      foreach ($r in ($shotRows | Sort-Object y)) {
        if ($r.y -gt ($H * 0.35)) { continue }
        if (($r.text -replace '\s', '') -like '*返回*') { $backRow = $r; break }
      }
      # ② 子列表特征：会话列上部出现「群助手」标记
      $asstRow = $null
      foreach ($r in ($shotRows | Sort-Object y)) {
        if ($r.y -gt ($H * 0.35)) { continue }
        $txt = ([string]$r.text -replace '\s', '')
        foreach ($m in $bkMarkers) { if ($txt -like ('*' + $m + '*')) { $asstRow = $r; break } }
        if ($asstRow) { break }
      }
      $reason = ''; $clickY = $null
      # 2026-10-26：**预检结果优先**，且预检命中时用**真实鼠标点击屏幕坐标**。
      # 为什么不换算成 Maa 抓图坐标再点：Maa 抓的是客户区(969x720)，而 win.h 含标题栏，
      # 按 win.h 换算会让 y 往下偏一行 —— 实测点到了列表里的会话上（"要早起要好好学习"）。
      # 屏幕坐标直接来自窗口截图，不需要任何换算，最可靠（人工验证过这个坐标能退回）。
      $preClicked = $false
      if ($preBackRow) {
        $win0 = $ctx.win
        # +20/+8 是人工实测能退回的偏移（OCR 给的是"〈 返 回"行首坐标；
        # +12 只落到箭头的左边缘，点了会取消选中而不是退回）。
        $px = [int]($win0.x + $preBackRow.x + 20)
        $py = [int]($win0.y + $preBackRow.y + 8)
        $topH = [WxNative]::TopAt($px, $py)
        if ($topH -eq $win0.hwnd) {
          Log ('  → 滚轮前预检读到"返回"：真实鼠标点屏幕 ({0},{1})' -f $px, $py)
          $savedPt = $null
          try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue; $savedPt = [System.Windows.Forms.Cursor]::Position } catch { }
          [WxNative]::Click($px, $py)
          Start-Sleep -Milliseconds 150
          if ($savedPt) { [void][WxNative]::SetCursorPos($savedPt.X, $savedPt.Y) }
          $preClicked = $true
        } else {
          Log ('  预检读到"返回"，但 ({0},{1}) 最顶层不是 QQ（hwnd={2}）→ 不点' -f $px, $py, $topH)
        }
      }
      if (-not $preClicked) {
        if ($preAsstRow) { $reason = '滚轮前预检见「群助手」标记'; $clickY = [int]($H * $bYRatio) }
        elseif ($backRow) { $reason = '顶部读到"返回"'; $clickY = $backRow.y }
        elseif ($asstRow) { $reason = '会话列上部出现「群助手」标记（子列表特征）'; $clickY = [int]($H * $bYRatio) }
        elseif ($bkEnabled -and $rowsAll.Count -le 2) { $reason = ('列表只有 {0} 行、看不到白名单群（盲点）' -f $rowsAll.Count); $clickY = [int]($H * $bYRatio) }
      }

      if ($preClicked -or $null -ne $clickY) {
        if (-not $preClicked) {
          Log ('  → {0}：自动点返回' -f $reason)
          # 读到了「返回」这一行就用它自己的 x（实测 x≈96，用 config 的 0.03 会点到最左边空白处）；
          # 没读到（靠「群助手」标记判定）才退回 config 的 backXRatio。
          $backX = if ($backRow) { [int]($backRow.x + 10) } else { [int][math]::Round($W * $bXRatio) }
          if ($backX -lt 6) { $backX = [int][math]::Round($W * $bXRatio) }
          [void](Invoke-QqClickRow -Ctx $ctx -Row ([pscustomobject]@{ index = 0; y = $clickY; clickX = $backX }) -SettleMs 2000)
        } else {
          Start-Sleep -Milliseconds 1600
        }
        $listShot = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-maa-list.png')
        $view0 = Get-QqChatView -Ctx $ctx -Rows $listShot.rows
        $auto2 = Get-QqGridAuto -Ctx $ctx -Rows $listShot.rows -Whitelist $wl -MaxRows $maxRows
        $rowsAll = $auto2.rows
        $script:QqPitch = $auto2.pitch
        $script:QqFirstY = $auto2.first
        $nameOffset = $auto2.offset
        $wlVisible = @($wl | Where-Object { $g = $_; @($rowsAll | Where-Object { Test-QqPrefix -name $_.name -pattern $g }).Count -gt 0 })
        $curIsWl = $false
        foreach ($g in $wl) { if (Test-QqMatch -name $view0.header -pattern $g) { $curIsWl = $true } }
        # 验证改用**屏幕截图**看上部还有没有「返回」——比"列表行数>2"可靠
        # （群助手子列表也可能有 8 行，旧判据会误报"返回成功"，实测踩到）。
        $stillBack = $false
        try {
          $win1 = $ctx.win
          $chk = Get-ScreenRows -Left $win1.x -Top $win1.y -W $win1.w -H $win1.h -Tag 'pre2'
          $stillBack = @($chk.rows | Where-Object { ((([string]$_.text) -replace '\s', '') -like '*返回*') -and $_.y -le ($win1.h * 0.35) }).Count -gt 0
        } catch { }
        $recovered = (-not $stillBack) -and (($rowsAll.Count -gt 2) -or ($wlVisible.Count -gt 0) -or $curIsWl)
        Log (("  返回{0}：当前打开='{1}'｜列表行 {2}｜可见白名单群 {3} 个" -f `
              $(if ($recovered) { '成功' } else { '**未见效**' }), $view0.header, $rowsAll.Count, $wlVisible.Count))
        if (-not $recovered) {
          Log '  点击未见效 → 这个位置不是返回键（或该面板要别的方式切回）；本轮跳过。请核对 config-qq.json 的 qqBackAssistant.backXRatio / clickYRatio'
        }
      } else {
        Log '  （没读到"返回"、上部也没有「群助手」标记、行数也不异常 → 不作自动点击）'
      }
    }
    if (-not $curIsWl -and $wlVisible.Count -eq 0) {
      Log '⚠️ 既没打开白名单群、列表里也看不到白名单群 → QQ 可能不在「群聊」列表（需手动切回）；本轮跳过'
      return 0
    }

    $state = Get-StateMap $stateFile
    $records = @()
    $newState = @{}
    $foundGroups = @{}
    $md5 = [System.Security.Cryptography.MD5]::Create()

    # 当前已打开的白名单群：直接读，不用点
    if ($curIsWl) {
      $hit0 = ''
      foreach ($g in $wl) { if (Test-QqMatch -name $view0.header -pattern $g) { $hit0 = $g } }
      $h0 = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($view0.text))) -replace '-', ''
      if ($state.ContainsKey(('maa|' + $hit0)) -and $state[('maa|' + $hit0)] -eq $h0) {
        Log ("（已打开：" + $hit0 + " 内容没变化）")
      } elseif ($view0.chars -ge 4) {
        # 群名清理：头部可能被 OCR 读成预览行（实测"示例学校新闻栏目编导莹钍：剧场票“．"），
        # 带冒号或过长时改用白名单词。⚠️ 冒号判断用**原始串**（Norm 会把标点删掉）。
        $name0 = [string]$view0.header
        $n0 = Norm $name0
        if ($n0.Length -lt 2 -or $name0.Contains('：') -or $name0.Contains(':') -or $n0.Length -gt 24) { $name0 = $hit0 }
        # R6（2026-10-27）：当前打开的这个群也带结构化发送时间（最旧那条时间戳）
        $times0 = Get-ChatTimesFromLines -Lines @($view0.lines) -Now (Get-PassNow)
        $sendIso0 = if ($times0.oldest) { $times0.oldest.ToString('o') } else { $null }
        $records += [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'qq-maa'
          chat = $name0; expected = $hit0; verified = $true; changed = $true
          sendTime = $sendIso0
          text = ($name0 + "`n" + $view0.text)
          lines = @($view0.lines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.text } })
        }
        $rule0 = Get-ChatRule -Name $hit0 -Rules $chatRules -DefaultMode 'all' -DefaultKeywords @()
        # 2026-10-26：与正文过滤统一走 Test-BroadcastKeyword（内置"告知所有人"全套词 + OCR 容错）
        if ($rule0.mode -ne 'all' -and -not (Test-BroadcastKeyword -Text $view0.text -ExtraKeywords $rule0.keywords)) {
          Log ("当前打开的 " + $hit0 + " 按规则只采[{0}]，本条没命中 → 不收" -f ($rule0.keywords -join '/'))
        } else {
          $newState[('maa|' + $hit0)] = $h0
          Log ("当前打开的白名单群：" + $hit0 + " → 收下 " + $view0.chars + " 字")
        }
      }
      if ($hit0) { $foundGroups[$hit0] = $true }
    }

    # ---------- 逐行点开候选（行名粗筛只是省时间；真正的白名单判定用点开后的聊天头部） ----------
    # ⚠️ 2026-10-15 修：`$prevFg`（"收尾时把前台窗口还回去"用的）原来**只在下面的 else 分支里赋值**，
    #    所以走 `-ReadOpen` 这条路径时它是未定义的 → 第 470 行那个"还原前台窗口"的判断永远为假，
    #    QQ 会被一直留在前台（静默，不报错）。这里提到分支之前，两条路径都能记住。
    $prevFg = [WxNative]::GetForegroundWindow()
    if ($NoAutoClick -or $ReadOpen) {
      Log '（-NoAutoClick/-ReadOpen：不逐行点开）'
    } else {
      $settle = if ($cfg.PSObject.Properties['autoReadSettleMs']) { [int]$cfg.autoReadSettleMs } else { 2000 }
      # 是否需要"把 QQ 提到前台"取决于 Maa 的输入方式（2026-10-26 后台无感改造）：
      #   1024 = AnchoredTouch：注入合成触控，**未激活时 QQ 会忽略** → 必须提前台（会打扰用户）。
      #   2 = SendMessage / 4 = PostMessage：直接发窗口消息，**支持后台、不抢焦点、不动鼠标**，
      #       文档明确"抢占鼠标=否、支持后台=是" → 不用提前台，用户完全无感。
      # 配置 maaInputMethod 切换；默认走 SendMessage，失败再退回 AnchoredTouch+提前台。
      $inMethod = if ($cfg.PSObject.Properties['maaInputMethod']) { [int]$cfg.maaInputMethod } else { 2 }
      $needFocus = ($inMethod -eq 1024 -or $inMethod -eq 0)
      if ($needFocus) {
        if (-not (Enable-QqFocus -Ctx $ctx)) {
          Log '  ⚠️ 激活 QQ 失败（SetForegroundWindow 没生效）→ 点击会退回"真实鼠标"方式'
        } else {
          Log '  已把 QQ 提到前台（AnchoredTouch 在未激活时会忽略合成触摸）'
        }
      } else {
        Log ("  后台输入方式 {0}（不抢焦点、不动鼠标）" -f $inMethod)
      }
      # nameOffset 已由上面的"行距自适应"给出（≈行距/2）；这里只在没拿到时兜底。
      # 2026-10-27：兜底值也按抓图高度折算 —— config 里的 28 是按 1079x720 标定的，
      #   换分辨率/DPI 后抓图高度会变（实测 720 / 942 / 1065 都出现过），写死 28 会点到相邻行。
      if (-not $nameOffset -or $nameOffset -le 0) {
        $baseNameOff = if ($cfg.PSObject.Properties['nameClickOffset']) { [double]$cfg.nameClickOffset } else { 28.0 }
        $shotScale = [double]$ctx.captureH / 720.0
        if ($shotScale -le 0) { $shotScale = 1.0 }
        $nameOffset = [int][Math]::Round($baseNameOff * $shotScale)
      }
      # 2026-10-27：点击 x 原来写死 137，**正好落在头像上** → QQ 点头像弹出的是「群资料卡」，
      #   不是进聊天。实测证据：示例群B 的记录里读到「表演部部长杨一诺」「示例学校新闻喙组长刘家佳」
      #   这类成员名（群资料页特征），正文却是空的；同屏其他群能读到 100~200 字。
      #   改成点**群名文字区**（抓图宽 15%，1440 宽时约 216px；群名文字从 x≈150 起）。
      $rowClickX = [int][Math]::Max([double]$ctx.captureW * 0.15, 170.0)
      $script:QqPendingRecords = @()

      # 点一行（2026-10-26 链路适配 · 最终版）：
      #   一律走 Maa 后台点击（不抢焦点、不动鼠标）。原来 raw 模式下改真实鼠标点击，
      #   是因为点击坐标会偏；真因是**点击控制器没设原始尺寸**（抓图和点击是两个控制器），
      #   已在 qqread.ps1 里修掉：两个控制器都设 ScreenshotUseRawSize 后坐标 1:1。
      #   配置 maaClickMode='real' 可强制真实鼠标点击（调试用）。
      function Invoke-QqRowClick {
        param($Row, $SettleMs)
        $clickMode = if ($cfg.PSObject.Properties['maaClickMode']) { [string]$cfg.maaClickMode } else { 'maa' }
        if ($clickMode -eq 'real') {
          $wx0 = [int]$ctx.win.x; $wy0 = [int]$ctx.win.y
          $cx = if ($Row.clickX) { [int]$Row.clickX } else { $rowClickX }
          $px = $wx0 + $cx
          $py = $wy0 + [int]$Row.y
          if (-not [WxNative]::TopAt($px, $py)) {
            Log ("  [跳过·点不到QQ] 屏幕({0},{1}) 最顶层不是 QQ" -f $px, $py)
            return $false
          }
          [WxNative]::Click($px, $py)
          Start-Sleep -Milliseconds ([int]$SettleMs)
          return $true
        }
        [void](Invoke-QqClickRow -Ctx $ctx -Row ([pscustomobject]@{ index = $Row.index; y = $Row.y; clickX = $rowClickX }) -SettleMs $SettleMs)
        return $true
      }

      # ⚠️ 只点一次！QQ 里"再点一下同一个会话"会把聊天区取消选中变空（用户实测反馈 + 日志印证）。
      #    所以这里不做"再点一次重试"，只做"多点几次截图、多等一会儿"。
      # 注意：必须用"函数"而不是 scriptblock —— 脚本块里给 $records/$newState 赋值只会改到子作用域副本，
      #      外层数组不会被更新（实测：日志说"收下"，spool 却一行没写）。收记录/写状态一律在调用方做。
      function Read-QqTarget {
        param($Target, $Settle)
        [void](Invoke-QqRowClick -Row ([pscustomobject]@{ index = $Target.index; y = $Target.y; clickX = $rowClickX }) -SettleMs $Settle)
        $p2 = Join-Path $shotDir 'qq-maa-read.png'
        # 2026-10-27 改：**轮询**等渲染（最多 4 次 ×700ms），不再"只重读一次"。
        #   真机踩到：点开「示例学校新闻」后连续两次读到空画面（标题认不出 + 正文 0 字）→ 整轮跳过这个群；
        #   而人工把该群调出来后同一处能读到 320 字。说明是渲染慢/抓到空帧，不是没内容。
        $s3 = $null; $v3 = $null; $tries = 0
        for ($try = 1; $try -le 4; $try++) {
          $tries = $try
          $s3 = Get-QqShot -Ctx $ctx -Path $p2
          $v3 = Get-QqChatView -Ctx $ctx -Rows $s3.rows
          if ($v3.chars -ge 4 -and -not [string]::IsNullOrWhiteSpace($v3.header)) { break }
          if ($try -lt 4) { Start-Sleep -Milliseconds 700 }
        }
        if ($tries -gt 1) { Log ('  读面板：重试 {0} 次后读到 正文 {1} 字 / 头部「{2}」' -f ($tries - 1), $v3.chars, $v3.header) }
        # ---------- 往期记录（2026-10-19）：聊天区滚轮向上翻几屏 ----------
        # 与微信侧同一套合并算法；注意滚轮必须作用在**聊天区**（Invoke-QqWheel 是列表用的，别混用）。
        # 锚点（2026-10-19）：上一轮记录过的最旧 3 行，读到就停
        # 2026-10-26 改：① key 用**稳定标识**（白名单词，取最长命中），不再用会抖的 OCR 群名；
        #   ② 翻页改成"一直翻到锚点为止"（用户要求：固定 2 屏会漏消息）。
        $qqAnchorFile = Join-Path $stateDir 'seen-anchors.txt'
        $qqStable = Get-ChatStableKey -Name $v3.header -Whitelist @($wl)
        $qqAnchorKey = 'qq|' + $qqStable
        # 2026-10-27：锚点升级成 **文本 + 时间**（用户要求：时间也要作为确认锚点的一部分）。
        #   只比文本时，OCR 抖一两个字就永远命不中 → 白翻到硬上限 40 屏；时间判据不受 OCR 抖动影响。
        $qqAnchorRecs = @(Get-ChatAnchorRecords -AnchorFile $qqAnchorFile -Key $qqAnchorKey -Fuzzy $qqStable -Whitelist @($wl))
        $qqAnchors = @($qqAnchorRecs | ForEach-Object { $_.line })
        # 锚点时间取**最旧**那条（"上次看到这里"的边界）；旧 2 列锚点没有时间 → $null，自动退化成纯文本锚点
        $qqAnchorTime = $null
        $qqTmp = @($qqAnchorRecs | Where-Object { $_.time } | Sort-Object { $_.time })
        if ($qqTmp.Count -gt 0) { $qqAnchorTime = $qqTmp[0].time }
        $qqAnchorHitFirst = Test-ChatAnchorHit -Lines $v3.lines -Anchors $qqAnchors
        # R4（用户原话）：如果当前界面的时间就是上一次锚点的时间 → 没有新消息，不用向上翻滚。
        $curTimes = Get-ChatTimesFromLines -Lines @($v3.lines) -Now (Get-PassNow)
        $qqNoNewByTime = [bool]($qqAnchorTime -and $curTimes.newest -and ($curTimes.newest -le $qqAnchorTime))
        if ($qqAnchorHitFirst -and $qqAnchors.Count -gt 0) {
          Log '  往期滚动：当前屏全是上一轮记录过的内容 → 不往前翻'
        } elseif ($qqNoNewByTime) {
          Log ('  往期滚动：当前屏最新时间 {0:MM-dd HH:mm} ≤ 锚点时间 {1:MM-dd HH:mm} → 没有新消息，不往前翻（不发滚轮）' -f $curTimes.newest, $qqAnchorTime)
        }
        # R5（用户原话）：点进了**非白名单**群聊/资料卡时，不许翻滚它的历史，直接识别出来去点白名单群。
        #   原来翻页循环在"白名单判定"（下面的 $h3 那一段）**之前**，所以点错一次就把那个群的历史整段翻一遍。
        #   这里的粗判比 $h3 那套**更宽松**（头部 or 列表行名任一命中即可）—— 宁可多收，不可漏；
        #   完整的白名单判定仍然在下面，一点不动。
        $preHit = ''
        foreach ($g in $wl) { if (Test-QqMatch -name $v3.header -pattern $g) { $preHit = $g } }
        if (-not $preHit -and $Target.guess) {
          $nm5 = Norm ([string]$Target.name)
          $best5 = ''
          foreach ($g in @($Target.guess -split '/')) {
            if ($g -and $nm5.Contains((Norm $g)) -and (Norm $g).Length -gt (Norm $best5).Length) { $best5 = $g }
          }
          if ($best5) { $preHit = $best5 }
        }
        $histInitial = if ($cfg.PSObject.Properties['qqHistoryScreens']) { [int]$cfg.qqHistoryScreens } else { 2 }
        $histHardMax = if ($cfg.PSObject.Properties['qqHistoryMaxScreens']) { [int]$cfg.qqHistoryMaxScreens } else { 40 }
        $histUntilAnchor = if ($cfg.PSObject.Properties['qqHistoryUntilAnchor']) { [bool]$cfg.qqHistoryUntilAnchor } else { $true }
        $histN = if ($histUntilAnchor -and ($qqAnchors.Count -gt 0 -or $qqAnchorTime)) { $histHardMax } else { $histInitial }
        # 不翻的三种情况：① 不在白名单（R5）② 当前屏就是上次的记录（文本）③ 时间上也没有新消息（R4）
        if (-not $preHit -or $qqAnchorHitFirst -or $qqNoNewByTime) { $histN = 0 }
        if (-not $preHit) {
          Log ("  目标 y={0} 头部'{1}' 不在白名单 → 不翻历史，直接去找白名单群" -f $Target.y, $v3.header)
        }
        $histNotches = if ($cfg.PSObject.Properties['qqHistoryNotches']) { [int]$cfg.qqHistoryNotches } else { 3 }
        $histSettle = if ($cfg.PSObject.Properties['qqHistorySettleMs']) { [int]$cfg.qqHistorySettleMs } else { 600 }
        $histMax = if ($cfg.PSObject.Properties['qqHistoryMaxLines']) { [int]$cfg.qqHistoryMaxLines } else { 150 }
        if ($histN -gt 0 -and $histNotches -gt 0 -and $v3.chars -ge 4) {
          Log ("  往期滚动：目标=翻到上次记录的边界（上限 {0} 屏）" -f $histN)
          $screens = @(, @($v3.lines))
          $scrolled = 0
          for ($hi = 1; $hi -le $histN; $hi++) {
            try {
              [void](Invoke-QqChatWheel -Ctx $ctx -Notches (-$histNotches) -SettleMs $histSettle)
              $ph = Join-Path $shotDir ('qq-hist-{0}.png' -f $hi)
              $sh = Get-QqShot -Ctx $ctx -Path $ph
              $vh = Get-QqChatView -Ctx $ctx -Rows $sh.rows
              $scrolled++
              if ($vh.chars -lt 4) { Log ('  往期滚动：第 {0} 屏读不到内容（可能到顶）→ 停止' -f $hi); break }
              # 到顶判断跟**上一屏**比（$screens 最后一项），不是最新那一屏：
              # 以前比 $screens[0]，翻到第 3 屏以后到顶也发现不了，会白滚到硬上限。
              if ((($vh.lines -join "`n")) -eq ((@($screens[$screens.Count - 1])) -join "`n")) { Log ('  往期滚动：第 {0} 屏与上一屏相同（没滚动/到顶）→ 停止' -f $hi); break }
              # 停止条件（2026-10-27）：文本命中 **或** 时间越过锚点。
              #   原来只有文本判据 —— OCR 抖一两个字就永远命不中，于是白滚到硬上限 40 屏。
              $vhHitText = Test-ChatAnchorHit -Lines $vh.lines -Anchors $qqAnchors
              $vhHitTime = $false
              if ($qqAnchorTime) {
                $vhTimes = Get-ChatTimesFromLines -Lines @($vh.lines) -Now (Get-PassNow)
                $vhHitTime = [bool]($vhTimes.oldest -and ($vhTimes.oldest -le $qqAnchorTime))
                if ($vhHitTime) { $vhHitWhy = ('时间越过：本屏最旧 {0:MM-dd HH:mm} ≤ 锚点 {1:MM-dd HH:mm}' -f $vhTimes.oldest, $qqAnchorTime) }
              }
              if ($vhHitText -or $vhHitTime) {
                $screens += , @($vh.lines)
                $whyStop = @()
                if ($vhHitText) { $whyStop += '文本命中锚点' }
                if ($vhHitTime) { $whyStop += $vhHitWhy }
                Log ('  往期滚动：第 {0} 屏到达上次记录的边界（{1}）→ 停止' -f $hi, ($whyStop -join '；'))
                break
              }
              $screens += , @($vh.lines)
            } catch {
              Log ('  往期滚动第 {0} 屏失败：{1}' -f $hi, $_.Exception.Message)
              break
            }
          }
          if ($scrolled -gt 0) {
            try { [void](Invoke-QqChatWheel -Ctx $ctx -Notches ($histNotches * $scrolled + 2) -SettleMs 400) } catch { }
            $mergedLines = Merge-ChatScreens -Screens $screens -Header $v3.header -MaxLines $histMax -Log { param($m) Log $m }
            $mergedText = ($mergedLines -join "`n")
            $v3 = [pscustomobject]@{ text = $mergedText; header = $v3.header; chars = $mergedText.Length; lines = $mergedLines }
            Log ('  往期滚动：翻了 {0} 屏 → 合并 {1} 行 / {2} 字（已滚回底部）' -f $scrolled, $mergedLines.Count, $v3.chars)
          }
        }
        $h3 = ''
        foreach ($g in $wl) { if (Test-QqMatch -name $v3.header -pattern $g) { $h3 = $g } }
        if (-not $h3 -and $Target.guess) {
          # 兜底（2026-10-26）：头部 OCR 有时整行乱码 —— 实测点开 示例群B，头部被读成
          #   "佣迮1」旧儼，找1刂，卜芸十冫莎泞」多，" → 判"不在白名单" → 整轮漏掉 示例群B。
          # 但**列表里那一行的群名是清楚的**。所以：行名严格包含白名单词（不做容错）时，
          # 就按该群收下（内容仍是点开后读到的正文，不伪造）。
          $nm3 = Norm ([string]$Target.name)
          # 取**最长**的那个匹配（"26示例部门小组"同时命中"示例部门"和"示例部门小组"，
          # 必须取更具体的"示例部门小组"，否则会和"示例部门-示例群C"撞成同一个群）。
          $bestG = ''
          foreach ($g in @($Target.guess -split '/')) {
            if ($g -and $nm3.Contains((Norm $g)) -and (Norm $g).Length -gt (Norm $bestG).Length) { $bestG = $g }
          }
          if ($bestG) {
            $h3 = $bestG
            Log ("  目标 y={0} → 头部认不出，但列表行名'{1}'严格命中「{2}」→ 按该群收下" -f $Target.y, $Target.name, $bestG)
          }
        }
        if (-not $h3) { Log ("  目标 y={0} → 头部'{1}' 不在白名单，跳过" -f $Target.y, $v3.header) }
        elseif ($v3.chars -lt 4) { Log ("  目标 y={0} → {1} 正文太短（{2} 字），跳过" -f $Target.y, $h3, $v3.chars); $h3 = '' }
        return [pscustomobject]@{ hit = $h3; text = $v3.text; header = $v3.header; chars = $v3.chars; lines = $v3.lines; rowName = ([string]$Target.name) }
      }

      # 判断一条读取结果是否要收下：哈希写进 $newState（哈希表是可变的，能跨作用域生效），
      # 但**新记录对象要 return 给调用方**去 append —— 因为嵌套函数里 `$数组 += x` 只重绑本地副本，
      # 外层数组不会变（实测：日志说"收下"，spool 一行没写）。
      function Add-QqResult {
        param($Result)
        if (-not $Result.hit) { return $null }
        $foundGroups[$Result.hit] = $true
        $ruleR = Get-ChatRule -Name $Result.hit -Rules $chatRules -DefaultMode 'all' -DefaultKeywords @()
        # 2026-10-26：改用 Test-BroadcastKeyword —— 内置"告知所有人"全套词 + OCR 容错，
        # 配置里的 keywords 作为附加词（短词/完整名写哪种白名单都适用）。
        if ($ruleR.mode -ne 'all' -and -not (Test-BroadcastKeyword -Text $Result.text -ExtraKeywords $ruleR.keywords)) {
          Log ("  {0} 按规则只采[{1}]，本条没命中 → 不收" -f $Result.hit, (@(Get-BroadcastKeywords) + @($ruleR.keywords) -join '/'))
          return $null
        }
        $hh = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Result.text))) -replace '-', ''
        # 去重要同时看"本轮已经收过的"（$newState）和"上一轮落盘的"（$state）——
        # 只看 $state 的话，同一个群在同一轮里被读两次（比如"当前已打开"+"点开候选"）会写两条重复记录。
        $prevHash = $null
        $key = 'maa|' + $Result.hit
        if ($newState.ContainsKey($key)) { $prevHash = $newState[$key] }
        elseif ($state.ContainsKey($key)) { $prevHash = $state[$key] }
        if ($prevHash -eq $hh) {
          Log ("  {0} 内容没变化，跳过" -f $Result.hit)
          return $null
        }
        $newState[('maa|' + $Result.hit)] = $hh
        Log ("  {0} → 收下 {1} 字" -f $Result.hit, $Result.chars)
        # 群名（写进 chat 字段）优先用"头部 OCR 认出来的"；头部是乱码时（实测示例群I被读成
        # "确定选鞅剁瞬翦，我们不会干涉特别多，"）退回**列表行名**，别把乱码写进待办。
        $chatName = $Result.header
        if ($Result.rowName) {
          $hdrRaw = [string]$Result.header
          $rowRaw = [string]$Result.rowName
          $hdrNorm = Norm $hdrRaw
          $rowNorm = Norm $rowRaw
          # ⚠️ 判"带不带冒号"必须用**原始串**：Norm 会把 ：: ，。 等标点全删掉，
          #   用 Norm 后的串判断永远为 false（实测踩过这个坑）。
          # 头部不可信：空/乱码、不含白名单词、带冒号（说明读到的是预览行）、明显过长。
          # 实测头部被读成"示例学校新闻栏目编导莹钍：剧场票“．"——它包含"示例学校新闻"，
          # 只判断"含不含白名单词"会误判为可信，于是把预览行当群名写进待办。
          $hdrBad = ($hdrNorm.Length -lt 2) -or
                    (-not $hdrNorm.Contains((Norm $Result.hit))) -or
                    $hdrRaw.Contains('：') -or $hdrRaw.Contains(':') -or
                    ($hdrNorm.Length -gt 24)
          if ($hdrBad) {
            $chatName = $rowRaw
            if ($rowRaw.Contains('：') -or $rowRaw.Contains(':') -or $rowNorm.Length -gt 24) { $chatName = $Result.hit }
          }
        }
        # 锚点时间（2026-10-27）= 本轮读到的**最旧**那条时间戳，也就是"上次看到这里"的边界。
        $recTimes = Get-ChatTimesFromLines -Lines @($Result.lines) -Now (Get-PassNow)
        if (-not $Peek) { try { Save-ChatAnchors -AnchorFile (Join-Path $stateDir 'seen-anchors.txt') -Key ('qq|' + (Get-ChatStableKey -Name $Result.header -Whitelist @($wl))) -Lines @($Result.lines | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.text } }) -ConsolidateFuzzy (Get-ChatStableKey -Name $Result.header -Whitelist @($wl)) -ConsolidateWhitelist @($wl) -Time $recTimes.oldest } catch { } }
        # R6（2026-10-27）：消息的**发送时间**单独结构化（以前只有正文第一行的 "昨天19：22"，下游没法用）。
        #   text 保持原样不动（下游提示词不用改），只多一个 sendTime 字段。
        $sendIso = if ($recTimes.oldest) { $recTimes.oldest.ToString('o') } else { $null }
        return [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'qq-maa'
          chat = $chatName; expected = $Result.hit; verified = $true; changed = $true
          sendTime = $sendIso
          text = ($chatName + "`n" + $Result.text)
          lines = @($Result.lines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.text } })
        }
      }

      # 从一屏 OCR 里挑出"要点的行" —— **每行最多一个点击点**（QQ 里对已选中会话再点一下会取消选中！）
      # 选点规则：优先"名字+偏移"（实测点开正确）；只有当它和别的行的网格中心撞车时才用网格中心。
      function Get-QqTargets {
        param($RowsIn)
        $TS_TOL = 20
        $gridYs = @($RowsIn | ForEach-Object { $_.y })
        $ts = @()
        foreach ($r in $RowsIn) {
          # 2026-10-26：跳过「群助手」这一行。它不是群，是导航入口 —— 点进去会把整轮带进
          # 子列表，之后所有点击都落在子列表里，白名单群全漏（实测：点了它之后"示例群I"没采到，
          # 兜底时抓到的也是子列表的会话）。
          if ((Norm $r.name) -like '*群助手*') { continue }
          $pre = @($wl | Where-Object { Test-QqPrefix -name $r.name -pattern $_ })
          # scanAllRows：OCR 经常读不出某些群的**名字行**（只读到预览行）→ 只挑"名字像白名单"的行会漏群。
          # 打开后就把可见的行都点一遍，真正的判定交给点开后的**聊天头部**（更可靠，代价是会把点到的会话标记已读）。
          $scanAll = if ($cfg.PSObject.Properties['scanAllRows']) { [bool]$cfg.scanAllRows } else { $false }
          if ($pre.Count -eq 0) {
            if (-not $scanAll) { continue }
            # ⚠️ 2026-10-15 修：这里原来写的是 `$Ctx`（大写 C），而本函数作用域里只有 `$ctx`（小写）。
            #    PowerShell 变量不区分大小写，但 `$Ctx` 在该函数里**从未被赋值** → 表达式恒为 $null →
            #    `$null -gt 数字` 为 false → 这道"太靠下的行别点"的闸门**恒等于 no-op**（另一台机器审阅时发现）。
            if ($ctx -and $r.y -gt ($ctx.captureH * 0.95)) { continue }
          }
          # 优先用"该行文字定位"的 clickY（与行距/缩放无关）；没有才退回网格推算
          if ($r.clickY) {
            $y = [int]$r.clickY; $which = '文字定位'
          } else {
            $candY = $r.y + $nameOffset
            $hitNeighbor = @($gridYs | Where-Object { $_ -ne $r.y -and [Math]::Abs($_ - $candY) -lt $TS_TOL }).Count -gt 0
            if ($hitNeighbor) { $y = $r.y; $which = '网格中心' } else { $y = $candY; $which = '名字+偏移' }
          }
          if (@($ts | Where-Object { [Math]::Abs($_.y - $y) -lt $TS_TOL }).Count -gt 0) { continue }
          $ts += [pscustomobject]@{ index = $r.index; y = $y; which = $which; name = $r.name; guess = ($pre -join '/') }
        }
        return , $ts
      }

      # 采集一屏候选：截图 → 解析候选行 → 逐个点开读 → 收记录；返回找到的群数
      function Invoke-QqScreen {
        param($Settle, [int]$MaxTargets = 0)
        $shotT = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-maa-list.png')
        # 用校准过的行距/首行（Get-QqGridAuto 在 Maa pass 开头算好的 $script:QqPitch / QqFirstY）
        $rowsT = Get-QqSessionRows -Ctx $ctx -Rows $shotT.rows -MaxRows ([int]$(if ($cfg.autoReadMaxRows) { $cfg.autoReadMaxRows } else { 12 })) -RowHeightOverride $script:QqPitch -FirstRowYOverride $script:QqFirstY
        $ts = Get-QqTargets -RowsIn $rowsT
        if ($MaxTargets -gt 0 -and $ts.Count -gt $MaxTargets) { $ts = @($ts | Select-Object -First $MaxTargets) }
        Log ("  本屏候选 {0} 个（每行只点一次）" -f $ts.Count)
        $found = 0
        foreach ($t in $ts) {
          $script:QqDoneYs += $t.y
          $r = Read-QqTarget -Target $t -Settle $Settle
          $rec = Add-QqResult -Result $r
          if ($rec) { $script:QqPendingRecords += , $rec; $found++ }
        }
        return $found
      }
      # 记录"本轮已经点过的 y"（$script: 作用域，函数里也要能加）：即使列表重排/滚动后再解析，
      # 也不会对同一行点第二次 —— 对已选中的 QQ 会话再点一下会把聊天区点空。
      $script:QqDoneYs = @()
      # 兜底专用去重集合（2026-10-26）：兜底**允许再点一次正常路径点过的行**。
      # 为什么：正常路径按"网格行名"判定，网格错位时行名会取到预览行 → 明明点开了示例群I，
      # 却因为名字对不上而丢弃；兜底用**原始 OCR 行**匹配（"第 一 次 月 视 频"），
      # 若沿用 QqDoneYs 就会被"已点过"挡掉，兜底形同虚设。
      $script:QqFallbackYs = @()

      # ⓿ 先把会话列表滚到**顶部**（2026-10-27 新增）。
      #   事故：10-26 16:52~17:05 那轮没读到 示例群B —— 查下来的真因是**采集器从不回顶**：
      #   它只从"列表当前停留的位置"往下读，列表停在中间时，上方的群永远读不到。
      #   注意两点（都是实测踩过的）：
      #     ① 必须用**真实滚轮** Invoke-QqWheel —— Maa 的 Scroll 对 QQ 列表纹丝不动（全部返回 True 但界面没动）；
      #     ② 判据用"再滚一屏后 OCR 内容没变化"＝到顶了，不靠固定次数。
      if (-not $ReadOpen) {
        $toTopMax = if ($cfg.PSObject.Properties['listToTopRounds']) { [int]$cfg.listToTopRounds } else { 8 }
        $prevSig = ''
        $moved = 0
        for ($ti = 0; $ti -lt $toTopMax; $ti++) {
          $sTop = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir ("qq-top-{0}.png" -f $ti))
          $sigNow = (@($sTop.rows | Where-Object { $_.x -lt ([double]$ctx.captureW * 0.42) } | Sort-Object y | ForEach-Object { [string]$_.text }) -join '|')
          if ($ti -gt 0 -and $sigNow -eq $prevSig) { break }
          $prevSig = $sigNow
          [void](Invoke-QqWheel -Ctx $ctx -Notches (-5) -SettleMs 550)
          $moved++
        }
        Log ("  会话列表已滚到顶部（真实滚轮 {0} 次）" -f $moved)
      }

      # ① 先处理当前这一屏
      [void](Invoke-QqScreen -Settle $settle)

      # ② 再滚回列表顶部读一屏（可选；实测回滚不稳定，默认关）
      $topPass = if ($cfg.PSObject.Properties['topPassScroll']) { [int]$cfg.topPassScroll } else { 0 }
      if ($topPass -gt 0) {
        $missingTop = @($wl | Where-Object { $g = $_; -not ($foundGroups.ContainsKey($g)) })
        if ($missingTop.Count -gt 0) {
          Log ("  回到顶部再读一屏（还缺：{0}）" -f ($missingTop -join '、'))
          [void](Invoke-QqScrollList -Ctx $ctx -Direction 'up' -Times $topPass -SettleMs 500)
          Start-Sleep -Milliseconds 1200
          [void](Invoke-QqScreen -Settle $settle)
        }
      }
      # ③ 滚动找群：首屏没看到的白名单群，用**真实滚轮**把列表翻出来（用户要求）
      #
      # 为什么不用 Maa 的滚动：实测 MaaControllerPostScroll 用 2/4/32/64/128/256 六种输入法
      # **全部返回 True 但 QQ 列表纹丝不动**；真实滚轮事件（mouse_event WHEEL）才有效。
      # 滚轮需要光标在列表上，Invoke-QqWheel 会临时移过去、滚完还原。
      $scrollSearchSteps = if ($cfg.PSObject.Properties['scrollSearchSteps']) { [int]$cfg.scrollSearchSteps } else { 8 }
      if (-not ($NoAutoClick -or $ReadOpen) -and $scrollSearchSteps -gt 0) {
        $missingNow = @($wl | Where-Object { $g = $_; -not ($foundGroups.ContainsKey($g)) })
        if ($missingNow.Count -gt 0) {
          Log ("  滚动找群：还缺 {0}（最多滚 {1} 步，每步 2 格）" -f ($missingNow -join '、'), $scrollSearchSteps)
          $rolled = 0
          $rejectedNames = @()
          for ($step = 1; $step -le $scrollSearchSteps; $step++) {
            [void](Invoke-QqWheel -Ctx $ctx -Notches 2)
            $rolled += 2
            $s5 = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-maa-list.png')
            $auto5 = Get-QqGridAuto -Ctx $ctx -Rows $s5.rows -Whitelist $missingNow -MaxRows $maxRows
            $rows5 = $auto5.rows
            # 只挑"还没读到的那些群"对应的行（列表已滚动，y 位置的含义变了，所以不能沿用 $script:QqDoneYs）
            $t5 = @()
            foreach ($r in $rows5) {
              $pre = @($missingNow | Where-Object { Test-QqPrefix -name $r.name -pattern $_ })
              if ($pre.Count -eq 0) { continue }
              # 过滤①：白名单里带数字的，行名必须**精确**含那段数字（OCR 对数字很准；实测不加这条会把
              #          "2020级初三9班" 当成 "2026级…" 的候选）
              $pre = @($pre | Where-Object {
                  $dg = [regex]::Matches((Norm $_), '\d{2,}') | ForEach-Object { $_.Value }
                  ($dg.Count -eq 0) -or (@($dg | Where-Object { (Norm $r.name).Contains($_) }).Count -eq $dg.Count)
                })
              if ($pre.Count -eq 0) { continue }
              # 过滤②：这一轮已经点过、且头部不是白名单群的那些"行名"不再重复点
              #         （实测：'某学校．' 被连点三次，每次都是"…临时会话"）
              $rn = Norm $r.name
              if (@($rejectedNames | Where-Object { $w = $_; $rn.Length -ge 2 -and ($w.StartsWith($rn) -or $rn.StartsWith($w)) }).Count -gt 0) { continue }
              if ($r.clickY) { $y = [int]$r.clickY }
              else {
                $candY = $r.y + $nameOffset
                $gridYs = @($rows5 | ForEach-Object { $_.y })
                $hitNeighbor = @($gridYs | Where-Object { $_ -ne $r.y -and [Math]::Abs($_ - $candY) -lt 20 }).Count -gt 0
                $y = if ($hitNeighbor) { $r.y } else { $candY }
              }
              if (@($t5 | Where-Object { [Math]::Abs($_.y - $y) -lt 20 }).Count -gt 0) { continue }
              $t5 += [pscustomobject]@{ index = $r.index; y = $y; which = $(if ($hitNeighbor) { '网格中心' } else { '名字+偏移' }); name = $r.name; guess = ($pre -join '/') }
            }
            foreach ($t in $t5) {
              Log ("    滚动第 {0} 步看到候选 '{1}' → 点开读" -f $step, $t.name)
              $r5 = Read-QqTarget -Target $t -Settle $settle
              if ($r5.hit) {
                $rec5 = Add-QqResult -Result $r5
                if ($rec5) { $script:QqPendingRecords += , $rec5 }
              } else {
                $rejectedNames += (Norm $t.name)   # 记住这行不是白名单群，本轮别再点同类行
              }
            }
            $missingNow = @($wl | Where-Object { $g = $_; -not ($foundGroups.ContainsKey($g)) })
            if ($missingNow.Count -eq 0) { Log ("    滚动 {0} 步后白名单群全部找到" -f $step); break }
            # 一步都没看到候选就继续滚；连续 3 步无候选说明到底了
            if ($t5.Count -eq 0 -and $step -ge 3) { Log '    连续滚动都没看到候选（可能已到底）'; }
          }
          if ($rolled -gt 0) {
            [void](Invoke-QqWheel -Ctx $ctx -Notches (-$rolled))
            Log ("    已把列表滚回原位（向上 {0} 格）" -f $rolled)
          }
        }
      }      $stillMissing = @($wl | Where-Object { $g = $_; -not ($foundGroups.ContainsKey($g)) })

      # 兜底（2026-10-26）：OCR 偶尔读到了群名、但 Get-QqSessionRows 的固定行距网格没把它
      #   解析成会话行 → 这个群一次都没被点到（实测 示例群B：原始行明明有「示例群B 有 限 集 团」，
      #   却整轮没点）。这里对还没读到的群，直接按**原始 OCR 行**找关键词，点一次再做头部判定；
      #   点错不记，继续试下一个候选（不影响正常路径）。
      if ($stillMissing.Count -gt 0 -and -not ($NoAutoClick -or $ReadOpen)) {
        try {
          # 兜底用**屏幕截图**（已验证：19:43 那次靠它把 示例群B 和示例群I都补上了）。
          # 为什么不用 Maa 抓图：968x720 的抓图 OCR 会漏行（实测"第 一 次 月 视 频"
          # 整行不存在），屏幕截图 OCR 行数约多一倍，能读到。
          # 坐标换算：屏幕截图坐标 × (抓图/窗口) = 抓图坐标，Maa 点击要抓图坐标。
          $winF = $ctx.win
          $scrF = Get-ScreenRows -Left $winF.x -Top $winF.y -W $winF.w -H $winF.h -Tag 'fallback'
          $raw7 = @($scrF.rows | Sort-Object y)
          $syF = [double]$ctx.captureH / [double]$winF.h
          foreach ($g in $stillMissing) {
            $cands = @($raw7 | Where-Object {
                $t7 = [string]$_.text
                if (($t7 -replace '\s', '').Length -lt 2) { return $false }
                if ($_.y -lt ($winF.h * 0.10) -or $_.y -gt ($winF.h * 0.92)) { return $false }
                (Test-QqPrefix -name $t7 -pattern $g)
              })
            foreach ($c7 in $cands) {
              if ($foundGroups.ContainsKey($g)) { break }
              # 2026-10-27 修：点击 y 原来固定 +18，实测点在「群名文字」下沿、常常点到空隙，
              #   结果是进了群但读到的是空的/头部认不出（10-26 示例群B 那 13 条记录 10 条正文为空）。
              #   改成 30px（按抓图高度等比：抓图 1065 时实测 +30 能稳定进群并读到内容）。
              $cy = [int][math]::Round($c7.y * $syF) + [int][Math]::Round([double]$ctx.captureH * 0.028)
              # 用兜底专用去重集合：允许再点一次正常路径点过的行（网格错位时那一行会被误判丢弃）
              if (@($script:QqFallbackYs | Where-Object { [Math]::Abs($_ - $cy) -lt 22 }).Count -gt 0) { continue }
              $script:QqFallbackYs += $cy
              Log ("    兜底：原始行 '{0}'（y={1}）→ 点开读" -f $c7.text, $c7.y)
              # guess 传**整个白名单**而不是单个 $g：这样"26示例部门小组"能取到更具体的
              # 「示例部门小组」，不会被「示例部门」抢走（实测两者会撞成同一个群）。
              $r7 = Read-QqTarget -Target ([pscustomobject]@{ index = 0; y = $cy; which = '原始行兜底'; name = $c7.text; guess = ($wl -join '/') }) -Settle $settle
              if ($r7.hit) {
                $rec7 = Add-QqResult -Result $r7
                if ($rec7) { $script:QqPendingRecords += , $rec7 }
              }
            }
          }
        } catch { Log ('    兜底点击失败：' + $_.Exception.Message) }
        $stillMissing = @($wl | Where-Object { $g = $_; -not ($foundGroups.ContainsKey($g)) })
      }
      if ($stillMissing.Count -gt 0) { Log ("  本轮没读到的白名单群：" + ($stillMissing -join '、') + "（不在可见列表里）") }
    }

    # 收尾（2026-10-26 用户要求）：采集完如果还停在「群助手」子列表，自动点「返回」回群聊列表；
    # 点完再截一张验证，未见效就如实记日志（不假装成功）。
    # 2026-10-26 后台无感改造：**优先用 Maa 抓图 + Maa 后台点击**（不抢焦点、不动鼠标）。
    #   之前用"屏幕截图 + 真实鼠标"是因为 968x720 的抓图读不到「〈 返回」那一行；
    #   现在抓图是原始分辨率，顶部那行能读到，所以整条收尾链路都能后台完成。
    #   只有抓图完全没看到返回标记、且窗口恰好已在前台时，才补一次屏幕截图（不为它抢焦点）。
    try {
      $winE = $ctx.win
      $endBack = $null; $endSrc = ''
      try {
        $sE = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-end-maa.png')
        $endCapH = [double]$ctx.captureH
        foreach ($r in ($sE.rows | Sort-Object y)) {
          if ($r.y -gt ($endCapH * 0.35)) { continue }
          if ((([string]$r.text) -replace '\s', '') -like '*返回*') { $endBack = $r; $endSrc = '抓图'; break }
        }
      } catch { }
      if (-not $endBack -and [WxNative]::GetForegroundWindow() -eq $winE.hwnd) {
        try {
          $endPass = Get-ScreenRows -Left $winE.x -Top $winE.y -W $winE.w -H $winE.h -Tag 'end'
          foreach ($r in ($endPass.rows | Sort-Object y)) {
            if ($r.y -gt ($winE.h * 0.35)) { continue }
            if ((([string]$r.text) -replace '\s', '') -like '*返回*') { $endBack = $r; $endSrc = '屏幕'; break }
          }
        } catch { }
      }
      if ($endBack) {
        if ($endSrc -eq '抓图') {
          # 抓图坐标 = Maa 点击坐标（两个控制器都设了原始尺寸，1:1）
          $pxE = [int]$endBack.x + 20
          $pyE = [int]$endBack.y + 8
          Log ('  收尾：还停在子列表 → Maa 后台点「返回」({0},{1})' -f $pxE, $pyE)
          [void](Invoke-QqClickRow -Ctx $ctx -Row ([pscustomobject]@{ index = 0; y = $pyE; clickX = $pxE }) -SettleMs 1400)
        } else {
          $pxE = [int]($winE.x + $endBack.x + 20)
          $pyE = [int]($winE.y + $endBack.y + 8)
          Log ('  收尾：还停在子列表 → 真实鼠标点「返回」({0},{1})' -f $pxE, $pyE)
          $savedE = $null
          try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue; $savedE = [System.Windows.Forms.Cursor]::Position } catch { }
          [WxNative]::Click($pxE, $pyE)
          Start-Sleep -Milliseconds 150
          if ($savedE) { [void][WxNative]::SetCursorPos($savedE.X, $savedE.Y) }
          Start-Sleep -Milliseconds 1400
        }
        # 验证：再用抓图看还有没有返回标记
        $stillE = 0
        try {
          $sE2 = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-end-maa2.png')
          $stillE = @($sE2.rows | Where-Object { ((([string]$_.text) -replace '\s', '') -like '*返回*') -and $_.y -le ([double]$ctx.captureH * 0.35) }).Count
        } catch { }
        if ($stillE -gt 0) { Log '  收尾：点了「返回」但仍读到返回标记 → 未退回' }
        else { Log '  收尾：已退回群聊列表' }
      }
    } catch { Log ('  收尾自动返回失败：' + $_.Exception.Message) }

    # 收集到的记录是在嵌套函数里产生的（那里不能直接 append 外层数组）→ 这里合并
    # 收尾：把采集前的前台窗口还回去（别让 QQ 一直压着用户的窗口）
    if ($prevFg -and $prevFg -ne [IntPtr]::Zero -and ([WxNative]::GetForegroundWindow() -ne $prevFg)) {
      [void][WxNative]::SetForegroundWindow($prevFg)
      Start-Sleep -Milliseconds 300
    }
    if ($script:QqPendingRecords.Count -gt 0) { $records += $script:QqPendingRecords }
    $script:QqPendingRecords = @()
    $md5.Dispose()

    if (-not $Peek) {
      foreach ($r in $records) { Write-Record $r }
      foreach ($k in $newState.Keys) { $state[$k] = $newState[$k] }
      Save-StateMap $state $stateFile
      Log ("本轮写出 {0} 条记录" -f $records.Count)
    } else { Log ("（-Peek：不写；本轮本来会写 {0} 条）" -f $records.Count) }
    return $records.Count
  } finally {
    # ⚠️ 还原 QQ 窗口位置：只要挪过就一定要还原（哪怕中间抛了异常）。
    #    放在 finally 里而不是正常出口，就是为了"采集失败也不会把你的 QQ 留在屏幕外"。
    if ($null -ne $offSaved) {
      try {
        Clear-QqMoveState
        Restore-QqPosition -Hwnd $ctx.win.hwnd -Saved $offSaved
        Log ("  已还原 QQ 窗口位置到 ({0},{1})" -f $offSaved.left, $offSaved.top)
      } catch {
        Log ('  ⚠️ 还原 QQ 窗口位置失败：' + $_.Exception.Message + '（请手动把 QQ 拖回来）')
      }
    }
    Stop-QqRead -Ctx $ctx
    if (-not $SaveShots) {
      foreach ($t in 'qq-maa-list', 'qq-maa-read') {
        Remove-Item -LiteralPath (Join-Path $shotDir ($t + '.png')) -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

# ============ 屏幕截取模式（老办法，兜底） ============
function Invoke-QqScreenPass {
  Log '===== QQ 采集 第 1 轮（屏幕截取模式）====='
  $w = Find-QqMainWindow
  if (-not $w) { Log '跳过：没找到 QQ 主窗口（QQ 没运行 / 主面板没打开）'; $script:skipNote = 'QQ 未运行，本轮跳过（无窗口可采）'; return 0 }

  $info = Get-WxWindowInfo -Hwnd $w.hwnd
  $hidden = ($null -eq $info) -or ($info.minimized) -or ($info.width -lt 300) -or ($info.height -lt 250)
  if ($hidden -and $cfg.restoreIfMinimized) {
    Log 'QQ 窗口不可见 → 尝试恢复'
    [void](Restore-WxWindow -Hwnd $w.hwnd)
    Start-Sleep -Milliseconds 1800
    $info = Get-WxWindowInfo -Hwnd $w.hwnd
    $hidden = ($null -eq $info) -or ($info.minimized) -or ($info.width -lt 300)
  }
  if ($hidden) { Log '跳过：QQ 窗口不可见（点托盘图标打开主面板）'; $script:skipNote = 'QQ 窗口不可见，本轮跳过'; return 0 }
  Log ("窗口 {0}x{1} @ ({2},{3}) hwnd={4}" -f $info.width, $info.height, $info.left, $info.top, $w.hwnd)

  if ($cfg.topmostWhileCapture) { [void][WxNative]::SetWindowPos($w.hwnd, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0043) }
  Start-Sleep -Milliseconds 1200

  $pass = Get-ScreenRows -Left $info.left -Top $info.top -W $info.width -H $info.height -Tag 'list'
  $rows = $pass.rows
  Log ("窗口内 OCR {0} 行" -f $rows.Count)
  if ($DumpRows) { foreach ($r in ($rows | Sort-Object y)) { Write-Host ("  y={0,4} x={1,4} | {2}" -f $r.y, $r.x, $r.text) } }
  if ($rows.Count -eq 0) {
    if ($cfg.topmostWhileCapture) { [void][WxNative]::SetWindowPos($w.hwnd, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0043) }
    Log 'OCR 为空，跳过'; return 0
  }

  # ---------- 只读"当前已打开的那个群" ----------
  if ($ReadOpen -or $cfg.openChatOnly) {
    $header = ''
    foreach ($r in $rows) { if ($r.x -ge ($info.width * 0.5) -and $r.y -lt ($info.height * 0.25)) { $header = $r.text; break } }
    $chatLines = @($rows | Where-Object { $_.x -ge ($info.width * [double]$cfg.chatXFrom) -and $_.y -ge ($info.height * [double]$cfg.chatYFrom) } | Sort-Object y)
    $msgText = (($chatLines | ForEach-Object { $_.text }) -join "`n").Trim()
    $wl0 = @($cfg.groupWhitelist | Where-Object { $_ })
    $hit = ''
    foreach ($g in $wl0) { if (Test-QqMatch -name $header -pattern $g) { $hit = $g } }
    Log ("当前打开的会话头部='" + $header + "' 命中白名单=" + $(if ($hit) { $hit } else { '否' }) + " 正文 " + $msgText.Length + " 字")
    if ($cfg.topmostWhileCapture) { [void][WxNative]::SetWindowPos($w.hwnd, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0043) }
    if (-not $hit -or $msgText.Length -lt 4) {
      if (-not $Peek -and -not $SaveShots) { Remove-Item -LiteralPath (Join-Path $shotDir 'qq-list.png') -Force -ErrorAction SilentlyContinue }
      return 0
    }
    $st0 = Get-StateMap $stateFile
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $h = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($msgText))) -replace '-', ''
    $md5.Dispose()
    if ($st0.ContainsKey(('open|' + $hit)) -and $st0[('open|' + $hit)] -eq $h) { Log '（这个群的内容没变化，跳过）'; return 0 }
    $rec = [ordered]@{
      kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'qq-screen'
      chat = $(if ($header) { $header } else { $hit }); expected = $hit; verified = $true; changed = $true
      text = ($(if ($header) { $header } else { $hit }) + "`n" + $msgText)
      lines = @($chatLines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.text } })
    }
    if (-not $Peek) {
      Write-Record $rec
      $st0[('open|' + $hit)] = $h
      Save-StateMap $st0 $stateFile
      Log '已写出 1 条聊天记录'
    } else { Log '（-Peek：不写）' }
    if (-not $SaveShots) { Remove-Item -LiteralPath (Join-Path $shotDir 'qq-list.png') -Force -ErrorAction SilentlyContinue }
    return 1
  }

  # ---------- 会话列表：粗筛候选 → 点击 → 头部判定 ----------
  $x1 = $info.width * [double]$cfg.sessionXFrom
  $x2 = $info.width * [double]$cfg.sessionXTo
  $y0 = $info.height * [double]$cfg.listYFrom
  $inList = @($rows | Where-Object { $_.x -ge $x1 -and $_.x -le $x2 -and $_.y -ge $y0 })
  Log ("列表区域内 {0} 行" -f $inList.Count)

  $yTol = if ($cfg.yTol) { [int]$cfg.yTol } else { 40 }
  $clusters = @()
  $cur = $null
  foreach ($r in ($inList | Sort-Object y)) {
    if ($null -eq $cur -or ($r.y - $cur.lastY) -gt $yTol) {
      if ($cur) { $clusters += $cur }
      $cur = [pscustomobject]@{ lines = @($r); lastY = $r.y }
    } else {
      $cur.lines += $r
      if ($r.y -gt $cur.lastY) { $cur.lastY = $r.y }
    }
  }
  if ($cur) { $clusters += $cur }
  Log ("识别到 {0} 个会话" -f $clusters.Count)

  $state = Get-StateMap $stateFile
  $wl = @($cfg.groupWhitelist | Where-Object { $_ })
  $records = @()
  $newState = @{}
  foreach ($c in $clusters) {
    $byY = @($c.lines | Sort-Object y)
    $nameLine = $byY[0]
    $name = $nameLine.text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $preview = (($byY | Select-Object -Skip 1 | Where-Object { $_.x -lt ($nameLine.x + 80) } | ForEach-Object { $_.text }) -join ' ').Trim()
    $key = Norm $name

    $maybe = ($wl.Count -eq 0)
    foreach ($g in $wl) { if (Test-QqPrefix -name $name -pattern $g) { $maybe = $true } }
    $newState[$key] = $preview
    Log ("    · " + $name + $(if ($maybe) { '  [候选]' } else { '' }))
    if (-not $maybe) { continue }

    $changed = (-not $state.ContainsKey($key)) -or (Norm $state[$key]) -ne (Norm $preview)
    if (-not $changed) { continue }

    $rec = $null
    if (-not $NoRead -and $cfg.readChat -ne $false) {
      $clickX = [int]($info.left + $nameLine.x - 30)
      $clickY = [int]($info.top + $nameLine.y)
      [void][WxNative]::SetForegroundWindow($w.hwnd)
      Start-Sleep -Milliseconds 250
      $under = [WxNative]::TopAt($clickX, $clickY)
      if ($under -ne $w.hwnd) {
        Log ("  [跳过·点不到QQ] 目标点 (" + $clickX + "," + $clickY + ") 下面是 hwnd=" + $under)
      } else {
        [WxNative]::Click($clickX, $clickY)
        Start-Sleep -Milliseconds ([int]$cfg.clickSettleMs)
        $pane = Get-ScreenRows -Left $info.left -Top $info.top -W $info.width -H $info.height -Tag 'read'
        $header = ''
        foreach ($x in $pane.rows) { if ($x.x -ge ($info.width * 0.5) -and $x.y -lt ($info.height * 0.25)) { $header = $x.text; break } }
        $hitGroup = ''
        foreach ($g in $wl) { if (Test-QqMatch -name $header -pattern $g) { $hitGroup = $g } }
        $chatLines = @($pane.rows | Where-Object { $_.x -ge ($info.width * [double]$cfg.chatXFrom) -and $_.y -ge ($info.height * [double]$cfg.chatYFrom) } | Sort-Object y)
        $msgText = (($chatLines | ForEach-Object { $_.text }) -join "`n").Trim()
        Log ("  → 聊天头部'" + $header + "' 命中白名单=" + $(if ($hitGroup) { $hitGroup } else { '否' }) + " 正文 " + $msgText.Length + " 字")
        if ($hitGroup -and $msgText.Length -ge 4) {
          $realName = if ($header) { $header } else { $name }
          $rec = [ordered]@{
            kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'qq-screen'
            chat = $realName; expected = $hitGroup; verified = $true; changed = $true
            text = ($realName + "`n" + $msgText)
            lines = @($chatLines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.text } })
          }
          $newState[(Norm $realName)] = $preview
        } elseif (-not $hitGroup) {
          Log ("  [忽略·头部不属于白名单] " + $header)
        }
      }
    }
    if (-not $rec) {
      $rec = [ordered]@{
        kind = 'preview'; ts = (Get-Date).ToString('o'); source = 'qq-screen'
        chat = $name; preview = $preview; verified = $true; changed = $true
        text = ($name + "`n" + $preview)
      }
    }
    $records += $rec
    Log ("  [收下] " + $name + "  kind=" + $rec.kind)
  }

  if ($cfg.topmostWhileCapture) { [void][WxNative]::SetWindowPos($w.hwnd, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0043) }

  if (-not $Peek) {
    if ($records.Count -gt 0) {
      foreach ($r in $records) { Write-Record $r }
      Log ("本轮写出 {0} 条记录" -f $records.Count)
    } else { Log '本轮写出 0 条记录（白名单会话没有变化）' }
    Save-StateMap $newState $stateFile
  } else { Log '（-Peek：不写 spool、不更新状态）' }

  if (-not $SaveShots) {
    foreach ($t in 'list', 'read') { Remove-Item -LiteralPath (Join-Path $shotDir ("qq-" + $t + ".png")) -Force -ErrorAction SilentlyContinue }
  }
  return $records.Count
}

function Invoke-QqPass {
  # R1（2026-10-27 用户要求）：记录**本轮命令执行时间**，整轮只取一次。
  #   后面所有"昨天/今天/前天"的时间解析都以它为准（锚点时间判据也靠它）。
  $script:PassNow = Get-Date
  Log ('本轮执行时间 {0:yyyy-MM-dd HH:mm:ss}（相对时间以它为准）' -f $script:PassNow)
  $mode = 'auto'
  if ($MaaMode) { $mode = 'maa' } elseif ($ScreenMode) { $mode = 'screen' } elseif ($cfg.captureMode) { $mode = [string]$cfg.captureMode }
  if ($mode -eq 'maa') { return (Invoke-QqMaaPass) }
  if ($mode -eq 'screen') { return (Invoke-QqScreenPass) }
  # auto：先试 Maa（后台、不抢前台）；不可用再退回屏幕截取
  $script:MaaFailed = $false
  $n = Invoke-QqMaaPass
  if (-not $script:MaaFailed) { return $n }
  Log 'Maa 模式不可用 → 回退屏幕截取模式'
  return (Invoke-QqScreenPass)
}

# ⚠️ 2026-10-15：`exit` 会跳过 Invoke-QqMaaPass 里的 finally，所以"挪出屏幕"的还原**
  # 不能只靠 finally**（实测漏过一次：QQ 被留在屏幕外 (2760,327)，只能手动拖回）。
  # 这里在 exit 之前显式检查并还原；另外启动时还会读状态文件自愈（即使被强杀也救得回来）。
# 启动自愈：上次若被强杀（状态文件还在），先把 QQ 拖回原位再干活
if (Get-Command Restore-QqIfMoved -ErrorAction SilentlyContinue) {
  if (Restore-QqIfMoved) { Write-Host '  [自愈] 检测到上次未还原，已把 QQ 窗口拖回原位' }
}
if ($Once) {
  $script:skipNote = ''
  # 入口层兜底：Invoke-QqPass 里**任何**没被处理的异常都要留下 code=1 的运行状态（否则"崩了"和"没跑"在数据上一样，自检看不见）
  try { [void](Invoke-QqPass) } catch { Log ('本轮崩溃：' + $_.Exception.Message); $script:skipNote = '本轮崩溃：' + $_.Exception.Message }
  if (Get-Command Restore-QqIfMoved -ErrorAction SilentlyContinue) { [void](Restore-QqIfMoved) }
  $crash = ($script:skipNote -match '^本轮崩溃')
  Write-RunStatus -Name '采集器-QQ' -Code $(if ($crash) { 1 } else { 0 }) -Note $script:skipNote
  exit $(if ($crash) { 1 } else { 0 })
}
while ($true) {
  $script:skipNote = ''
  try { [void](Invoke-QqPass) } catch { Log ('本轮崩溃：' + $_.Exception.Message); $script:skipNote = '本轮崩溃：' + $_.Exception.Message }
  $crash = ($script:skipNote -match '^本轮崩溃')
  Write-RunStatus -Name '采集器-QQ' -Code $(if ($crash) { 1 } else { 0 }) -Note $script:skipNote
  Start-Sleep -Seconds $Interval
}
# ↑ 写在**入口这一层**：不管走 Maa / 屏幕模式 / Maa 失败回退 / 崩溃，每轮都会留下状态记录
#   （1550 版只写在 Maa 成功分支里 → 没装 Maa 的用户永远没有记录，自检看不到它。）
