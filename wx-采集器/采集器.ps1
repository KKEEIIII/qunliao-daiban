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
  [switch]$Peek               # 只看不写：不写 spool、不更新 state（文档/回归测试/自测清单都用它）
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'wxlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'dsh-接入\运行状态.ps1')   # 记录本轮结果

$stateDir = Join-Path $root 'state'
$spoolDir = Join-Path $root 'spool'
$shotDir = Join-Path $root 'shots'
$logDir = Join-Path $root 'logs'
foreach ($d in @($stateDir, $spoolDir, $shotDir, $logDir)) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------- 配置（区域比例 + 忽略名单），首次运行自动生成 ----------
$configPath = Join-Path $root 'config.json'
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

$script:logLines = New-Object System.Collections.Generic.List[string]
function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line
  $script:logLines.Add($line) | Out-Null
}

function Get-ChatsFromRows($rows) {
  <# 把 OCR 行按 x 分到「会话列表」和「聊天区」，再把会话列表行按 y 聚成会话行 #>
  $win = $script:win
  $sxFrom = [int]($win.width * $cfg.sessionXFrom)
  $sxTo = [int]($win.width * $cfg.sessionXTo)
  $cxFrom = [int]($win.width * $cfg.chatXFrom)

  $sessionLines = @($rows | Where-Object { $_.x -ge $sxFrom -and $_.x -le $sxTo } | Sort-Object y)
  $chatLines = @($rows | Where-Object { $_.x -ge $cxFrom } | Sort-Object y)

  $chats = @()
  $cur = $null
  foreach ($ln in $sessionLines) {
    $text = Format-OcrText $ln.text
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $item = [pscustomobject]@{ t = $text; h = [int]$ln.h; y = [int]$ln.y; x = [int]$ln.x }
    if ($null -eq $cur -or ($ln.y - $cur.lastY) -gt $cfg.rowGap) {
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
  $badgeRe = if ($cfg.PSObject.Properties.Name -contains 'badgePattern' -and $cfg.badgePattern) { [string]$cfg.badgePattern } else { '^\d+[+Ww]?$' }
  $nameXMin = 0
  if ($cfg.PSObject.Properties.Name -contains 'nameXFrom' -and $cfg.nameXFrom) { $nameXMin = [int]($win.width * [double]$cfg.nameXFrom) }
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
    #    单看字号不靠谱 —— 实测：名字 '212' 的 h=15，它下面那行预览 '赖杰益：[图片]' 的 h 也是 15，
    #    于是"字号最大"会挑中预览行，把会话名记成 '赖杰益：[图片]'。
    #    真正稳的信号是**文本形态**：预览行几乎都是"发言人：内容"的样子（含冒号且冒号前 ≥2 字），
    #    或"已支付¥…"这类系统文案；群名基本不含冒号。
    $previewRe = if ($cfg.PSObject.Properties.Name -contains 'previewPattern' -and $cfg.previewPattern) { [string]$cfg.previewPattern } else { '^[^：:]{2,16}[：:]\s*\S' }

    $nameLike = @($cand | Where-Object { $_.t -notmatch $previewRe -and $_.t -notmatch '^已(支付|收款|领取)' })
    $pool = if ($nameLike.Count -gt 0) { $nameLike } else { $cand }   # 全像预览时退回全部候选

    $maxIdx = 0
    for ($i = 1; $i -lt $pool.Count; $i++) {
      if ($pool[$i].h -gt $pool[$maxIdx].h) { $maxIdx = $i }
    }
    $name = $pool[$maxIdx].t

    $prevParts = @()
    foreach ($x in $cand) {
      if ($x.t -eq $name) { continue }
      $t = $x.t
      if ($t -match '^\d{1,2}[:：]\d{2}$') { continue }        # 时间
      if ($t -match '^(昨天|星期|周[一二三四五六日天])') { continue }
      $prevParts += $t
    }
    $preview = ($prevParts -join ' ')
    if ($preview.Length -gt $cfg.maxPreviewLen) { $preview = $preview.Substring(0, $cfg.maxPreviewLen) }
    $result += [pscustomobject]@{ name = $name; preview = $preview; y = [int]$c.y; yEnd = [int]$c.lastY; nameY = [int]$pool[$maxIdx].y }
  }
  return [pscustomobject]@{ chats = $result; chatLines = $chatLines }
}

function Get-ChatHeader($chatLines) {
  $win = $script:win
  $limit = [int]($win.height * $cfg.headerYTo)
  foreach ($ln in ($chatLines | Sort-Object y)) {
    if ($ln.y -le $limit -and -not [string]::IsNullOrWhiteSpace($ln.text)) { return (Format-OcrText $ln.text) }
  }
  return ''
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
function Test-Whitelisted([string]$name) {
  if ($null -eq $cfg.groupWhitelist -or $cfg.groupWhitelist.Count -eq 0) { return $true }
  $n = Norm $name
  foreach ($w in $cfg.groupWhitelist) {
    $wn = Norm $w
    if ($wn.Length -gt 0 -and $n -like ("*" + $wn + "*")) { return $true }
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
    if ($rule.mode -ne 'all' -and -not (Test-ChatKeyword $c.preview $rule.keywords)) { continue }
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

  if ($changed.Count -gt 0 -and $AllowClick) {
    # 伪最小化是"点击穿透"的，要做真实点击必须先退出伪最小化、让窗口真正可见可点
    if ($pseudoOldEx -ne $null) {
      Log '有会话需要点开读取 → 退出伪最小化，临时恢复窗口（读完会再收回去）'
      [void](Exit-WxPseudoMinimize -Hwnd $info.hwnd -OldExStyle $pseudoOldEx -RestoreState $restoreState)
      $pseudoOldEx = $null
      [void](Restore-WxWindow -Hwnd $info.hwnd)
      Start-Sleep -Milliseconds 1200
    }
    $prevFg = Get-WxForeground
    $targets = $changed | Select-Object -First $MaxClicks
    foreach ($c in $targets) {
      $null = Set-WxForeground -Hwnd $info.hwnd
      Start-Sleep -Milliseconds 400

      # 关键：列表会因新消息到达而重排，所以点击前**重新截图定位**，只点这一轮里还在原位的会话
      $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale $ocrScale
      $freshRows = Invoke-WxOcr -Path $shot -Scale $ocrScale
      $fresh = (Get-ChatsFromRows $freshRows).chats
      $target = $fresh | Where-Object { (Norm $_.name) -eq (Norm $c.name) } | Select-Object -First 1
      if ($null -eq $target) {
        $target = $fresh | Where-Object {
          $a = Norm $_.name; $b = Norm $c.name
          ($a.Length -gt 1) -and $b.Length -gt 1 -and ($a.Contains($b) -or $b.Contains($a))
        } | Select-Object -First 1
      }
      if ($null -eq $target) {
        Log ("跳过「{0}」：重新截图后列表里找不到它（已被新消息挤走）" -f $c.name)
        continue
      }

      $cx = [int]($info.left + $info.width * $cfg.clickX)
      # 点击 y 以"群名那一行"为基准（$target.nameY）；用 cluster 起点($target.y)会点串行 ——
      # 实测：本意点第 2 行的群，结果命中了第 3 行（cluster 起点比群名行更靠上/更靠下时都会偏）。
      $baseY = if ($target.PSObject.Properties['nameY'] -and $target.nameY -gt 0) { [int]$target.nameY } else { [int]$target.y }
      $cy = [int]($info.top + $baseY + 24)
      # 安全锁：点击坐标处最顶层的窗口必须是微信（否则会把点击送到别的程序上）
      $topAt = [WxNative]::TopAt($cx, $cy)
      if ($topAt -ne $info.hwnd) {
        Log ("跳过「{0}」：({1},{2}) 处最顶层窗口是 0x{3}，不是微信 → 为避免误点已放弃" -f $target.name, $cx, $cy, $topAt.ToInt64().ToString('X'))
        continue
      }
      Log ("点击会话「{0}」 @ 屏幕({1},{2})" -f $target.name, $cx, $cy)
      Invoke-WxClickAt -X $cx -Y $cy
      Start-Sleep -Milliseconds $cfg.clickSettleMs

      $shot2 = Join-Path $shotDir ('chat-{0}.png' -f ([DateTime]::Now.ToString('HHmmss')))
      $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot2 -Scale $ocrScale
      $rows2 = Invoke-WxOcr -Path $shot2 -Scale $ocrScale
      $parsed2 = Get-ChatsFromRows $rows2
      # 刚点开会话时聊天区可能还没渲染完（实测出现过"正文 0 字"）→ 等一会儿再截一次（**不再点**，避免取消选中）
      $bodyGuess = @($parsed2.chatLines | ForEach-Object { (Format-OcrText $_.text) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($bodyGuess.Count -lt 2) {
        Start-Sleep -Milliseconds 1800
        $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot2 -Scale $ocrScale
        $rows2 = Invoke-WxOcr -Path $shot2 -Scale $ocrScale
        $parsed2 = Get-ChatsFromRows $rows2
      }
      $header = Get-ChatHeader $parsed2.chatLines
      if ([string]::IsNullOrWhiteSpace($header)) {
        # 标题没读到（界面还在渲染/被遮挡）：用期望名兜底，并标记未通过校验
        $header = $c.name
        Log ("  标题未识别，暂用期望名「{0}」兜底（verified=false）" -f $header)
      }
      $verified = ((Norm $header).Contains((Norm $c.name))) -or ((Norm $c.name).Contains((Norm $header)))

      # ---------- 误入"非聊天界面"（群助手/服务通知…）→ 退回到会话列表再继续 ----------
      # 为什么需要：点进这类列表型界面后，**后面所有行的坐标都会错位、整轮白跑**。
      # ignoreChats 能在列表层挡住一部分，但 OCR 把名字读错字就挡不住（实测「班级群」→「班纟及群」）。
      # ⚠️ 检测**只用名字白名单**，不用"尾部带 (数字)"的形态启发式：
      #    实测「理综6班-勇往直前（25）」是**正常群名**（括号里是群人数），形态判断会误踢正常群。
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

      $cleanLines = @($parsed2.chatLines | Sort-Object y | ForEach-Object {
          [pscustomobject]@{ x = $_.x; y = $_.y; t = (Format-OcrText $_.text) }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.t) })

      # 按该群的规则过滤：mention 规则只保留命中关键词的行（+上一行发言人）；all 规则保留全部
      # ⚠️ 规则要按**实际点开的那个群**（$header）算，不能按"本意想点的"（$c.name）：
      #    点串行时（列表重排/坐标偏移）会拿错规则去过滤别的群的内容 —— 实测点错到"理综6班"，
      #    却按 <示例群号> 群的 all 规则把它的正文整段收了进来。
      $ruleName = if ([string]::IsNullOrWhiteSpace($header)) { $c.name } else { $header }
      $rule2 = Get-ChatRule -Name $ruleName -Rules $rules -DefaultMode $defMode -DefaultKeywords $defKw
      if (-not $verified) {
        Log ("  ⚠️ 点开的不是本意群（想点「{0}」，实际「{1}」）→ 改按实际群的规则过滤" -f $c.name, $header)
      }
      if ($rule2.mode -ne 'all') {
        $onlyKw = @(Select-KeywordLines -Lines $cleanLines -Keywords $rule2.keywords)
        if ($onlyKw.Count -eq 0) {
          Log ("  → {0} 按规则只采[{1}]，本条没命中，跳过记录（会话已被点开，注意它已被标记已读）" -f $ruleName, ($rule2.keywords -join '/'))
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
        $rec = [ordered]@{
          kind = 'chat'; ts = (Get-Date).ToString('o'); source = 'wechat-screenshot-ocr'
          chat = $header; expected = $c.name; verified = $verified
          changed = $isNew; text = $text
          lines = @($cleanLines | ForEach-Object { [ordered]@{ x = $_.x; y = $_.y; t = $_.t } })
        }
        Append-Record $rec | Out-Null; $written++
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



















