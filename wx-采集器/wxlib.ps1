# wxlib.ps1 —— 微信窗口抓图 / 内置 OCR / 模拟点击 的公共库（Windows PowerShell 5.1 可用）
# 用法：. "$PSScriptRoot\wxlib.ps1"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ============ Win32 ============
if (-not ('WxNative' -as [type])) {
  Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class WxNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
  [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint crKey, byte alpha, uint flags);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint crKey, out byte alpha, out uint flags);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  public static bool IsValidWindow(IntPtr h) { uint pid; return h != IntPtr.Zero && GetWindowThreadProcessId(h, out pid) != 0; }
  // 2026-10-29：DPI 相关（125%/150% 缩放下坐标必须统一到物理像素，见下方说明）
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
  // ⚠️ GetThreadDpiAwarenessContext 返回的是**不透明句柄**（本机实测 = 34），
  //   不能直接和 -4/-3/-2 这些预定义值比较；必须先换算成级别
  //   （0=UNAWARE 1=SYSTEM_AWARE 2=PER_MONITOR_AWARE）。这是 2026-10-29 实测踩到的。
  [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();   // 老系统（< Win10 1703）兜底
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X; public int Y; }

  public static IntPtr FindMain() {
    IntPtr best = IntPtr.Zero; int bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (c.ToString() == "Qt51514QWindowIcon" && t.ToString().StartsWith("微信") && IsWindowVisible(h)) {
        RECT r; GetWindowRect(h, out r);
        int area = (r.R - r.L) * (r.B - r.T);
        if (area > bestArea) { bestArea = area; best = h; }
      }
      return true; }, IntPtr.Zero);
    return best; }

  // 列出指定进程的顶层窗口：hwnd|可见|最小化|x|y|宽|高|类名|标题（QQ 采集用）
  public static List<string> ListTopWindows(uint[] pids) {
    var set = new HashSet<uint>(pids);
    var res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (!set.Contains(pid)) return true;
      RECT r; GetWindowRect(h, out r);
      int w = r.R - r.L, hh = r.B - r.T;
      if (w < 200 || hh < 150) return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      res.Add(h.ToInt64() + "|" + IsWindowVisible(h) + "|" + IsIconic(h) + "|" + r.L + "|" + r.T + "|" + w + "|" + hh + "|" + c.ToString() + "|" + t.ToString());
      return true; }, IntPtr.Zero);
    return res; }

  public static int[] RectOf(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    return new int[] { r.L, r.T, r.R - r.L, r.B - r.T }; }

  public static bool IsMin(IntPtr h) { return IsIconic(h); }
  public static IntPtr RootWindow(IntPtr h) { return IsValidWindow(h) ? GetAncestor(h, 2) : IntPtr.Zero; }
  public static bool SameRootWindow(IntPtr a, IntPtr b) {
    if (!IsValidWindow(a) || !IsValidWindow(b)) return false;
    IntPtr ar = RootWindow(a), br = RootWindow(b);
    return ar != IntPtr.Zero && br != IntPtr.Zero && ar == br;
  }
  public static IntPtr ForegroundRoot() { return RootWindow(GetForegroundWindow()); }
  public static bool ForegroundMatches(IntPtr h) { return IsWechatMainWindow(h) && SameRootWindow(GetForegroundWindow(), h); }
  public static bool IsWechatMainWindow(IntPtr h) {
    if (!IsValidWindow(h) || RootWindow(h) != h) return false;
    uint pid; if (GetWindowThreadProcessId(h, out pid) == 0) return false;
    try { string n = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; if (n != "Weixin" && n != "WeChat") return false; } catch { return false; }
    var c = new StringBuilder(256); var t = new StringBuilder(512);
    GetClassNameW(h, c, c.Capacity); GetWindowTextW(h, t, t.Capacity);
    return c.ToString() == "Qt51514QWindowIcon" && t.ToString().StartsWith("微信");
  }
  public static IntPtr PointRoot(int x, int y) { return RootWindow(WindowAt(x, y)); }
  // 2026-11-06：遮挡时"临时置顶 → 滚一下 → 复原 z 序"要用到这两个。
  //   IsTopmost 读 GWL_EXSTYLE 的 WS_EX_TOPMOST(0x8)；ZPrev 取 z 序里紧挨在上面的窗口，
  //   复原时用 SetWindowPos(hwnd, prevZ, ...) 把窗口放回它下面。
  public static bool IsTopmost(IntPtr h) { return h != IntPtr.Zero && (GetWindowLong(h, -20) & 0x8) != 0; }
  public static IntPtr ZPrev(IntPtr h) { return h == IntPtr.Zero ? IntPtr.Zero : GetWindow(h, 3); }
  public static IntPtr WindowAt(int x, int y) {
    POINT p; p.X = x; p.Y = y; return WindowFromPoint(p);
  }
  public static IntPtr TopAt(int x, int y) { return RootWindow(WindowAt(x, y)); }
  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(60);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);   // LEFTDOWN
    System.Threading.Thread.Sleep(40);
    mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);   // LEFTUP
  }
}
"@
}

# 键盘发送（单独一个类，**不去改 WxNative** —— PowerShell 的 `-as [type]` 只加载一次，
# 往已加载的类里加方法不会生效，改了也白改；另起一个类最稳）
if (-not ('WxInput' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WxInput {
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  // 发一次完整的按下+抬起。vk: 0x08=Backspace, 0x0D=Enter, 0x25/0x26/0x27/0x28=方向键, 0x1B=ESC（慎用，见下方说明）
  public static void SendKey(int vk) {
    keybd_event((byte)vk, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    keybd_event((byte)vk, 0, 2, UIntPtr.Zero);
  }
}
'@
}

# ============ DPI 感知：把坐标统一到"物理像素"（2026-10-29）============
#
# 为什么必须有（证据与推导见 发布\实测报告-2026-10-29\维修报告-DPI缩放坐标错乱.md）：
#   本库以前从不声明 DPI 感知，于是在 125%/150% 缩放时 GetWindowRect 返回的是**虚拟坐标**
#   （实测 150%：物理约 1206x1538 的窗口被报成 804x1025），而另外两套坐标是物理的：
#     · PrintWindow 永远按窗口**物理像素**渲染 → 按虚拟尺寸建位图 = 内容被裁掉右下角；
#     · SetCursorPos / mouse_event 吃**物理**屏幕坐标 → 用虚拟坐标算出的点会落到窗口外
#       （实测：算出的 (663,155) 在微信左边界 693 之外，点在了别的程序上）；
#     · Maa 的 PostClick 吃**客户区**坐标（2026-10-27 实测：不能再乘抓图比例）。
#   三套坐标混用，**只在 100% 缩放时数值恰好相等**，所以"我本机能跑、别人机器上全残"。
#
# 做法：把本线程切到 PER_MONITOR_AWARE_V2，让 GetWindowRect 直接返回物理像素。
#   这样截图尺寸、OCR 坐标、点击坐标自动同空间，**所有现有公式一行都不用改**；
#   100% 缩放下这些调用全是 no-op（回归风险几乎为零）。
#   ⚠️ 用线程级而不是进程级：PowerShell / wscript 宿主可能已声明过感知，
#      SetProcessDpiAwarenessContext 在这种情况下会失败（实测），线程级调用总是成功。
$script:WxDpiAware = $false
$script:WxDpiNote = '未初始化'
try {
  [void][WxNative]::SetThreadDpiAwarenessContext([IntPtr](-4))    # -4 = PER_MONITOR_AWARE_V2
  # ⚠️ 不能拿 GetThreadDpiAwarenessContext 的返回值直接和 -4/-3/-2 比 —— 它是**不透明句柄**
  #   （本机实测为 34，2026-10-29）。必须用 GetAwarenessFromDpiAwarenessContext 换算：
  #   0=UNAWARE（虚拟坐标）1=SYSTEM_AWARE 2=PER_MONITOR_AWARE（后两者都是物理坐标）。
  $hCtx = [WxNative]::GetThreadDpiAwarenessContext()
  $script:WxDpiLevel = [WxNative]::GetAwarenessFromDpiAwarenessContext($hCtx)
  $script:WxDpiAware = ($script:WxDpiLevel -ge 1)
  $script:WxDpiNote = ('级别={0}（0=不感知 1=系统 2=每显示器）' -f $script:WxDpiLevel)
} catch {
  try {
    [void][WxNative]::SetProcessDPIAware()                        # Win10 1703 之前的兜底
    $script:WxDpiAware = $true
    $script:WxDpiNote = '进程级（老系统兜底）'
  } catch {
    $script:WxDpiAware = $false
    $script:WxDpiNote = '声明失败：' + $_.Exception.Message
  }
}

# 纯计算：把一个"可能是虚拟坐标"的窗口矩形按窗口 DPI 换算成物理像素。
# 抽成独立函数只为了能单测（测试-DPI坐标.ps1 直接用 150% 的真实数字喂它）。
# -Aware = $true 时原样返回（感知生效时 GetWindowRect 已经是物理值）。
function Convert-WxRectByDpi {
  param(
    [Parameter(Mandatory = $true)][int[]]$Rect,   # @(left, top, width, height)
    [int]$Dpi = 96,
    [bool]$Aware = $true
  )
  $f = 1.0
  if (-not $Aware -and $Dpi -gt 96) { $f = [double]$Dpi / 96.0 }
  if ($f -eq 1.0) {
    return [pscustomobject]@{
      left = $Rect[0]; top = $Rect[1]; width = $Rect[2]; height = $Rect[3]
      factor = 1.0; corrected = $false
    }
  }
  return [pscustomobject]@{
    left = [int][Math]::Round($Rect[0] * $f)
    top = [int][Math]::Round($Rect[1] * $f)
    width = [int][Math]::Round($Rect[2] * $f)
    height = [int][Math]::Round($Rect[3] * $f)
    factor = $f; corrected = $true
  }
}

# 取窗口矩形，并**保证拿到的是物理像素**。
# 正常情况下是 GetWindowRect 原值（上面的感知已生效）；万一感知没生效
# （宿主线程已固定、或调用方另起线程），按窗口 DPI 再校正一次 ——
# 否则 PrintWindow 按物理像素画、我们按虚拟尺寸建位图，画面会被裁掉右下角。
function Get-WxPhysicalRect {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
  $r = [WxNative]::RectOf($Hwnd)
  $dpi = 0
  try { $dpi = [WxNative]::GetDpiForWindow($Hwnd) } catch { }
  $p = Convert-WxRectByDpi -Rect $r -Dpi $dpi -Aware ([bool]$script:WxDpiAware)
  return [pscustomobject]@{
    left = $p.left; top = $p.top; width = $p.width; height = $p.height
    factor = $p.factor; corrected = $p.corrected; dpi = $dpi
  }
}

# ============ 抓图（PrintWindow，含 alpha 修正与放大） ============
function Save-WxWindowShot {
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Scale = 2
  )
  # 2026-10-29：用**物理像素**矩形建位图 —— PrintWindow 是按窗口物理像素渲染的，
  #   以前用 GetWindowRect（125%/150% 下是虚拟值）建位图会把内容裁掉右下角。
  $rp = Get-WxPhysicalRect -Hwnd $Hwnd
  $w = $rp.width; $h = $rp.height
  if ($w -le 0 -or $h -le 0) { throw "窗口尺寸异常：${w}x${h}" }

  $raw = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($raw)
  $hdc = $g.GetHdc()
  $ok = [WxNative]::PrintWindow($Hwnd, $hdc, 2)   # PW_RENDERFULLCONTENT
  $g.ReleaseHdc($hdc); $g.Dispose()
  if (-not $ok) { throw 'PrintWindow 调用失败' }

  if ($Scale -gt 1) {
    $big = New-Object System.Drawing.Bitmap(($w * $Scale), ($h * $Scale))
    $g2 = [System.Drawing.Graphics]::FromImage($big)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($raw, 0, 0, $big.Width, $big.Height)
    $g2.Dispose(); $raw.Dispose()
    $out = $big
  } else {
    $out = $raw
  }

  $out.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $info = [pscustomobject]@{
    path   = $Path
    width  = $out.Width
    height = $out.Height
    scale  = $Scale
    winW   = $w
    winH   = $h
    left   = $rp.left
    top    = $rp.top
  }
  $out.Dispose()
  return $info
}

# ============ 单行裁剪复读（点击前确认目标行，2026-11-06） ============
# 为什么需要：整窗 OCR 会把相邻两行并成一行、把「212」读成「21」、把群名读成乱码，
#   而点击一旦落到错行就会打开错的会话（历史上真的发生过）。
#   做法：只把候选行的名字区域裁出来、放大 3×/4× 各读一遍，**两档都认出同一目标**才允许点击。
function Get-WxRowCropRect {
  <#
    .SYNOPSIS  候选会话行在窗口像素里的裁剪矩形（纯计算，不读图）
    .DESCRIPTION
      x 用名字列的比例边界（默认 0.145~0.42W），y 取名字行基线上下各留 Pad 像素。
      尺寸过小（窗口异常/行高为 0）时 valid=false，调用方必须 fail-closed。
  #>
  param(
    [Parameter(Mandatory = $true)]$Win,
    [Parameter(Mandatory = $true)]$Row,
    [double]$XFrom = 0.145,
    [double]$XTo = 0.42,
    [int]$XToPx = 0,
    [int]$Pad = 6
  )
  $baseY = if ($Row.PSObject.Properties['nameY'] -and $Row.nameY -gt 0) { [int]$Row.nameY } else { [int]$Row.y }
  $nameH = if ($Row.PSObject.Properties['nameH'] -and $Row.nameH -gt 0) { [int]$Row.nameH } else { 18 }
  # 横向优先用「这一行自己的 OCR 范围」：名字列起点随 DPI/字号漂移，
  #   固定比例容易把名字左边切掉（实测 0.145W=162，而名字实际从 x≈150 起）。
  #   ⚠️ 行的 w 是「最宽单个字宽」（见 Invoke-WxOcr），整行右边界要用 x2。
  $nameX = if ($Row.PSObject.Properties['nameX']) { [int]$Row.nameX } else { 0 }
  $nameX2 = if ($Row.PSObject.Properties['nameX2']) { [int]$Row.nameX2 } else { 0 }
  $rowX = if ($nameX -gt 0) { $nameX } elseif ($Row.PSObject.Properties['x']) { [int]$Row.x } else { 0 }
  $rowX2 = if ($nameX -gt 0 -and $nameX2 -gt $nameX) { $nameX2 } elseif ($Row.PSObject.Properties['x2']) { [int]$Row.x2 } else { 0 }
  if ($rowX -gt 0 -and $rowX2 -gt $rowX) {
    $x0 = $rowX - 6
    $x1 = $rowX2 + 6
    if ($XToPx -gt 0 -and $x1 -gt $XToPx) { $x1 = $XToPx }
  } else {
    $x0 = [int][Math]::Floor([double]$Win.width * $XFrom)
    # 右边界默认取比例，但调用方通常应传「列表/聊天分界线 - 边距」的像素值：
    #   分界线常比 0.42W 略靠左，直接用比例会把聊天正文一起裁进来 → 复读结果被污染。
    $x1 = if ($XToPx -gt 0) { $XToPx } else { [int][Math]::Ceiling([double]$Win.width * $XTo) }
  }
  $y0 = $baseY - $Pad
  $y1 = $baseY + [Math]::Max($nameH, 18) + $Pad
  if ($x0 -lt 0) { $x0 = 0 }
  if ($y0 -lt 0) { $y0 = 0 }
  if ($x1 -gt [int]$Win.width) { $x1 = [int]$Win.width }
  if ($y1 -gt [int]$Win.height) { $y1 = [int]$Win.height }
  $w = $x1 - $x0
  $h = $y1 - $y0
  return [pscustomobject]@{
    x = $x0; y = $y0; w = $w; h = $h
    valid = ($w -ge 24 -and $h -ge 12)
    baseY = $baseY; nameH = $nameH
  }
}

function Save-WxRegionShot {
  <#
    .SYNOPSIS  从窗口当前画面裁一块区域，放大后存成 PNG（坐标是窗口像素）
  #>
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [Parameter(Mandatory = $true)][int]$W,
    [Parameter(Mandatory = $true)][int]$H,
    [int]$Scale = 3
  )
  if ($W -le 0 -or $H -le 0) { throw "裁剪区域无效：${W}x${H}" }
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wxregion-{0}.png' -f [guid]::NewGuid().ToString('N'))
  try {
    $null = Save-WxWindowShot -Hwnd $Hwnd -Path $tmp -Scale 1
    $src = [System.Drawing.Bitmap]::FromFile($tmp)
    try {
      $cx = [Math]::Min([Math]::Max(0, $X), [Math]::Max(0, $src.Width - 1))
      $cy = [Math]::Min([Math]::Max(0, $Y), [Math]::Max(0, $src.Height - 1))
      $cw = [Math]::Min($W, $src.Width - $cx)
      $ch = [Math]::Min($H, $src.Height - $cy)
      if ($cw -le 0 -or $ch -le 0) { throw '裁剪区域超出窗口' }
      $rect = New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)
      $crop = $src.Clone($rect, $src.PixelFormat)
    } finally { $src.Dispose() }
    try {
      $outW = [int]($cw * $Scale); $outH = [int]($ch * $Scale)
      $big = New-Object System.Drawing.Bitmap($outW, $outH)
      $g = [System.Drawing.Graphics]::FromImage($big)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($crop, 0, 0, $outW, $outH)
      $g.Dispose()
      $big.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
      $big.Dispose()
    } finally { $crop.Dispose() }
    return [pscustomobject]@{ path = $Path; width = $outW; height = $outH; scale = $Scale }
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Test-WxRowTextMatchesExpected {
  <#
    .SYNOPSIS  复读文本与预期群名是否算同一行（容忍"名字 + 右侧时间/角标"被读成一行）
    .DESCRIPTION
      截图里时间在名字右边同一基线上，OCR 常把它并进名字里（实测
      「26 示例群A 2 班 266…」后面跟着「10/31」和一个未读角标）。
      所以：只有当多出来的尾巴是纯数字/时间符号时才放过；像「DeepSeek」↔「DeepSeek AI」
      这种尾巴带字母的**必须拒绝**（它们是两个不同的会话，配置注释里明确警告过）。
  #>
  param([string]$Text, [string]$Expected)
  if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
  # 归一化口径与 Get-ChatMatchInfo 一致（去空白 + 去标点/括号），
  #   否则「．“」与「."」这类全半角差异会把同一个群判成不同（实测踩过）。
  $clean = { param($s) (([string]$s) -replace '\s', '' -replace '[：:，。、．（）()【】\[\]“”"''·]', '') }
  $nt = & $clean $Text
  $ne = & $clean $Expected
  if ($nt.Length -lt 2 -or $ne.Length -lt 2) { return $false }
  if ($nt -eq $ne) { return $true }
  # 裁剪区左侧可能带进一点面板碎屑（实测读成「、，」），去掉再比
  $nt = $nt -replace '^[^\p{L}\p{N}]+', ''
  if ($nt -eq $ne) { return $true }
  if ($nt.Length -gt $ne.Length -and $nt.StartsWith($ne)) {
    # 只容忍"名字 + 右侧时间/角标"：尾巴必须是数字或时间符号；
    #   角标 0/1 常被 OCR 读成字母 O/I/l（实测「10 / 31 / O」），一并放过。
    $tail = $nt.Substring($ne.Length)
    if ($tail -match '^[\d:/\-OoIl]{1,12}$') { return $true }
  }
  $mi = Get-ChatMatchInfo -A $Text -B $Expected -Whitelist @()
  return [bool]$mi.same
}

function Test-WxRowConfirmation {
  <#
    .SYNOPSIS  点击前的目标行确认：裁行 + 多档放大 OCR，全部档位都认出预期名字才算通过
    .OUTPUTS   @{ ok; reason; passes=@(每档识别文本); rect }
    .DESCRIPTION
      判定规则刻意保守（fail-closed）：默认两档（3×、4×）都要成功识别；
      只要有一档读不出或读成别的名字，就 ok=false → 调用方应跳过该会话而不是冒险点击。
      代价是 OCR 抖动时会少点几个群（下一轮还能补），好过点开错误的群。
  #>
  param(
    [Parameter(Mandatory = $true)]$Win,
    [Parameter(Mandatory = $true)]$Row,
    [Parameter(Mandatory = $true)][string]$Expected,
    [double]$XFrom = 0.145,
    [double]$XTo = 0.42,
    [int]$XToPx = 0,
    [int[]]$Scales = @(3, 4)
  )
  $rect = Get-WxRowCropRect -Win $Win -Row $Row -XFrom $XFrom -XTo $XTo -XToPx $XToPx
  if (-not $rect.valid) {
    return [pscustomobject]@{ ok = $false; reason = ('裁剪区域无效 {0}x{1}' -f $rect.w, $rect.h); passes = @(); rect = $rect }
  }
  $passes = @()
  $matched = 0
  foreach ($s in $Scales) {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('wxrow-{0}-x{1}.png' -f [guid]::NewGuid().ToString('N'), $s)
    try {
      $null = Save-WxRegionShot -Hwnd $Win.hwnd -Path $p -X $rect.x -Y $rect.y -W $rect.w -H $rect.h -Scale $s
      $text = (@(Invoke-WxOcr -Path $p -Scale 1) | ForEach-Object { $_.text }) -join ''
      $text = [string]$text
      $passes += $text
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        # 用「列表行名」那套容错匹配（长名共同前缀 / 数字前缀）+ 尾部时间容忍，
        #   而不是点开后的严格身份：整窗 OCR 的行名本来就带噪声。
        if (Test-WxRowTextMatchesExpected -Text $text -Expected $Expected) { $matched++ }
      }
    } catch {
      $passes += ''
    } finally {
      Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
  }
  $need = [Math]::Max(2, $Scales.Count)
  $ok = ($passes.Count -ge 1 -and $matched -ge $need -and $matched -eq $passes.Count)
  $reason = if ($ok) { '两档 OCR 一致' } else { ('复读未确认（{0}/{1} 档匹配，{2} 档识别）' -f $matched, $need, @($passes | Where-Object { $_ }).Count) }
  return [pscustomobject]@{ ok = $ok; reason = $reason; passes = $passes; rect = $rect }
}

# ============ 会话列表是否被滚离顶部（2026-11-06） ============
# 为什么需要：采集器**不会滚动会话列表**，只认当前可见的那几行。用户手动把列表往下滚过之后，
#   视野外的群就等于"不存在"——它们有新消息也采不到（实测：13:27 有 7 个置顶群，13:57 只剩 3 个可见，
#   另外几个只是滚出了视野）。所以每轮采集前先判断列表有没有被滚走，必要时滚回顶部。
function Get-WxChatListClipInfo {
  <#
    .SYNOPSIS  从 OCR 行判断「列表顶行是不是被视口切掉」（= 列表被滚离了顶部）
    .DESCRIPTION
      标定依据（本机 1118x809 实测）：
        · 在顶部时，顶行是完整的一行，OCR 行高 16；
        · 滚离顶部时，顶行被视口边缘切断，OCR 行高只有 8、文字也读成碎屑（"乙》乙"）。
      所以判据是**相对**的：顶行高 < 其余行中位高 × 0.85 → 认为被切。
      （阈值标定：被切实测 8/13=0.61、10/14=0.71；在顶部实测 16/13=1.23。
        取 0.85 是为了宁可误报——误报只是在顶部多滚几下（无效动作），漏报才是漏采。）
      绝对 y 不能用来判断（两种状态顶行的 y 都是 100，差不出区别）。
    .OUTPUTS   @{ known; clipped; topH; medianH; count; topText; reason }
  #>
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
    [Parameter(Mandatory = $true)][double]$WinW,
    [Parameter(Mandatory = $true)][double]$WinH,
    [double]$XFrom = 0.10,
    [double]$XTo = 0.37,
    [double]$ListTopRatio = 0.10,
    [double]$Ratio = 0.85
  )
  $x0 = [int]($WinW * $XFrom); $x1 = [int]($WinW * $XTo); $y0 = [int]($WinH * $ListTopRatio)
  $sel = @($Rows | Where-Object {
      $_ -and $_.x -ge $x0 -and $_.x -lt $x1 -and $_.y -ge $y0 -and ([string]$_.text).Trim().Length -ge 1
    } | Sort-Object y)
  if ($sel.Count -lt 3) {
    return [pscustomobject]@{ known = $false; clipped = $false; topH = 0; medianH = 0; count = $sel.Count; topText = ''; reason = '列表可读行太少，无法判断' }
  }
  $topH = [int]$sel[0].h
  $hs = @($sel | Select-Object -Skip 1 | ForEach-Object { [int]$_.h } | Sort-Object)
  $medianH = [int]$hs[[int](($hs.Count - 1) / 2)]
  $clipped = ($medianH -ge 10 -and $topH -gt 0 -and $topH -lt ($medianH * $Ratio))
  $reason = if ($clipped) { ('顶行被切（h={0} vs 常规 {1}）' -f $topH, $medianH) } else { ('顶行完整（h={0} / 常规 {1}）' -f $topH, $medianH) }
  return [pscustomobject]@{ known = $true; clipped = $clipped; topH = $topH; medianH = $medianH; count = $sel.Count; topText = [string]$sel[0].text; reason = $reason }
}

function Invoke-WxChatListReset {
  <#
    .SYNOPSIS  把会话列表滚回顶部（只在检测到"顶行被切"时才动）
    .DESCRIPTION
      ⚠️ 必须用**真实滚轮**：微信只认真实 WM_MOUSEWHEEL（合成消息它不理），
      所以调用前窗口必须是可见/可接收输入的。伪最小化时窗口带 WS_EX_TRANSPARENT（点击穿透），
      落点会被下发到后面的窗口 —— `Invoke-TargetWindowWheel` 会拒绝，这里也会安全返回 moved=false。
    .OUTPUTS   @{ moved; steps; notches; clippedBefore; clippedAfter; before; after }
  #>
  param(
    [Parameter(Mandatory = $true)]$Win,
    [int]$StepNotches = 3,
    [int]$MaxSteps = 3,
    [int]$StepDelayMs = 260,
    [switch]$AutoFocus
  )
  $hwnd = $Win.hwnd
  $shot = Join-Path ([System.IO.Path]::GetTempPath()) ('wxlist-{0}.png' -f [guid]::NewGuid().ToString('N'))
  $prevFg = [IntPtr]::Zero; $focusedByUs = $false
  $measure = {
    param($path)
    $null = Save-WxWindowShot -Hwnd $hwnd -Path $path -Scale 1
    $rows = @(Invoke-WxOcr -Path $path -Scale 1)
    Get-WxChatListClipInfo -Rows $rows -WinW ([double]$Win.width) -WinH ([double]$Win.height)
  }
  try {
    $before = & $measure $shot
    if ($before.known -and -not $before.clipped) {
      return [pscustomobject]@{ moved = $false; steps = 0; notches = 0; method = 'geometry'; clippedBefore = $false; clippedAfter = $false; before = $before; after = $before }
    }
    # 确实需要归位（或几何判不出来）时才动前台：真实滚轮要求落点归目标窗口，被别的窗口盖住会被守卫拒绝。
    # 滚完立刻把前台还给原来的窗口，不长期抢焦点。
    if ($AutoFocus -and -not [WxNative]::ForegroundMatches($hwnd)) {
      $prevFg = [WxNative]::GetForegroundWindow()
      [void](Set-WxForeground -Hwnd $hwnd)
      Start-Sleep -Milliseconds 500
      $focusedByUs = $true
    }
    $sx = [int]($Win.left + $Win.width * 0.20)
    $sy = [int]($Win.top + $Win.height * 0.45)
    # 2026-11-06：**几何判据判不出来时**（列表可读行太少），退回"内容签名法"：
    #   一路向上滚，直到 OCR 文本不再变化（= 到顶）。QQ 那边一直用这个，稳但不依赖版式特征。
    if (-not $before.known) {
      $prevSig = ''; $sigRounds = 0; $sigNotches = 0
      while ($sigRounds -lt $MaxSteps) {
        $null = Save-WxWindowShot -Hwnd $hwnd -Path $shot -Scale 1
        $sigRows = @(Invoke-WxOcr -Path $shot -Scale 1)
        $curSig = (@($sigRows | Where-Object {
              $_.x -ge [int]($Win.width * 0.10) -and $_.x -lt [int]($Win.width * 0.37) -and
              -not [string]::IsNullOrWhiteSpace([string]$_.text)
            } | Sort-Object y | ForEach-Object { [string]$_.text }) -join '|')
        if ($sigRounds -gt 0 -and $curSig -eq $prevSig) { break }
        $prevSig = $curSig
        $null = Invoke-TargetWindowWheel -Hwnd $hwnd -X $sx -Y $sy -Notches $StepNotches -StepDelayMs 60 -RequireWechat
        $sigNotches += $StepNotches
        $sigRounds++
        Start-Sleep -Milliseconds $StepDelayMs
      }
      return [pscustomobject]@{ moved = ($sigRounds -gt 0); steps = $sigRounds; notches = $sigNotches; method = 'signature'; clippedBefore = $false; clippedAfter = $false; before = $before; after = $before }
    }
    $steps = 0; $notches = 0; $after = $before
    while ($steps -lt $MaxSteps) {
      $null = Invoke-TargetWindowWheel -Hwnd $hwnd -X $sx -Y $sy -Notches $StepNotches -StepDelayMs 60 -RequireWechat
      $notches += $StepNotches
      $steps++
      Start-Sleep -Milliseconds $StepDelayMs
      $after = & $measure $shot
      if (-not $after.known -or -not $after.clipped) { break }
    }
    return [pscustomobject]@{ moved = $true; steps = $steps; notches = $notches; method = 'geometry'; clippedBefore = $true; clippedAfter = [bool]$after.clipped; before = $before; after = $after }
  } finally {
    if ($focusedByUs -and $prevFg -ne [IntPtr]::Zero) {
      try { [void][WxNative]::SetForegroundWindow($prevFg) } catch { }
    }
    Remove-Item -LiteralPath $shot -Force -ErrorAction SilentlyContinue
  }
}

# ============ 内置 OCR（WinRT） ============
[Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime] | Out-Null

$script:WxOcrEngine = $null
function Get-WxOcrEngine {
  if ($null -eq $script:WxOcrEngine) {
    $script:WxOcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $script:WxOcrEngine) { throw 'OCR 引擎创建失败（缺中文语言包）' }
  }
  return $script:WxOcrEngine
}

function Invoke-WxOcr {
  <#
    .SYNOPSIS  对 PNG 做 OCR，返回 @( @{text;x;y;h;w} )

    坐标空间约定：返回的是**放大后图像空间**的像素坐标（$script:win.width 就是这张图的宽度），
    调用方拿 win.height * 0.16 之类去比 y 是对的。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [double]$Scale = 1.0   # 图是放大过的，坐标按此折算
  )
  $bmp = [System.Drawing.Bitmap]::FromFile($Path)
  $w = $bmp.Width; $h = $bmp.Height
  $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $locked = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $size = [Math]::Abs($locked.Stride) * $h
  $bytes = New-Object byte[] $size
  [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $bytes, 0, $size)
  $bmp.UnlockBits($locked); $bmp.Dispose()

  # PrintWindow 出来的 PNG alpha 无效，必须补 255，否则位图全透明、OCR 读不到东西
  for ($i = 3; $i -lt $size; $i += 4) { $bytes[$i] = 255 }

  $buffer = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($bytes)
  $software = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer(
    $buffer, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, $w, $h,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)

  $engine = Get-WxOcrEngine
  $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
  $netTask = $asTaskGeneric.MakeGenericMethod([Windows.Media.Ocr.OcrResult]).Invoke($null, @($engine.RecognizeAsync($software)))
  $netTask.Wait(-1) | Out-Null
  $result = $netTask.Result

  $rows = @()
  $div = if ($Scale -gt 1) { [double]$Scale } else { 1.0 }
  foreach ($line in $result.Lines) {
    $xs = @(); $ys = @(); $hs = @(); $ws = @(); $x2s = @()
    foreach ($word in $line.Words) {
      $r = $word.BoundingRect
      $xs += [double]$r.X; $ys += [double]$r.Y; $hs += [double]$r.Height; $ws += [double]$r.Width
      $x2s += ([double]$r.X + [double]$r.Width)
    }
    $rows += [pscustomobject]@{
      text = $line.Text
      # 坐标空间约定：OCR 跑在放大图上（×Scale），返回前**折算回窗口像素**，
      # 调用方（Get-ChatsFromRows 的 0.10/0.42 列边界、rowGap=35、点击 nameY+24）全部按窗口像素标定。
      # 2026-10-19 修：这里原来漏了折算 → 微信(scale=3) 所有会话名 x≈470 被列边界 [0.10W,0.42W] 拒掉，
      # 只有角标 "14"(x=161) 幸存 → "识别到 1 个会话：14"。QQ(scale=1) 不受影响。
      x    = [int]([Math]::Round((($xs | Measure-Object -Minimum).Minimum) / $div))
      y    = [int]([Math]::Round((($ys | Measure-Object -Minimum).Minimum) / $div))
      h    = [int]([Math]::Round((($hs | Measure-Object -Maximum).Maximum) / $div))
      # w 历史上是「最宽单个字宽」；x2 是整行真实右边界（2026-11-06 加，单行裁剪需要它）。
      w    = [int]([Math]::Round((($ws | Measure-Object -Maximum).Maximum) / $div))
      x2   = [int]([Math]::Round((($x2s | Measure-Object -Maximum).Maximum) / $div))
    }
  }
  return $rows
}

function Test-WxTargetWindowIdentity {
  param([IntPtr]$Hwnd, [switch]$RequireVisible)
  if (-not [WxNative]::IsValidWindow($Hwnd)) { return [pscustomobject]@{ valid = $false; hwnd = $Hwnd; reason = 'invalid-hwnd' } }
  $top = [WxNative]::RootWindow($Hwnd)
  if ($top -eq [IntPtr]::Zero -or $top -ne $Hwnd) { return [pscustomobject]@{ valid = $false; hwnd = $Hwnd; root = $top; reason = 'not-top-level-window' } }
  $processIdValue = [uint32]0
  [void][WxNative]::GetWindowThreadProcessId($Hwnd, [ref]$processIdValue)
  $process = Get-Process -Id ([int]$processIdValue) -ErrorAction SilentlyContinue
  if (-not $process -or $process.ProcessName -notin @('Weixin','WeChat')) { return [pscustomobject]@{ valid = $false; hwnd = $Hwnd; pid = $processIdValue; process = if($process){$process.ProcessName}else{''}; reason = 'not-wechat-process' } }
  $classBuffer = New-Object System.Text.StringBuilder 256
  [void][WxNative]::GetClassNameW($Hwnd, $classBuffer, $classBuffer.Capacity)
  $titleBuffer = New-Object System.Text.StringBuilder 512
  [void][WxNative]::GetWindowTextW($Hwnd, $titleBuffer, $titleBuffer.Capacity)
  $class = $classBuffer.ToString(); $title = $titleBuffer.ToString()
  if ($class -ne 'Qt51514QWindowIcon' -or -not $title.StartsWith('微信')) { return [pscustomobject]@{ valid = $false; hwnd = $Hwnd; pid = $processIdValue; process = $process.ProcessName; class = $class; title = $title; reason = 'wrong-window-class-or-title' } }
  $root = [WxNative]::RootWindow($Hwnd)
  if ($root -eq [IntPtr]::Zero) { return [pscustomobject]@{ valid = $false; hwnd = $Hwnd; pid = $processIdValue; process = $process.ProcessName; class = $class; title = $title; reason = 'missing-root-window' } }
  if ($RequireVisible -and -not [WxNative]::IsWindowVisible($root)) { return [pscustomobject]@{ valid = $false; hwnd = $Hwnd; root = $root; pid = $processIdValue; process = $process.ProcessName; class = $class; title = $title; reason = 'window-hidden' } }
  return [pscustomobject]@{ valid = $true; hwnd = $Hwnd; root = $root; pid = $processIdValue; process = $process.ProcessName; class = $class; title = $title; reason = 'wechat-main-window' }
}

function Get-WxWindowInfo {
  param([IntPtr]$Hwnd = [IntPtr]::Zero)
  $hwnd = if ($Hwnd -ne [IntPtr]::Zero) { $Hwnd } else { [WxNative]::FindMain() }
  if ($hwnd -ne [IntPtr]::Zero -and -not (Test-WxTargetWindowIdentity -Hwnd $hwnd).valid) { return $null }
  if ($hwnd -eq [IntPtr]::Zero) {
    # 兜底：窗口可能被"收进托盘"（SW_HIDE，可见=False）而不是最小化 —— 老逻辑只认可见窗口，
    # 于是直接报"找不到微信主窗口"。这里把隐藏的也找出来，交给伪最小化去抓。
    $hwnd = Find-WxWindowAny -IncludeHidden
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
  }
  # 2026-10-29：统一返回**物理像素**矩形（125%/150% 下以前的虚拟值会让会话列裁剪边界、
  #   标题区范围、点击落点全部按错的尺度算 → "识别到的会话变少 / 点开的不是本意群"）。
  $rp = Get-WxPhysicalRect -Hwnd $hwnd
  return [pscustomobject]@{
    hwnd      = $hwnd
    left      = $rp.left
    top       = $rp.top
    width     = $rp.width
    height    = $rp.height
    minimized = [WxNative]::IsMin($hwnd)
    visible   = [WxNative]::IsWindowVisible($hwnd)
    dpi       = $rp.dpi
    dpiAware  = [bool]$script:WxDpiAware
    dpiFactor = $rp.factor
    dpiFixed  = $rp.corrected
  }
}

function Invoke-WxClickAt {
  param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y)
  [WxNative]::Click($X, $Y)
}

# 真实鼠标点击的竞态保护：共享桌面输入互斥锁，移动后复核目标窗口，按下后总是释放。
if (-not ('WxGuardedClick' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WxGuardedClick {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  static bool Valid(IntPtr h) { uint pid; return h!=IntPtr.Zero && GetWindowThreadProcessId(h,out pid)!=0; }
  static IntPtr Root(IntPtr h) { return !Valid(h) ? IntPtr.Zero : GetAncestor(h,2); }
  public static bool SameRootWindow(IntPtr a, IntPtr b) { return a!=IntPtr.Zero && b!=IntPtr.Zero && Valid(a) && Valid(b) && Root(a)==Root(b); }
  static bool IsWechat(IntPtr h) {
    uint pid; if(!Valid(h) || GetWindowThreadProcessId(h,out pid)==0 || Root(h)!=h) return false;
    try { string n=System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; if(n!="Weixin" && n!="WeChat") return false; } catch { return false; }
    var c=new System.Text.StringBuilder(256); var t=new System.Text.StringBuilder(512);
    GetClassNameW(h,c,c.Capacity); GetWindowTextW(h,t,t.Capacity);
    return c.ToString()=="Qt51514QWindowIcon" && t.ToString().StartsWith("微信");
  }
  public static bool IsWechatWindow(IntPtr h) { return IsWechat(h); }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  static bool At(int x, int y) { POINT p; return GetCursorPos(out p) && p.X==x && p.Y==y; }

  static bool SameRoot(IntPtr a, IntPtr b) { return a!=IntPtr.Zero && b!=IntPtr.Zero && Valid(a) && Valid(b) && Root(a)==Root(b); }
  public static bool ForegroundMatches(IntPtr h) { return IsWechat(h) && SameRoot(GetForegroundWindow(),h); }
  static bool Owns(IntPtr h, int x, int y) {
    POINT p; p.X=x; p.Y=y;
    return IsWechat(h) && SameRoot(GetForegroundWindow(),h) && SameRoot(WindowFromPoint(p),h);
  }
  static bool OnPoint(IntPtr h, int x, int y) {
    POINT p; p.X=x; p.Y=y;
    return IsWechat(h) && SameRoot(WindowFromPoint(p),h);
  }
  public static bool Click(IntPtr h, int x, int y, int settleMs) {
    using (var m = new System.Threading.Mutex(false, "Local\\QunliaoDaiban-DesktopInput")) {
      bool locked=false, down=false, ok=false, haveSaved=false; POINT saved=new POINT(), now=new POINT();
      try {
        try { locked=m.WaitOne(0); } catch (System.Threading.AbandonedMutexException) { locked=true; }
        if (!locked) throw new InvalidOperationException("INPUT_BUSY: 另一采集器正在操作鼠标，跳过本次点击");
        if (!Owns(h,x,y) || !GetCursorPos(out saved)) return false;
        haveSaved=true;
        if (!SetCursorPos(x,y) || !At(x,y) || !Owns(h,x,y)) return false;
        mouse_event(0x0002,0,0,0,UIntPtr.Zero); down=true;
        System.Threading.Thread.Sleep(Math.Max(0,settleMs));
        ok=At(x,y) && Owns(h,x,y);
        return ok;
      } finally {
        if (down) mouse_event(0x0004,0,0,0,UIntPtr.Zero);
        if (haveSaved && GetCursorPos(out now) && now.X==x && now.Y==y && OnPoint(h,x,y)) SetCursorPos(saved.X,saved.Y);
        if (locked) { try { m.ReleaseMutex(); } catch { } }
      }
    }
  }
}
'@
}

function Invoke-TargetWindowClick {
  param([Parameter(Mandatory=$true)][IntPtr]$Hwnd,
    [Parameter(Mandatory=$true)][int]$X, [Parameter(Mandatory=$true)][int]$Y,
    [int]$SettleMs = 40)
  $identity = Test-WxTargetWindowIdentity -Hwnd $Hwnd
  if (-not $identity.valid) { return $false }
  if (-not [WxNative]::ForegroundMatches($Hwnd)) { return $false }
  return [WxGuardedClick]::Click($Hwnd,$X,$Y,$SettleMs)
}

# 每个滚轮事件都检查前台、鼠标位置和命中窗口；用户接管鼠标后立即停止。
# 不自动抢前台；后台截图成功不代表可以发送全局输入。
if (-not ('WxGuardedInput' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WxGuardedInput {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint x, uint y, int data, UIntPtr extra);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  static bool Valid(IntPtr h) { uint pid; return h!=IntPtr.Zero && GetWindowThreadProcessId(h,out pid)!=0; }
  static IntPtr Root(IntPtr h) { return !Valid(h) ? IntPtr.Zero : GetAncestor(h,2); }
  static bool SameRoot(IntPtr a, IntPtr b) { return a!=IntPtr.Zero && b!=IntPtr.Zero && Valid(a) && Valid(b) && Root(a)==Root(b); }
  static bool IsWechat(IntPtr h) {
    uint pid; if(!Valid(h) || GetWindowThreadProcessId(h,out pid)==0 || Root(h)!=h) return false;
    try { string n=System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; if(n!="Weixin" && n!="WeChat") return false; } catch { return false; }
    var c=new System.Text.StringBuilder(256); var t=new System.Text.StringBuilder(512);
    GetClassNameW(h,c,c.Capacity); GetWindowTextW(h,t,t.Capacity);
    return c.ToString()=="Qt51514QWindowIcon" && t.ToString().StartsWith("微信");
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  public static bool SameRootWindow(IntPtr a, IntPtr b) { return SameRoot(a,b); }
  public static bool IsWechatWindow(IntPtr h) { return IsWechat(h); }
  public static bool ForegroundMatches(IntPtr h) { return IsWechat(h) && SameRoot(GetForegroundWindow(),h); }
  public static bool OwnsPoint(IntPtr h, int x, int y) {
    POINT p; p.X=x; p.Y=y;
    // ⚠️ 2026-11-06：这是**通用**守卫（QQ 的滚轮也走这里），不能写死"必须是微信"，
    //   否则 QQ 一律被判"被遮挡"（实测：QQ 临时置顶后仍报 INPUT_TARGET_LOST）。
    //   微信专属身份校验放在调用方：Invoke-TargetWindowWheel -RequireWechat / Invoke-TargetWindowClick。
    return Valid(h) && SameRoot(GetForegroundWindow(),h) && SameRoot(WindowFromPoint(p),h);
  }
  // 2026-11-04：滚轮**不需要窗口在前台**。Windows 把 WM_MOUSEWHEEL 发给光标下的窗口，
  //   这个过程不会激活窗口（不抢焦点）。真正的风险只有一个：落点被别的窗口盖住 → 滚到别人身上。
  //   所以判据从"是不是前台"改成"这个点是不是归目标窗口"，既安全又能后台滚。
  public static bool OnPoint(IntPtr h, int x, int y) {
    POINT p; p.X=x; p.Y=y;
    return Valid(h) && SameRoot(WindowFromPoint(p),h);
  }
  public static bool PositionBg(IntPtr h,int x,int y) { return OnPoint(h,x,y) && SetCursorPos(x,y); }
  public static bool WheelBg(IntPtr h,int x,int y,int delta) {
    if(!At(x,y) || !OnPoint(h,x,y)) return false;
    mouse_event(0x0800,0,0,delta,UIntPtr.Zero); return true;
  }
  public static bool At(int x,int y) { POINT p; return GetCursorPos(out p) && p.X==x && p.Y==y; }
  public static int[] Cursor() { POINT p; if(!GetCursorPos(out p)) throw new InvalidOperationException("Cannot read cursor"); return new int[]{p.X,p.Y}; }
  public static bool Position(IntPtr h,int x,int y) { return OwnsPoint(h,x,y) && SetCursorPos(x,y); }
  public static bool Wheel(IntPtr h,int x,int y,int delta) {
    if(!At(x,y) || !OwnsPoint(h,x,y)) return false;
    mouse_event(0x0800,0,0,delta,UIntPtr.Zero); return true;
  }
  public static void Restore(IntPtr h,int x,int y,int oldX,int oldY) {
    if(At(x,y) && OnPoint(h,x,y)) SetCursorPos(oldX,oldY);
  }
}
'@
}

function Invoke-TargetWindowWheel {
  param([Parameter(Mandatory=$true)][IntPtr]$Hwnd,
    [Parameter(Mandatory=$true)][int]$X, [Parameter(Mandatory=$true)][int]$Y,
    [Parameter(Mandatory=$true)][int]$Notches, [int]$StepDelayMs = 70,
    [int[]]$ExpectedCursor = $null,
    # 2026-11-06：微信身份校验改成**显式开关**。这个函数是通用滚轮（QQ 也用），
    #   默认带上"必须是微信主窗"的校验会把 QQ 的滚轮拦成 INPUT_TARGET_LOST（实测踩过）。
    #   微信的调用点自己传 -RequireWechat。
    [switch]$RequireWechat)
  if ($Notches -eq 0) { return 0 }
  if ($RequireWechat) {
    $identity = Test-WxTargetWindowIdentity -Hwnd $Hwnd
    if (-not $identity.valid) { throw ('INPUT_TARGET_LOST: 输入目标不是有效微信主窗口（{0}）' -f $identity.reason) }
  }
  $mutex = New-Object System.Threading.Mutex($false, 'Local\QunliaoDaiban-DesktopInput')
  $locked = $false; $saved = $null
  try {
    try { $locked = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'INPUT_BUSY: 另一采集器正在操作鼠标，跳过本次滚动' }
    if ($ExpectedCursor -and -not (Test-WxHistoryCursorStable -Expected $ExpectedCursor -Actual ([WxGuardedInput]::Cursor()))) {
      throw 'INPUT_ABORTED: 用户移动鼠标，停止历史滚动'
    }
    if (-not [WxNative]::IsValidWindow($Hwnd) -or [WxNative]::RootWindow($Hwnd) -ne $Hwnd) { throw 'INPUT_TARGET_LOST: 目标句柄已失效或不是顶层窗口' }
    if (-not [WxGuardedInput]::OnPoint($Hwnd,$X,$Y)) { throw 'INPUT_TARGET_LOST: 滚动点不在目标窗口上（被其他窗口遮挡），未发送滚轮' }
    $saved = [WxGuardedInput]::Cursor()
    if (-not [WxGuardedInput]::PositionBg($Hwnd,$X,$Y)) { throw 'INPUT_TARGET_LOST: 无法定位目标滚动点' }
    $delta = if ($Notches -gt 0) { 120 } else { -120 }
    for ($i=0; $i -lt [Math]::Abs($Notches); $i++) {
      if (-not [WxGuardedInput]::WheelBg($Hwnd,$X,$Y,$delta)) {
        throw ('INPUT_ABORTED: 用户移动鼠标或目标被遮挡，停止滚动（已发送 {0} 格）' -f $i)
      }
      if ($StepDelayMs -gt 0) { Start-Sleep -Milliseconds $StepDelayMs }
    }
    return $Notches
  } finally {
    if ($saved) { [WxGuardedInput]::Restore($Hwnd,$X,$Y,$saved[0],$saved[1]) }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

# ==================== 真实鼠标滚轮（2026-10-18：翻往期聊天记录用） ====================
#
# 微信聊天区只响应真实 WM_MOUSEWHEEL；qqread.ps1 那边验证过：Maa 的 PostScroll 对 QQ 全无效，
# 只有 mouse_event WHEEL 有效。这里把它做成通用函数。
# ⚠️ dwData 有符号：正 = 向上（看更早），负 = 向下。类的签名是 uint，所以负值 [uint32](-120 -band 0xFFFFFFFF)。
function Get-WxChatWheelPoints {
  <# 返回消息面板中部的候选屏幕坐标；列表、标题和底部输入区均不在候选范围内。 #>
  param([Parameter(Mandatory=$true)]$Win, [Parameter(Mandatory=$true)]$Cfg, [int]$SplitX = 0)
  $w = [int]$Win.width; $h = [int]$Win.height
  if ($w -lt 400 -or $h -lt 300) { return @() }
  $prof = Get-WxLayoutProfile -Win $Win -Cfg $Cfg
  $split = if ($SplitX -gt 0) { [Math]::Max([int]$prof.splitX,$SplitX) } else { [int]$prof.splitX }
  $x0 = [int][Math]::Max($split + 32, $w * 0.48)
  # 采用聊天区中部的保守带，不向最右侧探测（避免成员/工具侧栏）。
  $x1 = [int][Math]::Min($w * 0.70, $split + ($w - $split) * 0.62)
  $y0 = [int][Math]::Max([double]$prof.titleY + ($h * 0.08), $h * 0.28)
  $y1 = [int]($h * 0.70)   # 避开底部输入区
  if ($x1 -le $x0 + 20 -or $y1 -le $y0 + 20) { return @() }
  $out = @()
  foreach ($yf in @(0.30,0.52,0.72)) {
    foreach ($xf in @(0.25,0.50,0.75)) {
      $lx = [int][Math]::Round($x0 + ($x1 - $x0) * $xf)
      $ly = [int][Math]::Round($y0 + ($y1 - $y0) * $yf)
      $out += [pscustomobject]@{ x = [int]($Win.left + $lx); y = [int]($Win.top + $ly); localX = $lx; localY = $ly }
    }
  }
  return $out
}

function Test-WxHistoryCursorStable {
  param([int[]]$Expected, [int[]]$Actual)
  return ($Expected -and $Actual -and $Expected.Count -ge 2 -and $Actual.Count -ge 2 -and
    $Expected[0] -eq $Actual[0] -and $Expected[1] -eq $Actual[1])
}

function Test-WxHistoryPageMatches {
  param([string]$ExpectedTitle, [string[]]$ExpectedLines, [string]$ActualTitle, [string[]]$ActualLines)
  if ([string]::IsNullOrWhiteSpace($ExpectedTitle) -or [string]::IsNullOrWhiteSpace($ActualTitle)) { return $false }
  if (-not (Test-ChatHeaderIdentity -Actual $ActualTitle -Expected $ExpectedTitle)) { return $false }
  $expected = @($ExpectedLines | ForEach-Object { (([string]$_) -replace '\s', '').ToLowerInvariant() } | Where-Object { $_ })
  $actual = @($ActualLines | ForEach-Object { (([string]$_) -replace '\s', '').ToLowerInvariant() } | Where-Object { $_ })
  if ($expected.Count -lt 2 -or $actual.Count -lt 2) { return $false }
  return (($expected -join "`n") -eq ($actual -join "`n"))
}

function Invoke-WxWheel {
  param(
    [Parameter(Mandatory = $true)][int]$Notches,
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [int]$StepDelayMs = 70,
    $Win = $null, $Cfg = $null, [int]$SplitX = 0, [switch]$HistoryGuard,
    [int[]]$HistoryCursor = $null
  )
  if ($Notches -eq 0) { return 0 }
  $rp = Get-WxPhysicalRect -Hwnd $Hwnd
  if ($rp.width -le 0 -or $rp.height -le 0) { throw 'INPUT_TARGET_LOST: 微信窗口矩形无效' }
  if ($null -eq $Win) {
    $Win = [pscustomobject]@{ hwnd = $Hwnd; left = $rp.left; top = $rp.top; width = $rp.width; height = $rp.height; dpi = $rp.dpi }
  } elseif ($rp.left -ne $Win.left -or $rp.top -ne $Win.top -or $rp.width -ne $Win.width -or $rp.height -ne $Win.height) {
    throw 'INPUT_TARGET_LOST: 微信窗口矩形在滚动前发生变化'
  }
  if ($null -eq $Cfg) { $Cfg = [pscustomobject]@{ headerYTo = 0.16; sessionXTo = 0.42 } }
  $points = @(Get-WxChatWheelPoints -Win $Win -Cfg $Cfg -SplitX $SplitX)
  if ($points.Count -eq 0) { throw 'INPUT_TARGET_LOST: 微信聊天区几何范围太窄或窗口尺寸无效' }
  if ($HistoryCursor -and -not (Test-WxHistoryCursorStable -Expected $HistoryCursor -Actual ([WxGuardedInput]::Cursor()))) {
    throw 'INPUT_ABORTED: 用户移动鼠标，停止历史滚动'
  }
  $cursorBefore = if ($HistoryGuard) { if ($HistoryCursor) { $HistoryCursor } else { [WxGuardedInput]::Cursor() } } else { $null }
  foreach ($p in $points) {
    if ($HistoryGuard -and -not (Test-WxHistoryCursorStable -Expected $cursorBefore -Actual ([WxGuardedInput]::Cursor()))) {
      throw 'INPUT_ABORTED: 用户移动鼠标，停止历史滚动'
    }
    if (-not [WxGuardedInput]::OnPoint($Hwnd,[int]$p.x,[int]$p.y)) { continue }
    try {
      return (Invoke-TargetWindowWheel -Hwnd $Hwnd -X ([int]$p.x) -Y ([int]$p.y) -Notches $Notches -StepDelayMs $StepDelayMs -ExpectedCursor $(if ($HistoryGuard) { $cursorBefore } else { $null }) -RequireWechat)
    } catch {
      if ($_.Exception.Message -match 'INPUT_BUSY|INPUT_ABORTED|已发送 [1-9]\d* 格') { throw }
      # 仅候选点在前置目标校验阶段失效时继续探测；开始注入后绝不换点重发。
      if ($_.Exception.Message -notmatch '^INPUT_TARGET_LOST: (滚动点不在目标窗口上|无法定位目标滚动点)') { throw }
      if ($HistoryGuard -and -not (Test-WxHistoryCursorStable -Expected $cursorBefore -Actual ([WxGuardedInput]::Cursor()))) {
        throw 'INPUT_ABORTED: 用户移动鼠标，停止历史滚动'
      }
    }
    if ($HistoryGuard -and -not (Test-WxHistoryCursorStable -Expected $cursorBefore -Actual ([WxGuardedInput]::Cursor()))) {
      throw 'INPUT_ABORTED: 用户移动鼠标，停止历史滚动'
    }
  }
  throw 'INPUT_TARGET_LOST: 微信聊天区所有安全滚轮候选点均不可用'
}

# 把光标移到"聊天区中心"（滚轮作用于光标下的窗口；左侧 0~42% 是会话列表）
function Move-WxCursorToChatArea {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [double]$XFactor = 0.72, [double]$YFactor = 0.55)
  # 2026-10-29：SetCursorPos 吃物理坐标，所以矩形也要物理值（以前非 100% 缩放会挪到错位置，
  #   滚轮就发给了别的窗口 → 往期翻页整段失效）。
  $rp = Get-WxPhysicalRect -Hwnd $Hwnd
  if ($rp.width -le 0 -or $rp.height -le 0) { return $false }
  $x = [int]($rp.left + $rp.width * $XFactor)
  $y = [int]($rp.top + $rp.height * $YFactor)
  return [WxNative]::SetCursorPos($x, $y)
}

# ==================== 误入非聊天界面的检测与返回 ====================
#
# 背景（为什么要这个）：会话列表里点某一行后，可能进的不是聊天，而是
#   微信的「群助手 / 服务通知 / 订阅号消息」这类**列表型界面**（还有可能是独立的小窗口）。
#   后果不是"少采一条"，而是**后面所有行坐标都错位、整轮白跑**。
#   ignoreChats 能在列表层挡住一部分，但 OCR 会把名字读错字（实测「班级群」→「<OCR 错字示例>」），
#   一旦读错就挡不住，所以还需要"进去之后能退回来"。
#
# ⚠️ 实测结论（2026-10-15）：**ESC 不能当返回键** —— 对微信窗口发 ESC 会让它
#   IsWindowVisible 变 False（等于把窗口藏了），采集器会彻底抓不到画面。
#   所以这里不提供 esc，只提供 backspace / click / clickKey。

# 判断当前看到的"标题"是不是聊天标题。返回 $true 表示"这不是正常聊天界面"。
function Test-WxNonChatHeader {
  param([string]$Header)
  if ([string]::IsNullOrWhiteSpace($Header)) { return $false }
  $h = $Header -replace '\s', ''
  # ⚠️ **只用名字标记白名单**，不用"尾部带 (数字)"这种形态启发式 ——
  #    实测「示例群G-勇往直前（25）」是**正常群名**（括号里是群人数），
  #    形态启发式会把它误判成"群助手"，触发返回 → **把正常群踢掉，比不返回更糟**。
  #    所以这里宁可漏判（漏判 = 回到现状：按实际群的规则过滤，不丢数据），也绝不误判。
  #    标记可通过 config 的 nonChatMarkers 扩展（可把 OCR 常见错字写法也写进去）。
  foreach ($m in @($script:NonChatMarkers)) {
    if ([string]::IsNullOrWhiteSpace($m)) { continue }
    if ($h.Contains(($m -replace '\s', ''))) { return $true }
  }
  return $false
}

# 尝试从"点错的界面"退回到会话列表。
# 返回 $true = 已经尝试过返回动作；$false = 没配/没执行。
function Invoke-WxReturnToMain {
  param($Cfg, [IntPtr]$Hwnd = [IntPtr]::Zero)
  $r = $script:ReturnCfg
  if (-not $r -or -not $r.enabled) { return $false }
  if ($Hwnd -eq [IntPtr]::Zero) { $Hwnd = [WxNative]::FindMain() }
  if ($Hwnd -eq [IntPtr]::Zero) { return $false }
  $null = Set-WxForeground -Hwnd $Hwnd
  Start-Sleep -Milliseconds 250
  if (-not [WxNative]::ForegroundMatches($Hwnd)) {
    Write-Host '  [返回] 微信未取得前台，拒绝发送键盘或鼠标输入'
    return $false
  }

  $action = if ($r.action) { [string]$r.action } else { 'backspace' }
  switch ($action) {
    'backspace' {
      if (-not [WxNative]::ForegroundMatches($Hwnd)) { return $false }
      [WxInput]::SendKey(0x08)              # VK_BACK
      Start-Sleep -Milliseconds 300
      if (-not [WxNative]::ForegroundMatches($Hwnd)) { return $false }
      [WxInput]::SendKey(0x08)
    }
    'click' {
      if (-not $r.click) { return $false }
      $info = Get-WxWindowInfo -Hwnd $Hwnd
      if (-not $info) { return $false }
      $cx = [int]($info.left + $info.width * [double]$r.click.x)
      $cy = [int]($info.top + $info.height * [double]$r.click.y)
      if (-not (Invoke-TargetWindowClick -Hwnd $Hwnd -X $cx -Y $cy -SettleMs 40)) { return $false }
    }
    'clickKey' {
      if (-not $r.click) { return $false }
      $info = Get-WxWindowInfo -Hwnd $Hwnd
      if (-not $info) { return $false }
      $cx = [int]($info.left + $info.width * [double]$r.click.x)
      $cy = [int]($info.top + $info.height * [double]$r.click.y)
      if (-not (Invoke-TargetWindowClick -Hwnd $Hwnd -X $cx -Y $cy -SettleMs 40)) { return $false }
      Start-Sleep -Milliseconds 350
      if ($r.key) {
        if (-not [WxNative]::ForegroundMatches($Hwnd)) { return $false }
        [WxInput]::SendKey([int]$r.key)
      }
    }
    default {
      Write-Host ("  [返回] 未知的 action：{0}" -f $action)
      return $false
    }
  }
  if ($r.settleMs) { Start-Sleep -Milliseconds ([int]$r.settleMs) } else { Start-Sleep -Milliseconds 900 }
  return $true
}

# ==================== 把窗口挪出屏幕（QQ 后台采集用）====================
#
# 为什么需要（2026-10-15 实测结论）：
#   Maa 用的是 Windows.Graphics.Capture 的 CreateForWindow：
#     · 窗口**最小化**时 → `CreateForCaptureItem failed (ret=-2147024809)`，抓出来全黑，抓不到；
#     · 窗口**完全在屏幕之外**但"处于显示状态" → **能抓到**（实测挪到 x=2760 后截图全黑 0%、内容正常）。
#   所以想"看不见 QQ 又不放弃采集"，应该"挪出屏幕"，而不是最小化。
#   （微信那套之所以能最小化，是因为它用 PrintWindow + 伪最小化（透明化）；
#     QQ 的 Chromium 窗口 PrintWindow 是 100% 全黑，只能走 Graphics.Capture，因而受这个限制。）

# 返回 $null = 没动（窗口本来就不是"正常可见"状态）；否则返回 @{left;top;offX} 供还原
function Move-QqOffscreen {
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [int]$ScreenWidth = 1920,
    [int]$Margin = 200
  )
  if ([WxNative]::IsIconic($Hwnd)) { return $null }          # 最小化时挪也没用（抓不到）
  if (-not [WxNative]::IsWindowVisible($Hwnd)) { return $null }
  $r = New-Object WxNative+RECT
  [void][WxNative]::GetWindowRect($Hwnd, [ref]$r)
  $left = $r.L; $top = $r.T
  if ($left -gt $ScreenWidth) { return $null }               # 已经在屏幕外了，不用再动
  $offX = $ScreenWidth + $Margin
  # SWP_NOSIZE(0x1) | SWP_NOZORDER(0x4) | SWP_NOACTIVATE(0x10) —— 不改尺寸、不改层级、不抢焦点
  [void][WxNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, $offX, $top, 0, 0, 0x1 -bor 0x4 -bor 0x10)
  return [pscustomobject]@{ left = $left; top = $top; offX = $offX }
}

function Restore-QqPosition {
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [Parameter(Mandatory = $true)]$Saved
  )
  [void][WxNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, [int]$Saved.left, [int]$Saved.top, 0, 0, 0x1 -bor 0x4 -bor 0x10)
}

# ==================== "挪出屏幕"的还原保险（三层）====================
# 为什么需要三层（2026-10-15 实测：QQ 被留在屏幕外 (2760,327)，日志里没有"已还原"）：
#   `exit` 会**跳过函数里的 finally**，而 -Once 路径正是 `Invoke-QqPass; exit 0`。
#   我在别处踩过这个坑，这次又踩了一次 —— 所以不能只靠 finally。
#   ① finally 里还原（正常路径）
#   ② -Once 的 exit 之前显式还原
#   ③ 启动时读状态文件自愈（即使被强杀也救得回来）

function Get-QqMoveStatePath {
  # 放工作区里（不依赖 $env:TEMP，被系统清理也不会丢）
  $root = Split-Path -Parent $PSScriptRoot
  $dir = Join-Path $root 'dsh-接入\logs'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return (Join-Path $dir 'qq-窗口位置.json')
}

function Save-QqMoveState {
  param([Parameter(Mandatory = $true)]$Saved)
  try {
    $obj = [ordered]@{ left = [int]$Saved.left; top = [int]$Saved.top; offX = [int]$Saved.offX; at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
    [System.IO.File]::WriteAllText((Get-QqMoveStatePath), ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Clear-QqMoveState {
  try { Remove-Item -LiteralPath (Get-QqMoveStatePath) -Force -ErrorAction SilentlyContinue } catch { }
}

# 自愈：上次被强杀 → 状态文件还在 → 把 QQ 拖回原位
function Restore-QqIfMoved {
  param([IntPtr]$Hwnd = [IntPtr]::Zero)
  $sp = Get-QqMoveStatePath
  if (-not (Test-Path -LiteralPath $sp)) { return $false }
  $ok = $false
  try {
    $s = ([System.IO.File]::ReadAllText($sp, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", '') | ConvertFrom-Json
    if ($Hwnd -eq [IntPtr]::Zero) {
      # 找 QQ 主窗口（Chrome_WidgetWin_1 + 标题 QQ）
      $processIdValues = @(Get-Process -Name QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
      foreach ($ln in @([WxNative]::ListTopWindows([UInt32[]]$processIdValues))) {
        $p = $ln -split '\|'
        if ($p[7] -eq 'Chrome_WidgetWin_1' -and $p[8] -eq 'QQ' -and [int]$p[5] -gt 500) { $Hwnd = [IntPtr][int64]$p[0]; break }
      }
    }
    if ($Hwnd -ne [IntPtr]::Zero) {
      [void][WxNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, [int]$s.left, [int]$s.top, 0, 0, 0x1 -bor 0x4 -bor 0x10)
      $ok = $true
    }
  } catch { }
  Clear-QqMoveState
  return $ok
}

function Set-WxForeground {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
  [WxNative]::ShowWindow($Hwnd, 9) | Out-Null          # SW_RESTORE
  [WxNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x43) | Out-Null  # NOMOVE|NOSIZE|SHOWWINDOW
  return [WxNative]::SetForegroundWindow($Hwnd)
}

# 找微信主窗口：默认只要可见的；-IncludeHidden 时把"被 SW_HIDE 藏起来（收托盘）"的也算上。
# 为什么需要：实测用户点关闭按钮后窗口是 **可见=False 而不是最小化**（hwnd 还在、位置尺寸都正常），
# 而老的 FindMain 只认"可见"，于是采集器直接报"找不到微信主窗口"跳过。
function Find-WxWindowAny {
  param([switch]$IncludeHidden)
  $procs = @(Get-Process -Name 'Weixin', 'WeChat' -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return [IntPtr]::Zero }
  $processIdValues = @($procs | ForEach-Object { [UInt32]$_.Id })
  $best = [IntPtr]::Zero
  $bestArea = 0
  foreach ($line in [WxNative]::ListTopWindows($processIdValues)) {
    $p = $line -split '\|'
    if ($p[7] -ne 'Qt51514QWindowIcon') { continue }
    if (-not ($p[8] -like '微信*')) { continue }
    $vis = ($p[1] -eq 'True')
    if (-not $vis -and -not $IncludeHidden) { continue }
    $area = [int]$p[5] * [int]$p[6]
    if ($area -gt $bestArea) { $bestArea = $area; $best = [IntPtr][int64]$p[0] }
  }
  return $best
}

# 只把窗口从最小化恢复出来，不抢焦点（只读采集用）
function Restore-WxWindow {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
  return [WxNative]::ShowWindow($Hwnd, 9)   # SW_RESTORE
}

# 最小化回去（恢复过再收回去用）
function Minimize-WxWindow {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
  return [WxNative]::ShowWindow($Hwnd, 6)   # SW_MINIMIZE
}

# ============ 伪最小化（参考 MaaFramework 的 pseudo-minimize 思路）============
# 窗口最小化时它不参与 DWM 合成，任何截图法都拿不到内容。
# 解法：把窗口"显示出来但不激活"，加上 WS_EX_LAYERED + WS_EX_TRANSPARENT（点击穿透）并把
# alpha 设为 1/255（用户几乎看不见），此时窗口仍在渲染 → PrintWindow 能抓到；
# 截完再还原样式并重新最小化。用户全程看不到窗口弹出、焦点也不会被抢。
function Enter-WxPseudoMinimize {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [string]$RestoreState = 'none')
  if ($Hwnd -eq [IntPtr]::Zero) { throw '无法伪最小化无效窗口句柄' }
  $rect = [WxNative]::RectOf($Hwnd)
  if (-not $rect -or $rect.Count -lt 4 -or $rect[2] -le 0 -or $rect[3] -le 0) { throw '无法伪最小化无效窗口句柄' }
  $old = [WxNative]::GetWindowLong($Hwnd, -20)          # GWL_EXSTYLE
  $oldKey = [uint32]0; $oldAlpha = [byte]255; $oldFlags = [uint32]0
  $hadLayerAttrs = [WxNative]::GetLayeredWindowAttributes($Hwnd,[ref]$oldKey,[ref]$oldAlpha,[ref]$oldFlags)
  $entered = $false
  try {
    [void][WxNative]::ShowWindow($Hwnd, 4)                # SW_SHOWNOACTIVATE
    $pseudoStyle = ($old -bor 0x00080000 -bor 0x00000020)
    [void][WxNative]::SetWindowLong($Hwnd, -20, $pseudoStyle)
    if ([WxNative]::GetWindowLong($Hwnd, -20) -ne $pseudoStyle) {
      throw '设置窗口伪最小化样式失败'
    }
    if (-not [WxNative]::SetLayeredWindowAttributes($Hwnd, 0, 1, 0x2)) {
      throw '设置窗口透明度失败'
    }
    $entered = $true
    return [pscustomobject]@{ oldExStyle = $old; restoreState = $RestoreState; hadLayerAttrs = $hadLayerAttrs; oldColorKey = $oldKey; oldAlpha = $oldAlpha; oldLayerFlags = $oldFlags }
  } finally {
    if (-not $entered) {
      if ($hadLayerAttrs) { [void][WxNative]::SetLayeredWindowAttributes($Hwnd, $oldKey, $oldAlpha, $oldFlags) }
      else { [void][WxNative]::SetLayeredWindowAttributes($Hwnd, 0, 255, 0x2) }
      [void][WxNative]::SetWindowLong($Hwnd, -20, $old)
      switch ($RestoreState) {
        'minimize' { [void][WxNative]::ShowWindow($Hwnd, 6) }
        'hide' { [void][WxNative]::ShowWindow($Hwnd, 0) }
      }
    }
  }
}

function Exit-WxPseudoMinimize {
  <# .PARAMETER RestoreState original | minimize | hide #>
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [int]$OldExStyle, [uint32]$OldColorKey = 0, [byte]$OldAlpha = 255, [uint32]$OldLayerFlags = 0, [switch]$HadLayerAttrs, [switch]$MinimizeAgain, [string]$RestoreState = '')
  $st = $RestoreState
  if (-not $st) { $st = if ($MinimizeAgain) { 'minimize' } else { 'none' } }
  $okAlpha = if ($HadLayerAttrs) {
    [WxNative]::SetLayeredWindowAttributes($Hwnd, $OldColorKey, $OldAlpha, $OldLayerFlags)
  } else {
    [WxNative]::SetLayeredWindowAttributes($Hwnd, 0, 255, 0x2)
  }
  [void][WxNative]::SetWindowLong($Hwnd, -20, $OldExStyle)
  $styleRestored = ([WxNative]::GetWindowLong($Hwnd, -20) -eq $OldExStyle)
  if (-not $okAlpha -or -not $styleRestored) { throw '恢复窗口透明度或扩展样式失败' }
  switch ($st) {
    'minimize' { [void][WxNative]::ShowWindow($Hwnd, 6) }   # SW_MINIMIZE
    'hide'     { [void][WxNative]::ShowWindow($Hwnd, 0) }   # SW_HIDE（收托盘）
  }
}

function Get-WxForeground {
  return [WxNative]::GetForegroundWindow()
}

function Set-WxForegroundRaw {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
  if ($Hwnd -eq [IntPtr]::Zero) { return $false }
  return [WxNative]::SetForegroundWindow($Hwnd)
}

function Format-OcrText {
  <#
    .SYNOPSIS  清洗 Windows OCR 对中文的输出：去掉 CJK 字符之间被插入的空格、标点前后的空格
  #>
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $t = $Text
  $cjk = '\u4e00-\u9fff\u3400-\u4dbf\u3000-\u303f\uff00-\uffef'
  $t = [regex]::Replace($t, "(?<=[$cjk])\s+(?=[$cjk])", '')
  $t = [regex]::Replace($t, '\s+(?=[，。、：；！？）】》」』…])', '')
  $t = [regex]::Replace($t, '(?<=[（【《「『])\s+', '')
  return $t.Trim()
}

# ============ 按群规则："这个群采全部消息，还是只采带指定关键词的" ============
# 配置里长这样（微信 config.json / QQ config-qq.json 通用）：
#   "chatRules": [
#       { "match": "<示例群号>",  "mode": "all" },                                ← 整群都采
#       { "match": "班级群",   "mode": "mention", "keywords": ["@所有人"] }     ← 只采带这些词的
#   ]
# 匹配规则：第一个 match 命中（去空格后包含）的规则生效；都没命中就用调用方给的默认。
function Test-ChatRuleMatch {
  <#
    .SYNOPSIS  规则名匹配（容 OCR 错字）：包含 / 数字前缀 / 滑窗编辑距离≤1
    .DESCRIPTION
      OCR 会把群名读残，所以死写全名匹配不上，要容错。三路依次尝试：
        ① 归一化后直接包含
        ② 数字前缀：**规则里的数字串，以名字里的数字串开头**（OCR 把长数字读残）
           例：规则 "示例群A<示例群号>（官方）" ← 名字被读成 "示例群A266"（<示例群号> → 266）
           实测命中 ✅
        ③ 滑窗编辑距离 ≤1：在名字里滑动长度为 |规则| 的窗口找最像的一段
           注意：**这一路要求"名字 ≥ 规则"长度**，名字更短时进不来。

    ⚠️ 2026-10-15 更正注释（原注释举的第二个例子是错的，实测不成立）：
      原注释写 "示例群A班级群" 被读成 "<OCR 错字示例>" 也能靠 ③ 救回来 ——
      实测**匹配不上**：该残名比规则**短 1 个字符**（10 vs 11），③ 的长度门槛先挡住了；
      而且它与规则的编辑距离是 3（超出 ≤1 的容差）。这是**已知限制**，不是回归：
      旧版（1402~1620）同样匹配不上。真正需要覆盖这类残名时，应把「白名单写短一点」
      （例如写 "26示例群A" 或带数字的短形式），而不是放宽 ③ 的容差 ——
      放宽容差会把不相干的群也匹配进来（实测 "999123" 对 "123" 这种已经因 ① 命中）。
  #>
  param([string]$Name, [string]$Pattern)
  $n = if ($null -eq $Name) { '' } else { ($Name -replace '\s', '') }
  $p = if ($null -eq $Pattern) { '' } else { ($Pattern -replace '\s', '') }
  if ($p.Length -lt 2 -or $n.Length -lt 2) { return $false }
  if ($n.Contains($p)) { return $true }
  # ② 数字前缀
  # ⚠️ 2026-10-15 **当天改错又改回来**，过程值得记下来：
  #   · 另一个 AI 从 1402 版起就报"这一行方向反了"，我前几次判断"现状更宽松、先不动"；
  #   · 后来我**自己手写了一遍判定**做对照实验，得出"该救的是名字数字更长的情形"→ 改成
  #     `$m.Value.StartsWith($pd)`（名字数字以规则数字开头）；
  #   · 那是**回归**：注释里的真实 OCR 残名 `示例群A266`（规则 `…<示例群号>（官方）`）
  #     反而匹配不上了，而第 ③ 步的滑窗编辑距离要求"名字比规则长"，救不回来。
  #   · 那个对照实验错在**把我自己的错误假设编码进了实验**（我假设该救的是"名字更长"）。
  #     对方跑的是**真实的 Test-ChatRuleMatch**，所以结论以它为准。
  # 正确语义就是下面这一行：**规则里的数字串，以名字里的数字串开头** ——
  #   OCR 把长数字读残时，`<示例群号>` 被读成 `266`，此时 `<示例群号>`.StartsWith('266') = True。
  #   （注释里 `266 ⊂ <示例群号>` 这个例子要的就是这个方向。）
  # 教训：判"方向/边界"这类问题**必须跑真实函数**，不能自己重写一遍来对照。
  $pd = ([regex]::Match($p, '\d{3,}')).Value
  if ($pd) {
    foreach ($m in [regex]::Matches($n, '\d{3,}')) {
      if ($pd.StartsWith($m.Value)) { return $true }
    }
  }
  # ③ 滑窗编辑距离 ≤1
  if ($n.Length -ge $p.Length) {
    for ($i = 0; $i -le ($n.Length - $p.Length); $i++) {
      if ((Get-ChatLevenshtein $n.Substring($i, $p.Length) $p) -le 1) { return $true }
    }
  }
  return $false
}

function Get-ChatLevenshtein([string]$a, [string]$b) {
  $n = $a.Length; $m = $b.Length
  if ($n -eq 0) { return $m }
  if ($m -eq 0) { return $n }
  $prev = New-Object 'int[]' ($m + 1); $cur = New-Object 'int[]' ($m + 1)
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

function Get-ChatRule {
  param(
    [string]$Name,
    $Rules,
    [string]$DefaultMode = 'all',
    [string[]]$DefaultKeywords = @()
  )
  if ($Rules) {
    foreach ($r in @($Rules)) {
      if ($null -eq $r) { continue }
      # match 允许写字符串或字符串数组（数组 = 任一命中即可），方便对着 OCR 变体多写几个
      $cands = @($r.match) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
      foreach ($m in $cands) {
        if (Test-ChatRuleMatch -Name $Name -Pattern ([string]$m)) {
          $kw = @()
          if ($r.keywords) { $kw = @($r.keywords | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) }
          return [pscustomobject]@{ mode = [string]$r.mode; keywords = $kw; matched = [string]$m }
        }
      }
    }
  }
  return [pscustomobject]@{ mode = $DefaultMode; keywords = @($DefaultKeywords); matched = '' }
}

# 文本里有没有命中任一关键词（去空格后包含即可）
function Test-ChatKeyword {
  param([string]$Text, [string[]]$Keywords)
  $t = if ($null -eq $Text) { '' } else { ($Text -replace '\s', '') }
  if ($t.Length -eq 0) { return $false }
  foreach ($k in @($Keywords)) {
    if ([string]::IsNullOrWhiteSpace($k)) { continue }
    if ($t.Contains(([string]$k -replace '\s', ''))) { return $true }
  }
  return $false
}

# ==================== 群名匹配（微信 / QQ 共用，2026-10-26） ====================
# 白名单既支持"短关键词"（示例群F/示例部门/某学校/示例群B/示例群I/<示例群号>），也支持完整群名。
# OCR 会把群名读残，所以四路依次尝试（与 QQ 侧原来的 Test-QqMatch 语义一致）：
#   ① 包含             —— 短关键词最常用（"示例群F" ⊂ "…学院示例群F培训"）
#   ② 数字前缀         —— 白名单里的数字串，以名字里的数字串开头（<示例群号> ← 266）
#   ③ 开头文字容错     —— 只对 ≥4 字的长名启用：比较开头 min(6, |规则|) 个字，编辑距离≤容差
#                        （OCR 常把开头几个字读错，如"示例学校新闻"读成"示例学校新闻新闻"）
#   ④ 滑窗编辑距离≤容差 —— 长名容差 2、短名（≤4 字）容差 1，兜住中间某几个字的错字
# 注意：③ 不对 2~3 字短词启用，否则"示例群F"会误命中"团建"之类；短词靠 ①/④。
function Get-ChatNameTolerance([int]$len) {
  # 短名（≤5 字）只容 1 个错字；6 字以上容 2 个 —— 实测 "26人工2紐开级群" 与
  # "示例群A" 的开头 6 字差 2 个字（智能→2紐），容 1 会漏掉整个群。
  if ($len -ge 6) { return 2 }
  return 1
}

function Test-ChatNameMatch {
  param([string]$Name, [string]$Pattern)
  $n = if ($null -eq $Name) { '' } else { ($Name -replace '\s', '') }
  $p = if ($null -eq $Pattern) { '' } else { ($Pattern -replace '\s', '') }
  if ($p.Length -lt 2 -or $n.Length -lt 2) { return $false }
  # ① 包含
  if ($n.Contains($p)) { return $true }
  # ② 数字前缀
  $pd = ([regex]::Match($p, '\d{3,}')).Value
  if ($pd) {
    foreach ($m in [regex]::Matches($n, '\d{3,}')) {
      if ($pd.StartsWith($m.Value)) { return $true }
    }
  }
  # ③ 开头文字容错（长名才启用）
  if ($p.Length -ge 4) {
    $pn = [Math]::Min(6, $p.Length)
    $nn = [Math]::Min($pn, $n.Length)
    if ($nn -ge 2) {
      if ((Get-ChatLevenshtein $n.Substring(0, $nn) $p.Substring(0, $pn)) -le (Get-ChatNameTolerance $nn)) { return $true }
    }
  }
  # ④ 滑窗编辑距离
  if ($n.Length -ge $p.Length) {
    $tol = Get-ChatNameTolerance $p.Length
    for ($i = 0; $i -le ($n.Length - $p.Length); $i++) {
      if ((Get-ChatLevenshtein $n.Substring($i, $p.Length) $p) -le $tol) { return $true }
    }
  }
  return $false
}

# 强标题身份复核：保留确认过的群号截断和 OCR 容错，但不使用短关键词猜测。
function Test-ChatHeaderIdentity {
  param([string]$Actual, [string]$Expected)
  if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
  $normalize = { param($s)
    $v = ([string]$s -replace '\s', '') -replace '[（(]\d+[）)]$', ''
    return ($v -replace '[：:，。、．（）()【】\[\]“”"''·]', '')
  }
  $a = & $normalize $Actual; $b = & $normalize $Expected
  if ($a.Length -ge 2 -and $a -eq $b) { return $true }
  return [bool](Get-ChatFinalIdentityInfo -Actual $a -Expected $b).same
}

# 最终聊天标题身份确认：候选匹配仍由 Get-ChatMatchInfo 负责；此处不接受白名单短词。
# 可容忍：尾部群人数/标点、单字符 OCR 错字；带数字群名的已知稳定前后锚点 OCR 变体；
# 列表名在长标题前被截断（需长数字群名、至少 8 字共同前缀，且数字段一致）。
function Get-ChatFinalIdentityInfo {
  param([string]$Actual, [string]$Expected)
  $normalize = { param($s)
    $v = [string]$s
    $v = $v -replace '\s', ''
    # 微信标题尾部的群人数不属于身份；如「（官方）（52）」只去掉人数。
    $v = $v -replace '[（(]\d+[）)]$', ''
    return ($v -replace '[：:，。、．（）()【】\[\]“”"''·]', '')
  }
  $a = & $normalize $Actual
  $e = & $normalize $Expected
  if ($a.Length -lt 2 -or $e.Length -lt 2) {
    return [pscustomobject]@{ same = $false; why = '标题为空或过短' }
  }
  if ($a -eq $e) {
    return [pscustomobject]@{ same = $true; why = '标题规范化后完全相同' }
  }

  $aNums = @([regex]::Matches($a, '\d+') | ForEach-Object { $_.Value })
  $eNums = @([regex]::Matches($e, '\d+') | ForEach-Object { $_.Value })
  $hasDigits = ($aNums.Count -gt 0 -or $eNums.Count -gt 0)
  $sameNumbers = ($aNums.Count -eq $eNums.Count)
  if ($sameNumbers) {
    for ($i = 0; $i -lt $aNums.Count; $i++) {
      if ($aNums[$i] -ne $eNums[$i]) { $sameNumbers = $false; break }
    }
  }
  # 群号相等为强身份依据；尾部号仅在短的号码为长号码前缀且至少 3 位时容忍 OCR 截断。
  $lastNumberTruncated = $false
  if ($aNums.Count -eq $eNums.Count -and $aNums.Count -gt 0 -and -not $sameNumbers) {
    $lastNumberTruncated = $true
    for ($li = 0; $li -lt ($aNums.Count - 1); $li++) {
      if ($aNums[$li] -ne $eNums[$li]) { $lastNumberTruncated = $false; break }
    }
    if ($lastNumberTruncated) {
      $shortId = if ($aNums[-1].Length -le $eNums[-1].Length) { $aNums[-1] } else { $eNums[-1] }
      $longId = if ($aNums[-1].Length -gt $eNums[-1].Length) { $aNums[-1] } else { $eNums[-1] }
      $lastNumberTruncated = ($shortId.Length -ge 3 -and $longId.StartsWith($shortId))
    }
  }
  if ($aNums.Count -gt 0 -and $eNums.Count -gt 0 -and $aNums[0] -ne $eNums[0]) {
    return [pscustomobject]@{ same = $false; why = '标题主数字标识不同' }
  }
  $extraIdSuffix = ($aNums.Count -lt $eNums.Count -and $aNums.Count -gt 0)
  if ($aNums.Count -eq $eNums.Count -and -not $sameNumbers -and -not $lastNumberTruncated) {
    return [pscustomobject]@{ same = $false; why = '标题数字标识不同' }
  }

  # 受限的 OCR 变体：两边长度相近，名称至少 6 字，只差 1 次编辑。
  # 含数字标题要求数字段相同，或末尾长群号确实被 OCR 截短。
  $nearDigitsCompatible = (-not $hasDigits -or $sameNumbers -or $lastNumberTruncated)
  if ($a.Length -ge 6 -and $e.Length -ge 6 -and [Math]::Abs($a.Length - $e.Length) -le 1 -and
      (Get-ChatLevenshtein $a $e) -le 1 -and $nearDigitsCompatible -and -not ($aNums.Count -lt $eNums.Count -and $aNums.Count -gt 0)) {
    return [pscustomobject]@{ same = $true; why = '标题仅有一个受限 OCR 字符差异' }
  }

  # 已知 OCR 形态：群名数字段相同、开头稳定且末尾仍保留至少两字锚点，
  # 中间出现少量字形误识别（如「26人工2毋形及群」vs「26人工2班<OCR 错字示例>」）。
  if ($sameNumbers -and $aNums.Count -gt 0 -and [Math]::Abs($a.Length - $e.Length) -le 2 -and -not ($aNums.Count -lt $eNums.Count -and $aNums.Count -gt 0)) {
    $prefix = 0
    $prefixLimit = [Math]::Min($a.Length, $e.Length)
    while ($prefix -lt $prefixLimit -and $a[$prefix] -eq $e[$prefix]) { $prefix++ }
    $suffix = 0
    while ($suffix -lt $prefixLimit -and $a[$a.Length - 1 - $suffix] -eq $e[$e.Length - 1 - $suffix]) { $suffix++ }
    if ($prefix -ge 5 -and $suffix -ge 2 -and (Get-ChatLevenshtein $a $e) -le 3) {
      return [pscustomobject]@{ same = $true; why = '数字标识及标题前后锚点一致（受限 OCR 变体）' }
    }
  }

  # 受限群名截断：要求群名前缀相同。若短标题本身已有长数字群号，则允许仅截掉身份文字尾缀；
  # 若短标题的号码只读出前缀，则必须以数字结尾并满足号码字段前缀一致，语义名称不能代替群号。
  $short = $null; $long = $null; $shortNums = @(); $longNums = @()
  if ($a.Length -lt $e.Length) { $short = $a; $long = $e; $shortNums = $aNums; $longNums = $eNums }
  elseif ($e.Length -lt $a.Length) { $short = $e; $long = $a; $shortNums = $eNums; $longNums = $aNums }
  if ($null -ne $short -and $short.Length -ge 8 -and $shortNums.Count -gt 0 -and $longNums.Count -ge $shortNums.Count) {
    $numbersPrefix = $true
    for ($i = 0; $i -lt $shortNums.Count; $i++) {
      if ($i -lt ($shortNums.Count - 1)) {
        if ($shortNums[$i] -ne $longNums[$i]) { $numbersPrefix = $false; break }
      } elseif ($shortNums[$i] -ne $longNums[$i] -and -not ($shortNums[$i].Length -ge 3 -and $longNums[$i].StartsWith($shortNums[$i]))) {
        $numbersPrefix = $false; break
      }
    }
    if ($numbersPrefix) {
      $common = 0
      while ($common -lt $short.Length -and $short[$common] -eq $long[$common]) { $common++ }
      $suffixIsSameTruncation = ($common -eq $short.Length -and $short.Length -lt $long.Length)
      $numSuffixTruncated = ($shortNums.Count -lt $longNums.Count) -or ($shortNums.Count -eq $longNums.Count -and $shortNums.Count -gt 0 -and $shortNums[-1].Length -lt $longNums[-1].Length)
      $mainNumberMatches = ($shortNums.Count -gt 0 -and $longNums.Count -gt 0 -and $shortNums[0] -eq $longNums[0])
      $shortEndLooksLikeId = ($short -match '\d$')
      $shortHasLongId = ($shortNums.Count -gt 0 -and $shortNums[-1].Length -ge 5)
      $shortHasNumericPrefix = ($shortEndLooksLikeId -and $numSuffixTruncated)
      $suffixAllowed = ($shortHasLongId -or $shortHasNumericPrefix)
      if ($suffixIsSameTruncation -and $suffixAllowed -and $mainNumberMatches) {
        return [pscustomobject]@{ same = $true; why = '长数字群标题与列表截断名的数字段/前缀一致' }
      }
    }
  }

  return [pscustomobject]@{ same = $false; why = '最终标题身份不匹配（不以白名单短词确认）' }
}

# ==================== 两个名字是不是同一个群（2026-10-27）====================
# 为什么需要：同一个群，**列表行 OCR 名** 与 **点开后的聊天头部** 经常差一两个字
#   （实测「26 人工 2 毋开级群」vs「26 人工 2 班<OCR 错字示例>（50）」）→ 原来用"包含"判断，
#   于是 verified=false；而两张截图之间同一行的名字也会变（「…2 班…」→「…2 班灬」）
#   → 抓取时"重新截图后列表里找不到它"，那一轮就少点一个群。
# 判据按可靠性排序（**不能只用包含**：「示例部门」⊂「示例部门小组」，但它们是两个群）：
#   ① 归一化后完全相同
#   ② 共同前缀 ≥6 个字（列表行名被截断的典型形态）
#   ③ 白名单**稳定标识**相同（Get-ChatStableKey 取最长命中，能区分「示例部门」和「示例部门小组」）
#   ④ 双方归一化后都 ≥4 字、长度差 ≤1、编辑距离 ≤1（纯 OCR 错一两个字；短名不参与，避免误判）
# 返回 @{ same; why }：why 会写进日志，排障时能看出"凭什么认为它是同一个群"。
function Get-ChatMatchInfo {
  param([string]$A, [string]$B, [string[]]$Whitelist = @())
  $clean = { param($s) if ($null -eq $s) { return '' } return (($s -replace '\s', '') -replace '[：:，。、．（）()【】\[\]“”"''·]', '') }
  $na = & $clean $A
  $nb = & $clean $B
  if ($na.Length -lt 2 -or $nb.Length -lt 2) { return [pscustomobject]@{ same = $false; why = '名字太短或为空' } }
  if ($na -eq $nb) { return [pscustomobject]@{ same = $true; why = '完全相同' } }
  # ② 共同前缀足够长、且**不是"短名正好是长名的完整前缀"** → 多半是**列表行名被截断**
  #   （真机实测：列表行只读到「26 示例群A 2 班灬」，点开后头部是完整的
  #    「26 示例群A 2 班 <示例群号>（官方）（52）」，共同前缀 8 个字后第 9 个字开始不同）。
  #   ⚠️ 排除"完整前缀"是为了别把「DeepSeek」和「DeepSeek AI」判成同一个（它们可能是两个会话）；
  #   「示例部门·示例群C」和「示例部门小组」只共同前缀 3 个字，也不会被误判。
  $common = 0
  $lim = [Math]::Min($na.Length, $nb.Length)
  while ($common -lt $lim -and $na[$common] -eq $nb[$common]) { $common++ }
  $shorterIsPrefix = ($na.Length -le $nb.Length -and $nb.StartsWith($na)) -or ($nb.Length -le $na.Length -and $na.StartsWith($nb))
  if ($common -ge 6 -and -not $shorterIsPrefix) { return [pscustomobject]@{ same = $true; why = ('名字共同前缀 ' + $common + ' 个字（列表行名多半被截断）') } }
  if ($Whitelist.Count -gt 0) {
    $ka = Get-ChatStableKey -Name $A -Whitelist $Whitelist
    $kb = Get-ChatStableKey -Name $B -Whitelist $Whitelist
    $ia = $false; $ib = $false
    foreach ($w in $Whitelist) {
      $wn = ([string]$w -replace '\s', '')
      if (-not $wn) { continue }
      if ($wn -eq $ka) { $ia = $true }
      if ($wn -eq $kb) { $ib = $true }
    }
    if ($ia -or $ib) {
      if ($ka -eq $kb) { return [pscustomobject]@{ same = $true; why = ('同一白名单群「' + $ka + '」') } }
      return [pscustomobject]@{ same = $false; why = ('分属不同白名单群（' + $ka + ' / ' + $kb + '）') }
    }
  }
  if ($na.Length -ge 4 -and [Math]::Abs($na.Length - $nb.Length) -le 1) {
    if ((Get-ChatLevenshtein $na $nb) -le 1) { return [pscustomobject]@{ same = $true; why = '编辑距离≤1（OCR 错字）' } }
  }
  return [pscustomobject]@{ same = $false; why = '既不是同一白名单群、也不像同一个名字' }
}

# ==================== "告知所有人"关键词（微信 / QQ 共用，2026-10-26） ====================
# 用户要求：白名单内所有群都要能识别 @全体成员 / @所有人 / 我们 / 大家 / 同学们 这类
# "对所有人说"的信号（OCR 常把 @全体成员 读成 @全体成员/@ 全 体 成 员/@斫有人 等）。
# 匹配方式：去空格后 ① 包含；② 2~4 字短词在文本里滑窗编辑距离≤1（容 OCR 错字）。
function Get-BroadcastKeywords {
  return @(
    '@全体成员', '@所有人', '@全部成员', '@全员', '@全体', '@所有',
    '全体成员', '所有人', '全部成员', '全员',
    '全体同学', '各位同学', '同学们', '大家', '我们', '各位'
  )
}

function Test-BroadcastKeyword {
  param([string]$Text, [string[]]$ExtraKeywords = @())
  $t = if ($null -eq $Text) { '' } else { ($Text -replace '\s', '') }
  if ($t.Length -eq 0) { return $false }
  $kws = @(Get-BroadcastKeywords) + @($ExtraKeywords | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  # ① 包含
  foreach ($k in $kws) {
    $kk = ([string]$k -replace '\s', '')
    if ($kk.Length -ge 2 -and $t.Contains($kk)) { return $true }
  }
  # ② 短词 OCR 容错（滑窗编辑距离≤1）
  foreach ($k in $kws) {
    $kk = ([string]$k -replace '\s', '')
    if ($kk.Length -lt 2 -or $kk.Length -gt 4) { continue }
    if ($t.Length -lt $kk.Length) { continue }
    for ($i = 0; $i -le ($t.Length - $kk.Length); $i++) {
      if ((Get-ChatLevenshtein $t.Substring($i, $kk.Length) $kk) -le 1) { return $true }
    }
  }
  return $false
}

# 只保留命中关键词的行（并带上上一行作为上下文，通常是发言人）
# 2026-10-26：命中判定改用 Test-BroadcastKeyword —— 自动包含"告知所有人"全套词 + OCR 容错。
function Select-KeywordLines {
  param($Lines, [string[]]$Keywords)
  $out = @()
  $sorted = @($Lines | Sort-Object y)
  for ($i = 0; $i -lt $sorted.Count; $i++) {
    if (Test-BroadcastKeyword -Text $sorted[$i].t -ExtraKeywords $Keywords) {
      if ($i -gt 0) { $out += $sorted[$i - 1] }
      $out += $sorted[$i]
    }
  }
  return $out
}










# ==================== 多屏合并（微信 / QQ 共用，2026-10-19） ====================
# 输入：从**新到旧**排列的多屏文本行（每屏 string[]）；输出：从旧到新、去掉跨屏重复的一串行。
# 两层去重：
#   ① 精确重叠：older 的尾部 == newer 的头部（连续 k 行）—— 滚动错开半屏时最准；
#   ② 跨屏内容去重：同一行文本已在合并结果里出现过就丢弃 —— OCR 对同一行偶有差异，只靠①会重复。
# 同一屏内部的重复（"收到"连发）保留，因为那是真实内容。
function Merge-ChatScreens {
  param(
    [Parameter(Mandatory = $true)][object[]]$Screens,
    [string]$Header = '',
    [int]$MaxLines = 150,
    [scriptblock]$Log = $null
  )
  if ($null -eq $Screens -or $Screens.Count -eq 0) { return @() }
  $NormLine = { param($s) if ($null -eq $s) { return '' } return ($s -replace '\s', '') }
  $merged = @($Screens[0])
  $seen = @{}
  foreach ($l in $merged) { $n = (& $NormLine $l); if ($n) { $seen[$n] = 1 } }
  for ($si = 1; $si -lt $Screens.Count; $si++) {
    $older = @($Screens[$si]); $newer = @($merged); $k = 0
    $maxK = [Math]::Min($older.Count, $newer.Count)
    for ($kk = $maxK; $kk -ge 1; $kk--) {
      $tail = ($older[($older.Count - $kk)..($older.Count - 1)]) -join "`n"
      $head = ($newer[0..($kk - 1)]) -join "`n"
      if ($tail -eq $head) { $k = $kk; break }
    }
    $rest = if ($k -ge $older.Count) { @() }
            elseif ($k -gt 0) { if ($older.Count - $k - 1 -ge 0) { @($older[0..($older.Count - $k - 1)]) } else { @() } }
            else { $older }
    $keep = @()
    foreach ($l in $rest) { $n = (& $NormLine $l); if ($n -and $seen.ContainsKey($n)) { continue }; $keep += $l }
    foreach ($l in $rest) { $n = (& $NormLine $l); if ($n) { $seen[$n] = 1 } }
    $merged = @($keep) + $merged
    if ($Log) { $dropCnt = [Math]::Max(0, (@($rest).Count - @($keep).Count)); & $Log ('  往期合并：第 {0} 屏 命中重叠 {1} 行、跨屏重复丢弃 {2} 行、净新增 {3} 行' -f $si, $k, $dropCnt, @($keep).Count) }
  }
  if (-not [string]::IsNullOrWhiteSpace($Header)) {
    $merged = @($merged | Where-Object { (& $NormLine $_) -ne (& $NormLine $Header) })
  }
  if ($MaxLines -gt 0 -and $merged.Count -gt $MaxLines) {
    $merged = @($merged[($merged.Count - $MaxLines)..($merged.Count - 1)])
  }
  return $merged
}

# ==================== "已经记录过的内容"锚点（2026-10-19） ====================
# 目的：翻往期时，一旦读到**上一轮已经记录过**的内容就停 —— 再往上都是记过的，
#   继续翻只会把同一批历史重新 OCR（费时、费 token，还可能让模型重复抽同一条待办）。
# 做法：记录落盘时把合并结果的"最旧 3 行"存成锚点（state\seen-anchors.txt，TSV：key<TAB>规范化行）；
#   翻页时每读一屏就比对锚点，命中即停。
# 2026-10-27 升级：锚点 = **文本 + 时间**（3 列：key<TAB>ISO时间<TAB>行）。
#   为什么：只比文本时，OCR 只要抖一两个字就永远命不中 → 白翻到硬上限 40 屏；
#   而"翻到时间 ≤ 上次锚点时间"这条判据不受 OCR 抖动影响（用户原话要求）。
#   旧文件是 2 列，读方兼容（Get-ChatAnchorRecords 里 time=$null，退化成纯文本锚点）。
function Get-ChatAnchorLines {
  # 2026-10-27：只返回"行文本"（老行为不变，所有旧调用点都不用改）。
  #   带时间的完整记录用 Get-ChatAnchorRecords（下面），这里只是它的薄包装。
  param([string]$AnchorFile, [string]$Key, [string]$Fuzzy = '', [string[]]$Whitelist = @())
  $recs = @(Get-ChatAnchorRecords -AnchorFile $AnchorFile -Key $Key -Fuzzy $Fuzzy -Whitelist $Whitelist)
  return @($recs | ForEach-Object { $_.line })
}

function Get-ChatAnchorRecords {
  <#
    .SYNOPSIS  读某个 key 的锚点记录（key + 时间 + 行文本），兼容旧的 2 列格式
    .DESCRIPTION
      seen-anchors.txt 的两种行格式：
        2 列（2026-10-19 起）：key<TAB>规范化行
        3 列（2026-10-27 起）：key<TAB>ISO时间<TAB>规范化行
      旧行没有时间 → time = $null（照样能用文本锚点，只是少了时间判据，行为与升级前一致）。
      key 匹配规则与以前完全一致：先精确命中，再按"归属标识"模糊命中（OCR 群名抖动产生的旧 key）。
      ⚠️ 不要给这个函数改名成 Get-ChatAnchorLines 的重载：PowerShell 没有函数重载，
         同名会互相覆盖（采集器里还 dot-source 了别的库）。
    .OUTPUTS  @( [pscustomobject]@{ key; time([datetime] 或 $null); line } )
  #>
  param([string]$AnchorFile, [string]$Key, [string]$Fuzzy = '', [string[]]$Whitelist = @())
  if ([string]::IsNullOrWhiteSpace($Key) -or -not (Test-Path -LiteralPath $AnchorFile)) { return @() }
  $exact = @()
  $fuzzyHit = @()
  $fz = ($Fuzzy -replace '\s', '')
  foreach ($ln in [System.IO.File]::ReadAllLines($AnchorFile, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    $parts = $ln -split "`t"
    if ($parts.Count -lt 2) { continue }
    $k = $parts[0]
    $t = $null
    if ($parts.Count -ge 3) {
      # 3 列：key<TAB>time<TAB>line（line 里理论上没有 TAB，保险起见把后面的都当 line）
      $line = ($parts[2..($parts.Count - 1)] -join "`t")
      $t = ConvertTo-ChatAnchorTimeText -Value $parts[1]
    } else {
      $line = $parts[1]
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $rec = [pscustomobject]@{ key = $k; time = $t; line = $line }
    if ($k -eq $Key) { $exact += $rec; continue }
    # 2026-10-26 兼容旧数据：以前 key 用的是**OCR 读出来的群名**，同一个群会因为 OCR 抖动
    #   散成好几个 key（实测 "示例群B（159）" / "示例群B有集团（159）" 是同一个群）。
    #   现在优先用稳定标识做 key，但旧数据不能丢 → 允许"这条旧 key 属于同一个群"时也算命中。
    if ($fz.Length -lt 2) { continue }
    $bare = $k -replace '^(qq|wx)\|', ''
    $owner = if ($Whitelist.Count -gt 0) { Get-ChatStableKey -Name $bare -Whitelist $Whitelist } else { $bare }
    # ⚠️ 必须比"归属标识"，不能只比"包含"：否则标识「示例部门」会把「示例部门小组」的锚点也捞过来，
    #   两个群的边界混在一起 → 翻页提前停或停不下来。
    if (($owner -replace '\s', '') -eq $fz) { $fuzzyHit += $rec }
  }
  # 精确命中优先：同一个群已有新格式 key 时，不要混进旧 key 的锚点（避免拿错边界）
  if ($exact.Count -gt 0) { return $exact }
  return $fuzzyHit
}

function Test-ChatAnchorHit {
  param([string[]]$Lines, [string[]]$Anchors, [int]$MinimumHits = 1)
  if ($null -eq $Anchors -or $Anchors.Count -eq 0 -or $null -eq $Lines -or $Lines.Count -eq 0) { return $false }
  $matched = @{}
  foreach ($l in $Lines) {
    $n = ($l -replace '\s', '')
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    foreach ($a in $Anchors) {
      $aa = ([string]$a -replace '\s', '')
      if ([string]::IsNullOrWhiteSpace($aa) -or $matched.ContainsKey($aa)) { continue }
      if ($n -eq $aa -or ($aa.Length -ge 8 -and $n.Length -ge 8 -and ($n.Contains($aa) -or $aa.Contains($n)))) { $matched[$aa] = $true; break }
    }
  }
  return ($matched.Count -ge [Math]::Max(1, $MinimumHits))
}

# ==================== 时间锚点（2026-10-27）====================
# 用户要求（原话）：「找聊天待办的时候需要知道执行命令的时间，并且理解上一次锚点群聊信息发送的时间，
#   在上一次锚点时间之后开始抓取，避免错过消息；可以不止用相同消息来确认，时间也要作为确认锚点的一部分；
#   如果当前界面的时间是上一次锚点的时间则不用向上翻滚。」
# 落地：
#   ① 时间分隔行 → 绝对时间（相对时间一律以**本轮执行时间**为基准，不能拿"现在"算）；
#   ② 锚点记录多一列时间（3 列），翻页时"文本命中 或 时间越过"都算到达边界；
#   ③ 当前屏最新时间 ≤ 锚点时间 → 没有新消息，一次滚轮都不发。
#
# ⚠️ 核心陷阱（真实日志）：正文里也有 HH:mm，例如 10:05 那轮出现过
#   「头部'10：10一11：50' 不在白名单」，那是公告里的**时间段**，不是时间戳。
#   所以下面所有正则都是 ^...$：只认"整行就是时间"，绝不能用"包含 \d+:\d+ 就当时间戳"。
# ⚠️ QQ 的 OCR 噪声（实测）：全角冒号「：」、冒号被读成「℃」（日志原样：「星期五23℃8」）、
#   冒号整个丢失（锚点文件里真有「昨天2333」）、分钟掉一位（「23:8」）。
#   容错这些，但保持"整行匹配"这条底线。
function ConvertTo-ChatAnchorTimeText {
  <#
    .SYNOPSIS  把锚点文件里的时间列（ISO 串 / 手写日期串 / datetime / 空）统一成 [datetime] 或 $null
  #>
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value }
  $s = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $d = [datetime]::MinValue
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  # ① 标准往返格式（我们自己写的 ToString('o')）
  if ([datetime]::TryParse($s, $inv, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d }
  # ② 手工改文件时常见的写法（2026-10-26 19:22 / 2026/10/26 19:22）
  if ([datetime]::TryParse($s, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  return $null
}

function ConvertFrom-ChatTimeText {
  <#
    .SYNOPSIS  把聊天区里的"时间分隔行"解析成绝对时间；不是时间行就返回 $null
    .DESCRIPTION
      认这些形态（**必须整行**，正文里夹着的时分一律不算）：
        昨天19:22 / 今天9:05 / 前天22:54          → 按 -Now 推相对日
        昨天2333（OCR 丢了冒号）
        10月26日19:22
        星期五23:38 / 星日07:53（OCR 把"星期"读成"星"）→ 最近的那个该星期几
        09:05（只有时分）→ 今天；比 -Now 晚 5 分钟以上算昨天
    .PARAMETER Now  本轮命令的执行时间（相对时间的基准）。**不要传 Get-Date 当"现在"去解析昨天的消息**。
    .OUTPUTS  [datetime] 或 $null
  #>
  param([string]$Text, [datetime]$Now = (Get-Date))
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  # 容错：去空白、全角冒号→半角、OCR 的 ℃→冒号；严格：下面全是 ^...$
  $t = (($Text -replace '\s', '') -replace '：', ':') -replace '℃', ':'
  if ($t.Length -lt 3 -or $t.Length -gt 24) { return $null }

  # A) 相对日 + 时:分
  $mA = [regex]::Match($t, '^(今天|昨天|前天|今|昨|前)(\d{1,2}):(\d{1,2})$')
  if ($mA.Success) {
    $hh = -1; $mi = -1
    if (-not [int]::TryParse($mA.Groups[2].Value, [ref]$hh)) { return $null }
    if (-not [int]::TryParse($mA.Groups[3].Value, [ref]$mi)) { return $null }
    if ($hh -gt 23 -or $mi -gt 59) { return $null }
    $off = if ($mA.Groups[1].Value -match '前') { -2 } elseif ($mA.Groups[1].Value -match '昨') { -1 } else { 0 }
    return $Now.Date.AddDays($off).AddHours($hh).AddMinutes($mi)
  }
  # B) 相对日 + 4 位时分（冒号被 OCR 吃掉：锚点文件里真有「昨天2333」）
  $mB = [regex]::Match($t, '^(今天|昨天|前天)(\d{1,2})(\d{2})$')
  if ($mB.Success) {
    $hh = -1; $mi = -1
    if (-not [int]::TryParse($mB.Groups[2].Value, [ref]$hh)) { return $null }
    if (-not [int]::TryParse($mB.Groups[3].Value, [ref]$mi)) { return $null }
    if ($hh -gt 23 -or $mi -gt 59) { return $null }
    $off = if ($mB.Groups[1].Value -match '前') { -2 } elseif ($mB.Groups[1].Value -match '昨') { -1 } else { 0 }
    return $Now.Date.AddDays($off).AddHours($hh).AddMinutes($mi)
  }
  # C) 月日 + 时:分（跨年时算去年）
  $mC = [regex]::Match($t, '^(\d{1,2})月(\d{1,2})日(\d{1,2}):(\d{1,2})$')
  if ($mC.Success) {
    $mo = [int]$mC.Groups[1].Value; $dd = [int]$mC.Groups[2].Value
    $hh = [int]$mC.Groups[3].Value; $mi = [int]$mC.Groups[4].Value
    if ($hh -gt 23 -or $mi -gt 59) { return $null }
    try {
      $d = New-Object datetime $Now.Year, $mo, $dd, $hh, $mi, 0
      if ($d -gt $Now.AddMinutes(5)) { $d = $d.AddYears(-1) }
      return $d
    } catch { return $null }
  }
  # D) 星期几 + 时:分（"星期"常被 OCR 读成"星"）
  $mD = [regex]::Match($t, '^(星期|周|星)([一二三四五六日天])(\d{1,2}):(\d{1,2})$')
  if ($mD.Success) {
    $hh = [int]$mD.Groups[3].Value; $mi = [int]$mD.Groups[4].Value
    if ($hh -gt 23 -or $mi -gt 59) { return $null }
    $dowMap = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '日' = 0; '天' = 0 }
    $dw = [int]$dowMap[$mD.Groups[2].Value]
    $cur = [int]$Now.DayOfWeek       # Sunday = 0
    $back = ($cur - $dw + 7) % 7
    $d = $Now.Date.AddDays(-$back).AddHours($hh).AddMinutes($mi)
    if ($d -gt $Now.AddMinutes(5)) { $d = $d.AddDays(-7) }
    return $d
  }
  # E) 只有时分（今天）—— 比现在还晚 5 分钟以上的，算昨天
  $mE = [regex]::Match($t, '^(\d{1,2}):(\d{1,2})$')
  if ($mE.Success) {
    $hh = [int]$mE.Groups[1].Value; $mi = [int]$mE.Groups[2].Value
    if ($hh -gt 23 -or $mi -gt 59) { return $null }
    $d = $Now.Date.AddHours($hh).AddMinutes($mi)
    if ($d -gt $Now.AddMinutes(5)) { $d = $d.AddDays(-1) }
    return $d
  }
  return $null
}

function Get-ChatTimesFromLines {
  <#
    .SYNOPSIS  一屏正文里所有时间戳行 → @{ times=@([datetime]…); newest; oldest; count }
    .DESCRIPTION
      Lines 可以是字符串数组，也可以是 OCR 行对象（取 .text）。QQ 的 .lines 是对象，微信的是一串字符串，
      两种都吃。`-Now` 必须是**本轮执行时间**（相对时间靠它解析）。
  #>
  param([object[]]$Lines, [datetime]$Now = (Get-Date))
  $out = New-Object System.Collections.ArrayList
  foreach ($ln in @($Lines)) {
    if ($null -eq $ln) { continue }
    $s = if ($ln -is [string]) { [string]$ln } else { [string]$ln.text }
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    $d = ConvertFrom-ChatTimeText -Text $s -Now $Now
    if ($d) { [void]$out.Add($d) }
  }
  $arr = @($out | Sort-Object)
  $newest = if ($arr.Count -gt 0) { $arr[$arr.Count - 1] } else { $null }
  $oldest = if ($arr.Count -gt 0) { $arr[0] } else { $null }
  return [pscustomobject]@{ times = $arr; newest = $newest; oldest = $oldest; count = $arr.Count }
}

function Save-ChatAnchors {
  param([string]$AnchorFile, [string]$Key, [object[]]$Lines, [int]$Take = 3, [string]$ConsolidateFuzzy = '', [string[]]$ConsolidateWhitelist = @(), [object]$Time = $null, [object[]]$Records = @())   # ⚠️ 必须是 object[]：声明成 [string[]] 时 PowerShell 会在进函数前把 OCR 行对象转成字符串
  if ([string]::IsNullOrWhiteSpace($Key)) { return }
  # 2026-10-19 修：QQ 的 .lines 是 OCR 行**对象**（@{text=…;x=…}），不是字符串 ——
  #   上一版直接把对象塞进来，锚点存成了 "@{text=26新闻郄怙;x=452;…}"，永远匹配不上。
  #   这里统一取 .text（字符串就直接用）。
  $norm = @()
  if ($Records -and $Records.Count -gt 0) {
    foreach ($rec in $Records) {
      if ($null -eq $rec -or -not $rec.PSObject.Properties['line']) { continue }
      $t = ([string]$rec.line) -replace '\s', ''
      if ([string]::IsNullOrWhiteSpace($t)) { continue }
      $rt = ConvertTo-ChatAnchorTimeText -Value $rec.time
      $norm += [pscustomobject]@{ line = $t; time = $rt }
    }
  } else {
    foreach ($v0 in @($Lines)) {
      $v = $v0
      if ($null -ne $v -and $v -isnot [string]) {
        if ($v.PSObject.Properties['text']) { $v = [string]$v.text } else { $v = [string]$v }
      }
      if ($null -eq $v) { continue }
      $t = ([string]$v) -replace '\s', ''
      if (-not [string]::IsNullOrWhiteSpace($t)) { $norm += [pscustomobject]@{ line = $t; time = (ConvertTo-ChatAnchorTimeText -Value $Time) } }
    }
  }
  if ($norm.Count -eq 0) { return }
  # Records 调用方已经排除了标题/公告元信息；旧调用保留短行锚点兼容。
  if ($Records -and $Records.Count -gt 0) {
    $norm = @($norm | Where-Object { $_.line.Length -ge 6 -and $_.line -notmatch '^(群聊成员|群成员|群公告|公告)$' })
  }
  if ($norm.Count -eq 0) { return }
  $n = [Math]::Min($Take, $norm.Count)
  $first = @($norm[0..($n - 1)])
  $keep = @()
  $fz = ($ConsolidateFuzzy -replace '\s', '')
  $dropped = 0
  if (Test-Path -LiteralPath $AnchorFile) {
    foreach ($ln in [System.IO.File]::ReadAllLines($AnchorFile, [System.Text.Encoding]::UTF8)) {
      $i = $ln.IndexOf([char]9)
      if ($i -lt 0) { continue }
      $k = $ln.Substring(0, $i)
      if ($k -eq $Key) { $dropped++; continue }
      # 2026-10-26：把同一个群的**旧格式 key**（OCR 群名抖动产生的那几个）一并清掉，
      #   否则同一个群会有 3~4 份锚点、文件越滚越大，还可能拿错边界。
      #   判定同样比"归属标识"（不能用包含，否则「示例部门」会删掉「示例部门小组」的记录）。
      if ($fz.Length -ge 2) {
        $bare = $k -replace '^(qq|wx)\|', ''
        $owner = if ($ConsolidateWhitelist.Count -gt 0) { Get-ChatStableKey -Name $bare -Whitelist $ConsolidateWhitelist } else { $bare }
        if (($owner -replace '\s', '') -eq $fz) { $dropped++; continue }
      }
      $keep += $ln
    }
  }
  # 2026-10-27：锚点 = 文本 + 时间。Records 模式按每行自身时间写，旧调用保留 -Time 行为。
  foreach ($a in $first) {
    $timeStr = ''
    $td = if ($a.PSObject.Properties['time']) { ConvertTo-ChatAnchorTimeText -Value $a.time } else { ConvertTo-ChatAnchorTimeText -Value $Time }
    if ($td) { $timeStr = $td.ToString('o') }
    if ($timeStr) { $keep += ($Key + [char]9 + $timeStr + [char]9 + $a.line) }
    else { $keep += ($Key + [char]9 + $a.line) }
  }
  $dir = Split-Path -Parent $AnchorFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllLines($AnchorFile, $keep, (New-Object System.Text.UTF8Encoding($false)))
}

# ==================== 锚点的稳定标识（2026-10-26）====================
# 为什么需要：锚点原来的 key 是"OCR 读出来的群名"，而 OCR 每轮都不一样
#   （实测同一个群散成 "示例群B（159）" / "示例群B有集团（159）" 两个 key），
#   于是下一轮拿着新群名去查、永远查不到 → 锚点形同失效、每轮都翻到底。
# 做法：优先用**白名单里命中的那个词**当标识（它在配置里是固定的，不会随 OCR 抖），
#   取"最长命中"，这样「示例部门小组」不会被更短的「示例部门」抢走。
#   一个白名单词都没命中时，退回规范化后的群名（至少比原始 OCR 稳一点）。
function Get-ChatStableKey {
  param([string]$Name, [string[]]$Whitelist = @())
  $n = if ($null -eq $Name) { '' } else { ($Name -replace '\s', '') }
  if ($n.Length -lt 2) { return '' }
  # ① 先找"直接包含"的白名单词，取最长（「示例部门小组」不会被更短的「示例部门」抢走）
  $best = ''
  foreach ($w in $Whitelist) {
    if ([string]::IsNullOrWhiteSpace($w)) { continue }
    $wn = ($w -replace '\s', '')
    if ($wn.Length -lt 2) { continue }
    if ($n.Contains($wn) -and $wn.Length -gt $best.Length) { $best = $wn }
  }
  if ($best) { return $best }
  # ② 包含不上再用容错匹配：OCR 会把「示例部门小组」读成「26统0部小组」，
  #    差一个字就退回原始群名的话，这个群的 key 又会随 OCR 抖 → 锚点照样失效。
  foreach ($w in $Whitelist) {
    if ([string]::IsNullOrWhiteSpace($w)) { continue }
    $wn = ($w -replace '\s', '')
    if ($wn.Length -lt 2) { continue }
    if ((Test-ChatNameMatch -Name $n -Pattern $wn) -and $wn.Length -gt $best.Length) { $best = $wn }
  }
  if ($best) { return $best }
  return $n
}

# ==================== 布局档案（微信 / QQ 共用，2026-10-29）====================
# 为什么要有这一层（外部 125%/150% 实测暴露的根本问题）：
#   原来所有区域边界都是"窗口宽/高的百分比"（sessionXTo=0.42、headerYTo=0.16…），
#   等于假设"UI 随窗口等比缩放"。但微信/QQ 的真实布局是
#     · 左侧会话列表 ≈ 固定像素宽（不随窗口变宽而变宽）
#     · 右侧聊天面板 = 吃掉剩下的弹性宽度
#     · 顶部标题条 ≈ 固定像素高
#   所以窗口一变宽，"列表宽 ÷ 窗口宽"就变小，0.42 那条线就切进聊天面板里 ——
#   实测：125% 时群名在 x=404、分界线 468；150% 时群名在 x=486、分界线 563，
#   分界线永远在群名右边，群名永远被切掉（于是"一个群都点不开"）。
# 这里的做法不是"再标定一次"，而是给比例加**像素上下限（按窗口 DPI 折算）**：
#   在标定过的窗口尺寸下数值完全不变（零回归），窗口异常宽/异常矮时兜住。
function Get-WxDpiFactorOf($Win) {
  if ($null -eq $Win) { return 1.0 }
  if ($Win.PSObject.Properties['dpi'] -and [int]$Win.dpi -gt 0) { return ([double]$Win.dpi / 96.0) }
  return 1.0
}

# 布局档案文件：部署时（安装器或 -Calibrate）实测一次，写成 key=value 文本。
# ⚠️ 刻意不用 JSON：本项目铁律是"JSON 只用 Node 写"，而这个文件要在 PS 安装器里生成，
#   用 key=value 就绕开了 BOM/单元素数组压平那一整类坑。
function Get-WxLayoutProfilePath { return (Join-Path $PSScriptRoot 'layout-profile.txt') }
function Get-QqLayoutProfilePath { return (Join-Path $PSScriptRoot 'layout-profile-qq.txt') }

function Read-LayoutProfileFile([string]$Path) {
  $h = @{}
  if (Test-Path -LiteralPath $Path) {
    try {
      foreach ($ln in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($ln) -or $ln -match '^\s*#') { continue }
        if ($ln -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$') { $h[$matches[1]] = $matches[2] }
      }
    } catch { $h = @{} }
  }
  return $h
}

# 档案路径可被环境变量覆盖，两个用处：
#   · 回归测试：设成 none → 完全按比例（结果与本机标定无关，fixture 才稳定）；
#   · 排障：临时指向另一份档案，对比两种布局模型。
function Resolve-LayoutProfilePath([string]$Default, [string]$EnvName) {
  $v = [Environment]::GetEnvironmentVariable($EnvName)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  if ($v -eq 'none') { return '' }
  return $v
}

function Read-WxLayoutProfile {
  if ($null -ne $script:WxLayoutProfileCache) { return $script:WxLayoutProfileCache }
  $p = Resolve-LayoutProfilePath -Default (Get-WxLayoutProfilePath) -EnvName 'WX_LAYOUT_PROFILE'
  $script:WxLayoutProfileCache = if ($p) { Read-LayoutProfileFile -Path $p } else { @{} }
  return $script:WxLayoutProfileCache
}

function Read-QqLayoutProfile {
  if ($null -ne $script:QqLayoutProfileCache) { return $script:QqLayoutProfileCache }
  $p = Resolve-LayoutProfilePath -Default (Get-QqLayoutProfilePath) -EnvName 'WX_LAYOUT_PROFILE_QQ'
  $script:QqLayoutProfileCache = if ($p) { Read-LayoutProfileFile -Path $p } else { @{} }
  return $script:QqLayoutProfileCache
}

function Get-WxLayoutProfile {
  <#
    .SYNOPSIS  把"比例"换算成"像素"，并套上按 DPI 折算的上下限
    .OUTPUTS   含 splitX / titleY / nameXMin / listCapPx / dpiFactor 等字段
  #>
  param($Win, $Cfg, [string]$ProfilePath = '')
  $f = Get-WxDpiFactorOf $Win
  $lay = $null
  if ($Cfg -and $Cfg.PSObject.Properties['layout']) { $lay = $Cfg.layout }
  $listCapPx = 420; if ($lay -and $lay.PSObject.Properties['listCapPx']) { $listCapPx = [int]$lay.listCapPx }
  $titlePx = 96; if ($lay -and $lay.PSObject.Properties['titleStripPx']) { $titlePx = [int]$lay.titleStripPx }
  $listFloorPx = 180; if ($lay -and $lay.PSObject.Properties['listFloorPx']) { $listFloorPx = [int]$lay.listFloorPx }

  $ratioSplit = [int]($Win.width * [double]$Cfg.sessionXTo)
  $split = [Math]::Min($ratioSplit, [int]($listCapPx * $f))
  $floor = [int]($listFloorPx * $f)
  if ($split -lt $floor) { $split = [Math]::Min($ratioSplit, [int]($Win.width * 0.5)) }

  # 有布局档案就用档案里的「列表宽度（96DPI 像素常数）」× 当前 DPI 系数 ——
  #   这才是符合真实布局的模型：列表宽度是固定像素，不随窗口变宽而变。
  #   实测：125% 量到 403 → 403/1.25=322；150% 量到 480 → 480/1.5=320，两个缩放互相印证。
  $prof = if ($ProfilePath) { Read-LayoutProfileFile -Path $ProfilePath } else { Read-WxLayoutProfile }
  $splitSource = 'ratio'
  if ($prof.ContainsKey('listWidthPx')) {
    $lw = 0
    if ([int]::TryParse($prof['listWidthPx'], [ref]$lw) -and $lw -gt 0) {
      $split = [int]($lw * $f)
      $splitSource = 'profile'
      if ($split -gt [int]($Win.width * 0.55)) { $split = [int]($Win.width * 0.55) }
      if ($split -lt [int]($Win.width * 0.20)) { $split = [int]($Win.width * 0.20) }
    }
  }
  if ($prof.ContainsKey('listCapPx')) { $v = 0; if ([int]::TryParse($prof['listCapPx'], [ref]$v) -and $v -gt 0) { $listCapPx = $v } }
  if ($prof.ContainsKey('titleStripPx')) { $v = 0; if ([int]::TryParse($prof['titleStripPx'], [ref]$v) -and $v -gt 0) { $titlePx = $v } }

  $ratioTitle = [int]($Win.height * [double]$Cfg.headerYTo)
  $titleY = [Math]::Max($ratioTitle, [int]($titlePx * $f))
  if ($titleY -gt [int]($Win.height * 0.5)) { $titleY = [int]($Win.height * 0.5) }

  $nameX = 0
  if ($Cfg.PSObject.Properties['nameXFrom'] -and $Cfg.nameXFrom) { $nameX = [int]($Win.width * [double]$Cfg.nameXFrom) }

  return [pscustomobject]@{
    dpiFactor   = $f
    splitX      = $split            # 会话列表 / 聊天面板 的默认分界（内容自锚定会再往前收）
    splitCap    = [int]($listCapPx * $f)
    splitSource = $splitSource      # 'profile'（已标定）或 'ratio'（还没标定过）
    titleY      = $titleY           # 标题条下沿
    nameXMin    = $nameX            # 名字列起点（比例；调用方可改用数据自校准）
    listCapPx   = $listCapPx
    titleStripPx = $titlePx
  }
}

function Get-WxNameXMinFromRows {
  <#
    .SYNOPSIS  从会话行的 x 分布推断"未读角标列 / 名字列"的分界（数据驱动）
    .DESCRIPTION
      角标（未读气泡里的 1/17/0）在名字列**左边**，判错就会把真名叫 "212" 的会话当角标丢掉。
      实测比例 0.145 在 150%（窗口 1341）算成 194，而名字列实际在 188 → 真名 212 被误删。
      这里改成找"第一处明显空隙"（角标簇与名字簇之间的空档），不再依赖窗口宽度比例。
  #>
  param([object[]]$SessionLines, [double]$WinW, $Cfg)
  $fallback = 0
  if ($Cfg -and $Cfg.PSObject.Properties['nameXFrom'] -and $Cfg.nameXFrom) { $fallback = [int]($WinW * [double]$Cfg.nameXFrom) }
  $xs = @($SessionLines | Where-Object { $_ } | ForEach-Object { [int]$_.x } | Sort-Object -Unique)
  $hi = [int]($WinW * 0.30)
  $xs = @($xs | Where-Object { $_ -ge 0 -and $_ -le $hi })
  if ($xs.Count -lt 2) { return $fallback }
  for ($i = 1; $i -lt $xs.Count; $i++) {
    if (($xs[$i] - $xs[$i - 1]) -ge 20) { return [int](($xs[$i] + $xs[$i - 1]) / 2) }
  }
  return $fallback
}

function Get-WxSplitCandidates {
  <#
    .SYNOPSIS  失败自搜索用的候选分界线（由可信到激进）
    .DESCRIPTION
      校验失败（点开读不到本意群）时，按这个顺序换分界线重试 —— 让"布局变了"能自愈，
      而不是等人来改配置。第 1 个是内容自锚定的结果，最后是比例兜底。
  #>
  param($Win, $Cfg, [int]$ContentSplit = 0)
  $out = @()
  if ($ContentSplit -gt 0) { $out += [int]$ContentSplit }
  $prof = Get-WxLayoutProfile -Win $Win -Cfg $Cfg
  foreach ($v in @($prof.splitX, [int]($prof.splitX * 0.9), [int]($prof.splitX * 0.8), [int]($prof.splitX * 1.1))) {
    if ($v -gt 0 -and $out -notcontains $v) { $out += [int]$v }
  }
  return $out
}

function Get-QqLayoutProfile {
  <#
    .SYNOPSIS  QQ 窗口的布局档案（与微信同一套思路：像素常数 × DPI 系数，比例只做兜底）
    .DESCRIPTION
      QQ 原来也是 chatXFrom=0.3 / listYFrom=0.15 这种"窗口比例"假设，同样是错的模型：
      左侧列表是近似固定像素宽，窗口一拉宽，0.3W 就切进聊天区。
      档案由 `采集器-QQ.ps1 -Calibrate` 生成；没有档案时退回比例（行为与以前完全一致）。
  #>
  param($Win, $Cfg, [string]$ProfilePath = '')
  $f = Get-WxDpiFactorOf $Win
  $prof = if ($ProfilePath) { Read-LayoutProfileFile -Path $ProfilePath } else { Read-QqLayoutProfile }
  $chatX = [int]($Win.width * [double]$Cfg.chatXFrom)
  $chatSrc = 'ratio'
  if ($prof.ContainsKey('listWidthPx')) {
    $v = 0
    if ([int]::TryParse($prof['listWidthPx'], [ref]$v) -and $v -gt 0) {
      $chatX = [int]($v * $f); $chatSrc = 'profile'
      if ($chatX -gt [int]($Win.width * 0.60)) { $chatX = [int]($Win.width * 0.60) }
      if ($chatX -lt [int]($Win.width * 0.15)) { $chatX = [int]($Win.width * 0.15) }
    }
  }
  $listY = [int]($Win.height * [double]$Cfg.listYFrom)
  if ($prof.ContainsKey('listTopPx')) {
    $v = 0
    if ([int]::TryParse($prof['listTopPx'], [ref]$v) -and $v -gt 0) { $listY = [int]($v * $f) }
  }
  $titlePx = 110
  if ($prof.ContainsKey('titleStripPx')) { $v = 0; if ([int]::TryParse($prof['titleStripPx'], [ref]$v) -and $v -gt 0) { $titlePx = $v } }
  $headerY = [Math]::Max([int]($Win.height * 0.25), [int]($titlePx * $f))
  if ($headerY -gt [int]($Win.height * 0.45)) { $headerY = [int]($Win.height * 0.45) }
  return [pscustomobject]@{
    dpiFactor = $f
    chatX     = $chatX        # 聊天区左边界（= 列表右边界）
    chatSrc   = $chatSrc
    listY     = $listY        # 会话列表上边界（跳过顶部搜索栏/标签栏）
    headerY   = $headerY      # 聊天头部（群名）纵向范围
  }
}