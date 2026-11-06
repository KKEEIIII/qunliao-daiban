# qqread.ps1 —— QQ 会话列表/聊天区解析（MaaFramework 后台截图 / AnchoredTouch 后台点击）
#
# 依赖：wxlib.ps1（OCR、Norm）、qqwin.ps1（选窗）、maacap.ps1（截图/点击）
#
# 关键坐标事实（实测标定）：
#   * Maa 抓图 = 窗口 × DPI 比例（本例窗口 960x641 → 抓图 1079x720，比例 1.124）
#   * Maa 点击坐标 = 抓图空间像素（1:1，内部自动换算到屏幕）
#   * 会话列表：行高 ≈ 57px（抓图空间），首行中心 y ≈ 120，头像中心 x ≈ 137
#     → 归一化成比例（firstRowY/CH ≈ 0.167、rowHeight/CH ≈ 0.079、avatarX/CW ≈ 0.127）
#
# 用法：
#   . "$PSScriptRoot\qqread.ps1"
#   $ctx = Start-QqRead -Config $cfg -ProbeDir $here
#   $rows = Get-QqSessionRows -Ctx $ctx
#   $view = Get-QqChatView -Ctx $ctx -Row $rows[0]
#   Stop-QqRead -Ctx $ctx

function Start-QqRead {
  <#
    .SYNOPSIS  准备 QQ 后台读取：选真窗口 → 建可复用的 Maa 控制器
    .OUTPUTS   @{ win; ctrl; ctrlClick; cfg; captureW; captureH; ok; reason }
  #>
  param(
    [Parameter(Mandatory = $true)]$Config,
    [string]$ProbeDir,
    [switch]$NoVerify
  )
  # ⚠️ 2026-10-15 深夜修（外部复测缺陷2）：原来 Initialize-Maa 失败时，Find-QqWindow 返回 $null，
  #   这里一律报"没找到真实 QQ 窗口"——把"缺 VC++ 运行库导致 DLL 加载不了"伪装成"面板没开"，
  #   用户照日志去查窗口、真正该做的是补运行库。现在先单独探一次初始化，把真实原因写进 reason。
  if (-not (Initialize-Maa)) {
    $why = if ($script:MaaLoadError) { [string]$script:MaaLoadError } else { 'maa\bin 缺失或依赖不齐' }
    # ⚠️ 2026-10-16 加（外部复测 §四.4 建议）：**按 HRESULT 分类**，别再一律说"缺 VC++"。
    #   当天真事故：包里的 23 个二进制被当文本重编码（头部变成 BOM 而不是 MZ），加载报
    #   `0x8007000B ERROR_BAD_EXE_FORMAT`，而日志仍旧说"常见：缺 VC++" → 把人往错方向带。
    #   0x8007007E = 找不到模块/依赖（缺 vc_redist）｜0x8007000B = 格式不正确（文件损坏/位数不符）
    $hint = '常见原因：缺 VC++ 2015-2022 运行库 → 装 https://aka.ms/vs/17/release/vc_redist.x64.exe'
    if ($why -match '8007000B') {
      $hint = '这是"文件格式不正确"（0x8007000B）—— DLL 本身损坏或位数不符，不是缺运行库：请重新解压/重新下载部署包（正常文件应以 4D 5A 开头）'
    } elseif ($why -match '8007007E') {
      $hint = '这是"找不到依赖模块"（0x8007007E）—— 多半缺 VC++ 2015-2022 运行库：装 https://aka.ms/vs/17/release/vc_redist.x64.exe'
    } elseif ($why -match '试图加载格式不正确|BadImageFormat') {
      $hint = '这是"文件格式不正确"—— DLL 损坏或位数不符，不是缺运行库：请重新解压/重新下载部署包'
    }
    return [pscustomobject]@{ ok = $false; reason = ('MaaFramework 加载失败（' + $hint + '）：' + $why); win = $null }
  }
  $win = Find-QqWindow -Config $Config -Verify:(-not $NoVerify) -ProbeDir $ProbeDir
  if (-not $win) {
    # 2026-11-06：把"进程没跑"和"面板没开"分开说 —— 实测常见是进程在跑、主面板收进了托盘，
    #   而日志一律写"面板没开"会让用户以为检测坏了。
    $procs = @(Get-Process -Name ($(if ($Config.processName) { $Config.processName } else { 'QQ' })) -ErrorAction SilentlyContinue)
    $why = if ($procs.Count -gt 0) { 'QQ 主面板没打开（进程在跑；可能收进托盘，或截图全是空白）' } else { 'QQ 没运行（没有 QQ 进程）' }
    return [pscustomobject]@{ ok = $false; reason = $why; win = $null }
  }
  if (-not (Initialize-Maa)) { return [pscustomobject]@{ ok = $false; reason = 'MaaFramework 初始化失败'; win = $win } }
  $method = if ($Config.maaInputMethod) { [uint64]$Config.maaInputMethod } else { [uint64]1024 }
  # 截图方式（2026-10-26 查官方文档 + 实测）：
  #   0x12 = FramePool|PrintWindow = 官方 MaaWin32ScreencapMethod_Background（支持后台，默认用它）
  #   0x04 = DXGI_DesktopDup，**不支持后台**，且抓出来是变形图（横向1:1、纵向压缩）→ 不要用
  $scMode = if ($Config.maaScreencap) { [uint64]$Config.maaScreencap } else { [uint64]0x12 }
  $ctrlShot = Get-MaaController -Hwnd $win.hwnd -Screencap $scMode
  # 截图不缩放（2026-10-26 查官方 API MaaControllerSetOption 找到的）：
  #   默认 Maa 把抓图缩到 968x720，窗口 1267x942 时纵向压掉 24% → 文字变小 → OCR 漏行
  #   （实测「第 一 次 月 视 频」整行读不到，示例群I群每轮漏采）。
  #   官方 ScreenshotUseRawSize（key=3，1 字节 bool）关掉缩放 → 抓图 1267x942 原始分辨率，
  #   而且**仍然是后台截图**，不用改用户窗口大小。
  #   配置 maaRawSize=false 可关掉（万一某些机器抓图过大导致慢/失败）。
  $useRaw = if ($Config.PSObject.Properties['maaRawSize']) { [bool]$Config.maaRawSize } else { $true }
  if ($useRaw -and $ctrlShot -ne [IntPtr]::Zero) { [void](Set-MaaShotOption -Controller $ctrlShot -Key 3 -IntValue 1 -AsBool) }
  $ctrlClick = Get-MaaController -Hwnd $win.hwnd -InputMethod $method
  # ⚠️ 2026-10-26 关键 bug 修复：**点击控制器也必须设成原始尺寸**。
  #   抓图和点击是两个不同的控制器；之前只给抓图设了 raw，点击控制器仍以为图是 968x720，
  #   于是它把抓图坐标按 942/720=1.308 放大后才点 → 点 y=174 实际落到 y≈228，
  #   表现为"点示例部门示例机构却打开示例学校新闻"。两个控制器都设成 raw，坐标才是 1:1。
  if ($useRaw -and $ctrlClick -ne [IntPtr]::Zero) { [void](Set-MaaShotOption -Controller $ctrlClick -Key 3 -IntValue 1 -AsBool) }
  if ($ctrlShot -eq [IntPtr]::Zero -or $ctrlClick -eq [IntPtr]::Zero) {
    return [pscustomobject]@{ ok = $false; reason = 'Maa 控制器连接失败'; win = $win }
  }
  # 抓图尺寸要在第一次截图后才知道；先截一张探路
  $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('qqread-probe-{0}.png' -f $PID)
  $s = Get-MaaShot -Hwnd $win.hwnd -Path $probe -Controller $ctrlShot
  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  if (-not $s.ok) { return [pscustomobject]@{ ok = $false; reason = 'Maa 截图失败'; win = $win } }
  return [pscustomobject]@{
    ok           = $true
    win          = $win
    cfg          = $Config
    ctrl         = $ctrlShot
    ctrlClick    = $ctrlClick
    inputMethod  = $method
    captureW     = $s.w
    captureH     = $s.h
    lastShotPath = ''
  }
}

function Stop-QqRead {
  param($Ctx)
  # 控制器可能因缓存/输入法配置共享同一 native handle；重复 Destroy 会触发 Maa 堆损坏。
  $seen = @{}
  foreach ($p in @('ctrl','ctrlClick','ctrlScroll')) {
    if (-not $Ctx -or -not $Ctx.PSObject.Properties[$p]) { continue }
    $h = $Ctx.$p
    if ($h -eq [IntPtr]::Zero) { continue }
    $key = $h.ToInt64().ToString()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    try { [MaaApi]::MaaControllerDestroy($h) } catch {}
  }
}

function Get-QqShot {
  <#
    .SYNOPSIS  后台截一张 QQ 窗口图（用 ctx 里已连接的控制器）
    .OUTPUTS   @{ ok; path; w; h; rows(OCR) }
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [string]$Path, [switch]$NoOcr)
  if (-not $Path) { $Path = Join-Path ([System.IO.Path]::GetTempPath()) ('qqshot-{0}.png' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))) }
  $s = Get-MaaShot -Hwnd $Ctx.win.hwnd -Path $Path -Controller $Ctx.ctrl
  if (-not $s.ok) { return [pscustomobject]@{ ok = $false; path = $Path; w = 0; h = 0; rows = @() } }
  $Ctx.captureW = $s.w; $Ctx.captureH = $s.h; $Ctx.lastShotPath = $Path
  $rows = @()
  if (-not $NoOcr) { $rows = @(Invoke-WxOcr -Path $Path -Scale 1) }
  return [pscustomobject]@{ ok = $true; path = $Path; w = $s.w; h = $s.h; rows = $rows }
}

function Get-QqSessionRows {
  <#
    .SYNOPSIS  从抓图 OCR 里解析出"会话列表行"（按 y 网格对齐，避免 OCR 行距抖动把两行并成一行）
    .OUTPUTS   @( @{ index(1起); y(抓图空间点击 y); name; texts; lines } )
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Rows, [int]$MaxRows = 12, [double]$RowHeightOverride = 0, [double]$FirstRowYOverride = 0)
  $W = $Ctx.captureW; $H = $Ctx.captureH; $cfg = $Ctx.cfg
  if ($W -le 0 -or $H -le 0) { return @() }

  # 行几何：优先用 config 里的抓图空间像素值，换算成比例；否则用实测默认
  $rowOverride = $RowHeightOverride -gt 0
  $firstOverride = $FirstRowYOverride -gt 0
  $rowH = if ($rowOverride) { [double]$RowHeightOverride } elseif ($cfg.rowHeight) { [double]$cfg.rowHeight } else { 57 }
  $firstY = if ($firstOverride) { [double]$FirstRowYOverride } elseif ($cfg.firstRowY) { [double]$cfg.firstRowY } else { 120 }
  # override 来自当前截图的像素坐标；配置默认值来自基准 720px 截图。
  $avatarX = if ($cfg.avatarX) { [double]$cfg.avatarX } else { 137 }
  $rowHn = if ($rowOverride) { $rowH / $H } else { $rowH / 720.0 }
  $firstYn = if ($firstOverride) { $firstY / $H } else { $firstY / 720.0 }
  $avatarXn = $avatarX / 1079.0

  $x1 = $W * [double]$cfg.sessionXFrom; $x2 = $W * [double]$cfg.sessionXTo
  # 首行名字位于中心上方，避免裁掉置顶群名而只留下预览。
  $y0 = [Math]::Max($H * 0.08, [Math]::Min($H * [double]$cfg.listYFrom, ($firstYn - $rowHn * 0.79) * $H))
  $inList = @($Rows | Where-Object { $_.x -ge $x1 -and $_.x -le $x2 -and $_.y -ge $y0 } | Sort-Object y)
  if ($inList.Count -eq 0) { return @() }

  # 锚点：用 config 标定的首行中心（不用"第一条 OCR 行"——搜索框文字会漏进来把整列带偏）
  $firstRowY = $firstYn * $H
  $out = @()
  for ($i = 0; $i -lt $MaxRows; $i++) {
    $cy = $firstRowY + $i * ($rowHn * $H)
    if ($cy -gt ($H - 10)) { break }
    # 行高 = 58px（抓图空间）。实测"会话名文字"与"该行的点击中心"关系：
    #   名字 y ≈ 点击中心 y - 35，预览/时间 y ≈ 点击中心 y + 3
    # 所以取 [cy-45, cy+12] 这一段：既拿到名字，又不会被上一行的时间戳污染。
    $halfUp = [int]($rowHn * $H * 0.79)   # 名字在上半部分（行距 57 时 ≈45）
    $lines = @($inList | Where-Object { $_.y -ge ($cy - $halfUp) -and $_.y -le ($cy + [int]($rowHn * $H * 0.21)) })
    if ($lines.Count -eq 0) { continue }
    # 会话名 = 最靠左的那条（头像右边），去掉时间戳数字尾巴
    $nameLine = ($lines | Sort-Object @{Expression='x';Ascending=$true}, @{Expression='y';Ascending=$true} | Select-Object -First 1)
    $name = ($nameLine.text -replace ' ', '').Trim()
    # 点击 y 必须绑定群名行，不能取区域最后一条 OCR 行：最后一条通常是预览/时间，
    # 会把点击点推到下一行。群名行下方约半行距是行内安全区，随缩放按当前抓图像素计算。
    $nameY = [int]$nameLine.y
    $clickY = [int][Math]::Round($nameY + (($rowHn * $H) * 0.42))
    $out += [pscustomobject]@{
      index  = $i + 1
      y      = [int][math]::Round($cy)
      clickY = $clickY
      clickX = [int][math]::Round($avatarXn * $W)
      name   = $name
      texts  = @($lines | Sort-Object y | ForEach-Object { ($_.text -replace ' ', '') })
      lines  = $lines
    }
  }
  return $out
}

function Get-QqChatHeader {
  <#
    .SYNOPSIS  从抓图 OCR 里取"聊天区标题"（完整群名）
    .DESCRIPTION
      2026-10-27 修：原来取**最长**的那一行，于是群里有"置顶公告"时会把公告当群名 ——
      实测「示例学校新闻」那一屏：标题 `示例群D（156）` 在 y≈0.070H，
      置顶公告 `万众待的年度剧场活动一一《剧院启幕计划》…正式拉开帷幕！` 在 y≈0.122H、比标题长一倍，
      结果头部被认成公告 → 判"不在白名单" → 这个群一直采不到。
      现在改成取**最靠上**的那一行（标题永远在聊天区最上面，公告/侧栏都在下面），
      并且右侧成员栏（x > chatXTo）不再参与（原来没有上界，成员名也可能被当标题）。
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Rows)
  $W = $Ctx.captureW; $H = $Ctx.captureH
  $cfg = $Ctx.cfg
  $xMax = if ($cfg -and $cfg.chatXTo) { $W * [double]$cfg.chatXTo } else { $W }
  $best = ''
  $bestY = [double]::MaxValue
  foreach ($r in ($Rows | Sort-Object y)) {
    $t = ($r.text -replace ' ', '')
    if ($t.Length -lt 3) { continue }
    if ($r.x -lt ($W * 0.26) -or $r.x -gt $xMax) { continue }
    if ($r.y -lt ($H * 0.05) -or $r.y -gt ($H * 0.16)) { continue }
    # 取最靠上的；同一 y 附近取更长的（标题一行可能有多个 OCR 片段）
    if ($r.y -lt ($bestY - 6) -or ($r.y -le ($bestY + 6) -and $t.Length -gt $best.Length)) {
      $best = $t
      $bestY = [double]$r.y
    }
  }
  return $best
}

function Get-QqChatText {
  <#
    .SYNOPSIS  取聊天正文（按 config 的 chatX/chatY 区域，排除右侧常驻侧栏）
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Rows)
  $W = $Ctx.captureW; $H = $Ctx.captureH; $cfg = $Ctx.cfg
  $x1 = $W * [double]$cfg.chatXFrom
  $x2 = if ($cfg.chatXTo) { $W * [double]$cfg.chatXTo } else { $W }
  $y1 = $H * [double]$cfg.chatYFrom
  $y2 = if ($cfg.chatYTo) { $H * [double]$cfg.chatYTo } else { $H }
  $lines = @($Rows | Where-Object { $_.x -ge $x1 -and $_.x -le $x2 -and $_.y -ge $y1 -and $_.y -le $y2 } | Sort-Object y)
  # 2026-10-27：过滤界面噪声行。实测 QQ 聊天区 OCR 会混进按钮/图标文字
  #   （"0"、"回"、"裔"、"0031" 这类），以及成员侧栏的短标签 —— 原来全都被拼进正文，
  #   示例群B 那条 148 字里有一半是这种噪声，模型抽取时会把它们当消息内容。
  # 判据保守：只丢"去掉标点后长度 < 2"和"纯数字/纯符号"的行，正文不会被误伤。
  $kept = @()
  foreach ($ln in $lines) {
    $t0 = ($ln.text -replace ' ', '')
    if ($t0.Length -ge 2) {
      $hasCjk = [regex]::IsMatch($t0, '[\u4e00-\u9fff]')
      $hasWord = [regex]::IsMatch($t0, '[A-Za-z]{2,}')
      if ($hasCjk -or $hasWord) { $kept += $ln; continue }
    }
    # 极短但确实可能是聊天内容（如"好"、"1"）——留着，但只留一个字符的中文
    if ($t0.Length -eq 1 -and [regex]::IsMatch($t0, '[\u4e00-\u9fff]')) { $kept += $ln; continue }
    # ⚠️ 2026-10-27：**整行就是时间的行必须留下**。
    #   聊天区的"时间分隔行"里，只有"昨天19：22 / 星期五23:38"带中文；
    #   纯时分的（如 "09:05"、"9:5"）在 OCR 里没有中文也没有字母 → 会被上面两道判据当噪声丢掉，
    #   于是新的时间锚点（文本+时间）永远看不到这类分隔行 → 翻页停不下、"没有新消息"也判不出来。
    #   判据用严格整行匹配（ConvertFrom-ChatTimeText 内部就是 ^...$），正文里的
    #   "活动时间19：00—21：00" 不会被当时间行。
    if (ConvertFrom-ChatTimeText -Text ([string]$ln.text)) { $kept += $ln; continue }
  }
  $lines = @($kept)
  $text = (($lines | ForEach-Object { ($_.text -replace ' ', '') }) -join "`n").Trim()
  return [pscustomobject]@{ text = $text; lines = $lines; chars = $text.Length }
}

function Get-QqChatView {
  <#
    .SYNOPSIS  当前打开的会话：头部 + 正文
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Rows)
  $h = Get-QqChatHeader -Ctx $Ctx -Rows $Rows
  $t = Get-QqChatText -Ctx $Ctx -Rows $Rows
  return [pscustomobject]@{ header = $h; text = $t.text; lines = $t.lines; chars = $t.chars }
}

function Invoke-QqClickRow {
  <#
    .SYNOPSIS  点某个会话行；成功返回 $true
    .DESCRIPTION
      ⚠️ 实测（2026-10-14）：**QQ 的会话列表在窗口未激活时会忽略合成触摸**。
      AnchoredTouch 的设计就是"不激活目标窗口"，所以窗口不在前台时，点多少次都不会切换会话
      （症状：每一行点完读回来的头部都是同一个群）。
      对策：窗口不在前台时，这一次改用**真实鼠标点击**——它既激活窗口、又完成这次选择（实测一次就切换成功）；
      之后的点击（窗口已激活）继续走 Maa，不再动鼠标。
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [Parameter(Mandatory = $true)]$Row, [int]$SettleMs = 0)
  $x = if ($Row.clickX) { [int]$Row.clickX } else { [int][math]::Round($Ctx.captureW * 0.127) }
  $y = [int]$Row.y
  $ok = $false
  $focused = ([WxNative]::GetForegroundWindow() -eq $Ctx.win.hwnd)
  if (-not $focused) {
    # 不抢焦点：用户切到别的应用时，真实输入必须停止，避免误点。
    # Maa 后台点击仍可用，但先确认窗口句柄仍有效；失败直接返回，不降级成全局鼠标点击。
    if (-not [WxNative]::IsWindowVisible($Ctx.win.hwnd)) { return $false }
  }
  if ($focused -or ($Ctx.PSObject.Properties['ctrlClick'] -and $Ctx.ctrlClick -ne [IntPtr]::Zero)) {
    $ok = Invoke-MaaClick -Hwnd $Ctx.win.hwnd -X $x -Y $y -Controller $Ctx.ctrlClick
  } else {
    # 换算到屏幕坐标
    $win = Update-QqWindowRect -Ctx $Ctx
    $sx = $win.w / [double]$Ctx.captureW
    $sy = $win.h / [double]$Ctx.captureH
    $px = [int]($win.x + $x * $sx)
    $py = [int]($win.y + $y * $sy)
    # 安全锁：这一点最顶层必须是 QQ，否则真实点击会落到别的程序上
    $top = [WxNative]::TopAt($px, $py)
    if ($top -ne $win.hwnd) {
      Write-Host ("  [跳过·点不到QQ] 屏幕({0},{1}) 最顶层是 hwnd={2}，不是 QQ" -f $px, $py, $top)
      $ok = $false
    } else {
      $saved = $null
      try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue; $saved = [System.Windows.Forms.Cursor]::Position } catch { $saved = $null }
      [WxNative]::Click($px, $py)          # Click 内部会 SetCursorPos + 左键按下/抬起
      Start-Sleep -Milliseconds 150
      if ($saved) { [void][WxNative]::SetCursorPos($saved.X, $saved.Y) }   # 把鼠标放回原处
      $ok = $true
    }
  }
  if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
  return $ok
}

# ============ 文本匹配（OCR 会认错字，用滑窗 + 编辑距离）============
function Norm([string]$s) {
  # 去空白 + 去常见中英标点，便于比对（OCR 标点极不可靠）
  if ($null -eq $s) { return '' }
  return (($s -replace '\s', '') -replace '[：:，。、．（）()\[\]【】\-—_~]', '')
}

function Get-QqLevenshtein([string]$a, [string]$b) {
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

function Test-QqHeaderExact {
  param([string]$Name, [string]$Pattern)
  # 2026-11-06：**放宽到"能认出同一个群"**，但仍不做任意包含（防"示例部门"吃掉"示例部门小组"）。
  #   真机踩到的两类误丢（覆盖率 4/7 的主因）：
  #     ① 头部比白名单词多了前缀/后缀：`第一次示例群I（11）` vs `示例群I`
  #     ② 群号型白名单：`示例群A（52）` vs `<示例群号>`
  #   原来只认「相等 / 数字前缀 / 短词前缀」，于是这两类被当成"标题不符"整条丢弃。
  $strip = { param($s)
    $t = ([string]$s -replace '\s', '')
    $t = $t -replace '[（(][^）)]*[）)]', ''     # 去掉**所有**括号段（群人数/官方/届别标注）
    return $t
  }
  $a = & $strip $Name; $b = & $strip $Pattern
  if ($a.Length -lt 2 -or $b.Length -lt 2) { return $false }
  if ($a -eq $b) { return $true }
  # ① 群号型白名单（≥5 位数字）：标题里出现同一串数字就是同一个群（群号是最强标识）
  if ($b -match '^\d{5,}$' -and $a.Contains($b)) { return $true }
  # ② 长名截断：短的那个是长的前缀，且长度 ≥4（"示例群A" ⊂ "示例群A前缀2班"）
  $shorter = if ($a.Length -le $b.Length) { $a } else { $b }
  $longer = if ($a.Length -gt $b.Length) { $a } else { $b }
  if ($shorter.Length -ge 4 -and $longer.StartsWith($shorter, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  # ③ 头部带前缀修饰：白名单词出现在标题**结尾**且长度 ≥3（"第一次示例群I" ← "示例群I"）
  if ($b.Length -ge 3 -and $a.EndsWith($b, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  # ④ QQ 偶尔把 1-4 位年级/班级数字拼到小群名前（"26示例部门小组"）：去数字前缀后必须全文相等
  if ($b.Length -ge 5 -and $a -match '^[0-9]{1,4}.+$') {
    $withoutNumericPrefix = $a -replace '^[0-9]{1,4}', ''
    if ($withoutNumericPrefix -ieq $b) { return $true }
  }
  # ⑤ 短白名单词做前缀（示例群B/示例部门/示例学校新闻/示例群F）
  if ($b.Length -le 4 -and $a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  # ⑥ 2 字词出现在标题**中间**（"示例群F（128）" ← "示例群F"）。
  #   刻意排除"出现在开头"：那正是 示例部门 / 示例部门小组 这种"短词是长词前缀"的混淆场景（由 ⑤ 之外单独处理）。
  if ($b.Length -eq 2 -and $a.IndexOf($b, [System.StringComparison]::OrdinalIgnoreCase) -gt 0) { return $true }
  return $false
}

function Test-QqMatchText {
  <#
    .SYNOPSIS  整体匹配（用于"聊天头部"的最终判定）：包含 或 编辑距离 ≤2（短词 ≤1）
  #>
  param([string]$Name, [string]$Pattern)
  $a = Norm $Name; $b = Norm $Pattern
  if ([string]::IsNullOrWhiteSpace($b) -or $a.Length -lt 2) { return $false }
  if ($a.Contains($b)) { return $true }
  $maxDist = 2
  if ($b.Length -le 4) { $maxDist = 1 }
  if ($a.Length -lt $b.Length) { return ((Get-QqLevenshtein $a $b) -le $maxDist) }
  for ($i = 0; $i -le ($a.Length - $b.Length); $i++) {
    if ((Get-QqLevenshtein $a.Substring($i, $b.Length) $b) -le $maxDist) { return $true }
  }
  return $false
}

function Test-QqPrefixText {
  <#
    .SYNOPSIS  粗筛（只挑"值得点开看看"的行；真正的白名单判定一律用点开后的聊天头部）
    .DESCRIPTION
      列表里的群名会被截断、OCR 又会认错字，所以只比前 N 个字：
        N=3 且允许差 1 个字（"示例学校新闻"→"示例学校新闻新"、"示例群B"→"示例群B有"）
      不要用 n=4：'2026．10…' 和 '2026级…' 前 4 字只差 1，会把不相关的群当候选（实测踩过）。
  #>
  param([string]$Name, [string]$Pattern, [int]$PrefixLen = 3)
  $a = Norm $Name; $b = Norm $Pattern
  if ([string]::IsNullOrWhiteSpace($b) -or $a.Length -lt 2) { return $false }
  if ($a.Contains($b)) { return $true }
  $n = [Math]::Min($PrefixLen, $b.Length)
  $pa = if ($a.Length -ge $n) { $a.Substring(0, $n) } else { $a }
  return ((Get-QqLevenshtein $pa $b.Substring(0, $n)) -le 1)
}

function Get-QqRowSignature {
  <#
    .SYNOPSIS  一行内容的指纹（文本，用于比"这行是否变化"）
  #>
  param($Row)
  if (-not $Row) { return '' }
  return (($Row.texts | Where-Object { $_ }) -join '|')
}

function Invoke-QqScrollList {
  <#
    .SYNOPSIS  在会话列表上滚一屏（把列表下/上翻一页，用于找不在首屏的白名单群）
    .PARAMETER Direction  down | up
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [string]$Direction = 'down', [int]$Times = 3, [int]$SettleMs = 900)
  # 注意：AnchoredTouch 不实现 scroll（会报 "AnchoredTouch does not implement scroll"），
  # 所以滚动用另一个输入法的控制器（默认 32=SendMessageWithCursorPos：把鼠标临时移到目标点发消息再还原）
  $dy = if ($Direction -eq 'up') { -1 } else { 1 }
  $method = [uint64]$(if ($Ctx.cfg.maaScrollInputMethod) { $Ctx.cfg.maaScrollInputMethod } else { 32 })
  if (-not $Ctx.PSObject.Properties['ctrlScroll'] -or $Ctx.ctrlScroll -eq [IntPtr]::Zero) {
    $c = Get-MaaController -Hwnd $Ctx.win.hwnd -InputMethod $method
    $Ctx | Add-Member -NotePropertyName ctrlScroll -NotePropertyValue $c -Force
  }
  $ok = $false
  for ($i = 0; $i -lt $Times; $i++) {
    $ok = Invoke-MaaScroll -Hwnd $Ctx.win.hwnd -Dy (200 * $dy) -Controller $Ctx.ctrlScroll
    Start-Sleep -Milliseconds $SettleMs
  }
  return $ok
}
function Update-QqWindowRect {
  param([Parameter(Mandatory = $true)]$Ctx)
  $r = Get-WxPhysicalRect -Hwnd $Ctx.win.hwnd
  if (-not $r -or $r.width -le 0 -or $r.height -le 0 -or $Ctx.captureW -le 0 -or $Ctx.captureH -le 0) {
    throw 'INPUT_TARGET_LOST: QQ 窗口或截图尺寸无效'
  }
  $Ctx.win.x = $r.left; $Ctx.win.y = $r.top
  $Ctx.win.w = $r.width; $Ctx.win.h = $r.height
  return $Ctx.win
}

function Test-QqWheelPoint {
  <# 给离线测试留一个可替换的遮挡判定边界；实际仍以顶层窗口句柄为准。 #>
  param([Parameter(Mandatory = $true)]$Ctx, [int]$X, [int]$Y)
  try { return ([WxNative]::TopAt($X, $Y) -eq $Ctx.win.hwnd) } catch { return $false }
}

function Get-QqWheelScreenPoint {
  <#
    .SYNOPSIS  在 QQ 指定区域内选一个未被遮挡的滚轮点，不激活窗口。
    .PARAMETER Area list | chat
    .DESCRIPTION
      先生成多组区域内候选点，再用 TopAt 验证点下方仍是 QQ。
      Invoke-TargetWindowWheel 发送前还会再次验证，遮挡发生竞态时仍安全失败。
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [ValidateSet('list','chat')][string]$Area = 'list')
  $win = Update-QqWindowRect -Ctx $Ctx
  if ($Ctx.captureW -le 0 -or $Ctx.captureH -le 0) { throw 'INPUT_TARGET_LOST: QQ 截图尺寸无效' }
  $cfg = $Ctx.cfg
  if ($Area -eq 'chat') {
    $x1 = if ($cfg.PSObject.Properties['chatXFrom']) { [double]$cfg.chatXFrom } else { 0.28 }
    $x2 = if ($cfg.PSObject.Properties['chatXTo']) { [double]$cfg.chatXTo } else { 0.78 }
    $y1 = if ($cfg.PSObject.Properties['chatYFrom']) { [double]$cfg.chatYFrom } else { 0.30 }
    $y2 = if ($cfg.PSObject.Properties['chatYTo']) { [double]$cfg.chatYTo } else { 0.88 }
    # 聊天正文区域内三列 × 三行，避开标题栏和底部输入框。
    $xFracs = @(0.22, 0.50, 0.78)
    $yFracs = @(0.35, 0.55, 0.75)
  } else {
    $x1 = if ($cfg.PSObject.Properties['sessionXFrom']) { [double]$cfg.sessionXFrom } else { 0.08 }
    $x2 = if ($cfg.PSObject.Properties['sessionXTo']) { [double]$cfg.sessionXTo } else { 0.35 }
    $y1 = if ($cfg.PSObject.Properties['listYFrom']) { [double]$cfg.listYFrom } else { 0.15 }
    $y2 = 0.94
    # 列表区域内三列 × 三行，不依赖头像列的单一固定坐标。
    $xFracs = @(0.24, 0.50, 0.76)
    $yFracs = @(0.28, 0.52, 0.76)
  }
  $script:QqWheelObstructed = $false
  if ($x2 -le $x1 -or $y2 -le $y1) { throw ('INPUT_TARGET_LOST: QQ {0} 区域比例无效' -f $Area) }
  $sx = $win.w / [double]$Ctx.captureW
  $sy = $win.h / [double]$Ctx.captureH
  foreach ($yf in $yFracs) {
    foreach ($xf in $xFracs) {
      $cx = $x1 + ($x2 - $x1) * $xf
      $cy = $y1 + ($y2 - $y1) * $yf
      $px = [int][Math]::Round($win.x + ($Ctx.captureW * $cx) * $sx)
      $py = [int][Math]::Round($win.y + ($Ctx.captureH * $cy) * $sy)
      if ($px -lt $win.x -or $px -ge ($win.x + $win.w) -or $py -lt $win.y -or $py -ge ($win.y + $win.h)) { continue }
      if (Test-QqWheelPoint -Ctx $Ctx -X $px -Y $py) { return [pscustomobject]@{ x = $px; y = $py; area = $Area } }
    }
  }
  $script:QqWheelObstructed = $true
  throw ('INPUT_TARGET_LOST: QQ {0} 区域的滚轮候选点均被遮挡' -f $Area)
}

function Get-QqListScreenPoint {
  param([Parameter(Mandatory = $true)]$Ctx)
  return (Get-QqWheelScreenPoint -Ctx $Ctx -Area 'list')
}

function Invoke-QqWheel {
  <#
    .SYNOPSIS  在会话列表上滚动（真实滚轮事件；临时移动鼠标，滚完还原）
    .PARAMETER Notches  滚几格（一格=120）；正数向下、负数向上
    .OUTPUTS   实际滚动的格数
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [int]$Notches = 2, [int]$SettleMs = 700)
  if ($Notches -eq 0) { return 0 }
  $script:QqWheelObstructed = $false
  # 2026-11-04：滚轮不抢焦点（Windows 把它发给光标下的窗口）。安全由 Invoke-TargetWindowWheel
  #   的"落点是否归 QQ"判断保证：被别的窗口盖住就抛 INPUT_TARGET_LOST，不会滚到别人身上。
  $pt = Get-QqListScreenPoint -Ctx $Ctx
  $actual = Invoke-TargetWindowWheel -Hwnd $Ctx.win.hwnd -X $pt.x -Y $pt.y -Notches (-$Notches) -StepDelayMs 60
  if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
  return (-$actual)
}
function Get-QqRowsAuto {
  <#
    .SYNOPSIS  自动定行距：试几个候选行距，挑"行名命中白名单最多"的那个
    .DESCRIPTION
      为什么需要：QQ 的**缩放**会改变行的实际间距（实测：100% 时 57px，缩放后 72px），
      而点击网格是"首行 y + N×行距"算出来的。间距错了 → 名字归错行 → 白名单匹配失败
      → 后面所有逻辑（含滚动找群）都在错误前提下跑。这里用"谁匹配得多"来自证。
    .OUTPUTS   @{ rows; pitch; offset; score }
  #>
  param(
    [Parameter(Mandatory = $true)]$Ctx,
    [Parameter(Mandatory = $true)]$Rows,
    [string[]]$Whitelist = @(),
    [int]$MaxRows = 12,
    [double[]]$Pitches = @(57, 64, 71, 72, 80, 86, 96)
  )
  $best = $null
  $bestScore = -1
  foreach ($p in $Pitches) {
    $rr = Get-QqSessionRows -Ctx $Ctx -Rows $Rows -MaxRows $MaxRows -RowHeightOverride $p
    $score = 0
    foreach ($r in $rr) {
      foreach ($g in $Whitelist) { if (Test-QqPrefixText -name $r.name -pattern $g) { $score++; break } }
    }
    if ($score -gt $bestScore) { $bestScore = $score; $best = [pscustomobject]@{ rows = $rr; pitch = $p } }
  }
  if (-not $best) { $best = [pscustomobject]@{ rows = @(); pitch = 57 } }
  return [pscustomobject]@{ rows = $best.rows; pitch = $best.pitch; offset = [int][math]::Round($best.pitch / 2); score = $bestScore }
}
function Enable-QqFocus {
  <#
    .SYNOPSIS  把 QQ 面板提到前台（QQ 的会话列表在窗口未激活时会忽略合成触摸，必须先激活）
    .OUTPUTS   $true = 现在是前台
  #>
  param([Parameter(Mandatory = $true)]$Ctx)
  $h = $Ctx.win.hwnd
  if ([WxNative]::GetForegroundWindow() -eq $h) { return $true }
  [void][WxNative]::ShowWindow($h, 4)                                   # SW_SHOWNOACTIVATE
  [void][WxNative]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x43)  # HWND_TOP|NOMOVE|NOSIZE|SHOWWINDOW
  Start-Sleep -Milliseconds 300
  [void][WxNative]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 500
  return ([WxNative]::GetForegroundWindow() -eq $h)
}
function Get-QqChatScreenPoint {
  param([Parameter(Mandatory = $true)]$Ctx)
  return (Get-QqWheelScreenPoint -Ctx $Ctx -Area 'chat')
}

function Invoke-QqChatWheel {
  <#
    .SYNOPSIS  在**聊天区**滚动（真实滚轮；临时移光标，滚完还原）
    .PARAMETER Notches  滚几格（一格=120）；**正数向下、负数向上**（与 Invoke-QqWheel 一致）
  #>
  param([Parameter(Mandatory = $true)]$Ctx, [int]$Notches = 2, [int]$SettleMs = 700)
  if ($Notches -eq 0) { return 0 }
  $script:QqWheelObstructed = $false
  $pt = Get-QqChatScreenPoint -Ctx $Ctx
  $actual = Invoke-TargetWindowWheel -Hwnd $Ctx.win.hwnd -X $pt.x -Y $pt.y -Notches (-$Notches) -StepDelayMs 60
  if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
  return (-$actual)
}