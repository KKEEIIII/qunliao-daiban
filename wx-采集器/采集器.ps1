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
  [switch]$Peek,              # 只看不写：不写 spool、不更新 state（文档/回归测试/自测清单都用它）
  [switch]$Calibrate          # 只标定布局：量出窗口/DPI/列表宽度/标题条/行距，写 layout-profile.txt 后退出
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
  # 2026-11-06：加「折叠置顶聊天/置顶聊天」——它是列表里的一条 UI 分隔行，会被当成会话识别；
  #   一旦被点开，置顶区就折叠成一行，视野外的置顶群全部消失（症状="好几个群忽然采不到了"）。
  ignoreChats    = @('公众号', '服务号', '订阅号', '折叠的聊天', '折叠的群聊', '折叠置顶聊天', '置顶聊天', '微信团队', 'QQ邮箱提醒', '微信支付', '文件传输助手', '群助手', '服务通知', '订阅号消息')
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
  $defaultJson = $defaultConfig | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($configPath, $defaultJson, (New-Object System.Text.UTF8Encoding($false)))
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
function Save-Json($path, $obj) {
  $json = $obj | ConvertTo-Json -Depth 6
  $tmp = $path + '.tmp'
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $path -Force
}
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
$script:WxPseudoState = $null
$script:WxRestoreAfterPass = $null
$script:WxPassForeground = [IntPtr]::Zero
$script:WxPassHwnd = [IntPtr]::Zero
$script:WxStatusKind = ''
function Clear-WxPseudoState {
  $s = $script:WxPseudoState
  if ($null -ne $s) {
    try {
      [void](Exit-WxPseudoMinimize -Hwnd $s.hwnd -OldExStyle $s.oldExStyle -OldColorKey $s.oldColorKey -OldAlpha $s.oldAlpha -OldLayerFlags $s.oldLayerFlags -HadLayerAttrs:([bool]$s.hadLayerAttrs) -RestoreState $s.restoreState)
      $script:WxPseudoState = $null
    } catch {
      Log ('⚠️ 伪最小化恢复异常（保留状态供外层重试）：' + $_.Exception.Message)
      throw
    }
  }
  $r = $script:WxRestoreAfterPass
  if ($null -ne $r) {
    try {
      if ([string]$r.restoreState -eq 'minimize' -or $r.minimized) { [void](Minimize-WxWindow -Hwnd $r.hwnd) }
      elseif ([string]$r.restoreState -eq 'hide' -or -not $r.visible) { [void][WxNative]::ShowWindow($r.hwnd, 0) }
      $script:WxRestoreAfterPass = $null
    } catch {
      Log ('⚠️ 采集器恢复原始微信窗口状态失败（保留状态供外层重试）：' + $_.Exception.Message)
      throw
    }
  }
  if ($script:WxPassForeground -ne [IntPtr]::Zero) {
    try {
      if ($script:WxPassHwnd -eq [IntPtr]::Zero -or $script:WxPassForeground -ne $script:WxPassHwnd) {
        [void](Set-WxForegroundRaw -Hwnd $script:WxPassForeground)
      }
      $script:WxPassForeground = [IntPtr]::Zero
      $script:WxPassHwnd = [IntPtr]::Zero
    } catch {
      Log ('⚠️ 恢复采集前台窗口失败（保留句柄供外层重试）：' + $_.Exception.Message)
      throw
    }
  }
}
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
    # 2026-10-29：加 [AllowEmptyCollection()] —— OCR 某次解析出 0 行会话时，PowerShell 会把
    #   空数组当成"不能绑定的值"直接抛 "Cannot bind argument to parameter 'SessionLines'
    #   because it is an empty array."，整轮采集作废（外部复测在 150% 缩放机器上实测到）。
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$SessionLines,
    [Parameter(Mandatory = $true)][double]$RowGap,
    [Parameter(Mandatory = $true)]$Cfg,
    [Parameter(Mandatory = $true)][double]$WinW
  )
  if ($null -eq $SessionLines -or @($SessionLines).Count -eq 0) { return @() }
  $chats = @()
  $cur = $null
  foreach ($ln in ($SessionLines | Sort-Object y)) {
    $text = Format-OcrText $ln.text
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    # x2 = 整行右边界（2026-11-06 加）：点击前"整行复读"要按它裁图；
    #   老 fixture 没有这个字段，[int]$null 会得到 0，裁剪函数会退回比例兜底。
    $item = [pscustomobject]@{ t = $text; h = [int]$ln.h; y = [int]$ln.y; x = [int]$ln.x; x2 = [int]$ln.x2 }
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
  # 2026-10-29（第二轮）：名字列起点改成**从行数据里量**（角标簇与名字簇之间的第一处明显空隙）。
  #   原来用比例 nameXFrom=0.145：150%（窗口 1341）算成 194，而名字列实际在 188 ——
  #   于是真名就叫 "212" 的会话会被当成未读角标**丢掉**。实测两个缩放都量对了：
  #   894 宽 → 135（名字 156）、1341 宽 → 163（名字 188）。
  $nameXMin = Get-WxNameXMinFromRows -SessionLines $SessionLines -WinW $WinW -Cfg $Cfg
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
      $cand += [pscustomobject]@{ t = $t; h = $ln.h; y = $ln.y; x = $ln.x; x2 = $ln.x2 }
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
    $nameLike = @($cand | Where-Object {
      $_.t -notmatch $previewRe -and $_.t -notmatch '^已(支付|收款|领取)' -and
      # 时间/日期标签不能当群名（整段只有时间才算，避免把「周三开会」这种真群名滤掉）
      $_.t -notmatch '^\d{1,2}[:：]\s*\d{2}$' -and
      $_.t -notmatch '^(昨天|今天|前天)(\s*\d{1,2}[:：]\s*\d{2})?$' -and
      $_.t -notmatch '^(星期|周)[一二三四五六日天]?(\s*\d{1,2}[:：]\s*\d{2})?$'
    })
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
      # 2026-11-06：名字行的横向范围也带出去 —— 点击前"整行复读"按它裁图，
      #   否则只能按比例裁整列，会把右边的角标/时间一起读进来，复读文本被污染。
      nameX = if ($pool[$maxIdx].PSObject.Properties['x']) { [int]$pool[$maxIdx].x } else { 0 }
      nameX2 = if ($pool[$maxIdx].PSObject.Properties['x2']) { [int]$pool[$maxIdx].x2 } else { 0 }
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
  # 2026-10-29（第二轮）：默认分界不再用"窗口宽度比例"，改用**布局档案**
  #   （部署时标定出的「列表宽度」像素常数 × 当前 DPI 系数）。比例模型错在假设
  #   "UI 随窗口等比缩放"，而微信的会话列表是近似固定像素宽的 —— 窗口一宽，
  #   0.42W 就切进聊天面板，群名被切掉、点击落到标题栏。详见 wxlib 的 Get-WxLayoutProfile。
  $prof = Get-WxLayoutProfile -Win $win -Cfg $cfg
  $defSplit = [int]$prof.splitX
  if ($script:WxSplitOverride -gt 0) {
    # 失败自搜索：上一轮"点开读不到本意群"时，按候选分界线重试
    $splitTo = [int]$script:WxSplitOverride
    Log ("  分界线改用候选值 {0}（自搜索第 {1} 个）" -f $splitTo, $script:WxSplitTry)
  } else {
    $splitTo = Get-WxChatSplitX -Rows $rows -W ([double]$win.width) -Cfg $cfg -DefTo $defSplit
    # 这次算不出（=默认值）但上次在同一窗口算出来过 → 沿用上次的（刚点开、群名还没渲染的那一帧）
    if ($splitTo -eq $defSplit) { $splitTo = Get-WxChatSplitMemory -WinW ([int]$win.width) -DefTo $defSplit }
    else { Set-WxChatSplitMemory -SplitX $splitTo -WinW ([int]$win.width) -DefTo $defSplit }
  }
  $sxTo = $splitTo
  $cxFrom = $splitTo
  $script:WxSplitX = $splitTo
  # 自校准只在"数值变了"的时候报一次（否则每张截图都刷一行）
  if ($splitTo -ne $defSplit -and $script:WxSplitLogged -ne $splitTo) {
    $script:WxSplitLogged = $splitTo
    Log ("  分界线自校准：{0} → {1}（按聊天面板群名左边界收窄，避免把群名切进会话列表）" -f $defSplit, $splitTo)
  }

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

function Get-WxChatSplitX {
  <#
    .SYNOPSIS  会话列表 / 聊天面板 的横向分界线（默认取配置的 sessionXTo，必要时按实际布局往左收）
    .DESCRIPTION
      2026-10-29 实测（窗口 1114x807、125%）：聊天面板的群名从 x=404 起，而配置分界线是
      0.42*1114 = 468 —— **群名前半截被切进"会话列表"**，于是：
        · 群名 OCR 只剩尾巴「倌方）（52）」→ 校验失败、被判"不在白名单"而丢弃整条；
        · 那个假"会话行"的 y 正好在标题栏，于是"点开会话"实际点在**标题**上（点不开）。
      根因：会话列表在微信里是**近似固定像素宽**的，窗口拉宽后 0.42 这个比例就不成立了。
      做法：**标题条**（窗口顶部很窄的一条，y ≤ 0.12H）里 x ≥ 0.30W 的最靠上那一簇就是聊天面板的群名，
      用它的左边界把分界线往左收（只在 0.30W ~ 默认值之间收，避免把真正的会话行误判成聊天区）。
      两个必须的限定（150% 实测踩过）：
        · 只认 x ≥ 0.30W 的行 —— 否则窗口左上角的图标碎片（x≈29）会把"群名左边界"拖到 29，自校准直接失效；
        · 只认 y ≤ 0.12H 的行 —— 否则**没开聊天时**会话行的右侧时间（x≈0.30W、y≈0.15H）会被当成群名，
          分界线往左一收，时间列就被踢出会话列表，时间锚点全丢。
  #>
  param([object[]]$Rows, [double]$W, $Cfg, [int]$DefTo = 0)
  if ($DefTo -le 0) { $DefTo = [int](Get-WxLayoutProfile -Win $script:win -Cfg $Cfg).splitX }
  $defTo = $DefTo
  $lo = [int]($W * 0.30)
  $stripLimit = [int]($script:win.height * 0.12)
  $band = @($Rows | Where-Object {
      $_ -and $_.y -le $stripLimit -and $_.x -ge $lo -and -not [string]::IsNullOrWhiteSpace($_.text)
    })
  if ($band.Count -eq 0) { return $defTo }
  $minY = [int](($band | Measure-Object -Property y -Minimum).Minimum)
  $cluster = @($band | Where-Object { ([int]$_.y - $minY) -le 8 })
  if ($cluster.Count -eq 0) { return $defTo }
  # 2026-11-04：只用"像群名的行"（≥2 个字）定标题左边界。
  #   实测：会话列表里的未读角标「O」（1 个字，x=340）与群名（x=404）同一行，
  #   它 ≥0.30W 所以能通过上面的过滤 → 左边界被拉到 340 → 分界线收到 334 →
  #   角标又被算进聊天区、拼进群名（标题读成「O26 人工 2 班<OCR 错字示例>（50）」）→ 校验失败漏采。
  #   群名几乎不可能只有 1 个字，用这个条件把角标/图标碎片排除掉。
  $nameRows = @($cluster | Where-Object { (Norm (Format-OcrText $_.text)).Length -ge 2 })
  if ($nameRows.Count -eq 0) { return $defTo }
  $titleMinX = [int](($nameRows | Measure-Object -Property x -Minimum).Minimum)
  if ($titleMinX -ge $lo -and $titleMinX -lt $defTo) { return ($titleMinX - 6) }
  return $defTo
}

# 分界线的"记忆"：点开聊天后第一张截图常常还没渲染出群名，自校准于是退回默认值（偏右）→
#   读不到标题 → 白多点一次。同一窗口的布局不会因为一次点击就变，所以记住上次算出来的值，
#   只在"这次算不出 + 窗口宽度没变"时沿用（窗口一变就作废，防止用户拉过窗口后拿旧值硬套）。
function Set-WxChatSplitMemory([int]$SplitX, [int]$WinW, [int]$DefTo) {
  if ($SplitX -ne $DefTo) {
    $script:WxSplitMem = [pscustomobject]@{ split = $SplitX; winW = $WinW }
  }
}
function Get-WxChatSplitMemory([int]$WinW, [int]$DefTo) {
  if ($script:WxSplitMem -and $script:WxSplitMem.winW -eq $WinW) { return [int]$script:WxSplitMem.split }
  return $DefTo
}

function Test-WxTimeLabel {
  <#
    .SYNOPSIS  这一行是不是"时间/日期标签"（不是群名）
    .DESCRIPTION
      2026-11-04 实测：点开会话后，聊天头部区最靠上的一行是时间分隔行「07：51」，
      被 Get-ChatHeader 当成群名 → 校验必然失败（「点开的是 07:51，不是本意群」）。
      只认"整段就是时间"的形态，避免把「周三开会」这类真群名误杀。
  #>
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
  $s = ($Text -replace '\s', '')
  if ($s -match '^\d{1,2}[:：]\d{2}$') { return $true }
  if ($s -match '^(昨天|今天|前天)(\d{1,2}[:：]\d{2})?$') { return $true }
  if ($s -match '^(星期|周)[一二三四五六日天]?(\d{1,2}[:：]\d{2})?$') { return $true }
  if ($s -match '^\d{1,2}月\d{1,2}日(\d{1,2}[:：]\d{2})?$') { return $true }
  return $false
}

function Get-ChatHeader($chatLines) {
  $win = $script:win
  # 2026-10-29（第二轮）：标题条下沿用布局档案（比例 + 按 DPI 折算的像素下限），
  #   窗口被拉矮时 0.16H 会小到把群名切掉，像素下限能兜住。
  $limit = [int](Get-WxLayoutProfile -Win $win -Cfg $cfg).titleY
  # 2026-10-29：以前是"取最靠上的那一行非空文本"。实测发现两件事：
  #   ① 群名会被 OCR **拆成同一条 y 上的两段**（「26 示例群A 2 班 <示例群号>」+「（官方）（52）」），
  #      只取一行就只剩尾巴 → 校验失败；
  #   ② 头部区里还混着窗口图标之类的碎片。
  #   改成：取"最靠上的一簇"（同一 y ±8px），按 x 排序拼起来 —— 拼出来的才是完整群名。
  $band = @($chatLines | Where-Object {
      $_ -and $_.y -le $limit -and -not [string]::IsNullOrWhiteSpace($_.text)
    } | ForEach-Object {
      [pscustomobject]@{ t = (Format-OcrText $_.text); h = [int]$_.h; x = [int]$_.x; y = [int]$_.y }
    })
  if ($band.Count -eq 0) { return '' }
  # 2026-11-04：时间/日期分隔行不是群名。实测点开后头部最靠上的一行是「07：51」，
  #   被当成标题 → 校验永远失败（「点开的是 07:51，不是本意群」），群白点一次还漏采。
  #   头部区全是时间行时返回空 = "认不出是哪个群"，交给上层安全跳过，绝不拿时间来冒充群名。
  $titled = @($band | Where-Object { -not (Test-WxTimeLabel $_.t) })
  if ($titled.Count -eq 0) { return '' }
  $minY = [int](($titled | Measure-Object -Property y -Minimum).Minimum)
  $cluster = @($titled | Where-Object { ([int]$_.y - $minY) -le 8 })
  if ($cluster.Count -eq 0) { return '' }
  # 2026-11-04：同一行上，会话列表的未读角标/图标碎片（1 个字，如「O」「0」）会被拼进群名。
  #   实测标题读成「O26 人工 2 班<OCR 错字示例>（50）」→ 与期望名不符 → 整轮白点一次还漏采。
  #   用"≥2 个字的第一段"作为标题左锚点，只拼它右边的行（群名被拆成两段时仍能拼全）。
  $anchorRows = @($cluster | Where-Object { (Norm $_.t).Length -ge 2 })
  if ($anchorRows.Count -gt 0) {
    $anchorX = [int](($anchorRows | Measure-Object -Property x -Minimum).Minimum)
    $cluster = @($cluster | Where-Object { [int]$_.x -ge ($anchorX - 2) })
  }
  $cluster = @($cluster | Sort-Object x)
  $joined = (($cluster | ForEach-Object { $_.t }) -join '')
  if ($joined.Length -ge 2) { return $joined }
  return (Format-OcrText ($cluster | Select-Object -First 1).t)
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
  $split = [int](Get-WxLayoutProfile -Win $Win -Cfg $Cfg).splitX
  if ($script:WxSplitX -gt 0 -and $script:WxSplitX -lt $Win.width) { $split = [int]$script:WxSplitX }
  $listLeft = [int]($Win.width * [double]$Cfg.sessionXFrom)
  $clickLocalX = [int]($Win.width * [double]$Cfg.clickX)
  if ($clickLocalX -ge ($split - 8) -or $clickLocalX -le $listLeft) { $clickLocalX = [int](($listLeft + $split) / 2) }
  return [pscustomobject]@{
    cx = [int]($Win.left + $clickLocalX)
    cy = [int]($Win.top + $baseY + $dy)
    baseY = $baseY; dy = $dy; nameH = $nameH; ratio = $ratio
  }
}

function Get-WxOcclusionHint {
  <#
    .SYNOPSIS  「这个点现在被谁盖住了」的可读说明（只用于排障日志，不参与任何判定）
    .DESCRIPTION
      2026-10-29：外部复测里"一个群都点不开"最容易被忽略的一种原因是**窗口被别的程序盖住** ——
      PrintWindow 在窗口被遮挡时可能返回旧帧，于是"点开了没有"这个判断本身就失真
      （日志里同时出现「内容变化=False」和「校验=False」）。
      以前日志只写"最顶层窗口不是微信"，用户不知道下一步该做什么；现在把标题也打出来。
  #>
  param(
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [IntPtr]$Expect = [IntPtr]::Zero
  )
  try {
    $top = [WxNative]::TopAt($X, $Y)
    $title = ''
    try {
      $sb = New-Object System.Text.StringBuilder 256
      [void][WxNative]::GetWindowTextW($top, $sb, 256)
      $title = $sb.ToString()
    } catch { }
    return [pscustomobject]@{
      hwnd    = $top
      title   = $title
      covered = ($Expect -ne [IntPtr]::Zero -and $top -ne $Expect)
    }
  } catch { return $null }
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
    # 2026-10-29：3 次 × 700ms 在 150% 实测不够 —— 大群（50 人、历史长）点开后 2 秒还没渲染完，
    #   抓到的是"旧帧/空面板"。放宽到 4 次 × 900ms；读到就 break，所以正常情况下不会变慢。
    [int]$Tries = 4,
    [int]$GapMs = 900
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
    # ⚠️ 2026-10-29：以前这里是无条件覆盖 —— 于是"第 1 帧读到了标题、第 2/3 帧渲染反而空"时，
    #   返回的是**最后一帧**（空标题），校验直接判失败、还白多点一次（150% 实测就是这么发生的）。
    #   改成保留"最好的一帧"：有标题优先，其次正文行数多的。
    $hdrBonus = 0
    if (-not [string]::IsNullOrWhiteSpace($hdr)) { $hdrBonus = 1000 }
    $score = $hdrBonus + [Math]::Min($cnt, 500)
    if ($null -eq $best -or $score -ge $best.score) {
      $best = [pscustomobject]@{ header = $hdr; parsed = $parsed; bodyCount = $cnt; tries = ($i + 1); score = $score }
    }
    if (-not [string]::IsNullOrWhiteSpace($hdr) -and $cnt -ge 2) { break }
  }
  # 2026-10-29（第二轮）：整帧空白 = 十有八九抓到的是"点开前那一帧"（窗口还没重绘完）。
  #   实测证据：采集器 3×700ms 判"点不开"，紧接着手工截图同一个群却标题清晰、正文完整 ——
  #   差的就是时间。这种时候再多快轮询都没用，补一次长等待（2s）再读一帧。
  if (($null -eq $best) -or ([string]::IsNullOrWhiteSpace($best.header) -and [int]$best.bodyCount -eq 0)) {
    Start-Sleep -Milliseconds 2000
    try {
      $null = Save-WxWindowShot -Hwnd $Win.hwnd -Path $Shot -Scale $Scale
      $rows = @(Invoke-WxOcr -Path $Shot -Scale $Scale)
      $parsed = Get-ChatsFromRows $rows
      $hdr = Get-ChatHeader $parsed.chatLines
      $cnt = @($parsed.chatLines | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
      $hdrBonus = 0
      if (-not [string]::IsNullOrWhiteSpace($hdr)) { $hdrBonus = 1000 }
      $score = $hdrBonus + [Math]::Min($cnt, 500)
      if (($null -eq $best) -or $score -ge $best.score) {
        $best = [pscustomobject]@{ header = $hdr; parsed = $parsed; bodyCount = $cnt; tries = ($Tries + 1); score = $score }
      }
      if ($score -gt 0) { Log '  整帧空白 → 长等待 2s 后重读，读到了' }
    } catch { }
  }
  if ($null -eq $best) { $best = [pscustomobject]@{ header = ''; parsed = $null; bodyCount = 0; tries = 0; score = 0 } }
  # 2026-10-29：标题读不到时，把"头部区实际认出了什么"打出来 —— 否则只能看到"标题仍为空"，
  #   没法判断是没渲染、还是被分界线切掉了、还是 OCR 读成碎片（150% 实测就吃过这个亏）。
  if ([string]::IsNullOrWhiteSpace($best.header) -and $best.parsed) {
    $limit = [int](Get-WxLayoutProfile -Win $Win -Cfg $cfg).titleY
    $band = @($best.parsed.chatLines | Where-Object { $_ -and $_.y -le $limit } | Sort-Object y, x |
        Select-Object -First 4 | ForEach-Object {
          'y={0} x={1} 「{2}」' -f $_.y, $_.x, (Format-OcrText $_.text)
        })
    if ($band.Count -eq 0) {
      # 再补一句"整帧到底有没有认出行"——区分「这一帧 OCR 全空（没渲染/抓到旧帧）」和「行有，但被 x/y 过滤掉了」
      $allRows = @($best.parsed.chatLines)
      $topAny = @($allRows | Sort-Object y, x | Select-Object -First 3 | ForEach-Object {
          'y={0} x={1} 「{2}」' -f $_.y, $_.x, (Format-OcrText $_.text)
        })
      $hint = if ($allRows.Count -eq 0) { '整帧聊天区一行都没有（多半还没渲染）' } else { ('聊天区共 {0} 行，最靠上的是 {1}' -f $allRows.Count, ($topAny -join ' / ')) }
      Log ('  标题读不到：头部区（y≤{0}、x≥{1}）一行都没认出来；{2}' -f $limit, $script:WxSplitX, $hint)
    } else {
      Log ('  标题读不到：头部区（y≤{0}、x≥{1}）最靠上的行 = {2}' -f $limit, $script:WxSplitX, ($band -join ' / '))
    }
  }
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

# 判断窗口是否处于"抓不到内容"的状态，并给出**原因**（2026-10-29 抽出）。
# 为什么抽出来：以前是内联的 `width -lt 400 -or height -lt 300`。这个阈值在
#   125%/150% 缩放 + 微信开成窄窗口时会把**正常窗口**判成"不可见"
#   （实测本机：物理 368x484 的真实微信窗口 → 每轮静默跳过、一条都不采）。
#   现在尺寸只用来挡真正的折叠/隐藏态（实测那种是 159x27）。
function Test-WxWindowCollapsed {
  param($Info)
  if ($null -eq $Info) { return '取不到窗口' }
  if ($Info.minimized) { return '窗口已最小化' }
  if (-not $Info.visible) { return '窗口被隐藏（收进托盘）' }
  if ($Info.left -lt -10000 -or $Info.top -lt -10000) { return ('窗口在屏幕外 ({0},{1})' -f $Info.left, $Info.top) }
  if ($Info.width -lt 200 -or $Info.height -lt 160) { return ('窗口尺寸过小 {0}x{1}（折叠/隐藏态）' -f $Info.width, $Info.height) }
  return ''
}

# ================= 主流程 =================
function Invoke-Pass([int]$index) {
  # 上轮若恢复曾失败，先重试清理；不能静默清空待恢复状态。
  if ($null -ne $script:WxPseudoState -or $null -ne $script:WxRestoreAfterPass) { Clear-WxPseudoState }
  # R1（2026-10-27）：记录本轮命令执行时间，整轮只取一次（时间锚点的基准）。
  $script:PassNow = Get-Date
  $script:WxStatusKind = 'complete'
  $script:skipNote = ''
  Log ('本轮执行时间 {0:yyyy-MM-dd HH:mm:ss}（相对时间以它为准）' -f $script:PassNow)
  $offline = -not [string]::IsNullOrWhiteSpace($OcrRows)
  if ($offline) {
    $fx0 = Get-Content -LiteralPath $OcrRows -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = [pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 0; top = 0; width = [int]$fx0.width; height = [int]$fx0.height; minimized = $false }
  } else {
    $info = Get-WxWindowInfo
  }
  if ($null -eq $info) { Log '跳过：微信未运行（无窗口可采，或窗口标题不含“微信”）'; $script:WxStatusKind = 'env-skip'; $script:skipNote = '环境跳过：微信未运行（无窗口可采）'; return 0 }
  if (-not $offline -and $script:WxPassForeground -eq [IntPtr]::Zero) { $script:WxPassForeground = Get-WxForeground }
  $script:WxPassHwnd = $info.hwnd
  $script:win = $info
  # 2026-10-29：坐标空间自证 —— 125%/150% 缩放下，如果这里报的是"虚拟值"，后面
  #   会话列裁剪边界、标题区、点击落点全都会按错的尺度算（外部复测的"一个群都点不开"就是这个）。
  #   这一行是排障第一眼：物理像素 = 屏幕上量的实际尺寸。
  $dpiNote = ''
  if ($info.PSObject.Properties['dpi']) {
    if ($info.dpiAware) { $dpiNote = ('（DPI {0}；坐标空间=物理像素，已声明 DPI 感知）' -f $info.dpi) }
    elseif ($info.dpiFixed) { $dpiNote = ('（DPI {0}；坐标空间=物理像素，按窗口 DPI ×{1:N2} 校正）' -f $info.dpi, $info.dpiFactor) }
    else { $dpiNote = ('（DPI {0}；⚠️ 坐标可能是虚拟像素 —— 若缩放不是 100% 会点歪）' -f $info.dpi) }
  }
  Log ("窗口 {0}x{1} @ ({2},{3}) hwnd=0x{4}{5}" -f $info.width, $info.height, $info.left, $info.top, $info.hwnd.ToInt64().ToString('X'), $dpiNote)

  # 窗口被最小化/收到托盘时：它不参与 DWM 合成，直接抓必然为空。
  # 两条路：① 只读采集 → 伪最小化（显示但不激活 + 近乎透明 + 点击穿透，用户看不见，PrintWindow 仍能抓）
  #         ② 需要点击（AllowClick）→ 只能真正恢复窗口可见
  $collapseWhy = if ($offline) { '' } else { Test-WxWindowCollapsed -Info $info }
  $hidden = -not [string]::IsNullOrEmpty($collapseWhy)
  $wasHidden = (-not $info.visible)                      # 收托盘（SW_HIDE）；还原时不要给用户留成"最小化"
  $restoreState = if ($wasHidden) { 'hide' } elseif ($info.minimized) { 'minimize' } else { 'none' }
  $wasMinimized = $hidden
  $pseudoOldEx = $null
  if ($hidden -and $cfg.restoreIfMinimized) {
    if ($Pseudo) {
      # 伪最小化后台抓图（MaaFramework 的 pseudo-minimize 思路）。
      # 2026-10-14 17:45 真实端到端验证通过：微信最小化态（159x27 @ -25600,-25600）和收托盘态（可见=False）
      # 都能抓到画面并正确解析出会话列表；计划任务一直带 -Pseudo。
      Log ('微信窗口不可用（{0}）→ 伪最小化后台抓图（不打扰，读完还原）' -f $collapseWhy)
      $pseudoEntry = Enter-WxPseudoMinimize -Hwnd $info.hwnd -RestoreState $restoreState
      $pseudoOldEx = [int]$pseudoEntry.oldExStyle
      $script:WxPseudoState = [pscustomobject]@{ hwnd = $info.hwnd; oldExStyle = $pseudoOldEx; restoreState = [string]$pseudoEntry.restoreState; hadLayerAttrs = [bool]$pseudoEntry.hadLayerAttrs; oldColorKey = [uint32]$pseudoEntry.oldColorKey; oldAlpha = [byte]$pseudoEntry.oldAlpha; oldLayerFlags = [uint32]$pseudoEntry.oldLayerFlags }
      try {
        Start-Sleep -Milliseconds 1800
        $info = Get-WxWindowInfo
        $collapseWhy = Test-WxWindowCollapsed -Info $info
        $hidden = -not [string]::IsNullOrEmpty($collapseWhy)
      } catch {
        Clear-WxPseudoState
        $pseudoOldEx = $null
        throw
      }
      if ($hidden -and $pseudoOldEx -ne $null) {
        Clear-WxPseudoState
        $pseudoOldEx = $null
      }
    } else {
      Log ('微信窗口不可用（{0}）→ 恢复窗口再采集（restoreIfMinimized=true）' -f $collapseWhy)
      $script:WxRestoreAfterPass = [pscustomobject]@{ hwnd = $info.hwnd; restoreState = $restoreState; minimized = [bool]$info.minimized; visible = [bool]$info.visible }
      [void](Restore-WxWindow -Hwnd $info.hwnd)
      Start-Sleep -Milliseconds 1800
      $info = Get-WxWindowInfo
      $collapseWhy = Test-WxWindowCollapsed -Info $info
      $hidden = -not [string]::IsNullOrEmpty($collapseWhy)
      if ($hidden) { Clear-WxPseudoState }
    }
  }
  if ($hidden) {
    if ($pseudoOldEx -ne $null) { Clear-WxPseudoState }
    $skipText = "微信窗口不可用（{0}；rect=({1},{2}) {3}x{4}）" -f $collapseWhy, $info.left, $info.top, $info.width, $info.height
    Log ("跳过：{0} —— 本轮不采集" -f $skipText)
    $script:WxStatusKind = 'env-skip'
    $script:skipNote = '环境跳过：' + $skipText
    return 0
  }
  if ($wasMinimized) { Log ("恢复后窗口 {0}x{1} @ ({2},{3})（伪最小化={4}）" -f $info.width, $info.height, $info.left, $info.top, ($pseudoOldEx -ne $null)) }

  # ⚠️ 必须在这里刷新 $script:win：上面可能刚把窗口从"最小化(159x27 @ -25600)"恢复成真实尺寸，
  # 而 Get-ChatsFromRows 是拿 $script:win.width/height 去算会话列 x 范围的。
  # 如果在恢复前就赋值，会话列范围会被算成 [15,66]，正好把 x≈156 的群名全部排除 →
  # 实测症状：24 行 OCR 但"会话列表识别到 0 个会话"（这就是交接文档里"伪最小化坐标空间不同、待标定"的真因）。
  $script:win = $info

  # 2026-11-06：会话列表被滚离顶部时，"视野外的群"等于不存在（不点、不采）。
  #   窗口可见时先把它滚回顶部再识别；伪最小化态窗口带 WS_EX_TRANSPARENT（点击穿透），
  #   真实滚轮会被下发到后面的窗口，所以那种情况只记一笔、不硬滚。
  if (-not $offline -and -not ($env:WX_LIST_RESET -eq '0')) {
    if ($pseudoOldEx -ne $null) {
      Log '  [列表] 伪最小化状态下无法滚动会话列表（输入穿透）→ 跳过归位'
    } else {
      try {
        $reset = Invoke-WxChatListReset -Win $info -AutoFocus
        if ($reset.method -eq 'signature') {
          # 几何判据判不出来（可读行太少）时走签名法：滚到文本不再变化即到顶
          Log ("  [列表] 行数不足，改用签名法归位（向上滚 {0} 档，已到顶）" -f $reset.notches)
        } elseif ($reset.clippedBefore) {
          if ($reset.clippedAfter) {
            Log ("  [列表] 会话列表滚离顶部（{0}）→ 已向上滚 {1} 档仍未到顶，下一个可见群可能仍被切" -f $reset.before.reason, $reset.notches)
          } else {
            Log ("  [列表] 会话列表滚离顶部（{0}）→ 已滚回顶部（{1} 档）" -f $reset.before.reason, $reset.notches)
          }
        }
      } catch {
        Log ('  [列表] 归位失败（{0}）→ 本轮仍按当前可见列表采集' -f $_.Exception.Message)
      }
    }
  }

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
    $fxJson = $fxOut | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($DumpRowsJson, $fxJson, (New-Object System.Text.UTF8Encoding($false)))
    Log ("已导出 OCR fixture → " + $DumpRowsJson + "（" + $rows.Count + " 行）")
    Clear-WxPseudoState
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
    Clear-WxPseudoState
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
      $script:WxBgClickLastTitle = ''
      $script:WxBgClickLastResult = $null
      # ⚠️ 2026-10-27：点击坐标**不再**乘下面这个"图像/窗口"比例（见 Invoke-WxClickSmart 里的注释：
      #   Maa 的 PostClick 吃客户区坐标；乘了比例会随 y 增大而越点越偏，正是老问题"点开的是别的群"的真因）。
      # 2026-10-29：这段结论成立的**前提是"抓图尺寸与窗口是同一套像素"**（即两者都是物理像素）。
      #   比例本身不是错误信号 —— Maa 的抓图分辨率本来就可能比窗口大（本机 100% 下 1100/894 = 1.23）；
      #   真正会点歪的是"窗口矩形是虚拟坐标"（非 100% 缩放 + 没声明 DPI 感知）。
      #   所以下面判的是**坐标空间**，不是比例数字。
      $spaceNote = if ($script:WxDpiAware) { '坐标空间=物理像素（DPI 感知）' }
                   elseif ($script:win.PSObject.Properties['dpiFixed'] -and $script:win.dpiFixed) { ('坐标空间=物理像素（按 DPI ×{0:N2} 校正）' -f $script:win.dpiFactor) }
                   else { '⚠️ 坐标可能是虚拟像素' }
      Log ("  后台点击就绪：输入法 {0}｜Maa 图像 {1}x{2}｜窗口 {3}x{4}（图像/窗口 {5:N4}/{6:N4}；{7}；点击按客户区坐标发）" -f $im, $s.w, $s.h, $WinW, $WinH, $script:WxBgClickFx, $script:WxBgClickFy, $spaceNote)
      if (-not $script:WxDpiAware -and -not ($script:win.PSObject.Properties['dpiFixed'] -and $script:win.dpiFixed)) {
        Log ('  [警告] 本进程未声明 DPI 感知（{0}）且没取到窗口 DPI：若系统缩放不是 100%，点击/裁剪都会偏。' -f $script:WxDpiNote)
      }
      return $true
    } catch {
      Log ('  后台点击初始化异常：{0} → 退回真实鼠标' -f $_.Exception.Message)
      return $false
    }
  }

  function Invoke-WxClickSmart {
    param([IntPtr]$Hwnd, [int]$ScreenX, [int]$ScreenY, [int]$WinLeft, [int]$WinTop)
    if (-not $script:WxBgClickReady) {
      try {
        $clicked = Invoke-TargetWindowClick -Hwnd $Hwnd -X $ScreenX -Y $ScreenY -SettleMs 40
      } catch {
        Log ('  真实点击取消：' + $_.Exception.Message); return $false
      }
      if (-not $clicked) { Log '  真实点击取消：目标失焦、被遮挡或鼠标被接管'; return $false }
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
    if (-not $ok) { Log '  后台点击返回失败'; return $false }
    return $true
  }

  if ($changed.Count -gt 0 -and $AllowClick) {
    # 本机真实实测 Maa 返回成功但打开了错误会话，因此微信端先禁用后台点击。
    # 仅在可见、未最小化且点击点确实归属微信时，才走受保护的真实鼠标路径。
    $bgOk = $false
    $script:WxBgClickReady = $false
    $script:WxBgClickCtrl = [IntPtr]::Zero
    # 真实鼠标点击必须先退出伪最小化、恢复窗口可见并让目标点受微信拥有；失焦/被遮挡则安全放弃。
    if (-not $bgOk -and $pseudoOldEx -ne $null) {
      Log '有会话需要点开读取 → 退出伪最小化，临时恢复窗口（读完会再收回去）'
      Clear-WxPseudoState
      $pseudoOldEx = $null
      $script:WxRestoreAfterPass = [pscustomobject]@{ hwnd = $info.hwnd; restoreState = $restoreState; minimized = [bool]$info.minimized; visible = [bool]$info.visible }
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
      # 2026-10-29（第二轮）失败自搜索：第 3 次尝试时换一个候选分界线。
      #   为什么需要：布局一变（拉窗口/换缩放/换微信版本），分界线就可能切进聊天面板，
      #   表现就是"点了但标题读不到/点开的不是本意群"。这时与其等人来改配置，
      #   不如自己换个分界线再试一次 —— 候选来自 Get-WxSplitCandidates（内容自锚定 → 档案/比例 → ±10%/20%）。
      $script:WxSplitOverride = 0
      $script:WxSplitCandidates = @(Get-WxSplitCandidates -Win $info -Cfg $cfg -ContentSplit ([int]$script:WxSplitX))
      $script:WxSplitTry = 0
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -eq 3) {
          $script:WxSplitTry++
          if ($script:WxSplitTry -lt $script:WxSplitCandidates.Count) {
            $script:WxSplitOverride = [int]$script:WxSplitCandidates[$script:WxSplitTry]
            Log ("  两次都没校验通过 → 换分界线重试（候选 {0}，当前 {1}）" -f $script:WxSplitTry, $script:WxSplitOverride)
          } else {
            $script:WxSplitOverride = 0
            Log '  候选分界线都试完了 → 不再重试，走兜底记录'
            break
          }
        }
        # 列表稳定化（2026-10-27）：新消息会让列表在"截图 → OCR(约 1s) → 点击"这段时间里重排，
        #   实测点「26 示例群A 2 班」却打开「示例群G」就是这种"一行之差的换位"（真机复现两次）。
        #   做法：连拍两张，**列表签名（每个会话名）一致才点**；不一致就再拍（最多 3 轮）。
        $fresh = @(); $sigPrev = $null; $shotsTaken = 0; $listStable = $false
        $info = Get-WxWindowInfo -Hwnd $info.hwnd
        $script:win = $info
        for ($st = 0; $st -lt 3; $st++) {
          $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale $ocrScale
          $fresh = @((Get-ChatsFromRows (Invoke-WxOcr -Path $shot -Scale $ocrScale)).chats)
          $sig = (@($fresh | ForEach-Object { '{0}@{1}' -f (Norm $_.name), [int]$_.nameY }) -join '|')
          $shotsTaken = $st + 1
          if ($null -ne $sigPrev -and $sig -eq $sigPrev) { $listStable = $true; break }
          $sigPrev = $sig
          if ($st -lt 2) { Start-Sleep -Milliseconds 200 }
        }
        if (-not $listStable) { Log '  名字或行位置仍在变化，本次不点击'; $target = $null; continue }
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
        # 2026-11-06：点击前「整行复读」确认 —— 防 OCR 认错行导致点开错误的群。
        #   整窗 OCR 会把相邻两行并成一行、把「212」读成「21」；一旦落到错行就打开了别的会话。
        #   这里把候选行的名字区裁出来、放大两档各读一遍，两档都认出本群才允许点击；
        #   任一档读不出/读成别的名字就跳过（下一轮还能补），绝不冒险点击。
        #   临时关闭：WX_ROW_CONFIRM=0，或 config.json 里 rowConfirm=false。
        $rowConfirmOn = -not ($null -ne $env:WX_ROW_CONFIRM -and $env:WX_ROW_CONFIRM -eq '0')
        if ($cfg.PSObject.Properties['rowConfirm'] -and $cfg.rowConfirm -eq $false) { $rowConfirmOn = $false }
        if ($rowConfirmOn) {
          # 裁剪右边界用「列表/聊天分界线 - 边距」，而不是 sessionXTo 比例：
          #   分界线常比比例值靠左，直接用比例会把聊天正文裁进来，复读结果被污染。
          $splitForCrop = [int](Get-WxLayoutProfile -Win $info -Cfg $cfg).splitX
          if ($script:WxSplitX -gt 0 -and $script:WxSplitX -lt $info.width) { $splitForCrop = [int]$script:WxSplitX }
          $cropRight = [int][Math]::Min($splitForCrop - 6, [int][Math]::Ceiling($info.width * 0.37))
          $conf = Test-WxRowConfirmation -Win $info -Row $target -Expected $c.name `
            -XFrom ([double]$cfg.sessionXFrom) -XToPx $cropRight
          if (-not $conf.ok) {
            $seen = (@($conf.passes | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { '（空）' } else { $_ } }) -join ' ‖ ')
            $rc = $conf.rect
            Log ("跳过「{0}」：点击前整行复读未通过（{1}）；裁剪=({2},{3},{4}x{5}) 预期=「{6}」两档识别=「{7}」→ 为避免点开错误会话已放弃" -f `
                $c.name, $conf.reason, $rc.x, $rc.y, $rc.w, $rc.h, $c.name, $seen)
            $target = $null
            break
          }
          Log ("  点击前确认「{0}」：{1}" -f $c.name, ($conf.passes -join ' / '))
        }
        # 安全锁：真实鼠标点击时，坐标处最顶层的窗口必须是微信（否则会把点击送到别的程序上）。
        # 后台点击是发窗口消息、不经过屏幕，被遮挡也能点 → 这时不需要（也不该）做这个检查，
        # 否则"微信被别的窗口盖住"就无法采集了，而那正是后台模式要解决的场景。
        if (-not $bgOk) {
          $topAt = [WxNative]::TopAt($pt.cx, $pt.cy)
          if (-not [WxNative]::SameRootWindow($topAt, $info.hwnd) -or -not [WxNative]::ForegroundMatches($info.hwnd)) {
            $occ = Get-WxOcclusionHint -X $pt.cx -Y $pt.cy -Expect $info.hwnd
            $occName = if ($occ) { ('0x{0}「{1}」' -f $occ.hwnd.ToInt64().ToString('X'), $occ.title) } else { '别的窗口' }
            Log ("跳过「{0}」：({1},{2}) 处最顶层窗口是 {3}，不是微信 → 为避免误点已放弃" -f $target.name, $pt.cx, $pt.cy, $occName)
            Log '        可操作办法：① 把微信窗口移到不被遮挡的位置；② 或让后台点击可用（它发窗口消息、不经过屏幕）；③ 或确认坐标空间是物理像素（上面"窗口 …"那行）'
            $target = $null
            break
          }
        }
        Log ("点击会话「{0}」{1} @ 屏幕({2},{3})（窗口内 y={4} = 名字行 {5} + 偏移 {6}［字高 {7}×{8}］）{9}" -f `
            $target.name, $(if ($attempt -gt 1) { '（第 2 次尝试）' } else { '' }), $pt.cx, $pt.cy, ($pt.cy - $info.top), $pt.baseY, $pt.dy, $pt.nameH, $pt.ratio, $(if ($bgOk) { '（后台）' } else { '' }))
        $nowRect = Get-WxWindowInfo -Hwnd $info.hwnd
        if ($nowRect.left -ne $info.left -or $nowRect.top -ne $info.top -or $nowRect.width -ne $info.width -or $nowRect.height -ne $info.height) {
          Log '  截图后窗口位置或尺寸变化，放弃旧坐标并重新定位'; continue
        }
        if (-not (Invoke-WxClickSmart -Hwnd $info.hwnd -ScreenX $pt.cx -ScreenY $pt.cy -WinLeft $info.left -WinTop $info.top)) {
          Log '  点击未成功，不读取旧聊天面板'; continue
        }
        Start-Sleep -Milliseconds $cfg.clickSettleMs

        # 读面板：轮询等渲染。2026-10-29（第二轮）实测：点开后窗口内容要**好几秒**才真正重绘完，
        #   3×700ms=2.1s 经常只拿到"点开前那一帧"（聊天区一行都没有）→ 误判"点不开"。
        #   标定时（点击后约 10s 再截图）同一个群明明已经打开且标题清晰，说明是等待不够，不是坐标错。
        #   这里放宽到 5×1000ms=5s；Read-WxChatPane 内部对"整帧空白"还会再补一次长等待。
        $pane = Read-WxChatPane -Win $info -Shot $shot2 -Scale $ocrScale -Tries 5 -GapMs 1000
        if ($null -eq $pane.parsed) { continue }
        $header = [string]$pane.header
        $headerRead = -not [string]::IsNullOrWhiteSpace($header)
        # 列表候选允许宽松 OCR 匹配；最终标题身份确认必须更严格，不能用共享短白名单词合并不同群。
        $identity = if ($headerRead) { Get-ChatFinalIdentityInfo -Actual $header -Expected ([string]$c.name) } else { [pscustomobject]@{ same = $false; why = '标题为空' } }
        $verified = [bool]$identity.same
        if ($verified) { break }
        if ($attempt -lt 2) {
          if ($headerRead) { Log ("  点开的是「{0}」，不是本意群 → 重新定位再点一次" -f $header) }
          else { Log '  点开后标题仍为空（点击没生效或还没渲染）→ 重新定位再点一次' }
          Start-Sleep -Milliseconds 400
        }
      }
      $script:WxSplitOverride = 0     # 自搜索只作用于这一个会话，别影响后面的
      if ($null -eq $target -or $null -eq $pane -or $null -eq $pane.parsed) {
        # 点开失败时绝不把列表预览冒充正文：列表行可能已错位，必须留待下一轮重新识别。
        Log '  → 点开或读取失败：不写预览、不更新锚点，避免错误群聊归属'
        # 2026-10-29：把"为什么点不开"写到能照做为止。外部复测在这条路上耗了一整晚，
        #   而三种成因各自对应完全不同的处置方式（遮挡 / 坐标空间 / 输入方式）。
        if ($null -ne $target) {
          try {
            $occ2 = Get-WxOcclusionHint -X $pt.cx -Y $pt.cy -Expect $info.hwnd
            if ($occ2 -and $occ2.covered) {
              Log ('        原因①：点击点 ({0},{1}) 现在被 0x{2}「{3}」盖住 —— 窗口被遮挡时 PrintWindow 可能返回旧帧，"点开了没有"本身就不可信；把微信挪到干净位置再试' -f $pt.cx, $pt.cy, $occ2.hwnd.ToInt64().ToString('X'), $occ2.title)
            }
          } catch { }
        }
        if (-not $script:WxDpiAware -and -not ($script:win.PSObject.Properties['dpiFixed'] -and $script:win.dpiFixed)) {
          Log ('        原因②：本进程未声明 DPI 感知（{0}）→ 若系统缩放不是 100%，算出来的点会偏（本次点击点 ({1},{2})）' -f $script:WxDpiNote, $pt.cx, $pt.cy)
        } else {
          Log ('        坐标空间正常（{0}；窗口 {1}x{2}）→ 排除"缩放导致点偏"' -f $(if ($script:WxDpiAware) { 'DPI 感知已声明' } else { '已按窗口 DPI 校正' }), $info.width, $info.height)
        }
        Log ('        原因③：点击方式可能不被微信接受（当前 {0}）→ 本机真实验证 Maa 点击会点偏，微信路径已关闭后台点击' -f $(if ($bgOk) { 'Maa 后台点击' } else { '受保护真实鼠标' }))
        continue
      }
      if (-not $verified) {
        Log ('  群标题未确认（期望「{0}」，读到「{1}」）→ 不翻页、不写正文和锚点，留待下轮重试' -f $c.name, $header)
        continue
      }
      $parsed2 = $pane.parsed
      if (-not $headerRead) {
        Log ("  标题未识别，放弃本次读取：不以期望名代替实际群名「{0}」，不写正文和锚点" -f $c.name)
        continue
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
      $newestRows = @($parsed2.chatLines | Sort-Object y | ForEach-Object {
          $t = Format-OcrText $_.text
          if (-not [string]::IsNullOrWhiteSpace($t)) { [pscustomobject]@{ text = $t; y = [int]$_.y } }
        })
      $newestTexts = @($newestRows | ForEach-Object { $_.text })
      # 锚点（2026-10-19）：上一轮记录过的"最旧 3 行"。翻页读到它就停 —— 再往上都是记过的内容，
      # 继续翻只会把同一批历史重新 OCR（费时费 token，还可能让模型重复抽同一条待办）。
      # 2026-10-26 改：① key 换成**稳定标识**（白名单词），不再用会抖的 OCR 群名；
      #   ② 翻页改成"一直翻到锚点为止"（用户要求：避免固定 2 屏漏掉消息）。
      $anchorFile = Join-Path $stateDir 'seen-anchors.txt'
      $historyRollupPath = Join-Path $stateDir 'history-rollup.json'
      $historyRollup = Load-Json $historyRollupPath ([pscustomobject]@{})
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
      $anchorFileMissing = ($anchorRecs.Count -eq 0)
      $longAnchorCount = @($anchors | Where-Object { ([string]$_ -replace '\s', '').Length -ge 6 }).Count
      $anchorHitFirst = ($longAnchorCount -ge 2 -and (Test-ChatAnchorHit -Lines $newestTexts -Anchors $anchors -MinimumHits 2))
      $rollup = $historyRollup
      $rollState = if ($rollup.PSObject.Properties.Name -contains $anchorKey) { $rollup.$anchorKey } else { $null }
      $nowRoll = Get-PassNow
      $rollDue = $false
      $lastWheelAt = $null
      if ($rollState -and $rollState.lastWheelSuccess) {
        $lastWheelAt = ConvertTo-ChatAnchorTimeText -Value $rollState.lastWheelSuccess
        if ($lastWheelAt) { $rollDue = (($nowRoll - $lastWheelAt).TotalMinutes -ge 60) }
      } else { $rollDue = $true }
      $rollBacklog = [bool]($rollState -and $rollState.backlog)
      $historyScanDue = $rollBacklog -or $rollDue
      if (-not $rollBacklog -and $rollState -and $rollState.lastWheelSuccess) { $rollBacklog = $rollDue }
      if ($rollBacklog) {
        $pendingRec = [ordered]@{ lastAttempt = (Get-Date).ToString('o'); lastWheelSuccess = $(if ($lastWheelAt) { $lastWheelAt.ToString('o') } else { $null }); lastFailure = '补扫待进行'; attempted = $false; succeeded = $false; backlog = $true }
        $historyRollup | Add-Member -NotePropertyMembers @{ ([string]$anchorKey) = [pscustomobject]$pendingRec } -Force
        if (-not $Peek) { Save-Json $historyRollupPath $historyRollup }
      }
      # R4（用户原话）：当前界面的时间就是上次锚点的时间 → 没有新消息，一次滚轮都不发。
      $curTimes = Get-ChatTimesFromLines -Lines $newestTexts -Now (Get-PassNow)
      $noNewByTime = [bool]($anchorTime -and $curTimes.newest -and ($curTimes.newest -le $anchorTime))
      if ($anchorHitFirst -and $anchors.Count -gt 0) {
        Log '  往期滚动：当前屏至少命中两个较长锚点 → 暂不翻页（避免单条常见文本/公告误停）'
      } elseif ($noNewByTime) {
        Log ('  往期滚动：当前屏最新时间 {0:MM-dd HH:mm} ≤ 锚点时间 {1:MM-dd HH:mm} → 没有新消息，不往前翻（不发滚轮）' -f $curTimes.newest, $anchorTime)
      }
      # 翻页上限：有锚点 → 一直翻到锚点（hardMax 兜底防死循环）；没锚点（第一次采这个群）→ 只翻 initial 屏
      $histInitial = if ($cfg.PSObject.Properties['historyScreens']) { [int]$cfg.historyScreens } else { 2 }
      $histHardMax = if ($cfg.PSObject.Properties['historyMaxScreens']) { [int]$cfg.historyMaxScreens } else { 40 }
      $untilAnchor = if ($cfg.PSObject.Properties['historyUntilAnchor']) { [bool]$cfg.historyUntilAnchor } else { $true }
      $histLimit = if ($untilAnchor -and ($anchors.Count -gt 0 -or $anchorTime)) { $histHardMax } else { $histInitial }
      if ($rollBacklog -or $anchorFileMissing) { $histLimit = $histHardMax }
      if (($anchorHitFirst -or $noNewByTime) -and -not $rollBacklog) { $histLimit = 0 }
      if ($rollBacklog) { Log ('  历史补扫：距上次滚轮成功已 {0:N0} 分钟，重新核对时间水位之后的消息' -f ($nowRoll - $lastWheelAt).TotalMinutes) }
      $screens = @(, $newestTexts)
      $historyUnsafe = $false
      $wheelAttempted = $false
      $wheelSucceeded = $false
      $historyStartLines = @($newestTexts)
      $wheelFailure = ''
      $wheelSuccessAt = $null
      $wheelNotchesSent = 0
      $wheelScreensChanged = $false
      $historyBoundaryReached = -not $rollBacklog
      $historyStableAtTop = $false
      $historyRestoreSucceeded = -not $rollBacklog
      $historyAnchorHit = $false
      $sameScreenStreak = 0
      if ($rollBacklog) {
        # 未成功完成补扫前，不允许重复写相同屏；保持原水位，失败会留待下轮重试。
        $wheelAttempted = $false
      }
      if ($histLimit -gt 0 -and $histNotches -gt 0) {
        Log ("  往期滚动：目标=翻到上次记录的边界（上限 {0} 屏）" -f $histLimit)
        $wheelNotchesSent = 0
        $wheelScreensChanged = $false
        $scrolledNotches = 0
        $mayRestoreHistory = $true
        $historyCursor = [WxGuardedInput]::Cursor()
        $sawHistoryContent = $false
        $historyProbeScreens = @()
        for ($hi = 1; $hi -le $histLimit; $hi++) {
          try {
            $wheelAttempted = $true
            $sentThisStep = [int](Invoke-WxWheel -Hwnd $info.hwnd -Notches $histNotches -Win $info -Cfg $cfg -SplitX ([int]$script:WxSplitX) -HistoryGuard -HistoryCursor $historyCursor)
            if ($sentThisStep -le 0) { throw 'INPUT_TARGET_LOST: 滚轮没有确认发送任何刻度' }
            $scrolledNotches += $sentThisStep
            $wheelNotchesSent += $sentThisStep
          } catch {
            $wheelError = $_.Exception.Message
            $wheelFailure = $wheelError
            if ($wheelError -match '已发送 (\d+) 格') { $scrolledNotches += [int]$matches[1] }
            if ($wheelError -match 'INPUT_ABORTED|已发送 [1-9]\d* 格') { $mayRestoreHistory = $false }
            Log ('  停止翻页：' + $wheelError)
            $historyUnsafe = $true
            break
          }
          Start-Sleep -Milliseconds $histSettle
          $shotH = Join-Path $shotDir ('hist-{0}-{1}.png' -f ([DateTime]::Now.ToString('HHmmss')), $hi)
          try {
            $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shotH -Scale $ocrScale
            $rowsH = Invoke-WxOcr -Path $shotH -Scale $ocrScale
            $parsedH = Get-ChatsFromRows $rowsH
            $pageHeader = Get-ChatHeader $parsedH.chatLines
            if (-not (Test-ChatHeaderIdentity -Actual $pageHeader -Expected $header)) {
              Log ('  翻页后标题改变或未识别「{0}」→ 放弃本群，不混合正文' -f $pageHeader)
              $historyUnsafe = $true; break
            }
            $textsH = @($parsedH.chatLines | Sort-Object y | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($textsH.Count -gt 0) {
              $sawHistoryContent = $true
              $historyProbeScreens += , $textsH
            }
          } catch {
            Log ('  往期滚动第 {0} 屏截图/OCR失败：{1} → 放弃本群，避免推进锚点' -f $hi, $_.Exception.Message)
            $textsH = @()
            $historyUnsafe = $true
            break
          }
          if ($textsH.Count -eq 0) {
            Log ('  往期滚动：第 {0} 屏没读到内容（可能到顶了）→ 停止' -f $hi)
            if ($rollBacklog) { $historyUnsafe = $true; $wheelFailure = '空 OCR 不足以确认历史边界' }
            break
          }
          $screenChanged = -not (Test-WxHistoryPageMatches -ExpectedTitle $header -ExpectedLines $historyStartLines -ActualTitle $pageHeader -ActualLines $textsH)
          if ($screenChanged) { $wheelScreensChanged = $true }
          $anchorHit = Test-ChatAnchorHit -Lines $textsH -Anchors $anchors -MinimumHits 2
          # 停止条件（2026-10-27）：文本命中 **或** 时间越过锚点（OCR 把锚点行读歪时靠时间兜底）
          $hitTime = $false
          if ($anchorTime) {
            $ht = Get-ChatTimesFromLines -Lines $textsH -Now (Get-PassNow)
            $hitTime = [bool]($ht.oldest -and ($ht.oldest -le $anchorTime))
            if ($hitTime) { $hitTimeWhy = ('时间越过：本屏最旧 {0:MM-dd HH:mm} ≤ 锚点 {1:MM-dd HH:mm}' -f $ht.oldest, $anchorTime) }
          }
          # 到顶判断要跟**上一屏**比（$screens 最后一项）。
          $same = (($textsH -join "`n") -eq ($screens[$screens.Count - 1] -join "`n"))
          if ($same) { $sameScreenStreak++ } else { $sameScreenStreak = 0 }
          $screens += , $textsH
          if ($sameScreenStreak -ge 2) {
            Log ('  往期滚动：连续 {0} 次画面不变，停止尝试；不能据此证明已到顶' -f ($sameScreenStreak + 1))
            if ($rollBacklog) { $wheelFailure = '画面连续不变，无法确认到顶或历史边界' }
            break
          }
          if ($anchorHit -or $hitTime) {
            $whyStop = @()
            if ($anchorHit) { $whyStop += '文本命中锚点' }
            if ($hitTime) { $whyStop += $hitTimeWhy }
            Log ('  往期滚动：第 {0} 屏到达上次记录的边界（{1}）→ 停止翻页' -f $hi, ($whyStop -join '；'))
            $historyAnchorHit = $true
            $historyBoundaryReached = $true
            break
          }
        }
        if ($scrolledNotches -ne 0 -and $mayRestoreHistory -and $wheelScreensChanged) {
          # 已确认历史画面确实变化、且没有用户抢鼠标时，才尝试按实际刻度滚回。
          try {
            [void](Invoke-WxWheel -Hwnd $info.hwnd -Notches (-$scrolledNotches) -StepDelayMs 40 -Win $info -Cfg $cfg -SplitX ([int]$script:WxSplitX) -HistoryGuard -HistoryCursor $historyCursor)
            Start-Sleep -Milliseconds $histSettle
            $restoreShot = Join-Path $shotDir ('hist-{0}-restore.png' -f [DateTime]::Now.ToString('HHmmss'))
            $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $restoreShot -Scale $ocrScale
            $restoreRows = Invoke-WxOcr -Path $restoreShot -Scale $ocrScale
            $restoreParsed = Get-ChatsFromRows $restoreRows
            $restoreHeader = Get-ChatHeader $restoreParsed.chatLines
            $restoreTexts = @($restoreParsed.chatLines | Sort-Object y | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $restoreMatches = Test-WxHistoryPageMatches -ExpectedTitle $header -ExpectedLines $historyStartLines -ActualTitle $restoreHeader -ActualLines $restoreTexts
            $restoreTitleOk = Test-ChatHeaderIdentity -Actual $restoreHeader -Expected $header
            $restoreContentOk = $restoreMatches
            if (-not $restoreTitleOk -or -not $restoreContentOk) {
              $historyRestoreSucceeded = $false
              $historyUnsafe = $true
              $wheelFailure = '滚回后标题或首屏正文未与操作前匹配'
              Log ('  滚回状态未验证：标题匹配={0}，首屏匹配={1}' -f $restoreTitleOk, $restoreContentOk)
              throw $wheelFailure
            }
            $historyRestoreSucceeded = $true
            if ($sawHistoryContent -and $wheelScreensChanged) { $wheelSucceeded = $true; $wheelSuccessAt = Get-Date }
            Log ('  往期滚动：实际翻动 {0} 格，已通过标题和首屏正文确认恢复' -f $scrolledNotches)
          } catch {
            Log ('  停止恢复滚动：' + $_.Exception.Message)
            $historyRestoreSucceeded = $false
            $historyUnsafe = $true
          }
        } elseif ($scrolledNotches -ne 0) {
          Log ('  未确认历史画面变化或用户已接管输入，保留当前滚动位置（已发送 {0} 格），不盲目恢复' -f $scrolledNotches)
          $historyUnsafe = $true
          if (-not $wheelFailure) { $wheelFailure = '未确认历史画面变化，未盲目恢复滚动' }
        }
      }
      if ($rollBacklog -and -not $historyBoundaryReached) {
        $historyUnsafe = $true
        if (-not $wheelFailure) { $wheelFailure = '达到扫描上限但未确认历史边界' }
      }
      if ($rollBacklog -and -not $historyUnsafe -and -not $historyAnchorHit -and -not $historyStableAtTop) {
        $historyUnsafe = $true
        $wheelFailure = '未找到原锚点且未确认到顶，补扫保持待处理'
      }
      if ($rollBacklog -and -not $historyRestoreSucceeded) {
        $historyUnsafe = $true
        if (-not $wheelFailure) { $wheelFailure = '未成功恢复原滚动位置' }
      }
      if ($historyUnsafe) {
        $rollRec = [ordered]@{ lastAttempt = (Get-Date).ToString('o'); lastWheelSuccess = $(if ($lastWheelAt) { $lastWheelAt.ToString('o') } else { $null }); lastFailure = $wheelFailure; attempted = $wheelAttempted; succeeded = $false; backlog = $true }
        $historyRollup | Add-Member -NotePropertyMembers @{ ([string]$anchorKey) = [pscustomobject]$rollRec } -Force
        if (-not $Peek) { Save-Json $historyRollupPath $historyRollup }
        Log '  本群操作被中断，不写正文或更新锚点；已记录滚轮水位，待下次可滚动时补扫'
        continue
      }
      # 只在整轮历史操作和回到底部都成功后，才把 backlog 标为完成；写 spool/锚点后再持久化完成水位。
      # 真实滚轮发送记在时间字段；不把当前轮启动时间伪装成“已检查完成”。
      if ($wheelSucceeded) { $rollWheelTime = $wheelSuccessAt }
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
      if (-not $verified) {
        Log '  标题身份不确定，已在正文过滤前终止，不按期望群规则继续处理'
        continue
      }
      $ruleName = $header
      $rule2 = Get-ChatRule -Name $ruleName -Rules $rules -DefaultMode $defMode -DefaultKeywords $defKw
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
      $hashKnown = ($hashes.PSObject.Properties.Name -contains $header)
      $isNew = $true
      if ($hashKnown -and $hashes.$header -eq $hash) { $isNew = $false }
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

      if ($hashKnown -and -not $isNew) {
        Log '  → 正文与上次成功记录完全相同，抑制重复 spool 记录（changed=false 不进入消费游标）'
      } elseif ($text.Length -lt 4) {
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
        $anchorRecords = @()
        $runningTime = $null
        foreach ($line0 in @($merged)) {
          $lineText = [string]$line0
          $lineTime = ConvertFrom-ChatTimeText -Text $lineText -Now (Get-PassNow)
          if ($lineTime) { $runningTime = $lineTime }
          if ((Norm $lineText).Length -ge 6 -and (Norm $lineText) -notmatch '^(群聊成员|群成员|群公告|公告)$') {
            $anchorRecords += [pscustomobject]@{ line = $lineText; time = $runningTime }
          }
        }
        $rec = [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'wechat-screenshot-ocr'
          chat = $header; expected = $c.name; verified = $verified
          changed = $isNew; text = $text
          sendTime = $sendIso
          lines = @($cleanLines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.t } })
        }
        Append-Record $rec | Out-Null; $written++
        # 记下"这一轮记到的最旧 3 行 + 它们的发送时间"：下一轮翻页读到它就停（2026-10-19 / 2026-10-27）
        if (-not $Peek) { Save-ChatAnchors -AnchorFile $anchorFile -Key $anchorKey -Lines $merged -ConsolidateFuzzy $stable -ConsolidateWhitelist $wlList -Time $recTimes.oldest -Records $anchorRecords }
        Log ("  → 标题「{0}」 校验={1} 内容变化={2} 正文 {3} 字" -f $header, $verified, $isNew, $text.Length)
      }
      if (-not $Peek -and $historyScanDue -and -not $historyUnsafe) {
        $rollRec = [ordered]@{ lastAttempt = (Get-Date).ToString('o'); lastWheelSuccess = $(if ($wheelSucceeded -and $rollWheelTime) { $rollWheelTime.ToString('o') } elseif ($lastWheelAt) { $lastWheelAt.ToString('o') } else { $null }); lastFailure = ''; attempted = $wheelAttempted; succeeded = [bool]$wheelSucceeded; backlog = $false }
        $historyRollup | Add-Member -NotePropertyMembers @{ ([string]$anchorKey) = [pscustomobject]$rollRec } -Force
        Save-Json $historyRollupPath $historyRollup
        if ($rollBacklog) { Log '  历史补扫完成：本轮正文和锚点已写入，backlog 已清除' }
      }
      if (-not $SaveShots) { Remove-Item -LiteralPath $shot2 -Force -ErrorAction SilentlyContinue }
    }
    if (-not $NoRestoreFocus -and $prevFg -ne [IntPtr]::Zero) {
      [void](Set-WxForegroundRaw -Hwnd $prevFg)
      Start-Sleep -Milliseconds 200
    }
    if ($script:WxRestoreAfterPass) {
      Clear-WxPseudoState
      Log ('已恢复微信原始窗口状态：{0}' -f $restoreState)
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
  if ($pseudoOldEx -ne $null -or $script:WxRestoreAfterPass -or $script:WxPassForeground -ne [IntPtr]::Zero) {
    Clear-WxPseudoState
    $pseudoOldEx = $null
    Log ('已恢复微信原始窗口状态：{0}' -f $restoreState)
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

# ================= 布局标定（-Calibrate，2026-10-29）=================
# 目的：让"换台机器 / 换个缩放 / 拉一下窗口"不用改代码也不用猜配置 ——
#   跑一次就量出这台机器上的真实布局，写成 layout-profile.txt，之后按「像素常数 × DPI 系数」算。
# 量什么：窗口物理尺寸、DPI、DPI 系数、会话列表宽度（用聊天面板群名左边界反推）、
#         标题条下沿、行距、以及"能不能正常读到会话"。
function Invoke-WxCalibrate {
  $info = Get-WxWindowInfo
  if ($null -eq $info) {
    Write-Host '找不到微信主窗口 —— 请先打开微信（窗口标题含"微信"）再标定。'
    return 1
  }
  if ($info.minimized -or $info.width -lt 200 -or $info.left -lt -10000) {
    Write-Host '微信窗口当前是最小化/折叠态，先恢复再标定…'
    [void](Restore-WxWindow -Hwnd $info.hwnd)
    Start-Sleep -Milliseconds 1500
    $info = Get-WxWindowInfo
  }
  $script:win = $info
  $f = Get-WxDpiFactorOf $info
  $prof = Get-WxLayoutProfile -Win $info -Cfg $cfg

  Write-Host ''
  Write-Host '=== 微信布局标定 ==='
  Write-Host ("窗口        : {0}x{1} @ ({2},{3}) hwnd=0x{4}" -f $info.width, $info.height, $info.left, $info.top, $info.hwnd.ToInt64().ToString('X'))
  Write-Host ("DPI         : {0}（系数 {1:N2}）  感知={2}" -f $info.dpi, $f, $info.dpiAware)
  Write-Host ("坐标空间    : " + $(if ($info.dpiAware) { '物理像素（已声明 DPI 感知）' } elseif ($info.dpiFixed) { '物理像素（按 DPI 校正）' } else { '⚠️ 虚拟像素 —— 缩放不是 100% 时会点歪' }))

  # 截图 + OCR，量真实的行位置
  $shot = Join-Path $shotDir 'calibrate.png'
  $scale = [int]$cfg.scale
  $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale $scale
  $rows = @(Invoke-WxOcr -Path $shot -Scale $scale)
  Write-Host ("OCR 行数    : {0}" -f $rows.Count)

  # 列表宽度：用"标题条里最靠上的一簇"（=聊天面板群名）的左边界反推；没有聊天打开时退回档案/比例
  $lo = [int]($info.width * 0.30)
  $stripLimit = [int]($info.height * 0.12)
  $band = @($rows | Where-Object { $_ -and $_.y -le $stripLimit -and $_.x -ge $lo -and -not [string]::IsNullOrWhiteSpace($_.text) })
  $measured = 0
  $measuredHow = '没打开聊天面板，量不到（按当前档案/比例）'
  if ($band.Count -gt 0) {
    $minY = [int](($band | Measure-Object -Property y -Minimum).Minimum)
    $cluster = @($band | Where-Object { ([int]$_.y - $minY) -le 8 })
    $titleMinX = [int](($cluster | Measure-Object -Property x -Minimum).Minimum)
    $measured = $titleMinX - 6
    $measuredHow = ('按聊天面板群名左边界 x={0} 反推' -f $titleMinX)
  }
  $split = if ($measured -gt 0) { $measured } else { [int]$prof.splitX }
  $listWidthPx = [int][Math]::Round($split / $f)
  Write-Host ("列表宽度    : {0}px（96DPI 折算 {1}px；{2}）" -f $split, $listWidthPx, $measuredHow)
  Write-Host ("标题条下沿  : {0}px（96DPI 折算 {1}px）" -f $prof.titleY, [int][Math]::Round($prof.titleY / $f))
  Write-Host ("分界来源    : {0}" -f $(if ($prof.splitSource -eq 'profile') { '已有布局档案' } else { '配置比例（尚未标定）' }))

  # 用这个分界试解析一次会话列表，看能不能读出会话（能读出来才算标定成功）
  $script:WxSplitOverride = 0
  $parsed = Get-ChatsFromRows $rows
  $sess = @($parsed.chats)
  Write-Host ("会话识别    : {0} 个{1}" -f $sess.Count, $(if ($sess.Count -gt 0) { ' → ' + (($sess | ForEach-Object { $_.name }) -join ' | ') } else { '' }))
  Write-Host ("行距        : {0}px（自适应={1}）" -f $parsed.rowGap, $parsed.gapAuto)

  $ok = ($sess.Count -ge 1) -and ($info.dpiAware -or $info.dpiFixed)
  if (-not $ok -and $sess.Count -eq 0) {
    Write-Host ''
    Write-Host '⚠️ 一个会话都没读到 —— 先确认微信停在会话列表（不是收藏/设置页），再重跑一次。'
    Write-Host '   （本次不写档案，避免把错的布局固化下来）'
    return 1
  }

  # 写档案（key=value 文本，刻意不用 JSON：见 wxlib 里的说明）
  # ⚠️ 只有**真量到**（打开着聊天面板）才写 listWidthPx。
  #   量不到时写进去的只是比例换算值，等于把"猜的数"固化成档案，反而更难发现错 —— 宁可不写。
  $path = Get-WxLayoutProfilePath
  $lines = @(
    '# 微信采集器 布局档案（由 采集器.ps1 -Calibrate 生成）'
    ('# 生成时间 {0:yyyy-MM-dd HH:mm:ss}；窗口 {1}x{2}；DPI {3}（系数 {4:N2}）' -f (Get-Date), $info.width, $info.height, $info.dpi, $f)
    '# 数值都是"96DPI 下的像素"，运行时按 当前DPI/96 换算 —— 所以换缩放不用重新标定。'
  )
  if ($measured -gt 0) {
    $lines += ('listWidthPx={0}' -f $listWidthPx)
    $lines += ('# listWidthPx 来源：{0}' -f $measuredHow)
  } else {
    $lines += '# listWidthPx 未写入：标定时没有打开聊天面板，量不到列表宽度（运行时按标题条自校准）'
  }
  $lines += ('titleStripPx={0}' -f [int][Math]::Round($prof.titleY / $f))
  $lines += ('listCapPx={0}' -f $prof.listCapPx)
  $lines += ('rowGapPx={0}' -f [int][Math]::Round([double]$parsed.rowGap / $f))
  $lines += ('calibratedAt={0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  $lines += ('calibratedWin={0}x{1}' -f $info.width, $info.height)
  $lines += ('calibratedDpi={0}' -f $info.dpi)
  [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($true)))
  $script:WxLayoutProfileCache = $null
  Write-Host ''
  Write-Host ("✅ 已写入布局档案：{0}" -f $path)
  if ($measured -le 0) {
    Write-Host '   ⚠️ 这次没打开聊天面板 → 列表宽度没写进档案（只记了标题条/行距）。'
    Write-Host '      想让档案更准：先手动点开任意一个群，再跑一次 -Calibrate。'
  }
  Write-Host '   之后无论系统缩放到 100%/125%/150%/175%/200%，都按这份档案的像素常数自动换算。'
  return 0
}

$pass = 0
if ($Calibrate) {
  $rc = Invoke-WxCalibrate
  exit $rc
}
do {
  $pass++
  Log ('===== 第 {0} 轮 =====' -f $pass)
  # 状态写在**执行之后**并反映真实结果（1550 版写在执行之前 → 本轮出错也报成功，与这套机制的目的相反）
  $passOk = $true; $passNote = ''; $script:skipNote = ''; $script:WxStatusKind = ''
  try { [void](Invoke-Pass $pass) } catch {
      # 2026-10-16 加：把**出错位置**也写进日志 —— 原来只记 Exception.Message，
      # 遇到"Add-Member 参数校验"这类错根本不知道是脚本哪一行（真事故：19:04 起每轮都崩，只能靠猜）。
      $passOk = $false
      try { Clear-WxPseudoState } catch { Log ('⚠️ 异常后窗口/焦点清理失败：' + $_.Exception.Message) }
      $where = ''
      try { $where = ($_.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim() } catch { }
      $passNote = '本轮出错：' + $_.Exception.Message + $(if ($where) { '｜位置：' + $where } else { '' })
      Log $passNote
    }
  $statusKind = if (-not $passOk) { 'failure' } elseif ($script:WxStatusKind -eq 'env-skip') { 'env-skip' } else { 'complete' }
  # 2026-11-06：离线 fixture 跑（-OcrRows，测试-解析.ps1 用）**不是真实采集**，不能写运行状态——
  #   否则自检里的"采集器 最近一轮 N 分钟前"会被测试刷新成"刚跑过"，真实故障就被掩盖了
  #   （实测：14:04 计划任务那轮的健康状况，被 14:04:45 的 fixture 运行盖掉）。
  if (-not $OcrRows) {
    Write-RunStatus -Name '采集器-微信' -Code $(if ($passOk) { 0 } else { 1 }) -Kind $statusKind -Note ($passNote + $script:skipNote)
  }
  if ($Once) { break }
  if ($Passes -gt 0 -and $pass -ge $Passes) { break }
  Start-Sleep -Seconds $Interval
} while ($true)

# 同上：fixture 运行写单独文件，别覆盖生产日志 last-pass.txt
$logName = if ($OcrRows) { 'last-pass-test.txt' } else { 'last-pass.txt' }
$script:logLines | Set-Content -LiteralPath (Join-Path $logDir $logName) -Encoding UTF8
Write-Host ("日志：{0}" -f (Join-Path $logDir $logName))



















