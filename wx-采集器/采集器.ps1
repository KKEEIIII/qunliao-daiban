# 采集器.ps1 —— 微信窗口「截图 + OCR (+自动点击)」采集器
#
# 只做三件事：抓微信窗口的图 → 本地 OCR → 把新消息写进 spool（可选：自动点开会话读完整消息）
# 不发送任何消息、不改任何设置。
#
# 用法：
#   # 只读模式（只看会话列表预览，不点击）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\采集器.ps1 -Once
#
#   # 自动点击模式（点开会话读完整消息；会把这些会话标记为已读）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\采集器.ps1 -Once -AllowClick -MaxClicks 3
#
#   # 常驻轮询
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\采集器.ps1 -Interval 60
#
param(
  [switch]$Once,
  [int]$Interval = 60,
  [int]$Passes = 0,            # >0 时跑指定轮数后退出（测试用）
  [switch]$AllowClick,         # 必须显式开启才会点击
  [switch]$Pseudo,             # 用"伪最小化"后台抓图（微信最小化/收托盘都能抓；计划任务一直带这个开关）
  [int]$MaxClicks = 3,
  [switch]$NoRestoreFocus,
  [switch]$SaveShots,
  [switch]$DumpRows,
  [string]$DumpRowsJson = '',   # 导出 OCR fixture（{width,height,rows}）供回归测试
  [string]$OcrRows = '',        # 用 fixture 代替实时抓图（离线跑 parser，供回归测试）
  [switch]$ScanMentions,      # 只扫描"@谁"的候选，方便配 myAliases，不采集
  [string]$ConfigPath = '',     # 指定配置文件（默认 config.json）。回归测试用来试不同开关，不动线上配置
  [switch]$Peek               # 只看不写：不写 spool、不更新 state（文档/回归测试/自测清单都用它）
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'wxlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'dsh-接入\运行状态.ps1')   # 记录本轮结果
# 2026-10-26 后台点击：微信的**抓图**继续用 PrintWindow（Maa 抓微信是黑图，实测 OCR 只剩 1 行），
# 只有**点击**改走 Maa 的后台消息（PostMessage），这样点开会话时不会把微信抢到前台。
# Maa 缺失/初始化失败时自动退回原来的真实鼠标点击（功能不变，只是会打扰用户）。
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'maafw-probe\maacap.ps1')

$stateDir = Join-Path $root 'state'
$spoolDir = Join-Path $root 'spool'
$shotDir = Join-Path $root 'shots'
$logDir = Join-Path $root 'logs'
foreach ($d in @($stateDir, $spoolDir, $shotDir, $logDir)) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------- 配置（区域比例 + 忽略名单），首次运行自动生成 ----------
$configPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $root 'config.json' }
              elseif ([System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath }
              else { Join-Path $root $ConfigPath }
$defaultConfig = [ordered]@{
  sessionXFrom   = 0.10      # 会话列表左边界（窗口宽度比例）
  sessionXTo     = 0.45      # 会话列表右边界
  chatXFrom      = 0.46      # 聊天区左边界
  headerYTo      = 0.16      # 聊天区头部（群名）的纵向范围
  rowGap         = 35        # 会话行的 y 间隔阈值（像素，窗口坐标系）
  clickX         = 0.25      # 点击会话行时的 x（窗口宽度比例）
  clickSettleMs  = 1100      # 点击后等待渲染
  ignoreChats    = @('公众号', '服务号', '订阅号', '折叠的聊天', '折叠的群聊', '微信团队', 'QQ邮箱提醒', '微信支付', '文件传输助手', '群助手', '服务通知', '订阅号消息')
  maxPreviewLen  = 200
  scale          = 3                          # OCR 放大倍数
  groupWhitelist = @()                        # 只采集名字包含其中任一项的会话；空 = 不过滤
  mentionOnly    = $true                      # 只采集 @我 的消息
  myAliases      = @()                        # 我的微信昵称/别名；空但 mentionOnly=true 时退化为"任意 @"
  # 误入"非聊天界面"时的返回动作。默认 enabled=$false —— 需要你先确认返回键的形态/位置，见 使用手册。
  #   action: 'backspace'   连按两次退格（最简单，无需坐标）
  #           'click'       点 click.x / click.y（**窗口宽高比例**，不是像素）
  #           'clickKey'    先点 click，再按 key（如 0x0D=Enter）
  #   ⚠️ **不要用 esc**：实测对微信发 ESC 会把窗口隐藏（IsWindowVisible=False），采集器会彻底失明。
  returnToMain   = [ordered]@{ enabled = $false; action = 'backspace'; click = [ordered]@{ x = 0.03; y = 0.06 }; key = 0 }
  # 判定为"非聊天界面"的标题标记（可用 OCR 常见错字写法扩展）
  nonChatMarkers = @('群助手', '服务通知', '订阅号消息', '公众号', '微信团队')
}
if (-not (Test-Path -LiteralPath $configPath)) {
  $defaultConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
}
$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
# OCR 放大倍数：放大后 Windows OCR 对小字、中文行分割更准（坐标会自动除回来）
$ocrScale = 3
if ($cfg.PSObject.Properties.Name -contains 'scale') { $ocrScale = [int]$cfg.scale }

$statePath = Join-Path $stateDir 'session-state.json'
$hashPath = Join-Path $stateDir 'chat-hash.json'

function Load-Json($path, $fallback) {
  if (-not (Test-Path -LiteralPath $path)) { return $fallback }
  try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $fallback }
}
function Save-Json($path, $obj) { $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8 }
function Norm([string]$s) { if ($null -eq $s) { return '' } return ($s -replace '\s', '') }

# R1（2026-10-27 用户要求）：采集器必须知道**命令执行时间**。
#   聊天区的时间分隔行是"昨天19:22 / 10月14日19:43 / 星期三19:22"这种相对时间，
#   必须用本轮执行时间当基准才能解析成绝对时间（不能用 Get-Date 当"现在"，跨零点会算错一天）。
#   每轮由 Invoke-Pass 设一次，整轮不变；轮询循环里每轮都会被重新赋值。
function Get-PassNow {
  if ($script:PassNow) { return $script:PassNow }
  return (Get-Date)
}

$script:logLines = New-Object System.Collections.Generic.List[string]
function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line
  $script:logLines.Add($line) | Out-Null
}

function Convert-WxChatRows {
  <#
    .SYNOPSIS  把"会话列的行"按 RowGap 聚成会话，并选出群名/预览
    .DESCRIPTION
      RowGap 由调用方传入（自适应算出来的），同一份代码能在任意窗口尺寸 / DPI / 字号下用。
      之前的 rowGap 是 config 里写死的 35（窗口像素），窗口或缩放一变就会
      "一个群被拆成两条"或"几个群并成一条"—— 2026-10-27 用 fixture 缩放到 0.5×/2× 实测复现：
      缩放 0.5× 只剩 2 个会话、2× 变成 11 个（真值 6 个）。
  #>
  param(
    [Parameter(Mandatory = $true)][object[]]$SessionLines,
    [Parameter(Mandatory = $true)][double]$RowGap,
    [Parameter(Mandatory = $true)]$Cfg,
    [Parameter(Mandatory = $true)][double]$WinW
  )
  $chats = @()
  $cur = $null
  foreach ($ln in ($SessionLines | Sort-Object y)) {
    $text = Format-OcrText $ln.text
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $item = [pscustomobject]@{ t = $text; h = [int]$ln.h; y = [int]$ln.y; x = [int]$ln.x }
    if ($null -eq $cur -or ($ln.y - $cur.lastY) -gt $RowGap) {
      if ($null -ne $cur) { $chats += $cur }
      $cur = [pscustomobject]@{ y = $ln.y; lastY = $ln.y; lines = @($item) }
    } else {
      $cur.lines += $item
      $cur.lastY = $ln.y
    }
  }
  if ($null -ne $cur) { $chats += $cur }

  # 微信会话行里：**群名/昵称那行字号更大**，下面是更小的预览行与时间。
  # OCR 有时会把两行合并、有时会漏掉一行，所以不按"第 0 行=名字"，而是按字号挑名字。
  #
  # 但"字号最大"会被**未读角标**骗到（实测：左侧绿色气泡上的 17 / 1 / 0 会被 OCR 读成
  # 'O' / '212' / '0'，而且有时和群名挤进同一行变成 '0苎'）→ 选名字前先剔除角标行。
  #
  # ⚠️ 不能只看"是不是纯数字"就删：**真有人拿纯数字当会话名**（实测有个会话就叫 '212'）。
  # 靠 x 位置区分：角标在头像左边（x≈54~115 / 窗口宽 894），名字列在 x≈156 起。
  # ↑ 这两个数是**窗口像素**，所以这里用比例（nameXFrom）而不是绝对值 —— 换分辨率才不会失效。
  $badgeRe = if ($Cfg.PSObject.Properties.Name -contains 'badgePattern' -and $Cfg.badgePattern) { [string]$Cfg.badgePattern } else { '^\d+[+Ww]?$' }
  $nameXMin = 0
  if ($Cfg.PSObject.Properties.Name -contains 'nameXFrom' -and $Cfg.nameXFrom) { $nameXMin = [int]($WinW * [double]$Cfg.nameXFrom) }
  $previewRe = if ($Cfg.PSObject.Properties.Name -contains 'previewPattern' -and $Cfg.previewPattern) { [string]$Cfg.previewPattern } else { '^[^：:]{2,16}[：:]\s*\S' }
  $maxPreviewLen = if ($Cfg.maxPreviewLen) { [int]$Cfg.maxPreviewLen } else { 200 }

  $result = @()
  foreach ($c in $chats) {
    # ① 把"纯角标"行整行丢掉（只在名字列左边才算角标）
    $cand = @()
    foreach ($ln in $c.lines) {
      $t = Format-OcrText $ln.t
      if ($t -match '^[^\p{L}\p{N}]+$') { continue }                     # 只有标点/符号（OCR 噪声）
      $isBadgeText = ($t -match $badgeRe) -or ($t -match '^\d{1,4}(?=[^\d\s])')
      if ($isBadgeText -and ($nameXMin -le 0 -or $ln.x -lt $nameXMin)) { continue }
      $cand += [pscustomobject]@{ t = $t; h = $ln.h; y = $ln.y; x = $ln.x }
    }
    if ($cand.Count -eq 0) { continue }                        # 这一"行"整个是角标 → 不是会话

    # ② 角标和名字挤在一行时（'0苎'）：剥掉开头的角标数字（同样只对名字列左边的行做）
    foreach ($x in $cand) {
      if ($nameXMin -gt 0 -and $x.x -ge $nameXMin) { continue }
      $stripped = $x.t -replace '^\d{1,3}(?=[^\d\s])', ''
      if ($stripped -ne $x.t) { $x.t = $stripped.Trim() }
    }
    $cand = @($cand | Where-Object { $_.t.Length -ge 2 })       # 剩 1 个字的多半是噪声（真群名极少单字）

    if ($cand.Count -eq 0) { continue }

    # ③ 哪一行才是群名？
    #    单看字号不靠谱 —— 实测：名字 '212' 的 h=15，它下面那行预览 '示例成员A：[图片]' 的 h 也是 15，
    #    于是"字号最大"会挑中预览行，把会话名记成 '示例成员A：[图片]'。
    #    真正稳的信号是**文本形态**：预览行几乎都是"发言人：内容"的样子（含冒号且冒号前 ≥2 字），
    #    或"已支付¥…"这类系统文案；群名基本不含冒号。
    $nameLike = @($cand | Where-Object { $_.t -notmatch $previewRe -and $_.t -notmatch '^已(支付|收款|领取)' })
    $pool = if ($nameLike.Count -gt 0) { $nameLike } else { $cand }   # 全像预览时退回全部候选

    $maxIdx = 0
    for ($i = 1; $i -lt $pool.Count; $i++) {
      if ($pool[$i].h -gt $pool[$maxIdx].h) { $maxIdx = $i }
    }
    $name = $pool[$maxIdx].t

    # 2026-10-27：OCR 偶尔把「会话名」和右侧的「时间」并成**一条 OCR 行**（不是两个 line）。
    #   实测 11:04 那轮：群名被解析成「26 人工 2 毋开纟及群昨天 23： 00」（名字 + 时间戳），
    #   这个脏名字会进 state / spool / 锚点 key，导致同一个群每轮换名字、待办分组乱。
    #   用时间解析器同一套容错把**结尾的时间**剥掉（全角冒号/℃/空格/星期几/相对日都认）；
    #   剥完长度 <2 的（例如整条就是 "07：30"）保持原样，避免把时间行误当群名又变成空名。
    $nameClean = ($name -replace '\s*(?:(?:昨天|今天|前天|星期|周)\s*[一二三四五六日天]\s*)?(?:(?:昨天|今天|前天)\s*)?\d{1,2}\s*[:：℃]\s*\d{1,2}\s*$', '').Trim()
    if ($nameClean.Length -ge 2 -and $nameClean -ne $name) { $name = $nameClean }

    $prevParts = @()
    foreach ($x in $cand) {
      if ($x.t -eq $name) { continue }
      $t = $x.t
      if ($t -match '^\d{1,2}[:：]\d{2}$') { continue }        # 时间
      if ($t -match '^(昨天|星期|周[一二三四五六日天])') { continue }
      $prevParts += $t
    }
    $preview = ($prevParts -join ' ')
    if ($preview.Length -gt $maxPreviewLen) { $preview = $preview.Substring(0, $maxPreviewLen) }
    $result += [pscustomobject]@{
      name = $name; preview = $preview
      y = [int]$c.y; yEnd = [int]$c.lastY
      nameY = [int]$pool[$maxIdx].y
      # 2026-10-27：名字行的字高也带出去 —— 点击偏移按它折算，就不再依赖"窗口像素 +8"这种定值
      nameH = [int]$pool[$maxIdx].h
      lineCount = @($cand).Count
    }
  }
  return $result
}

function Measure-WxParseScore {
  <#
    .SYNOPSIS  给一次"会话行聚类"的结果打质量分（越高越像"一个会话一行、名字干净、预览完整"）
    .DESCRIPTION
      用于行距自适应：同一个窗口试几个候选阈值，取分最高的那个。
      打分依据都是**结构特征**，与分辨率无关（所以换窗口/DPI 仍然成立）：
        · 命中白名单的群名 +4（最可靠的信号：用户就盯这几个群）
        · 其它像样的群名 +1
        · 带"发言人：内容"预览的会话 +1（说明名字行和预览行被正确分到同一簇）
        · 单行成簇 -2（多半是把一个会话的名字和预览拆开了）
        · 超过 4 行成一簇 -2（多半是把几个会话并成了一个大簇）
        · 群名被读成时间（07：30 / 昨天…）-4（这是 OCR 里的时间行，不是会话）
  #>
  param([object[]]$Chats, [string[]]$Whitelist = @())
  $sc = 0.0
  foreach ($c in $Chats) {
    $n = [string]$c.name
    if ($n.Length -lt 2) { continue }
    if ($n -match '^\d{1,2}[:：]\d{2}$' -or $n -match '^(昨天|今天|前天)') { $sc -= 4; continue }
    $wl = $false
    foreach ($w in $Whitelist) {
      if ([string]::IsNullOrWhiteSpace($w)) { continue }
      if ((Norm $n).Contains((Norm $w))) { $wl = $true; break }
    }
    if ($wl) { $sc += 4 } else { $sc += 1 }
    if ($c.preview -match '[:：]') { $sc += 1 }
    if ($c.lineCount -le 1) { $sc -= 2 }
    if ($c.lineCount -gt 4) { $sc -= 2 }
  }
  return $sc
}

function Get-WxRowGapAuto {
  <#
    .SYNOPSIS  会话行距阈值自适应（换分辨率 / DPI / 字号都不用重标 config）
    .DESCRIPTION
      做法与 QQ 侧 Get-QqGridAuto 同一思路：**候选阈值 + 用解析质量自证**。
        · 候选来自真实行距分布（相邻 y 差值排序后，间隔 ≥4px 的相邻两个值取中点）+ config 的 rowGap
        · 每个候选都真跑一遍聚类 + 选群名，用 Measure-WxParseScore 打分
        · 取分最高者；同分时取**更接近 config 值**的那个（保守，优先相信原标定）
      为什么不用固定阈值：实测同一份 OCR（fixture）缩放到 0.5×/2× 时，固定 35 会分别
      并成 2 个 / 拆成 11 个会话（真值 6 个）；自适应在 0.5×~2× 全部给出 6 个正确会话。
    .OUTPUTS  @{ gap; auto; score; cands; chats }
  #>
  param([object[]]$SessionLines, [double]$WinW, $Cfg, [string[]]$Whitelist = @())
  $baseGap = if ($Cfg.PSObject.Properties['rowGap'] -and [double]$Cfg.rowGap -gt 0) { [double]$Cfg.rowGap } else { 35 }
  $autoOn = if ($Cfg.PSObject.Properties['autoRowGap']) { [bool]$Cfg.autoRowGap } else { $true }
  $ys = @($SessionLines | Sort-Object y | ForEach-Object { [double]$_.y })
  if (-not $autoOn -or $ys.Count -lt 3) {
    $ch = @(Convert-WxChatRows -SessionLines $SessionLines -RowGap $baseGap -Cfg $Cfg -WinW $WinW)
    return [pscustomobject]@{ gap = $baseGap; auto = $false; score = [double](Measure-WxParseScore -Chats $ch -Whitelist $Whitelist); cands = @($baseGap); chats = $ch }
  }
  $gaps = @()
  for ($i = 1; $i -lt $ys.Count; $i++) { $g = $ys[$i] - $ys[$i - 1]; if ($g -gt 0) { $gaps += $g } }
  $uniq = @($gaps | Sort-Object -Unique)
  $cands = @($baseGap)
  for ($i = 1; $i -lt $uniq.Count; $i++) {
    # 只有"真的隔开一段"才当候选（≥4px），否则阈值太密、纯粹浪费时间
    if (($uniq[$i] - $uniq[$i - 1]) -ge 4) { $cands += [double](($uniq[$i] + $uniq[$i - 1]) / 2.0) }
  }
  $cands = @($cands | Sort-Object -Unique)
  $bestGap = $baseGap; $bestScore = [double]::MinValue; $bestChats = @()
  foreach ($c in $cands) {
    if ($c -lt 4 -or $c -gt 500) { continue }
    $ch = @(Convert-WxChatRows -SessionLines $SessionLines -RowGap $c -Cfg $Cfg -WinW $WinW)
    $sc = [double](Measure-WxParseScore -Chats $ch -Whitelist $Whitelist)
    $better = ($sc -gt $bestScore) -or (($sc -eq $bestScore) -and ([Math]::Abs($c - $baseGap) -lt [Math]::Abs($bestGap - $baseGap)))
    if ($better) { $bestGap = $c; $bestScore = $sc; $bestChats = $ch }
  }
  if ($null -eq $bestChats -or $bestChats.Count -eq 0) {
    $bestChats = @(Convert-WxChatRows -SessionLines $SessionLines -RowGap $baseGap -Cfg $Cfg -WinW $WinW)
    $bestGap = $baseGap
  }
  return [pscustomobject]@{ gap = $bestGap; auto = $true; score = $bestScore; cands = $cands; chats = $bestChats }
}

function Get-ChatsFromRows($rows) {
  <# 把 OCR 行按 x 分到「会话列表」和「聊天区」，再把会话列表行按 y 聚成会话行 #>
  $win = $script:win
  $sxFrom = [int]($win.width * $cfg.sessionXFrom)
  $sxTo = [int]($win.width * $cfg.sessionXTo)
  $cxFrom = [int]($win.width * $cfg.chatXFrom)

  $sessionLines = @($rows | Where-Object { $_.x -ge $sxFrom -and $_.x -le $sxTo } | Sort-Object y)
  $chatLines = @($rows | Where-Object { $_.x -ge $cxFrom } | Sort-Object y)

  # 2026-10-27：行距阈值自适应（不同分辨率/DPI/字号）。所有区域边界仍然是**窗口宽高比例**，
  #   只有"多远算下一个会话"这一条以前是写死的像素值，现在按 OCR 行距自己校准。
  $wlGap = @($cfg.groupWhitelist | Where-Object { $_ })
  $layout = Get-WxRowGapAuto -SessionLines $sessionLines -WinW ([double]$win.width) -Cfg $cfg -Whitelist $wlGap
  return [pscustomobject]@{
    chats = @($layout.chats); chatLines = $chatLines
    rowGap = $layout.gap; gapAuto = $layout.auto; gapScore = $layout.score; gapCands = @($layout.cands)
  }
}

function Get-ChatHeader($chatLines) {
  $win = $script:win
  $limit = [int]($win.height * $cfg.headerYTo)
  foreach ($ln in ($chatLines | Sort-Object y)) {
    if ($ln.y -le $limit -and -not [string]::IsNullOrWhiteSpace($ln.text)) { return (Format-OcrText $ln.text) }
  }
  return ''
}

# ---------- 会话定位 / 点击 / 读面板（2026-10-27 抽出，为了可排障、可复用） ----------
# 为什么单独抽：① 以前点击坐标是内联算的，出问题只能靠猜；② 偏移改成"按名字字高折算"后，
#   需要能单独算一遍坐标（日志/测试都用它）；③ 点开后要"轮询等渲染 + 必要时重新定位再点一次"，
#   需要一个能复用的定位函数。
function Get-WxClickPoint {
  <#
    .SYNOPSIS  一个会话行在屏幕上的点击坐标（纯计算，不点）
    .DESCRIPTION
      y = 窗口上边 + **名字行 y** + 偏移；偏移 = 名字行字高 × clickNameOffset（默认 0.55）。
      这样换 DPI / 改微信字号都不用重标（老写法是固定 +8 窗口像素）。
  #>
  param([Parameter(Mandatory = $true)]$Win, [Parameter(Mandatory = $true)]$Row, [Parameter(Mandatory = $true)]$Cfg)
  $baseY = if ($Row.PSObject.Properties['nameY'] -and $Row.nameY -gt 0) { [int]$Row.nameY } else { [int]$Row.y }
  $nameH = if ($Row.PSObject.Properties['nameH'] -and $Row.nameH -gt 0) { [int]$Row.nameH } else { 0 }
  $ratio = if ($Cfg.PSObject.Properties['clickNameOffset']) { [double]$Cfg.clickNameOffset } else { 0.55 }
  $dy = if ($nameH -gt 0) { [int][Math]::Max(4, [Math]::Round($nameH * $ratio)) } else { [int][Math]::Round(15 * $ratio) }
  return [pscustomobject]@{
    cx = [int]($Win.left + $Win.width * [double]$Cfg.clickX)
    cy = [int]($Win.top + $baseY + $dy)
    baseY = $baseY; dy = $dy; nameH = $nameH; ratio = $ratio
  }
}

function Find-WxChatTarget {
  <#
    .SYNOPSIS  在"重新截图的列表"里找到想点的那个会话（容忍两次截图之间的 OCR 抖动）
    .OUTPUTS   @{ row; why } 或 $null
  #>
  param([object[]]$Chats, [string]$Name, [string[]]$Whitelist = @())
  if ($null -eq $Chats -or $Chats.Count -eq 0) { return $null }
  $exact = $Chats | Where-Object { (Norm $_.name) -eq (Norm $Name) } | Select-Object -First 1
  if ($exact) { return [pscustomobject]@{ row = $exact; why = '名字完全相同' } }
  foreach ($ch in $Chats) {
    $mi = Get-ChatMatchInfo -A ([string]$ch.name) -B $Name -Whitelist $Whitelist
    if ($mi.same) { return [pscustomobject]@{ row = $ch; why = $mi.why } }
  }
  return $null
}

function Read-WxChatPane {
  <#
    .SYNOPSIS  点开会话后读聊天面板：**轮询等渲染**（最多 Tries 次，每次间隔 GapMs）
    .DESCRIPTION
      2026-10-27：原来"读不到就固定再等 1800ms 再截一张"。实测后台点击后面板渲染要 2~4 秒，
      仍然会读到空面板（日志：标题未识别 + 第 1 屏没读到内容）。改成轮询：
      读到"有标题 且 正文 ≥2 行"就停。
    .OUTPUTS   @{ header; parsed; bodyCount; tries }
  #>
  param(
    [Parameter(Mandatory = $true)]$Win,
    [Parameter(Mandatory = $true)][string]$Shot,
    [Parameter(Mandatory = $true)][int]$Scale,
    [int]$Tries = 3,
    [int]$GapMs = 700
  )
  $best = $null
  for ($i = 0; $i -lt $Tries; $i++) {
    if ($i -gt 0) { Start-Sleep -Milliseconds $GapMs }
    try {
      $null = Save-WxWindowShot -Hwnd $Win.hwnd -Path $Shot -Scale $Scale
      $rows = @(Invoke-WxOcr -Path $Shot -Scale $Scale)
      $parsed = Get-ChatsFromRows $rows
      $hdr = Get-ChatHeader $parsed.chatLines
      $cnt = @($parsed.chatLines | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    } catch {
      $parsed = $null; $hdr = ''; $cnt = 0
    }
    $best = [pscustomobject]@{ header = $hdr; parsed = $parsed; bodyCount = $cnt; tries = ($i + 1) }
    if (-not [string]::IsNullOrWhiteSpace($hdr) -and $cnt -ge 2) { break }
  }
  if ($null -eq $best) { $best = [pscustomobject]@{ header = ''; parsed = $null; bodyCount = 0; tries = 0 } }
  return $best
}

function Append-Record($record) {
  $file = Join-Path $spoolDir ('messages-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
  # ⚠️ -Peek = 只看不写：绝不能往真实 spool 里塞东西（插件会把它当真实聊天喂给模型）
  if ($Peek) { return $file }
  # ⚠️ 不要用 Add-Content -Encoding UTF8：文件**新建**时 PS 5.1 会写入 BOM，
  # 而首行带 BOM 会让插件的 JSON.parse 直接失败 → **整个文件的第一条记录被静默丢掉**
  # （实测 messages-20261013 / messages-20261015 都中招，后者只有 2 行 = 整个文件白采）。
  # AppendAllText + UTF8Encoding($false) 明确写"不带 BOM"的 UTF-8。
  $line = ($record | ConvertTo-Json -Depth 6 -Compress)
  [System.IO.File]::AppendAllText($file, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  return $file
}

function Test-Ignored([string]$name) {
  $n = Norm $name
  if ([string]::IsNullOrWhiteSpace($n)) { return $true }
  foreach ($ig in $cfg.ignoreChats) { if ($n -like ("*" + (Norm $ig) + "*")) { return $true } }
  if ($n.Length -le 1) { return $true }
  return $false
}

# ---------- 白名单 / @我 ----------
# 2026-10-26：原来是纯"包含"匹配（OCR 读残就漏群）→ 改用 wxlib 的共用容错匹配：
#   包含 / 数字前缀 / 开头文字容错 / 滑窗编辑距离，与 QQ 侧白名单同一套语义。
function Test-Whitelisted([string]$name) {
  if ($null -eq $cfg.groupWhitelist -or $cfg.groupWhitelist.Count -eq 0) { return $true }
  $n = Norm $name
  foreach ($w in $cfg.groupWhitelist) {
    $wn = Norm $w
    if ($wn.Length -gt 0 -and (Test-ChatNameMatch -Name $n -Pattern $wn)) { return $true }
  }
  return $false
}

function Get-WxAliases {
  $a = @()
  if ($cfg.myAliases) { foreach ($x in $cfg.myAliases) { if ((Norm $x).Length -gt 0) { $a += (Norm $x) } } }
  return $a
}

# 是否 @了我。别名没配时退化为"任意 @"（会在日志里警告）
function Test-Mention([string]$text) {
  $t = Norm $text
  if ([string]::IsNullOrEmpty($t)) { return $false }
  $aliases = Get-WxAliases
  if ($aliases.Count -eq 0) { return ($t.Contains('@')) }
  foreach ($a in $aliases) { if ($t.Contains('@' + $a)) { return $true } }
  return $false
}

# 抽出所有 @xxx 候选（给"该把哪个昵称配进 myAliases"用）
function Get-MentionTokens([string[]]$texts) {
  $tokens = @{}
  foreach ($t in $texts) {
    foreach ($m in [regex]::Matches([string]$t, '@\s*([^\s@，。、：；！？()（）\[\]【】]{1,16})')) {
      $k = $m.Groups[1].Value.Trim()
      if ($k.Length -ge 2) { $tokens[$k] = 1 + $tokens[$k] }
    }
  }
  return $tokens
}

# 只保留 @我 的行，并带上一行（通常是发言人）作为上下文
function Select-MentionLines($lines) {
  $out = @()
  $sorted = @($lines | Sort-Object y)
  for ($i = 0; $i -lt $sorted.Count; $i++) {
    if (Test-Mention $sorted[$i].t) {
      if ($i -gt 0 -and ($i -eq 0 -or $sorted[$i - 1].t -ne '')) { $out += $sorted[$i - 1] }
      $out += $sorted[$i]
    }
  }
  return $out
}

# ================= 主流程 =================
function Invoke-Pass([int]$index) {
  # R1（2026-10-27）：记录本轮命令执行时间，整轮只取一次（时间锚点的基准）。
  $script:PassNow = Get-Date
  Log ('本轮执行时间 {0:yyyy-MM-dd HH:mm:ss}（相对时间以它为准）' -f $script:PassNow)
  $offline = -not [string]::IsNullOrWhiteSpace($OcrRows)
  if ($offline) {
    $fx0 = Get-Content -LiteralPath $OcrRows -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 0; top = 0; width = [int]$fx0.width; height = [int]$fx0.height; minimized = $false }
  } else {
    $info = Get-WxWindowInfo
  }
  if ($null -eq $info) { Log '找不到微信主窗口（微信没开或窗口标题不含"微信"）'; $script:skipNote = '微信未运行，本轮跳过（无窗口可采）'; return 0 }
  $script:win = $info
  Log ("窗口 {0}x{1} @ ({2},{3}) hwnd=0x{4}" -f $info.width, $info.height, $info.left, $info.top, $info.hwnd.ToInt64().ToString('X'))

  # 窗口被最小化/收到托盘时：它不参与 DWM 合成，直接抓必然为空。
  # 两条路：① 只读采集 → 伪最小化（显示但不激活 + 近乎透明 + 点击穿透，用户看不见，PrintWindow 仍能抓）
  #         ② 需要点击（AllowClick）→ 只能真正恢复窗口可见
  $hidden = (-not $offline) -and (($info.minimized) -or (-not $info.visible) -or ($info.left -lt -10000) -or ($info.top -lt -10000) -or ($info.width -lt 400) -or ($info.height -lt 300))
  $wasHidden = (-not $info.visible)                      # 收托盘（SW_HIDE）；还原时不要给用户留成"最小化"
  $restoreState = if ($wasHidden) { 'hide' } elseif ($info.minimized) { 'minimize' } else { 'none' }
  $wasMinimized = $hidden
  $pseudoOldEx = $null
  if ($hidden -and $cfg.restoreIfMinimized) {
    if ($Pseudo) {
      # 伪最小化后台抓图（MaaFramework 的 pseudo-minimize 思路）。
      # 2026-10-14 17:45 真实端到端验证通过：微信最小化态（159x27 @ -25600,-25600）和收托盘态（可见=False）
      # 都能抓到画面并正确解析出会话列表；计划任务一直带 -Pseudo。
      Log '微信窗口不可见 → 伪最小化后台抓图（不打扰，读完还原）'
      $pseudoOldEx = Enter-WxPseudoMinimize -Hwnd $info.hwnd
      Start-Sleep -Milliseconds 1800
      $info = Get-WxWindowInfo
      $hidden = ($null -eq $info) -or ($info.left -lt -10000) -or ($info.top -lt -10000) -or ($info.width -lt 400) -or ($info.height -lt 300)
      if ($hidden -and $pseudoOldEx -ne $null) {
        [void](Exit-WxPseudoMinimize -Hwnd $info.hwnd -OldExStyle $pseudoOldEx -RestoreState $restoreState)
        $pseudoOldEx = $null
      }
    } else {
      Log '微信窗口不可见 → 恢复窗口再采集（restoreIfMinimized=true）'
      [void](Restore-WxWindow -Hwnd $info.hwnd)
      Start-Sleep -Milliseconds 1800
      $info = Get-WxWindowInfo
      $hidden = ($null -eq $info) -or ($info.minimized) -or ($info.left -lt -10000) -or ($info.top -lt -10000) -or ($info.width -lt 400) -or ($info.height -lt 300)
    }
  }
  if ($hidden) {
    if ($pseudoOldEx -ne $null) { [void](Exit-WxPseudoMinimize -Hwnd $info.hwnd -OldExStyle $pseudoOldEx -RestoreState $restoreState) }
    Log ("跳过：微信窗口当前不可见（min={0} rect=({1},{2}) {3}x{4}）——最小化/收进托盘了，本轮不采集" -f $info.minimized, $info.left, $info.top, $info.width, $info.height)
    return 0
  }
  if ($wasMinimized) { Log ("恢复后窗口 {0}x{1} @ ({2},{3})（伪最小化={4}）" -f $info.width, $info.height, $info.left, $info.top, ($pseudoOldEx -ne $null)) }

  # ⚠️ 必须在这里刷新 $script:win：上面可能刚把窗口从"最小化(159x27 @ -25600)"恢复成真实尺寸，
  # 而 Get-ChatsFromRows 是拿 $script:win.width/height 去算会话列 x 范围的。
  # 如果在恢复前就赋值，会话列范围会被算成 [15,66]，正好把 x≈156 的群名全部排除 →
  # 实测症状：24 行 OCR 但"会话列表识别到 0 个会话"（这就是交接文档里"伪最小化坐标空间不同、待标定"的真因）。
  $script:win = $info

  $shot = Join-Path $shotDir 'latest.png'
  # 离线钩子：-OcrRows 给一份 fixture（{width,height,rows:[{x,y,text,h}]}）就跳过抓图/OCR，
  # 直接拿它喂 parser —— 用于「测试-解析.ps1」的回归测试（parser 是这里最容易退化的部分）。
  if ($OcrRows) {
    $fx = Get-Content -LiteralPath $OcrRows -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 0; top = 0; width = [int]$fx.width; height = [int]$fx.height; minimized = $false }
    $script:win = $info
    $rows = @($fx.rows)
    $AllowClick = $false          # 离线模式不点窗口
    Log ("[fixture] 用离线 OCR 数据 " + $OcrRows + "：" + $rows.Count + " 行，" + $fx.width + "x" + $fx.height)
  } elseif ($DumpRowsJson) {
    $shotInfo = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale $ocrScale
    $rows = Invoke-WxOcr -Path $shot -Scale $ocrScale
    $fxOut = [ordered]@{ width = $info.width; height = $info.height; hwnd = $info.hwnd.ToInt64(); rows = @($rows | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; text = $_.text; h = $_.h } }) }
    ($fxOut | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $DumpRowsJson -Encoding UTF8
    Log ("已导出 OCR fixture → " + $DumpRowsJson + "（" + $rows.Count + " 行）")
    return 0
  } else {
    $shotInfo = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale $ocrScale
    $rows = Invoke-WxOcr -Path $shot -Scale $ocrScale
  }
  Log ("OCR 得到 {0} 行" -f $rows.Count)

  $parsed = Get-ChatsFromRows $rows
  $chats = $parsed.chats
  $nameList = ($chats | ForEach-Object { $_.name }) -join ' | '
  Log ("会话列表识别到 {0} 个会话：{1}" -f $chats.Count, $nameList)
  # 2026-10-27：行距自适应结果留痕（不同分辨率/DPI/字号下排障，第一眼看这一行）
  Log ("会话行距自适应：{0:N1}px（配置 {1}；{2}；候选 {3}；解析质量 {4}）" -f `
      $parsed.rowGap, $cfg.rowGap, $(if ($parsed.gapAuto) { '按 OCR 行距自动校准' } else { '用配置值' }), `
      (($parsed.gapCands | ForEach-Object { [string][Math]::Round($_, 1) }) -join ','), $parsed.gapScore)
  if ($DumpRows) { foreach ($ln in $rows) { Log ("  y={0,4} x={1,4} {2}" -f $ln.y, $ln.x, $ln.text) } }

  $state = Load-Json $statePath ([pscustomobject]@{})
  $hashes = Load-Json $hashPath ([pscustomobject]@{})

  # ---------- 扫描模式：只报告"@谁"的候选，不采集 ----------
  if ($ScanMentions) {
    $texts = @($chats | ForEach-Object { $_.name + ' ' + $_.preview })
    $texts += @($parsed.chatLines | ForEach-Object { (Format-OcrText $_.text) })
    $tokens = Get-MentionTokens $texts
    Log ("扫描到 {0} 个 @ 候选（按出现次数）：" -f $tokens.Count)
    $tokens.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
      Log ("   @{0}   x{1}" -f $_.Key, $_.Value)
    }
    Log '把"我"的昵称填进 config.json 的 myAliases，把要盯的群填进 groupWhitelist'
    return 0
  }

  # 默认规则（没有命中 chatRules 的群用它）：mentionOnly=true 时只采带关键词的
  $defMode = if ($cfg.mentionOnly) { 'mention' } else { 'all' }
  $defKw = @()
  if ($defMode -eq 'mention') {
    $al = Get-WxAliases
    $defKw = if ($al.Count -gt 0) { @($al | ForEach-Object { '@' + $_ }) } else { @('@') }
  }
  $rules = $null
  if ($cfg.PSObject.Properties.Name -contains 'chatRules') { $rules = $cfg.chatRules }

  # 把"非聊天界面标记"和"返回动作"从配置灌进 wxlib 的 script 变量
  # （放在这里而不是模块加载时：配置每轮重读，改了配置不用重启采集器）
  $script:NonChatMarkers = if ($cfg.PSObject.Properties.Name -contains 'nonChatMarkers') { @($cfg.nonChatMarkers) } else { @('群助手', '服务通知', '订阅号消息', '公众号', '微信团队') }
  $script:ReturnCfg = if ($cfg.PSObject.Properties.Name -contains 'returnToMain') { $cfg.returnToMain } else { $null }

  # 判断哪些会话有变化（新出现 / 预览文字变了）
  $changed = @()
  foreach ($c in $chats) {
    if (Test-Ignored $c.name) { continue }
    if (-not (Test-Whitelisted $c.name)) { continue }
    # 按群规则决定"这个群采全部还是只采带关键词的"
    $rule = Get-ChatRule -Name $c.name -Rules $rules -DefaultMode $defMode -DefaultKeywords $defKw
    # 2026-10-26：改用 Test-BroadcastKeyword —— 内置"告知所有人"全套词（@全体成员/@所有人/
    # 我们/大家/同学们/各位同学…）+ OCR 容错，配置里的 keywords 作为附加词。
    if ($rule.mode -ne 'all' -and -not (Test-BroadcastKeyword -Text $c.preview -ExtraKeywords $rule.keywords)) { continue }
    $c | Add-Member -NotePropertyName rule -NotePropertyValue $rule -Force
    $prev = $null
    if ($state.PSObject.Properties.Name -contains $c.name) { $prev = $state.$($c.name).preview }
    if ($null -eq $prev -or (Norm $prev) -ne (Norm $c.preview)) {
      $changed += $c
    }
  }
  if ($cfg.mentionOnly -and (Get-WxAliases).Count -eq 0) {
    Log '⚠ mentionOnly=true 但 myAliases 为空 → 暂时把"任意 @"都算 @我，建议把昵称填进 config.json'
  }
  # -DumpRows 时把每个会话命中的规则打出来（排查"为什么这个群没采/采了"最直接）
  if ($DumpRows) {
    foreach ($c2 in $chats) {
      if (Test-Ignored $c2.name) { continue }
      $rr = Get-ChatRule -Name $c2.name -Rules $rules -DefaultMode $defMode -DefaultKeywords $defKw
      Log ("  [规则] '{0}' → mode={1} 命中='{2}' 关键词=[{3}]" -f $c2.name, $rr.mode, $rr.matched, ($rr.keywords -join ','))
    }
  }
  $changedNames = ($changed | ForEach-Object { $_.name }) -join ' | '
  Log ("有变化的会话 {0} 个：{1}" -f $changed.Count, $changedNames)

  $written = 0
  if ($changed.Count -gt 0 -and -not $AllowClick) {
    foreach ($c in $changed) {
      $rec = [ordered]@{
        kind = 'preview'; ts = (Get-Date).ToString('o'); source = 'wechat-screenshot-ocr'
        chat = $c.name; preview = $c.preview
      }
      Append-Record $rec | Out-Null; $written++
    }
    Log '未开启 -AllowClick：只记录会话预览，不点击'
  }

  # ==================== 微信后台点击（2026-10-26）====================
  # 目的：点开会话读全文时，**不把微信抢到前台、不动用户的鼠标**。
  # 做法：Maa 控制器 + PostMessage 输入（4），按"客户端坐标"发窗口消息。
  # ⚠️ 只借 Maa 的**点击**：Maa 抓微信是黑图（实测 OCR 只剩 1 行，FramePool/PrintWindow 抓不到
  #    Chromium 内容），所以抓图和 OCR 仍然走 PrintWindow，两边坐标按尺寸比换算。
  # 失败/不可用时自动退回真实鼠标点击，功能不受影响，只是会打扰用户。
  $script:WxBgClickReady = $false
  $script:WxBgClickTried = $false
  $script:WxBgClickCtrl = [IntPtr]::Zero
  $script:WxBgClickFx = 1.0
  $script:WxBgClickFy = 1.0
  $script:WxBgClickFgHits = 0

  function Initialize-WxBgClick {
    param([IntPtr]$Hwnd, [int]$WinW, [int]$WinH)
    if ($script:WxBgClickTried) { return $script:WxBgClickReady }
    $script:WxBgClickTried = $true
    $mode = if ($cfg.PSObject.Properties['bgClick']) { [string]$cfg.bgClick } else { 'auto' }
    if ($mode -eq 'off') { Log '  后台点击：配置关闭（bgClick=off）→ 用真实鼠标'; return $false }
    try {
      if (-not (Initialize-Maa)) {
        $why = if ($script:MaaLoadError) { [string]$script:MaaLoadError } else { '未知' }
        Log ('  后台点击不可用（Maa 初始化失败：{0}）→ 退回真实鼠标' -f $why)
        return $false
      }
      $c1 = Get-MaaController -Hwnd $Hwnd -Screencap ([uint64]0x12)
      if ($c1 -eq [IntPtr]::Zero) { Log '  后台点击不可用（抓图控制器创建失败）→ 退回真实鼠标'; return $false }
      [void](Set-MaaShotOption -Controller $c1 -Key 3 -IntValue 1 -AsBool)
      $s = Get-MaaShot -Hwnd $Hwnd -Path (Join-Path $shotDir 'wx-bgclick-probe.png') -Controller $c1
      if ($s.w -le 0 -or $s.h -le 0) { Log '  后台点击不可用（抓图尺寸异常）→ 退回真实鼠标'; return $false }
      $im = if ($cfg.PSObject.Properties['maaInputMethod']) { [uint64]$cfg.maaInputMethod } else { [uint64]4 }
      $c2 = Get-MaaController -Hwnd $Hwnd -InputMethod $im
      if ($c2 -eq [IntPtr]::Zero) { Log '  后台点击不可用（点击控制器创建失败）→ 退回真实鼠标'; return $false }
      [void](Set-MaaShotOption -Controller $c2 -Key 3 -IntValue 1 -AsBool)
      $script:WxBgClickCtrl = $c2
      $script:WxBgClickFx = [double]$s.w / [double]$WinW
      $script:WxBgClickFy = [double]$s.h / [double]$WinH
      $script:WxBgClickReady = $true
      # ⚠️ 2026-10-27：点击坐标**不再**乘下面这个"图像/窗口"比例（见 Invoke-WxClickSmart 里的注释：
      #   Maa 的 PostClick 吃客户区坐标；乘了比例会随 y 增大而越点越偏，正是老问题"点开的是别的群"的真因）。
      #   这两个值保留在日志里，用来核对抓图与窗口的尺寸关系。
      Log ("  后台点击就绪：输入法 {0}｜Maa 图像 {1}x{2}｜窗口 {3}x{4}（图像/窗口 {5:N4}/{6:N4}；点击按客户区坐标发）" -f $im, $s.w, $s.h, $WinW, $WinH, $script:WxBgClickFx, $script:WxBgClickFy)
      return $true
    } catch {
      Log ('  后台点击初始化异常：{0} → 退回真实鼠标' -f $_.Exception.Message)
      return $false
    }
  }

  function Invoke-WxClickSmart {
    param([IntPtr]$Hwnd, [int]$ScreenX, [int]$ScreenY, [int]$WinLeft, [int]$WinTop)
    if (-not $script:WxBgClickReady) {
      Invoke-WxClickAt -X $ScreenX -Y $ScreenY
      return $true
    }
    # 2026-10-27 修（真机定位到的"点串行"根因）：坐标**不要**再乘"抓图/窗口比例"。
    #   Maa 的 PostClick 对 Win32 控制器吃的是**客户区坐标**（它自己按 DPI 换算到屏幕），
    #   而这里原来把客户区坐标 × 抓图比例（1.2304/1.2365）传进去 —— 等于同一段距离放大 1.23 倍，
    #   **y 越大偏得越多**：实测窗口 894x647、抓图 1100x800，想点 y=443 的会话，实际落到 y≈561
    #   → 打开了下面那一行（日志：点「26 示例群A 2 班」却打开「示例群G」）。上面几行因为
    #   偏差还在行高内，所以一直"看起来能用"（这就是老问题 ③"点了但打开的不是本意群"的真因）。
    $rx = [int]($ScreenX - $WinLeft)
    $ry = [int]($ScreenY - $WinTop)
    $fg0 = [WxNative]::GetForegroundWindow()
    $ok = Invoke-MaaClick -Hwnd $Hwnd -X $rx -Y $ry -Controller $script:WxBgClickCtrl
    Start-Sleep -Milliseconds 150
    $fg1 = [WxNative]::GetForegroundWindow()
    if ($fg1 -ne $fg0) {
      $script:WxBgClickFgHits++
      if ($fg0 -ne [IntPtr]::Zero) { try { [void][WxNative]::SetForegroundWindow($fg0) } catch { } }
      Log ("  [注意] 后台点击引起前台变化（0x{0:X} → 0x{1:X}），已尝试还原" -f [int64]$fg0, [int64]$fg1)
    }
    return $ok
  }

  if ($changed.Count -gt 0 -and $AllowClick) {
    # 先试着起后台点击。成功的话下面就不必退出伪最小化、也不必把微信提到前台。
    $bgOk = Initialize-WxBgClick -Hwnd $info.hwnd -WinW $info.width -WinH $info.height
    # 伪最小化是"点击穿透"的，要做**真实鼠标**点击必须先退出伪最小化、让窗口真正可见可点。
    # 后台点击（PostMessage）不需要窗口可见 → 保持伪最小化，用户完全看不到微信被翻出来。
    if (-not $bgOk -and $pseudoOldEx -ne $null) {
      Log '有会话需要点开读取 → 退出伪最小化，临时恢复窗口（读完会再收回去）'
      [void](Exit-WxPseudoMinimize -Hwnd $info.hwnd -OldExStyle $pseudoOldEx -RestoreState $restoreState)
      $pseudoOldEx = $null
      [void](Restore-WxWindow -Hwnd $info.hwnd)
      Start-Sleep -Milliseconds 1200
    }
    $prevFg = Get-WxForeground
    # 白名单（点击定位/校验/锚点都要用）—— 提到循环外只算一次
    $wlList = @($cfg.groupWhitelist | ForEach-Object { [string]$_ })
    $targets = $changed | Select-Object -First $MaxClicks
    foreach ($c in $targets) {
      if (-not $bgOk) {
        $null = Set-WxForeground -Hwnd $info.hwnd
        Start-Sleep -Milliseconds 400
      }

      # 关键：列表会因新消息到达而重排，所以点击前**重新截图定位**。
      # 2026-10-27：原来只做"归一化相等 / 互相包含"两种匹配 —— 实测同一行的 OCR 名在两张截图之间
      #   会变一个字（「…2 班…」→「…2 班灬」），于是整轮直接跳过这个群（日志：已被新消息挤走）。
      #   现在统一走 Find-WxChatTarget（完全相同 → 同一白名单群 → 编辑距离≤1）。
      #   另外**点开后要校验**：标题为空（点击没生效/还没渲染）或点开的是别的群（列表在两次截图
      #   之间重排）→ 重新定位再点一次。微信对同一个会话重复点击不会取消选中（这点和 QQ 不同），
      #   所以重试是安全的；最多 2 次，仍不对就走后面的兜底 + 白名单闸门（绝不写越界记录）。
      $pane = $null; $target = $null; $header = ''; $headerRead = $false; $verified = $false
      $shot2 = Join-Path $shotDir ('chat-{0}.png' -f ([DateTime]::Now.ToString('HHmmss')))
      for ($attempt = 1; $attempt -le 2; $attempt++) {
        # 列表稳定化（2026-10-27）：新消息会让列表在"截图 → OCR(约 1s) → 点击"这段时间里重排，
        #   实测点「26 示例群A 2 班」却打开「示例群G」就是这种"一行之差的换位"（真机复现两次）。
        #   做法：连拍两张，**列表签名（每个会话名）一致才点**；不一致就再拍（最多 3 轮）。
        $fresh = @(); $sigPrev = $null; $shotsTaken = 0
        for ($st = 0; $st -lt 3; $st++) {
          $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale $ocrScale
          $fresh = @((Get-ChatsFromRows (Invoke-WxOcr -Path $shot -Scale $ocrScale)).chats)
          $sig = (@($fresh | ForEach-Object { (Norm $_.name) }) -join '|')
          $shotsTaken = $st + 1
          if ($null -ne $sigPrev -and $sig -eq $sigPrev) { break }
          $sigPrev = $sig
          if ($st -lt 2) { Start-Sleep -Milliseconds 200 }
        }
        if ($shotsTaken -gt 2) { Log ("  列表一直在变（连拍 {0} 张才稳定）→ 以最后一张为准" -f $shotsTaken) }
        # 排障：把"点击前这一眼看到的列表"（名字@nameY）打出来。点歪时能直接看出
        #   ① 是不是名字认错了行的位置 ② 是不是 OCR 把两行并了 ③ 点的是不是这张图里的行。
        if ($DumpRows) { Log ('  [点击前列表] ' + ((@($fresh | ForEach-Object { ('{0}@{1}' -f [string]$_.name, [int]$_.nameY) })) -join ' | ')) }
        $found = Find-WxChatTarget -Chats $fresh -Name $c.name -Whitelist $wlList
        if ($null -eq $found) {
          Log ("跳过「{0}」：重新截图后列表里找不到它（已被新消息挤走）" -f $c.name)
          $target = $null
          break
        }
        $target = $found.row
        if ($attempt -eq 1 -and $found.why -ne '名字完全相同') {
          Log ("  重新定位「{0}」→ 列表里是「{1}」（{2}）" -f $c.name, $target.name, $found.why)
        }

        # 2026-10-27：点击坐标/偏移统一由 Get-WxClickPoint 算（日志里拆开展示）。
        $pt = Get-WxClickPoint -Win $info -Row $target -Cfg $cfg
        # 安全锁：真实鼠标点击时，坐标处最顶层的窗口必须是微信（否则会把点击送到别的程序上）。
        # 后台点击是发窗口消息、不经过屏幕，被遮挡也能点 → 这时不需要（也不该）做这个检查，
        # 否则"微信被别的窗口盖住"就无法采集了，而那正是后台模式要解决的场景。
        if (-not $bgOk) {
          $topAt = [WxNative]::TopAt($pt.cx, $pt.cy)
          if ($topAt -ne $info.hwnd) {
            Log ("跳过「{0}」：({1},{2}) 处最顶层窗口是 0x{3}，不是微信 → 为避免误点已放弃" -f $target.name, $pt.cx, $pt.cy, $topAt.ToInt64().ToString('X'))
            $target = $null
            break
          }
        }
        Log ("点击会话「{0}」{1} @ 屏幕({2},{3})（窗口内 y={4} = 名字行 {5} + 偏移 {6}［字高 {7}×{8}］）{9}" -f `
            $target.name, $(if ($attempt -gt 1) { '（第 2 次尝试）' } else { '' }), $pt.cx, $pt.cy, ($pt.cy - $info.top), $pt.baseY, $pt.dy, $pt.nameH, $pt.ratio, $(if ($bgOk) { '（后台）' } else { '' }))
        [void](Invoke-WxClickSmart -Hwnd $info.hwnd -ScreenX $pt.cx -ScreenY $pt.cy -WinLeft $info.left -WinTop $info.top)
        Start-Sleep -Milliseconds $cfg.clickSettleMs

        # 读面板：轮询等渲染（最多 3 次 ×700ms）
        $pane = Read-WxChatPane -Win $info -Shot $shot2 -Scale $ocrScale -Tries 3 -GapMs 700
        if ($null -eq $pane.parsed) { continue }
        $header = [string]$pane.header
        $headerRead = -not [string]::IsNullOrWhiteSpace($header)
        # 2026-10-27：verified 改用容错判定（同名 / 同一白名单群 / 编辑距离≤1），
        #   别再因为 OCR 错一两个字就把"同一个群"判成"点开了别的群"。
        $verified = if ($headerRead) { (Get-ChatMatchInfo -A $header -B $c.name -Whitelist $wlList).same } else { $false }
        if ($verified) { break }
        if ($attempt -lt 2) {
          if ($headerRead) { Log ("  点开的是「{0}」，不是本意群 → 重新定位再点一次" -f $header) }
          else { Log '  点开后标题仍为空（点击没生效或还没渲染）→ 重新定位再点一次' }
          Start-Sleep -Milliseconds 400
        }
      }
      if ($null -eq $target -or $null -eq $pane -or $null -eq $pane.parsed) {
        # 两次都没打开/没读到画面：至少把列表里的预览记下来（与"正文太短"那条兜底同一策略），别让这次变化白丢
        $rec = [ordered]@{
          kind = 'preview'; ts = (Get-Date).ToString('o'); source = 'wechat-screenshot-ocr'
          chat = $c.name; preview = $c.preview
          note = '点开两次都没读到聊天面板，退回记录列表预览'
        }
        Append-Record $rec | Out-Null; $written++
        Log ("  → 点开两次都没读到面板 → 退回记录列表预览（避免这次变化白丢）")
        continue
      }
      $parsed2 = $pane.parsed
      if (-not $headerRead) {
        # 标题没读到（界面被遮挡/渲染异常）：用期望名兜底，并标记未通过校验
        $header = $c.name
        Log ("  标题未识别，暂用期望名「{0}」兜底（verified=false）" -f $header)
      }

      # ---------- 误入"非聊天界面"（群助手/服务通知…）→ 退回到会话列表再继续 ----------
      # 为什么需要：点进这类列表型界面后，**后面所有行的坐标都会错位、整轮白跑**。
      # ignoreChats 能在列表层挡住一部分，但 OCR 把名字读错字就挡不住（实测「班级群」→「<OCR 错字示例>」）。
      # ⚠️ 检测**只用名字白名单**，不用"尾部带 (数字)"的形态启发式：
      #    实测「示例群G-勇往直前（25）」是**正常群名**（括号里是群人数），形态判断会误踢正常群。
      # ⚠️ 返回动作默认**关闭**（config.json 的 returnToMain.enabled = true 才生效）——
      #    需要先确认"返回键长什么样/在哪"，我不猜坐标。
      if (Test-WxNonChatHeader -Header $header) {
        Log ("  ⚠️ 点进了非聊天界面「{0}」→ 尝试返回会话列表" -f $header)
        if (Invoke-WxReturnToMain -Cfg $cfg -Hwnd $info.hwnd) {
          Log '  → 已执行返回动作'
        } else {
          Log '  → 未配置返回动作（config.json 的 returnToMain）→ 放弃这个目标，避免坐标继续错位'
        }
        continue
      }

      # 2026-10-27：**白名单硬闸门** —— 读到的标题必须属于白名单，否则这条绝不写。
      #   原来只在"点开前"按列表名过滤；一旦真点开的是别的群（列表重排 / OCR 认错行），
      #   后面会按那个群的规则过滤、把它的正文写进 spool —— 那就是**越界记录**（不在白名单的群被采走）。
      #   标题没读到时（$headerRead=false）不算越界：那种情况已经兜底成期望名，且下面还有"正文太短就跳过"。
      if ($headerRead -and -not (Test-Whitelisted $header)) {
        Log ("  ⚠️ 点开的「{0}」不在白名单 → 丢弃这条（不写越界记录）" -f $header)
        continue
      }

      # ---------- 往期记录：滚轮向上翻几屏（2026-10-18 加） ----------
      # 为什么加：只读"当前可见屏" = 只采到最后几条；几小时前发的通知永远采不到，
      #   而群里真正要紧的（报名截止/会议改时间）恰恰经常在更早的位置。
      # 做法：光标移到聊天区 → 滚轮向上 N 次 → 等渲染 → 截图 OCR → 重复（默认 2 屏）→
      #   把每屏的非重叠部分拼到前面 → 最后滚回底部（还原用户视图）。
      # 代价：每屏多一次截图 + OCR（约 0.6~1 秒）；只对**点开的会话**做，且可配置关闭。
      # 翻几屏由下面的"翻到锚点"逻辑决定（historyScreens=首轮屏数，historyMaxScreens=硬上限）。
      $histNotches = if ($cfg.PSObject.Properties['historyWheelNotches']) { [int]$cfg.historyWheelNotches } else { 3 }
      $histSettle = if ($cfg.PSObject.Properties['historySettleMs']) { [int]$cfg.historySettleMs } else { 350 }
      $histMaxLines = if ($cfg.PSObject.Properties['historyMaxLines']) { [int]$cfg.historyMaxLines } else { 150 }
      $newestTexts = @($parsed2.chatLines | Sort-Object y | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      # 锚点（2026-10-19）：上一轮记录过的"最旧 3 行"。翻页读到它就停 —— 再往上都是记过的内容，
      # 继续翻只会把同一批历史重新 OCR（费时费 token，还可能让模型重复抽同一条待办）。
      # 2026-10-26 改：① key 换成**稳定标识**（白名单词），不再用会抖的 OCR 群名；
      #   ② 翻页改成"一直翻到锚点为止"（用户要求：避免固定 2 屏漏掉消息）。
      $anchorFile = Join-Path $stateDir 'seen-anchors.txt'
      # 稳定标识优先取"聊天头部"，但微信的头部 OCR 很不可靠（实测整条读成 "O"），
      # 一旦头部里一个白名单词都没有，就退回**列表里那个会话名**（$c.name，有白名单校验过，更可靠）。
      $stable = Get-ChatStableKey -Name $header -Whitelist $wlList
      $isWlToken = $false
      foreach ($w in $wlList) { if ($stable -eq ($w -replace '\s', '')) { $isWlToken = $true; break } }
      if (-not $isWlToken) {
        $stableFromList = Get-ChatStableKey -Name $c.name -Whitelist $wlList
        foreach ($w in $wlList) { if ($stableFromList -eq ($w -replace '\s', '')) { $stable = $stableFromList; $isWlToken = $true; break } }
        if (-not $isWlToken -and $stableFromList.Length -gt 1) { $stable = $stableFromList }
      }
      $anchorKey = 'wx|' + $stable
      # 2026-10-27：锚点升级成 **文本 + 时间**（与 QQ 侧同一套库函数）。
      #   旧 2 列锚点没有时间 → 自动退化成纯文本锚点，行为与升级前一致。
      $anchorRecs = @(Get-ChatAnchorRecords -AnchorFile $anchorFile -Key $anchorKey -Fuzzy $stable -Whitelist $wlList)
      $anchors = @($anchorRecs | ForEach-Object { $_.line })
      $anchorTime = $null
      $anchorTmp = @($anchorRecs | Where-Object { $_.time } | Sort-Object { $_.time })
      if ($anchorTmp.Count -gt 0) { $anchorTime = $anchorTmp[0].time }
      $anchorHitFirst = Test-ChatAnchorHit -Lines $newestTexts -Anchors $anchors
      # R4（用户原话）：当前界面的时间就是上次锚点的时间 → 没有新消息，一次滚轮都不发。
      $curTimes = Get-ChatTimesFromLines -Lines $newestTexts -Now (Get-PassNow)
      $noNewByTime = [bool]($anchorTime -and $curTimes.newest -and ($curTimes.newest -le $anchorTime))
      if ($anchorHitFirst -and $anchors.Count -gt 0) {
        Log '  往期滚动：当前屏全是上一轮记录过的内容 → 不往前翻（省时省 token）'
      } elseif ($noNewByTime) {
        Log ('  往期滚动：当前屏最新时间 {0:MM-dd HH:mm} ≤ 锚点时间 {1:MM-dd HH:mm} → 没有新消息，不往前翻（不发滚轮）' -f $curTimes.newest, $anchorTime)
      }
      # 翻页上限：有锚点 → 一直翻到锚点（hardMax 兜底防死循环）；没锚点（第一次采这个群）→ 只翻 initial 屏
      $histInitial = if ($cfg.PSObject.Properties['historyScreens']) { [int]$cfg.historyScreens } else { 2 }
      $histHardMax = if ($cfg.PSObject.Properties['historyMaxScreens']) { [int]$cfg.historyMaxScreens } else { 40 }
      $untilAnchor = if ($cfg.PSObject.Properties['historyUntilAnchor']) { [bool]$cfg.historyUntilAnchor } else { $true }
      $histLimit = if ($untilAnchor -and ($anchors.Count -gt 0 -or $anchorTime)) { $histHardMax } else { $histInitial }
      if ($anchorHitFirst -or $noNewByTime) { $histLimit = 0 }
      $screens = @(, $newestTexts)
      if ($histLimit -gt 0 -and $histNotches -gt 0) {
        $moved = Move-WxCursorToChatArea -Hwnd $info.hwnd
        if (-not $moved) { Log '  往期滚动：光标没能移到聊天区（窗口矩形取不到）→ 跳过' }
        else {
          Log ("  往期滚动：目标=翻到上次记录的边界（上限 {0} 屏）" -f $histLimit)
          $scrolled = 0
          $prevTexts = $newestTexts
          for ($hi = 1; $hi -le $histLimit; $hi++) {
            Invoke-WxWheel -Notches $histNotches
            Start-Sleep -Milliseconds $histSettle
            $shotH = Join-Path $shotDir ('hist-{0}-{1}.png' -f ([DateTime]::Now.ToString('HHmmss')), $hi)
            try {
              $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shotH -Scale $ocrScale
              $rowsH = Invoke-WxOcr -Path $shotH -Scale $ocrScale
              $parsedH = Get-ChatsFromRows $rowsH
              $textsH = @($parsedH.chatLines | Sort-Object y | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            } catch {
              Log ('  往期滚动第 {0} 屏失败：{1}' -f $hi, $_.Exception.Message)
              $textsH = @()
            }
            $scrolled++
            if ($textsH.Count -eq 0) { Log ('  往期滚动：第 {0} 屏没读到内容（可能到顶了）→ 停止' -f $hi); break }
            $anchorHit = Test-ChatAnchorHit -Lines $textsH -Anchors $anchors
            # 停止条件（2026-10-27）：文本命中 **或** 时间越过锚点（OCR 把锚点行读歪时靠时间兜底）
            $hitTime = $false
            if ($anchorTime) {
              $ht = Get-ChatTimesFromLines -Lines $textsH -Now (Get-PassNow)
              $hitTime = [bool]($ht.oldest -and ($ht.oldest -le $anchorTime))
              if ($hitTime) { $hitTimeWhy = ('时间越过：本屏最旧 {0:MM-dd HH:mm} ≤ 锚点 {1:MM-dd HH:mm}' -f $ht.oldest, $anchorTime) }
            }
            # 到顶判断要跟**上一屏**比（$screens 最后一项）。以前比的是最新那一屏（$screens[0]），
            # 翻到第 3 屏以后就算已经到顶也发现不了，会白滚到硬上限。
            $same = (($textsH -join "`n") -eq ($screens[$screens.Count - 1] -join "`n"))
            if ($same) { Log ('  往期滚动：第 {0} 屏和上一屏一样（到顶/没滚动）→ 停止' -f $hi); break }
            $screens += , $textsH
            if ($anchorHit -or $hitTime) {
              $whyStop = @()
              if ($anchorHit) { $whyStop += '文本命中锚点' }
              if ($hitTime) { $whyStop += $hitTimeWhy }
              Log ('  往期滚动：第 {0} 屏到达上次记录的边界（{1}）→ 停止翻页' -f $hi, ($whyStop -join '；'))
              break
            }
          }
          if ($scrolled -gt 0) {
            # 滚回底部（多滚 2 格贴底），还原用户视图
            Invoke-WxWheel -Notches (-($histNotches * $scrolled) - 2) -StepDelayMs 40
            Start-Sleep -Milliseconds 200
            Log ('  往期滚动：翻了 {0} 屏（画面已滚回底部）' -f ($screens.Count - 1))
          }
        }
      }
      # 合并（从最新一屏往前拼）。两层去重缺一不可：
      #   ① 精确的重叠检测（older 尾部 == newer 头部，连续 k 行）—— 滚动正好错开半屏时最准；
      #   ② **内容去重**（同一行文本已在合并结果里出现过就丢弃）—— OCR 对同一行偶尔会有细微差异，
      #      精确比对抓不到，光靠 ① 会把同一批消息重复送进模型（白花钱，还可能让模型把同一条待办抽两次）。
      #   ② 只跨屏去重；同一屏内的重复（"收到"连发）保留，因为那是真实内容。
      $merged = @($screens[0])
      $seen = @{}
      foreach ($l in $merged) { $n0 = Norm $l; if ($n0) { $seen[$n0] = 1 } }
      for ($si = 1; $si -lt $screens.Count; $si++) {
        $older = @($screens[$si])
        $newer = @($merged)
        $k = 0
        $maxK = [Math]::Min($older.Count, $newer.Count)
        for ($kk = $maxK; $kk -ge 1; $kk--) {
          $tail = ($older[($older.Count - $kk)..($older.Count - 1)]) -join "`n"
          $head = ($newer[0..($kk - 1)]) -join "`n"
          if ($tail -eq $head) { $k = $kk; break }
        }
        $rest = if ($k -ge $older.Count) { @() }
                elseif ($k -gt 0) { if ($older.Count - $k - 1 -ge 0) { @($older[0..($older.Count - $k - 1)]) } else { @() } }
                else { $older }
        # ② 内容去重（跨屏）
        $keep = @()
        foreach ($l in $rest) {
          $n = Norm $l
          if ($n -and $seen.ContainsKey($n)) { continue }
          $keep += $l
        }
        foreach ($l in $rest) { $n = Norm $l; if ($n) { $seen[$n] = 1 } }
        $merged = @($keep) + $merged
        Log ('  往期合并：第 {0} 屏命中重叠 {1} 行，跨屏重复丢弃 {2} 行，净新增 {3} 行' -f $si, $k, ($rest.Count - $keep.Count), $keep.Count)
      }
      # 去掉重复出现的聊天标题行（每屏顶部都有它），并限总行数（保护 token 用量）
      if (-not [string]::IsNullOrWhiteSpace($header)) {
        $merged = @($merged | Where-Object { (Norm $_) -ne (Norm $header) })
      }
      if ($histMaxLines -gt 0 -and $merged.Count -gt $histMaxLines) {
        $merged = @($merged[($merged.Count - $histMaxLines)..($merged.Count - 1)])
      }
      $cleanLines = @($merged | ForEach-Object {
          [pscustomobject]@{ x = 0; y = 0; t = $_ }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.t) })

      # 按该群的规则过滤：mention 规则只保留命中关键词的行（+上一行发言人）；all 规则保留全部
      # ⚠️ 规则要按**实际点开的那个群**（$header）算，不能按"本意想点的"（$c.name）：
      #    点串行时（列表重排/坐标偏移）会拿错规则去过滤别的群的内容 —— 实测点错到"示例群G"，
      #    却按 <示例群号> 群的 all 规则把它的正文整段收了进来。
      $ruleName = if ([string]::IsNullOrWhiteSpace($header)) { $c.name } else { $header }
      $rule2 = Get-ChatRule -Name $ruleName -Rules $rules -DefaultMode $defMode -DefaultKeywords $defKw
      if (-not $verified) {
        Log ("  ⚠️ 点开的不是本意群（想点「{0}」，实际「{1}」）→ 改按实际群的规则过滤" -f $c.name, $header)
      }
      if ($rule2.mode -ne 'all') {
        $onlyKw = @(Select-KeywordLines -Lines $cleanLines -Keywords $rule2.keywords)
        if ($onlyKw.Count -eq 0) {
          Log ("  → {0} 按规则只采[{1}]，本条没命中，跳过记录（会话已被点开，注意它已被标记已读）" -f $ruleName, ((@(Get-BroadcastKeywords) + @($rule2.keywords)) -join '/'))
          continue
        }
        $cleanLines = $onlyKw
      }

      $text = (($cleanLines | ForEach-Object { $_.t }) -join "`n")
      $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text))) -Algorithm SHA1).Hash
      $isNew = $true
      if ($hashes.PSObject.Properties.Name -contains $header) { if ($hashes.$header -eq $hash) { $isNew = $false } }
      # ⚠️ 2026-10-15 修：$header 为空时 Add-Member -NotePropertyName "" 会抛
      #   "NotePropertyName 参数不能使用可转换为类型 PSMemberTypes 的值"（20:04 实测踩到）。
      #   空标题只跳过哈希簿记，不影响下面的记录流程（记录里 chat=$header 为空也能被插件容错）。
      if (-not [string]::IsNullOrWhiteSpace([string]$header)) {
        # ⚠️ 2026-10-16 修：**必须显式 -MemberType**。原来只给 -NotePropertyName，
        #   而 PS 会把"看起来像数字"的名字转成 PSMemberTypes 枚举按值匹配 ——
        #   OCR 把会话名识别成 `16` 时，"16" 正好 = PSMemberTypes.ScriptProperty(16)，
        #   绑定器于是抛 "cannot take values that could be converted to PSMemberTypes"，
        #   **整轮采集直接失败**（19:04 起每轮崩，靠错误位置才定位到）。
        # ⚠️ 2026-10-16 真事故 + 实验结论：**动态名字一律用 -NotePropertyMembers，别用 -NotePropertyName**。
        #   原因：-NotePropertyName 的参数校验会把"看起来像数字"的名字当成 PSMemberTypes 枚举按值转换 ——
        #   OCR 把会话名识别成 `16` 时，"16" 正好 = PSMemberTypes.ScriptProperty(16)，
        #   绑定器抛 "cannot take values that could be converted to PSMemberTypes"，**整轮采集直接失败**
        #   （19:04 起每轮崩；加 -MemberType 也没用，实测 "16"/"32"/"1" 都过不去，只有哈希表写法全过）。
        $hashes | Add-Member -NotePropertyMembers @{ ([string]$header) = $hash } -Force
      }

      if ($text.Length -lt 4) {
        # 兜底：正文没读到（渲染慢/被遮挡）也不能让这次"有变化"白丢 —— 至少把列表里的预览记下来
        $rec = [ordered]@{
          kind = 'preview'; ts = (Get-Date).ToString('o'); source = 'wechat-screenshot-ocr'
          chat = $c.name; preview = $c.preview
          note = ('点开后正文没读到（{0} 字），退回记录预览' -f $text.Length)
        }
        Append-Record $rec | Out-Null; $written++
        Log ("  → 正文只读到 {0} 字 → 退回记录列表预览（避免这次变化白丢）" -f $text.Length)
      } else {
        # R6（2026-10-27）：消息发送时间结构化（以前只藏在正文第一行的 "昨天19：22" 里）。
        $recTimes = Get-ChatTimesFromLines -Lines $merged -Now (Get-PassNow)
        $sendIso = if ($recTimes.oldest) { $recTimes.oldest.ToString('o') } else { $null }
        $rec = [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'wechat-screenshot-ocr'
          chat = $header; expected = $c.name; verified = $verified
          changed = $isNew; text = $text
          sendTime = $sendIso
          lines = @($cleanLines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.t } })
        }
        Append-Record $rec | Out-Null; $written++
        # 记下"这一轮记到的最旧 3 行 + 它们的发送时间"：下一轮翻页读到它就停（2026-10-19 / 2026-10-27）
        if (-not $Peek) { Save-ChatAnchors -AnchorFile $anchorFile -Key $anchorKey -Lines $merged -ConsolidateFuzzy $stable -ConsolidateWhitelist $wlList -Time $recTimes.oldest }
        Log ("  → 标题「{0}」 校验={1} 内容变化={2} 正文 {3} 字" -f $header, $verified, $isNew, $text.Length)
      }
      if (-not $SaveShots) { Remove-Item -LiteralPath $shot2 -Force -ErrorAction SilentlyContinue }
    }
    if (-not $NoRestoreFocus -and $prevFg -ne [IntPtr]::Zero) {
      [void](Set-WxForegroundRaw -Hwnd $prevFg)
      Start-Sleep -Milliseconds 200
    }
  }

  foreach ($c in $chats) {
    if (Test-Ignored $c.name) { continue }
    # ⚠️ 2026-10-15 修：空会话名同样会让 Add-Member 抛 PSMemberTypes 校验错（与上面 $header 同一类）
    if ([string]::IsNullOrWhiteSpace([string]$c.name)) { continue }
    $state | Add-Member -NotePropertyMembers @{ ([string]$c.name) = ([pscustomobject]@{ preview = $c.preview; seen = (Get-Date).ToString('o') }) } -Force
  }
  if ($Peek) {
    # ⚠️ -Peek = "只看不写"：不写 spool、不更新状态。
    # 2026-10-15 补：原来**没有**这个开关，而 使用手册/遗留问题清单/测试-解析.ps1 都在用 `-Peek`。
    # PS 5.1 的 `-File` 模式对**无法识别的命名参数不报错**，直接丢进 $args（脚本从不读）→
    # 静默忽略，于是"只看一眼"的结果是**往真实 spool 里写了一条合成记录**，插件随后把它当真实聊天喂给模型。
    # 别人按自测清单验证时就会踩到（另一台机器实测复现）。
    Log ("-Peek：本轮识别到 {0} 个会话，不写 spool、不更新状态" -f @($chats).Count)
  } else {
    Save-Json $statePath $state
    Save-Json $hashPath $hashes
  }
  # 伪最小化用完要还原（本来是收起来的就再收回去，别留一个看不见的窗口在外面）
  if ($pseudoOldEx -ne $null) {
    [void](Exit-WxPseudoMinimize -Hwnd $info.hwnd -OldExStyle $pseudoOldEx -RestoreState $restoreState)
    Log '已还原微信窗口状态（伪最小化结束）'
  } elseif ($wasMinimized -and $AllowClick) {
    [void](Minimize-WxWindow -Hwnd $info.hwnd)
    Log '读完已把微信窗口收回最小化'
  }
  Log ("本轮写出 {0} 条记录（spool 累积 {1} 条）" -f $written, (Get-SpoolCount))
  return $written
}

function Get-SpoolCount {
  $n = 0
  Get-ChildItem -LiteralPath $spoolDir -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
    $n += (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
  }
  return $n
}

$pass = 0
do {
  $pass++
  Log ('===== 第 {0} 轮 =====' -f $pass)
  # 状态写在**执行之后**并反映真实结果（1550 版写在执行之前 → 本轮出错也报成功，与这套机制的目的相反）
  $passOk = $true; $passNote = ''; $script:skipNote = ''
  try { [void](Invoke-Pass $pass) } catch {
      # 2026-10-16 加：把**出错位置**也写进日志 —— 原来只记 Exception.Message，
      # 遇到"Add-Member 参数校验"这类错根本不知道是脚本哪一行（真事故：19:04 起每轮都崩，只能靠猜）。
      $passOk = $false
      $where = ''
      try { $where = ($_.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim() } catch { }
      $passNote = '本轮出错：' + $_.Exception.Message + $(if ($where) { '｜位置：' + $where } else { '' })
      Log $passNote
    }
  Write-RunStatus -Name '采集器-微信' -Code $(if ($passOk) { 0 } else { 1 }) -Note ($passNote + $script:skipNote)
  if ($Once) { break }
  if ($Passes -gt 0 -and $pass -ge $Passes) { break }
  Start-Sleep -Seconds $Interval
} while ($true)

$script:logLines | Set-Content -LiteralPath (Join-Path $logDir 'last-pass.txt') -Encoding UTF8
Write-Host ("日志：{0}" -f (Join-Path $logDir 'last-pass.txt'))



















