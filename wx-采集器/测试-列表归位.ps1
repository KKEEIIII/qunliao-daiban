param()
$ErrorActionPreference = 'Stop'
$env:WX_LAYOUT_PROFILE = 'none'
$env:WX_LAYOUT_PROFILE_QQ = 'none'
. (Join-Path $PSScriptRoot 'wxlib.ps1')

# ============ 一、列表"被滚离顶部"的判定（纯逻辑，不碰窗口） ============
# 标定依据（本机 1118x809 实测）：顶部时顶行完整 h=16；滚离顶部时顶行被切 h=8~10，其余行 13~14。
function New-Row($x, $y, $h, $t) { [pscustomobject]@{ x = $x; y = $y; h = $h; text = $t } }

$atTop = @(
  (New-Row 157 100 16 'DeepSeek'),
  (New-Row 157 184 13 '微信已切前台'),
  (New-Row 157 268 16 '养场'),
  (New-Row 157 352 13 '预览行')
)
$ci = Get-WxChatListClipInfo -Rows $atTop -WinW 1118 -WinH 809
if (-not $ci.known) { throw '在顶部时应能判断' }
if ($ci.clipped) { throw ('在顶部被误判成滚离顶部：' + $ci.reason) }

$scrolled = @(
  (New-Row 157 100 8 '残行'),
  (New-Row 157 174 13 '预览行'),
  (New-Row 157 258 16 '示例群I1组'),
  (New-Row 157 342 13 '预览行')
)
$ci2 = Get-WxChatListClipInfo -Rows $scrolled -WinW 1118 -WinH 809
if (-not $ci2.clipped) { throw ('滚离顶部漏判：' + $ci2.reason) }
if ($ci2.topH -ne 8) { throw ('顶行高应读成 8：' + $ci2.topH) }

# 行数不足时不得乱判（返回 known=false，调用方据此不动作）
$few = @((New-Row 157 100 8 '残行'), (New-Row 157 174 13 '预览行'))
if ((Get-WxChatListClipInfo -Rows $few -WinW 1118 -WinH 809).known) { throw '行数不足时应返回 known=false' }

# 聊天面板里的行（x 靠右）不能被算进会话列表
$chatPane = @(
  (New-Row 157 100 16 'DeepSeek'),
  (New-Row 157 184 13 '预览'),
  (New-Row 157 268 16 '养场'),
  (New-Row 600 120 8 '聊天正文'),
  (New-Row 620 150 8 '聊天正文2')
)
$ci3 = Get-WxChatListClipInfo -Rows $chatPane -WinW 1118 -WinH 809
if ($ci3.clipped) { throw '聊天面板的行不应影响列表判定' }

# 标题栏区域（很靠上）的行不参与判定
$withTitle = @(
  (New-Row 157 20 8 '标题碎屑'),
  (New-Row 157 120 16 'DeepSeek'),
  (New-Row 157 204 13 '预览'),
  (New-Row 157 288 16 '养场')
)
if ((Get-WxChatListClipInfo -Rows $withTitle -WinW 1118 -WinH 809).clipped) { throw '标题栏碎屑不应触发归位' }

# ============ 二、归位函数的边界（不打真实滚轮） ============
# 窗口零宽高时，抓图会抛错——这里只验证"参数与返回值结构"不会因为空列表炸掉。
$res = Invoke-WxChatListReset -Win ([pscustomobject]@{ hwnd = [IntPtr]::Zero; left = 0; top = 0; width = 0; height = 0 }) -MaxSteps 0 -ErrorAction SilentlyContinue
if ($null -ne $res -and -not $res.PSObject.Properties['moved']) { throw '归位函数返回值缺少 moved 字段' }

# ============ 三、实机（有微信窗口才算，且只读） ============
$info = Get-WxWindowInfo
if (-not $info) {
  Write-Host '（跳过实机部分：当前没有微信窗口）'
  Write-Host '列表归位回归通过（判定逻辑）'
  exit 0
}
$shot = Join-Path $env:TEMP ('wxlistreg-{0}.png' -f [guid]::NewGuid().ToString('N'))
try {
  $null = Save-WxWindowShot -Hwnd $info.hwnd -Path $shot -Scale 1
  $rows = @(Invoke-WxOcr -Path $shot -Scale 1)
} finally {
  Remove-Item -LiteralPath $shot -Force -ErrorAction SilentlyContinue
}
$live = Get-WxChatListClipInfo -Rows $rows -WinW $info.width -WinH $info.height
if (-not $live.known) { throw ('实机列表行数不足，判定逻辑无法工作：{0}' -f $live.count) }
Write-Host ('  实机判定：clipped={0}（{1}）' -f $live.clipped, $live.reason)

Write-Host '列表归位回归通过：顶行被切判定 + 行数不足/聊天面板/标题区不误判'
