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
  [switch]$NoAutoClick       # Maa 模式下也只读当前打开的群（不逐行点开）
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'wxlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'dsh-接入\运行状态.ps1')   # 记录本轮结果

$cfgPath = Join-Path $here 'config-qq.json'
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
function Test-QqMatch([string]$name, [string]$pattern) {
  $a = Norm $name; $b = Norm $pattern
  if ([string]::IsNullOrWhiteSpace($b) -or $a.Length -lt 2) { return $false }
  if ($a.Contains($b)) { return $true }
  $maxDist = 2
  if ($b.Length -le 4) { $maxDist = 1 }
  if ($a.Length -lt $b.Length) { return ((Get-Levenshtein $a $b) -le $maxDist) }
  for ($i = 0; $i -le ($a.Length - $b.Length); $i++) {
    if ((Get-Levenshtein $a.Substring($i, $b.Length) $b) -le $maxDist) { return $true }
  }
  return $false
}
# 粗筛（只用来挑"值得点开看看"的行；真正的白名单判定一律用点开后的聊天头部）
# 注意：门槛要严一点 —— "示例群F" 和 "示例群A" 前 4 字只差 1 个字，
#       用 n=4/距离1 会把不相关的群也当候选（实测踩过）。
function Test-QqPrefix([string]$name, [string]$pattern) {
  $a = Norm $name; $b = Norm $pattern
  if ([string]::IsNullOrWhiteSpace($b) -or $a.Length -lt 2) { return $false }
  if ($a.Contains($b)) { return $true }
  $n = [Math]::Min(3, $b.Length)
  $pa = if ($a.Length -ge $n) { $a.Substring(0, $n) } else { $a }
  return ((Get-Levenshtein $pa $b.Substring(0, $n)) -le 1)
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
    $toTop = if ($cfg.PSObject.Properties['normalizeListToTop']) { [bool]$cfg.normalizeListToTop } else { $true }
    if ($toTop -and -not ($NoAutoClick -or $ReadOpen)) {
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
    $auto = Get-QqRowsAuto -Ctx $ctx -Rows $listShot.rows -Whitelist $wl -MaxRows $maxRows
    $rowsAll = $auto.rows
    $script:QqPitch = $auto.pitch
    $nameOffset = $auto.offset
    Log ("  行距自适应 = {0}px（点击偏移用 {1}，白名单命中 {2} 个）" -f $auto.pitch, $auto.offset, $auto.score)
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
      $backRow = $null
      foreach ($r in ($shotRows | Sort-Object y)) {
        if ($r.y -gt ($H * 0.20)) { continue }
        if (($r.text -replace '\s', '') -like '*返回*') { $backRow = $r; break }
      }
      # ② 子列表特征：会话列上部出现「群助手」标记
      $asstRow = $null
      foreach ($r in ($shotRows | Sort-Object y)) {
        if ($r.y -gt ($H * 0.25)) { continue }
        $txt = ([string]$r.text -replace '\s', '')
        foreach ($m in $bkMarkers) { if ($txt -like ('*' + $m + '*')) { $asstRow = $r; break } }
        if ($asstRow) { break }
      }
      $reason = ''; $clickY = $null
      if ($backRow) { $reason = '顶部读到"返回"'; $clickY = $backRow.y }
      elseif ($asstRow) { $reason = '会话列上部出现「群助手」标记（子列表特征）'; $clickY = [int]($H * $bYRatio) }
      elseif ($bkEnabled -and $rowsAll.Count -le 2) { $reason = ('列表只有 {0} 行、看不到白名单群（盲点）' -f $rowsAll.Count); $clickY = [int]($H * $bYRatio) }

      if ($null -ne $clickY) {
        Log ('  → {0}：自动点返回' -f $reason)
        $backX = [int][math]::Round($W * $bXRatio)
        [void](Invoke-QqClickRow -Ctx $ctx -Row ([pscustomobject]@{ index = 0; y = $clickY; clickX = $backX }) -SettleMs 2000)
        $listShot = Get-QqShot -Ctx $ctx -Path (Join-Path $shotDir 'qq-maa-list.png')
        $view0 = Get-QqChatView -Ctx $ctx -Rows $listShot.rows
        $auto2 = Get-QqRowsAuto -Ctx $ctx -Rows $listShot.rows -Whitelist $wl -MaxRows $maxRows
        $rowsAll = $auto2.rows
        $nameOffset = $auto2.offset
        $wlVisible = @($wl | Where-Object { $g = $_; @($rowsAll | Where-Object { Test-QqPrefix -name $_.name -pattern $g }).Count -gt 0 })
        $curIsWl = $false
        foreach ($g in $wl) { if (Test-QqMatch -name $view0.header -pattern $g) { $curIsWl = $true } }
        $recovered = ($rowsAll.Count -gt 2) -or ($wlVisible.Count -gt 0) -or $curIsWl
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
        $records += [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'qq-maa'
          chat = $view0.header; expected = $hit0; verified = $true; changed = $true
          text = ($view0.header + "`n" + $view0.text)
          lines = @($view0.lines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.text } })
        }
        $rule0 = Get-ChatRule -Name $hit0 -Rules $chatRules -DefaultMode 'all' -DefaultKeywords @()
        if ($rule0.mode -ne 'all' -and -not (Test-ChatKeyword $view0.text $rule0.keywords)) {
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
      # QQ 的列表在窗口未激活时忽略合成触摸 → 点之前先激活一次；记下原来的前台窗口，收尾时还回去
      if (-not (Enable-QqFocus -Ctx $ctx)) {
        Log '  ⚠️ 激活 QQ 失败（SetForegroundWindow 没生效）→ 点击会退回"真实鼠标"方式'
      } else {
        Log '  已把 QQ 提到前台（它的列表在未激活时会忽略合成触摸）'
      }
      # nameOffset 已由上面的"行距自适应"给出（≈行距/2）；这里只在没拿到时兜底
      if (-not $nameOffset -or $nameOffset -le 0) { $nameOffset = [int]$(if ($cfg.nameClickOffset) { $cfg.nameClickOffset } else { 28 }) }
      $script:QqPendingRecords = @()

      # 读取一个目标：点开 → 截图 → 用聊天头部判定；返回 @{ hit; text; header; chars }
      # ⚠️ 只点一次！QQ 里"再点一下同一个会话"会把聊天区取消选中变空（用户实测反馈 + 日志印证）。
      #    所以这里不做"再点一次重试"，只做"多点几次截图、多等一会儿"。
      # 注意：必须用"函数"而不是 scriptblock —— 脚本块里给 $records/$newState 赋值只会改到子作用域副本，
      #      外层数组不会被更新（实测：日志说"收下"，spool 却一行没写）。收记录/写状态一律在调用方做。
      function Read-QqTarget {
        param($Target, $Settle)
        [void](Invoke-QqClickRow -Ctx $ctx -Row ([pscustomobject]@{ index = $Target.index; y = $Target.y; clickX = 137 }) -SettleMs $Settle)
        $p2 = Join-Path $shotDir 'qq-maa-read.png'
        $s3 = Get-QqShot -Ctx $ctx -Path $p2
        $v3 = Get-QqChatView -Ctx $ctx -Rows $s3.rows
        # 画面可能还没渲染完：等一会儿再截一张（再截一次，但绝不再点）
        if ($v3.chars -lt 4 -or [string]::IsNullOrWhiteSpace($v3.header)) {
          Start-Sleep -Milliseconds 2000
          $s3 = Get-QqShot -Ctx $ctx -Path $p2
          $v3 = Get-QqChatView -Ctx $ctx -Rows $s3.rows
        }
        # ---------- 往期记录（2026-10-19）：聊天区滚轮向上翻几屏 ----------
        # 与微信侧同一套合并算法；注意滚轮必须作用在**聊天区**（Invoke-QqWheel 是列表用的，别混用）。
        # 锚点（2026-10-19）：上一轮记录过的最旧 3 行，读到就停
        $qqAnchorFile = Join-Path $stateDir 'seen-anchors.txt'
        $qqAnchorKey = 'qq|' + $v3.header
        $qqAnchors = @(Get-ChatAnchorLines -AnchorFile $qqAnchorFile -Key $qqAnchorKey)
        $qqAnchorHitFirst = Test-ChatAnchorHit -Lines $v3.lines -Anchors $qqAnchors
        if ($qqAnchorHitFirst -and $qqAnchors.Count -gt 0) { Log '  往期滚动：当前屏全是上一轮记录过的内容 → 不往前翻' }
        $histN = if ($cfg.PSObject.Properties['qqHistoryScreens']) { [int]$cfg.qqHistoryScreens } else { 2 }
        $histNotches = if ($cfg.PSObject.Properties['qqHistoryNotches']) { [int]$cfg.qqHistoryNotches } else { 3 }
        $histSettle = if ($cfg.PSObject.Properties['qqHistorySettleMs']) { [int]$cfg.qqHistorySettleMs } else { 600 }
        $histMax = if ($cfg.PSObject.Properties['qqHistoryMaxLines']) { [int]$cfg.qqHistoryMaxLines } else { 150 }
        if ($histN -gt 0 -and $histNotches -gt 0 -and $v3.chars -ge 4 -and -not $qqAnchorHitFirst) {
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
              if ((($vh.lines -join "`n")) -eq (($screens[0]) -join "`n")) { Log ('  往期滚动：第 {0} 屏与上一屏相同（没滚动/到顶）→ 停止' -f $hi); break }
              if (Test-ChatAnchorHit -Lines $vh.lines -Anchors $qqAnchors) { $screens += , @($vh.lines); Log ('  往期滚动：第 {0} 屏读到上一轮记录过的内容 → 停止' -f $hi); break }
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
        if (-not $h3) { Log ("  目标 y={0} → 头部'{1}' 不在白名单，跳过" -f $Target.y, $v3.header) }
        elseif ($v3.chars -lt 4) { Log ("  目标 y={0} → {1} 正文太短（{2} 字），跳过" -f $Target.y, $h3, $v3.chars); $h3 = '' }
        return [pscustomobject]@{ hit = $h3; text = $v3.text; header = $v3.header; chars = $v3.chars; lines = $v3.lines }
      }

      # 判断一条读取结果是否要收下：哈希写进 $newState（哈希表是可变的，能跨作用域生效），
      # 但**新记录对象要 return 给调用方**去 append —— 因为嵌套函数里 `$数组 += x` 只重绑本地副本，
      # 外层数组不会变（实测：日志说"收下"，spool 一行没写）。
      function Add-QqResult {
        param($Result)
        if (-not $Result.hit) { return $null }
        $foundGroups[$Result.hit] = $true
        $ruleR = Get-ChatRule -Name $Result.hit -Rules $chatRules -DefaultMode 'all' -DefaultKeywords @()
        if ($ruleR.mode -ne 'all' -and -not (Test-ChatKeyword $Result.text $ruleR.keywords)) {
          Log ("  {0} 按规则只采[{1}]，本条没命中 → 不收" -f $Result.hit, ($ruleR.keywords -join '/'))
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
        if (-not $Peek) { try { Save-ChatAnchors -AnchorFile (Join-Path $stateDir 'seen-anchors.txt') -Key ('qq|' + $Result.header) -Lines $Result.lines } catch { } }
        return [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'qq-maa'
          chat = $Result.header; expected = $Result.hit; verified = $true; changed = $true
          text = ($Result.header + "`n" + $Result.text)
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
        $rowsT = Get-QqSessionRows -Ctx $ctx -Rows $shotT.rows -MaxRows ([int]$(if ($cfg.autoReadMaxRows) { $cfg.autoReadMaxRows } else { 12 }))
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
            $auto5 = Get-QqRowsAuto -Ctx $ctx -Rows $s5.rows -Whitelist $missingNow -MaxRows $maxRows
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
      if ($stillMissing.Count -gt 0) { Log ("  本轮没读到的白名单群：" + ($stillMissing -join '、') + "（不在可见列表里）") }
    }
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
