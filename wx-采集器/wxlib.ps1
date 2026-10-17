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
  public static IntPtr TopAt(int x, int y) {
    POINT p; p.X = x; p.Y = y;
    return GetAncestor(WindowFromPoint(p), 2);   // GA_ROOT
  }
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

# ============ 抓图（PrintWindow，含 alpha 修正与放大） ============
function Save-WxWindowShot {
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Scale = 2
  )
  $r = [WxNative]::RectOf($Hwnd)
  $w = $r[2]; $h = $r[3]
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
    left   = $r[0]
    top    = $r[1]
  }
  $out.Dispose()
  return $info
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
  foreach ($line in $result.Lines) {
    $xs = @(); $ys = @(); $hs = @(); $ws = @()
    foreach ($word in $line.Words) {
      $r = $word.BoundingRect
      $xs += [double]$r.X; $ys += [double]$r.Y; $hs += [double]$r.Height; $ws += [double]$r.Width
    }
    $rows += [pscustomobject]@{
      text = $line.Text
      # 坐标空间约定：这是**放大后图像空间**的坐标（$script:win.width 即该图宽度），调用方按此比较。
      x    = [int](($xs | Measure-Object -Minimum).Minimum)
      y    = [int](($ys | Measure-Object -Minimum).Minimum)
      h    = [int](($hs | Measure-Object -Maximum).Maximum)
      w    = [int](($ws | Measure-Object -Maximum).Maximum)
    }
  }
  return $rows
}

function Get-WxWindowInfo {
  param([IntPtr]$Hwnd = [IntPtr]::Zero)
  $hwnd = if ($Hwnd -ne [IntPtr]::Zero) { $Hwnd } else { [WxNative]::FindMain() }
  if ($hwnd -eq [IntPtr]::Zero) {
    # 兜底：窗口可能被"收进托盘"（SW_HIDE，可见=False）而不是最小化 —— 老逻辑只认可见窗口，
    # 于是直接报"找不到微信主窗口"。这里把隐藏的也找出来，交给伪最小化去抓。
    $hwnd = Find-WxWindowAny -IncludeHidden
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
  }
  $r = [WxNative]::RectOf($hwnd)
  return [pscustomobject]@{
    hwnd      = $hwnd
    left      = $r[0]
    top       = $r[1]
    width     = $r[2]
    height    = $r[3]
    minimized = [WxNative]::IsMin($hwnd)
    visible   = [WxNative]::IsWindowVisible($hwnd)
  }
}

function Invoke-WxClickAt {
  param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y)
  [WxNative]::Click($X, $Y)
}

# ==================== 误入非聊天界面的检测与返回 ====================
#
# 背景（为什么要这个）：会话列表里点某一行后，可能进的不是聊天，而是
#   微信的「群助手 / 服务通知 / 订阅号消息」这类**列表型界面**（还有可能是独立的小窗口）。
#   后果不是"少采一条"，而是**后面所有行坐标都错位、整轮白跑**。
#   ignoreChats 能在列表层挡住一部分，但 OCR 会把名字读错字（实测「班级群」→「班纟及群」），
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
  #    实测「理综6班-勇往直前（25）」是**正常群名**（括号里是群人数），
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
  $null = Set-WxForeground -Hwnd $Hwnd       # 发键/点击前必须先让微信在前台
  Start-Sleep -Milliseconds 250

  $action = if ($r.action) { [string]$r.action } else { 'backspace' }
  switch ($action) {
    'backspace' {
      [WxInput]::SendKey(0x08)              # VK_BACK
      Start-Sleep -Milliseconds 300
      [WxInput]::SendKey(0x08)
    }
    'click' {
      if (-not $r.click) { return $false }
      $info = Get-WxWindowInfo -Hwnd $Hwnd
      if (-not $info) { return $false }
      $cx = [int]($info.width * [double]$r.click.x)
      $cy = [int]($info.height * [double]$r.click.y)
      [WxNative]::Click($cx, $cy)
    }
    'clickKey' {
      if (-not $r.click) { return $false }
      $info = Get-WxWindowInfo -Hwnd $Hwnd
      if (-not $info) { return $false }
      $cx = [int]($info.width * [double]$r.click.x)
      $cy = [int]($info.height * [double]$r.click.y)
      [WxNative]::Click($cx, $cy)
      Start-Sleep -Milliseconds 350
      if ($r.key) { [WxInput]::SendKey([int]$r.key) }
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
      $pids = @(Get-Process -Name QQ -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
      foreach ($ln in @([WxNative]::ListTopWindows([UInt32[]]$pids))) {
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
  $pids = @($procs | ForEach-Object { [UInt32]$_.Id })
  $best = [IntPtr]::Zero
  $bestArea = 0
  foreach ($line in [WxNative]::ListTopWindows($pids)) {
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
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
  $old = [WxNative]::GetWindowLong($Hwnd, -20)          # GWL_EXSTYLE
  [void][WxNative]::ShowWindow($Hwnd, 4)                # SW_SHOWNOACTIVATE
  [void][WxNative]::SetWindowLong($Hwnd, -20, ($old -bor 0x00080000 -bor 0x00000020))  # LAYERED|TRANSPARENT
  [void][WxNative]::SetLayeredWindowAttributes($Hwnd, 0, 1, 0x2)                        # alpha=1/255
  return $old
}

function Exit-WxPseudoMinimize {
  <#
    .PARAMETER RestoreState  original | minimize | hide
      original = 采集前是隐藏（收托盘）就还原成隐藏、是最小化就还原成最小化（推荐）
  #>
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [int]$OldExStyle, [switch]$MinimizeAgain, [string]$RestoreState = '')
  [void][WxNative]::SetLayeredWindowAttributes($Hwnd, 0, 255, 0x2)
  [void][WxNative]::SetWindowLong($Hwnd, -20, $OldExStyle)
  $st = $RestoreState
  if (-not $st) { $st = if ($MinimizeAgain) { 'minimize' } else { 'none' } }
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
           例：规则 "26人工智能2班<示例群号>（官方）" ← 名字被读成 "26人工智能2班266"（<示例群号> → 266）
           实测命中 ✅
        ③ 滑窗编辑距离 ≤1：在名字里滑动长度为 |规则| 的窗口找最像的一段
           注意：**这一路要求"名字 ≥ 规则"长度**，名字更短时进不来。

    ⚠️ 2026-10-15 更正注释（原注释举的第二个例子是错的，实测不成立）：
      原注释写 "26人工智能2班班级群" 被读成 "26人工2册开纟及群" 也能靠 ③ 救回来 ——
      实测**匹配不上**：该残名比规则**短 1 个字符**（10 vs 11），③ 的长度门槛先挡住了；
      而且它与规则的编辑距离是 3（超出 ≤1 的容差）。这是**已知限制**，不是回归：
      旧版（1402~1620）同样匹配不上。真正需要覆盖这类残名时，应把「白名单写短一点」
      （例如写 "26人工智能" 或带数字的短形式），而不是放宽 ③ 的容差 ——
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
  #   · 那是**回归**：注释里的真实 OCR 残名 `26人工智能2班266`（规则 `…<示例群号>（官方）`）
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

# 只保留命中关键词的行（并带上上一行作为上下文，通常是发言人）
function Select-KeywordLines {
  param($Lines, [string[]]$Keywords)
  $out = @()
  $sorted = @($Lines | Sort-Object y)
  for ($i = 0; $i -lt $sorted.Count; $i++) {
    if (Test-ChatKeyword $sorted[$i].t $Keywords) {
      if ($i -gt 0) { $out += $sorted[$i - 1] }
      $out += $sorted[$i]
    }
  }
  return $out
}








