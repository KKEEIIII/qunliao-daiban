# 遮挡测试.ps1（v3）—— 验证"微信窗口被盖住时，PrintWindow 还能不能抓到内容"
# 做法：自己弹一个**置顶的纯色窗体**精确盖住微信窗口 → 用 WindowFromPoint 确认真的盖住了 → 再 PrintWindow 抓微信
# 只读：不点击、不发消息；窗体测完立即关闭
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'wxlib.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('Find2' -as [type])) {
  Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class Find2 {
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  public struct POINT { public int X; public int Y; }
  public static IntPtr TopAt(int x, int y) { POINT p; p.X = x; p.Y = y; return GetAncestor(WindowFromPoint(p), 2); }
}
"@
}

function Get-Stats([string]$path) {
  $bmp = [System.Drawing.Bitmap]::FromFile($path)
  $colors = New-Object 'System.Collections.Generic.HashSet[int]'
  $nonBlack = 0; $total = 0
  for ($y = 0; $y -lt $bmp.Height; $y += 5) {
    for ($x = 0; $x -lt $bmp.Width; $x += 5) {
      $p = $bmp.GetPixel($x, $y); $total++
      [void]$colors.Add($p.ToArgb())
      if ($p.R -gt 12 -or $p.G -gt 12 -or $p.B -gt 12) { $nonBlack++ }
    }
  }
  $bmp.Dispose()
  return [pscustomobject]@{ colors = $colors.Count; nonBlackRatio = [math]::Round($nonBlack / $total, 4) }
}

function Compare-Shots([string]$a, [string]$b) {
  $ba = [System.Drawing.Bitmap]::FromFile($a); $bb = [System.Drawing.Bitmap]::FromFile($b)
  $diff = 0; $total = 0
  for ($y = 0; $y -lt $ba.Height; $y += 4) {
    for ($x = 0; $x -lt $ba.Width; $x += 4) {
      $pa = $ba.GetPixel($x, $y); $pb = $bb.GetPixel($x, $y); $total++
      if ([Math]::Abs($pa.R - $pb.R) -gt 20 -or [Math]::Abs($pa.G - $pb.G) -gt 20 -or [Math]::Abs($pa.B - $pb.B) -gt 20) { $diff++ }
    }
  }
  $ba.Dispose(); $bb.Dispose()
  return [math]::Round($diff / $total, 4)
}

$info = Get-WxWindowInfo
if ($null -eq $info) { throw '找不到微信主窗口' }
Write-Host ("微信窗口 {0}x{1} @ ({2},{3})" -f $info.width, $info.height, $info.left, $info.top)

# [1] 微信在前台时抓基准图
[void](Set-WxForeground -Hwnd $info.hwnd)
Start-Sleep -Milliseconds 500
$frontShot = Join-Path $root 'shots\occlusion-front.png'
$null = Save-WxWindowShot -Hwnd $info.hwnd -Path $frontShot -Scale 1
$s1 = Get-Stats $frontShot
Write-Host ("[1] 微信在前台：颜色 {0}，非黑占比 {1}" -f $s1.colors, $s1.nonBlackRatio)

# [2] 弹一个置顶纯色窗体，精确盖住微信窗口
$cover = New-Object System.Windows.Forms.Form
$cover.FormBorderStyle = 'None'
$cover.ShowInTaskbar = $false
$cover.TopMost = $true
$cover.StartPosition = 'Manual'
$cover.Location = New-Object System.Drawing.Point($info.left, $info.top)
$cover.Size = New-Object System.Drawing.Size($info.width, $info.height)
$cover.BackColor = [System.Drawing.Color]::FromArgb(255, 0, 255)
$cover.Show()
for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
Start-Sleep -Milliseconds 400

$cx = $info.left + [int]($info.width / 2)
$cy = $info.top + [int]($info.height / 2)
$topAt = [Find2]::TopAt($cx, $cy)
$covered = ($topAt -ne $info.hwnd)
Write-Host ("[2] 置顶覆盖窗体已显示；微信中心点({0},{1}) 最顶层窗口 hwnd=0x{2}" -f $cx, $cy, $topAt.ToInt64().ToString('X'))
Write-Host ("    微信是否被真正盖住：{0}（微信 hwnd=0x{1}）" -f $covered, $info.hwnd.ToInt64().ToString('X'))

# [3] 盖住状态下抓微信 + 全屏佐证
$coveredShot = Join-Path $root 'shots\occlusion-covered.png'
$null = Save-WxWindowShot -Hwnd $info.hwnd -Path $coveredShot -Scale 1
$s2 = Get-Stats $coveredShot
Write-Host ("[3] 被盖住时抓图：颜色 {0}，非黑占比 {1}" -f $s2.colors, $s2.nonBlackRatio)

$b = New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($b); $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
$fullShot = Join-Path $root 'shots\occlusion-desktop.png'
$b.Save($fullShot); $g.Dispose(); $b.Dispose()
Write-Host ("    全屏佐证图（应看到紫色块盖住微信）：{0}" -f $fullShot)

# [4] 关闭覆盖窗体并比对
$cover.Close(); $cover.Dispose()
Start-Sleep -Milliseconds 300
$diffRatio = Compare-Shots $frontShot $coveredShot
Write-Host ("[4] 盖住前/后抓到的微信图差异像素占比 = {0}" -f $diffRatio)

Write-Host ''
if (-not $covered) {
  Write-Host '结论：⚠️ 仍没能盖住微信，本测试无效'
} elseif ($s2.nonBlackRatio -gt 0.5 -and $s2.colors -gt 50 -and $diffRatio -lt 0.5) {
  Write-Host '结论：✅ PrintWindow 在被遮挡时仍能抓到微信窗口内容 → 采图不需要微信在前台'
} else {
  Write-Host '结论：❌ 被遮挡时抓到的是黑图/占位图 → 读图前必须让微信窗口可见'
}

