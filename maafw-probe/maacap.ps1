# maacap.ps1 —— MaaFramework 封装：后台截图（FramePool/PrintWindow）+ 后台点击（多种输入法）
#
# 用法：
#   . "$PSScriptRoot\maacap.ps1"
#   Initialize-Maa
#   $ctrl = Get-MaaController -Hwnd $h -InputMethod 1024     # 建/取缓存控制器（省掉每次连接开销）
#   Get-MaaShot -Hwnd $h -Path x.png -Controller $ctrl
#   Invoke-MaaClick -Hwnd $h -X 10 -Y 20 -Controller $ctrl
#
# 输入法（MaaWin32InputMethod，只能单选一个）：
#   1=Seize  2=SendMessage  4=PostMessage  8=LegacyEvent  16=PostThreadMessage(弃用)
#   32=SendMessageWithCursorPos  64=PostMessageWithCursorPos
#   128=SendMessageWithWindowPos  256=PostMessageWithWindowPos
#   512=Interception(需驱动)  1024=AnchoredTouch ★QQ 实测可用
$script:MaaBin = Join-Path $PSScriptRoot 'maa\bin'
$script:MaaControllers = @{}      # "hwnd|inputMethod" → IntPtr（复用，避免每次重连）

function Initialize-Maa {
  if ($script:MaaReady) { return $true }
  if (-not (Test-Path -LiteralPath $script:MaaBin)) { return $false }
  if (-not ('MaaApi' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MaaApi {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern bool SetDllDirectory(string p);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr MaaWin32ControllerCreate(IntPtr hWnd, ulong screencap, ulong mouse, ulong keyboard);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void MaaControllerDestroy(IntPtr c);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern long MaaControllerPostConnection(IntPtr c);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern long MaaControllerPostScreencap(IntPtr c);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern long MaaControllerPostClick(IntPtr c, int x, int y);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern long MaaControllerPostScroll(IntPtr c, int dx, int dy);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int MaaControllerWait(IntPtr c, long id);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr MaaImageBufferCreate();
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern void MaaImageBufferDestroy(IntPtr b);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern byte MaaControllerCachedImage(IntPtr c, IntPtr buf);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr MaaImageBufferGetEncoded(IntPtr b);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern ulong MaaImageBufferGetEncodedSize(IntPtr b);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int MaaImageBufferWidth(IntPtr b);
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern int MaaImageBufferHeight(IntPtr b);
  // 2026-10-26 加：截图尺寸配置（MaaFramework 官方 API，见 docs/zh_cn/2.2-集成接口一览.md 的 MaaControllerSetOption）
  //   key=1 ScreenshotTargetLongSide（int32）｜key=2 ScreenshotTargetShortSide（int32）
  //   key=3 ScreenshotUseRawSize（**1 字节 bool**）｜key=6 ScreenshotResizeMethod（int32）
  //   实测：不设置时抓图被缩到 968x720；设 key=3 → 抓图 1267x942（窗口原始分辨率）
  [DllImport("MaaFramework.dll", CallingConvention=CallingConvention.Cdecl)] public static extern byte MaaControllerSetOption(IntPtr ctrl, int key, IntPtr value, ulong valSize);
  public static byte[] Png(IntPtr b) {
    IntPtr p = MaaImageBufferGetEncoded(b);
    ulong n = MaaImageBufferGetEncodedSize(b);
    if (p == IntPtr.Zero || n == 0) return new byte[0];
    byte[] o = new byte[n]; Marshal.Copy(p, o, 0, (int)n); return o; }
}
"@
  }
  try {
    [void][MaaApi]::SetDllDirectory($script:MaaBin)
    # ⚠️ 2026-10-15 深夜修（外部复测 2136 版抓的）：原来只查目录存在就 return $true，**从不真正加载 DLL**。
    #   结果"文件在但加载不了"（最常见：机器缺 VC++ 2015-2022 运行库）时，第一次 P/Invoke 在调用链深处抛
    #   DllNotFoundException → 采集器-QQ 直接崩、不写状态、自检绿灯。现在用 MaaImageBufferCreate 强制触发
    #   加载并立刻销毁 —— 加载不了就在**这里**返回 false，调用方走"回退屏幕模式"，不再炸在半路。
    $probe = [MaaApi]::MaaImageBufferCreate()
    if ($probe -ne [IntPtr]::Zero) { [MaaApi]::MaaImageBufferDestroy($probe) }
  } catch {
    $script:MaaLoadError = $_.Exception.Message
    return $false
  }
  $script:MaaReady = $true
  return $true
}

# 建一个控制器（截图法：Background = FramePool|PrintWindow = 0x12）
function New-MaaController {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [uint64]$Screencap = 0x12, [uint64]$InputMethod = 4)
  if (-not (Initialize-Maa)) { return [IntPtr]::Zero }
  # 兜底一层 try/catch：即使上面 Initialize-Maa 过了，真建控制器仍可能因别的依赖抛异常，
  # 一律返回 Zero（调用方都按 Zero 处理回退），绝不让原生异常穿透到采集器顶层。
  try {
    return [MaaApi]::MaaWin32ControllerCreate($Hwnd, $Screencap, $InputMethod, $InputMethod)
  } catch {
    $script:MaaLoadError = $_.Exception.Message
    return [IntPtr]::Zero
  }
}

# 取（或建）一个已连接、可复用的控制器；同一脚本里只连接一次
function Get-MaaController {
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
    [uint64]$Screencap = 0x12,
    [uint64]$InputMethod = 4,
    [switch]$Force
  )
  if (-not (Initialize-Maa)) { return [IntPtr]::Zero }
  $key = ('{0}|{1}|{2}' -f [int64]$Hwnd, $Screencap, $InputMethod)
  if (-not $Force -and $script:MaaControllers.ContainsKey($key)) { return $script:MaaControllers[$key] }
  $ctrl = New-MaaController -Hwnd $Hwnd -Screencap $Screencap -InputMethod $InputMethod
  if ($ctrl -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
  $id = [MaaApi]::MaaControllerPostConnection($ctrl)
  if ([MaaApi]::MaaControllerWait($ctrl, $id) -ne 3000) {
    [MaaApi]::MaaControllerDestroy($ctrl)
    return [IntPtr]::Zero
  }
  $script:MaaControllers[$key] = $ctrl
  return $ctrl
}

function Close-MaaControllers {
  foreach ($k in @($script:MaaControllers.Keys)) {
    try { [MaaApi]::MaaControllerDestroy($script:MaaControllers[$k]) } catch {}
  }
  $script:MaaControllers = @{}
}

function Set-MaaShotOption {
  <#
    .SYNOPSIS  设置控制器截图选项（MaaControllerSetOption 封装）
    .DESCRIPTION
      2026-10-26 加。为什么需要：Maa 默认把抓图缩到 968x720（窗口 1267x942 时压掉 24%），
      文字变小 → Windows OCR 漏行/串行（实测"第 一次 月 视频"整行读不出来）。
      官方 API 支持关掉缩放：
        Key=1 ScreenshotTargetLongSide  (int32) 长边缩到指定长度
        Key=2 ScreenshotTargetShortSide (int32) 短边缩到指定长度
        Key=3 ScreenshotUseRawSize      (**1 字节 bool**) 截图不缩放 → 原始分辨率
        Key=6 ScreenshotResizeMethod    (int32) 插值方法 0..4，默认 3=INTER_AREA
      实测 Key=3 传 1 字节 true → 抓图 1267x942（原始分辨率），后台截图能力不变。
    .PARAMETER AsBool  该选项要 1 字节 bool（Key=3、Key=4 这类），否则按 int32 传
  #>
  param(
    [Parameter(Mandatory = $true)][IntPtr]$Controller,
    [Parameter(Mandatory = $true)][int]$Key,
    [int]$IntValue = 0,
    [switch]$AsBool
  )
  if (-not (Initialize-Maa)) { return $false }
  if ($Controller -eq [IntPtr]::Zero) { return $false }
  $mem = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
  try {
    if ($AsBool) {
      $b = if ($IntValue -ne 0) { [byte]1 } else { [byte]0 }
      [System.Runtime.InteropServices.Marshal]::WriteByte($mem, $b)
      return ([MaaApi]::MaaControllerSetOption($Controller, $Key, $mem, [uint64]1) -ne 0)
    }
    [System.Runtime.InteropServices.Marshal]::WriteInt32($mem, $IntValue)
    return ([MaaApi]::MaaControllerSetOption($Controller, $Key, $mem, [uint64]4) -ne 0)
  } catch {
    return $false
  } finally {
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($mem)
  }
}

# 后台截图 → 存 PNG，返回 @{ok; w; h; bytes}
function Get-MaaShot {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [Parameter(Mandatory = $true)][string]$Path,
    [uint64]$Screencap = 0x12, [IntPtr]$Controller = [IntPtr]::Zero, [switch]$Reuse)
  $own = $false
  $ctrl = $Controller
  if ($ctrl -eq [IntPtr]::Zero) {
    if ($Reuse) {
      $ctrl = Get-MaaController -Hwnd $Hwnd -Screencap $Screencap
      if ($ctrl -eq [IntPtr]::Zero) { return [pscustomobject]@{ ok = $false; w = 0; h = 0; bytes = 0 } }
    } else {
      $ctrl = New-MaaController -Hwnd $Hwnd -Screencap $Screencap
      if ($ctrl -eq [IntPtr]::Zero) { return [pscustomobject]@{ ok = $false; w = 0; h = 0; bytes = 0 } }
      $own = $true
      $id = [MaaApi]::MaaControllerPostConnection($ctrl)
      if ([MaaApi]::MaaControllerWait($ctrl, $id) -ne 3000) {
        [MaaApi]::MaaControllerDestroy($ctrl)
        return [pscustomobject]@{ ok = $false; w = 0; h = 0; bytes = 0 }
      }
    }
  }
  $id = [MaaApi]::MaaControllerPostScreencap($ctrl)
  $st = [MaaApi]::MaaControllerWait($ctrl, $id)
  $buf = [MaaApi]::MaaImageBufferCreate()
  $ok = [MaaApi]::MaaControllerCachedImage($ctrl, $buf)
  $w = [MaaApi]::MaaImageBufferWidth($buf)
  $h = [MaaApi]::MaaImageBufferHeight($buf)
  $bytes = [MaaApi]::Png($buf)
  if ($bytes.Length -gt 0) { [System.IO.File]::WriteAllBytes($Path, $bytes) }
  [MaaApi]::MaaImageBufferDestroy($buf)
  if ($own) { [MaaApi]::MaaControllerDestroy($ctrl) }
  return [pscustomobject]@{ ok = ($ok -eq 1 -and $st -eq 3000 -and $bytes.Length -gt 0); w = $w; h = $h; bytes = $bytes.Length }
}

# 后台点击（坐标 = 抓图空间像素；QQ 实测 1:1，Maa 内部会按 DPI 比例换算到屏幕）
function Invoke-MaaClick {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y,
    [uint64]$InputMethod = 4, [IntPtr]$Controller = [IntPtr]::Zero, [switch]$Reuse)
  $own = $false
  $ctrl = $Controller
  if ($ctrl -eq [IntPtr]::Zero) {
    if ($Reuse) {
      $ctrl = Get-MaaController -Hwnd $Hwnd -InputMethod $InputMethod
      if ($ctrl -eq [IntPtr]::Zero) { return $false }
    } else {
      $ctrl = New-MaaController -Hwnd $Hwnd -InputMethod $InputMethod
      if ($ctrl -eq [IntPtr]::Zero) { return $false }
      $own = $true
      $id = [MaaApi]::MaaControllerPostConnection($ctrl)
      if ([MaaApi]::MaaControllerWait($ctrl, $id) -ne 3000) { [MaaApi]::MaaControllerDestroy($ctrl); return $false }
    }
  }
  $id = [MaaApi]::MaaControllerPostClick($ctrl, $X, $Y)
  $st = [MaaApi]::MaaControllerWait($ctrl, $id)
  if ($own) { [MaaApi]::MaaControllerDestroy($ctrl) }
  return ($st -eq 3000)
}

# 后台滚轮（dx/dy 为滚动量；QQ 会话列表用 dy 正/负来上下翻）
function Invoke-MaaScroll {
  param([Parameter(Mandatory = $true)][IntPtr]$Hwnd, [int]$Dx = 0, [int]$Dy = 0,
    [uint64]$InputMethod = 1024, [IntPtr]$Controller = [IntPtr]::Zero)
  $ctrl = $Controller
  if ($ctrl -eq [IntPtr]::Zero) {
    $ctrl = Get-MaaController -Hwnd $Hwnd -InputMethod $InputMethod
    if ($ctrl -eq [IntPtr]::Zero) { return $false }
  }
  $id = [MaaApi]::MaaControllerPostScroll($ctrl, $Dx, $Dy)
  $st = [MaaApi]::MaaControllerWait($ctrl, $id)
  return ($st -eq 3000)
}
# ============ 真实滚轮（Maa 的 PostScroll 对 QQ 无效，只能用真滚轮）============
# 实测（2026-10-14）：MaaControllerPostScroll 用 2/4/32/64/128/256 六种输入法**全部返回 True 但 QQ 列表纹丝不动**；
# 而真实滚轮事件（mouse_event / SendInput 的 MOUSEEVENTF_WHEEL）能可靠滚动。
# 注意：P/Invoke 里 dwData 必须是**有符号 int**（正=向上，负=向下），声明成 uint 就没法传负数。
if (-not ('WxWheel' -as [type])) {
  Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class WxWheel {
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int data, UIntPtr extra);
  public static void Turn(int delta, int times) {
    for (int i = 0; i < times; i++) { mouse_event(0x0800, 0, 0, delta, UIntPtr.Zero); System.Threading.Thread.Sleep(90); }
  }
}
"@
}