# 开机自启DSH.ps1 —— 让 DSH 开机自动启动并**最小化**（无感：不抢焦点、不弹窗）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\开机自启DSH.ps1 -Status     # 看现在开没开
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\开机自启DSH.ps1 -Enable     # 打开
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\开机自启DSH.ps1 -Disable    # 关掉
#   （也支持 -Enable -StartNow：立刻按同样方式启动一次，便于当场验证）
#
# 实现：注册一个**登录时触发**的计划任务（任务名 DSH-开机自启），动作 = run-hidden.vbs 拉起本脚本
# 的 -StartMinimized 分支：启动 DSH → 等主窗口出现（最多 90 秒）→ ShowWindow(SW_MINIMIZE) 最小化。
# 为什么不用注册表 Run：Run 项只能启动、没法在启动后最小化；而计划任务能做"启动 + 收窗"两步。
#
# 无感程度（页面里也照这个说，别夸大）：
#   · 登录后 DSH 在**后台最小化**启动，不抢焦点、不弹任何窗口
#   · 任务栏上会有一个 DSH 图标（收不掉的，那需要改 DSH 自己的启动参数）
#   · 采集/抽取/提醒/自检照常在后台跑，和手动打开完全一样
#   · 想彻底不留痕：-Disable 关掉即可，只删这一条任务，不动 DSH 本身
param(
  [switch]$Enable,
  [switch]$Disable,
  [switch]$Status,
  [switch]$StartNow,
  [switch]$StartMinimized,   # 内部用：任务动作调这个分支
  [switch]$Force,   # 允许从临时目录注册（默认拒绝，见 -Enable 里的护栏）
  [string]$ExePath = ''
)

$ErrorActionPreference = 'Continue'
$taskName = 'DSH-开机自启'
$ws = Split-Path -Parent $PSScriptRoot
$vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir '开机自启.log'

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
  Write-Host $line
}

# 找 DSH 主程序：① 显式传入 ② 正在运行的进程路径（最可靠）③ 常见安装位置
# 取一个 exe 的"版本键"：优先 FileVersion 的数字部分，否则按文件时间
function Get-DshExeKey([string]$path) {
  $i = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
  if (-not $i) { return $null }
  $vt = [string]$i.VersionInfo.FileVersion
  $m = [regex]::Match($vt, '\d+(\.\d+){1,3}')
  $ver = if ($m.Success) { [version]$m.Value } else { [version]'0.0.0' }
  return [pscustomobject]@{ path = $path; ver = $ver; verText = $vt; time = $i.LastWriteTime }
}

# 找 DSH 主程序。**返回版本最高的那个**（2026-10-23 改）
# 为什么改：本机实测同时存在两份安装
#   · <DSH安装目录>\DeepSeek Harness.exe        0.2.0-rc.2（9/29，旧）
#   · E:\DEEPSSEEK HARDNESS\DeepSeek Harness.exe       0.2.1-rc.2（10/17，新）
# 原来的实现"取第一个存在的"→ 常常选中旧版；而开机时启动文件夹里那个指向旧版的 .lnk
# 会先把旧版拉起来，本脚本看到"进程同名已在运行"就不再启动 → 用户永远用老版本。
function Find-DshExe {
  if ($ExePath -and (Test-Path -LiteralPath $ExePath)) { return $ExePath }
  $cands = New-Object System.Collections.Generic.List[string]
  foreach ($p in @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
    if ($p.Path -and ($p.Path -notmatch 'app.asar')) { $cands.Add($p.Path) }
  }
  $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'))
  $cands.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'))
  if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe')) }
  foreach ($root in @('D:\', 'E:\', 'C:\')) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
      $cands.Add((Join-Path $d.FullName 'DeepSeek Harness.exe'))
    }
  }
  $best = $null
  foreach ($c in $cands) {
    if (-not ($c -and (Test-Path -LiteralPath $c -PathType Leaf))) { continue }
    $k = Get-DshExeKey $c
    if (-not $k) { continue }
    if (-not $best) { $best = $k; continue }
    if (($k.ver -gt $best.ver) -or (($k.ver -eq $best.ver) -and ($k.time -gt $best.time))) { $best = $k }
  }
  if ($best) { return $best.path }
  return $null
}

# ---------- 内部：启动并最小化 ----------
if ($StartMinimized) {
  # 2026-10-23 加：自愈 —— 每次开机启动时核对"计划任务指向的脚本是不是当前这份"。
  # 指向别处（临时目录/旧副本）或引用文件已不存在 → 立刻改回当前版本，避免开机一直拉老版本。
  try {
    $curTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($curTask) {
      $arg = [string](($curTask.Actions | Select-Object -First 1).Arguments)
      $pointsHere = $arg -and $arg.Contains($PSCommandPath)
      $vbsOk = $true
      $m = [regex]::Match($arg, '"([^"]+\.vbs)"')
      if ($m.Success) { $vbsOk = Test-Path -LiteralPath $m.Groups[1].Value }
      if ((-not $pointsHere) -or (-not $vbsOk)) {
        Log ('[自启] 计划任务指向别处或已失效：' + $arg)
        Log ('[自启] → 自动改回当前版本：' + $PSCommandPath)
        $a2 = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}" "{1}" -StartMinimized' -f $vbs, $PSCommandPath)
        $t2 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $s2 = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $a2 -Trigger $t2 -Settings $s2 -Description '登录时自动启动 DSH 并最小化（由群聊待办控制台设置）' -Force -ErrorAction Stop | Out-Null
        Log '[自启] 已修正'
      } else {
        Log ('[自启] 计划任务指向正确：' + $PSCommandPath)
      }
    }
  } catch { Log ('[自启] 任务自愈失败：' + $_.Exception.Message) }
  $exe = Find-DshExe
  if (-not $exe) { Log '[自启] ❌ 找不到 DSH 主程序，放弃'; exit 1 }
  # 2026-10-23 加：核对"正在运行的 DSH 是不是最新版"。
  # 旧逻辑是"进程同名就算已就绪 → 不启动"：启动文件夹那个指向旧版的快捷方式先把 0.2.0 拉起来，
  # 本脚本就永远不启动 0.2.1 → 用户感觉"开机自启永远是老版本"。
  try {
    $newestPath = Find-DshExe
    $runProcs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    if ($runProcs.Count -gt 0 -and $newestPath) {
      $runPath = $runProcs[0].Path
      $runVer = [string](Get-Item -LiteralPath $runPath -ErrorAction SilentlyContinue).VersionInfo.FileVersion
      $newVer = [string](Get-Item -LiteralPath $newestPath -ErrorAction SilentlyContinue).VersionInfo.FileVersion
      Log ('[自启] 正在运行：' + $runPath + '（' + $runVer + '）')
      Log ('[自启] 磁盘最新：' + $newestPath + '（' + $newVer + '）')
      if ($runPath -ne $newestPath) {
        Log '[自启] ⚠️ 正在运行的不是最新版（旧版可能来自启动文件夹的快捷方式）→ 请修正该快捷方式，或在控制台关掉旧版自启'
      }
    }
  } catch { }
  $running = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) { Log ("[自启] DSH 已在运行（{0} 个进程），不重复启动" -f $running.Count); exit 0 }
  Log ("[自启] 启动：{0}" -f $exe)
  Start-Process -FilePath $exe
  # 等主窗口出现再最小化（Electron 冷启动可能要十几秒）
  Add-Type -Namespace Win32 -Name Show -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    $w = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($w) {
      Start-Sleep -Seconds 2          # 再等两秒，确保窗口画完再收
      [void][Win32.Show]::ShowWindow($w.MainWindowHandle, 6)   # 6 = SW_MINIMIZE
      Log ("[自启] 已最小化（PID {0}，等待 {1} 秒）" -f $w.Id, $i)
      exit 0
    }
  }
  Log '[自启] ⚠️ 等了 90 秒没等到主窗口（可能启动失败或被杀软拦），已放弃最小化'
  exit 0
}

# ---------- -Status ----------
# 两种机制都要看：① 计划任务（登录时触发）② HKCU\...\Run 项（任务被权限拒绝时的兜底）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'DSH-AutoStart'
function Get-RunEntry {
  try { return (Get-ItemProperty -Path $runKey -Name $runName -ErrorAction Stop).$runName } catch { return '' }
}
function Get-AutostartState {
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $run = Get-RunEntry
  if ($t -and $t.State -ne 'Disabled') { return @{ enabled = $true; mech = '计划任务（登录时触发）'; run = $run } }
  if ($run) { return @{ enabled = $true; mech = 'HKCU Run 项（登录时启动）'; run = $run } }
  return @{ enabled = $false; mech = '未启用'; run = '' }
}

if ($Status -or ((-not $Enable) -and (-not $Disable))) {
  $st = Get-AutostartState
  $exe = Find-DshExe
  Write-Host '=== DSH 开机自启状态 ==='
  Write-Host ("  已启用     : {0}" -f $(if ($st.enabled) { '是' } else { '否' }))
  Write-Host ("  机制       : {0}" -f $st.mech)
  if ($st.run) { Write-Host ("  Run 项     : {0}" -f $st.run) }
  Write-Host ("  DSH 主程序 : {0}" -f $(if ($exe) { $exe } else { '未找到（装好后重试）' }))
  # 2026-10-23 加：打印任务实际指向的脚本 —— "开机打开老版本"从这里看出来
  $tt = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($tt) {
    $targ = [string](($tt.Actions | Select-Object -First 1).Arguments)
    $here = $targ.Contains($PSCommandPath)
    $m2 = [regex]::Match($targ, '"([^"]+\.vbs)"')
    $vOk = if ($m2.Success) { Test-Path -LiteralPath $m2.Groups[1].Value } else { $false }
    Write-Host ('  任务指向   : {0}' -f $targ)
    Write-Host ('  指向本机版 : {0}{1}' -f $(if ($here) { '是' } else { '否 —— 开机启动的会是别处的旧版本！跑一次 -Enable 修正' }), $(if ($vOk) { '' } else { '（且引用的 vbs 已不存在）' }))
  }
  Write-Host '  无感程度   : 登录后后台最小化启动，不抢焦点不弹窗；任务栏会有一个 DSH 图标；采集/提醒照常跑'
  exit 0
}

# ---------- -Enable ----------
if ($Enable) {
  # 2026-10-23 加：不要从 %TEMP% 的临时解压副本里注册开机自启。
  # 实测事故：在 %TEMP%\verify-out-1029-... 里跑过一次 -Enable，任务被写死到临时目录；
  # 目录删掉后开机启动静默失败（任务结果=1），用户看到的却是"开机打开的还是老版本"。
  if ($PSScriptRoot -like (Join-Path $env:TEMP '*') -and -not $Force) {
    Write-Host ('X 当前运行位置是临时目录：' + $PSScriptRoot)
    Write-Host '  从这里注册开机自启会把任务写死到临时目录（重启后目录可能已被清理）→ 已拒绝。'
    Write-Host '  请在正式安装目录里运行；确实要这么做请加 -Force。'
    exit 1
  }
  $exe = Find-DshExe
  if (-not $exe) { Write-Host '❌ 找不到 DSH 主程序，无法设置（先启动一次 DSH 再试）'; exit 1 }
  if (-not (Test-Path -LiteralPath $vbs)) { Write-Host ("❌ 缺少 {0}" -f $vbs); exit 1 }
  $mech = ''
  # ① 首选计划任务：能做"启动 + 收窗"两步，且不污染 Run 项
  try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}" "{1}" -StartMinimized' -f $vbs, $PSCommandPath)
    # ⚠️ 触发器要显式带 -User：不带时注册 AtLogOn 任务会 Access denied（0x80070005，本机实测）
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description '登录时自动启动 DSH 并最小化（由群聊待办控制台设置）' -Force -ErrorAction Stop | Out-Null
    $mech = '计划任务（登录时触发）'
  } catch {
    Log ('[自启] 计划任务注册失败（' + $_.Exception.Message + '）→ 改用 HKCU Run 项兜底')
  }
  # ② 兜底：HKCU\...\Run（普通用户可写，不需要管理员）
  if (-not $mech) {
    try {
      $cmd = 'wscript.exe "{0}" "{1}" -StartMinimized' -f $vbs, $PSCommandPath
      New-Item -Path $runKey -Force | Out-Null
      Set-ItemProperty -Path $runKey -Name $runName -Value $cmd -ErrorAction Stop
      $mech = 'HKCU Run 项（登录时启动）'
    } catch {
      Write-Host ('❌ 两种方式都失败了：' + $_.Exception.Message)
      Log ('[自启] Run 项也写入失败：' + $_.Exception.Message)
      exit 1
    }
  }
  Log ("[自启] 已启用（{0}）：{1} → 登录后启动并最小化" -f $mech, $exe)
  Write-Host ("✅ 已开启（{0}）：下次登录 Windows 时，DSH 会自动在后台最小化启动" -f $mech)

  # 2026-10-23 加：顺手把"启动文件夹里的 DSH 快捷方式"也指向最新版。
  # 本机实测它就是"开机拉起旧版"的真正原因（两套入口并存时，快捷方式抢先启动旧版，
  # 我们的任务随后看到进程同名就不再启动 → 新版永远起不来）。
  try {
    $lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\DeepSeek Harness.lnk'
    if (Test-Path -LiteralPath $lnkPath) {
      $sh = New-Object -ComObject WScript.Shell
      $sc = $sh.CreateShortcut($lnkPath)
      if ($sc.TargetPath -and ($sc.TargetPath -ne $exe)) {
        $oldT = $sc.TargetPath
        $sc.TargetPath = $exe
        $sc.WorkingDirectory = Split-Path -Parent $exe
        $sc.Save()
        Log ('[自启] 已把启动文件夹快捷方式改指向最新版：' + $oldT + ' → ' + $exe)
      }
    }
  } catch { Log ('[自启] 修正启动快捷方式失败：' + $_.Exception.Message) }
  Write-Host ("   主程序：{0}" -f $exe)
  if ($StartNow) {
    Write-Host '   -StartNow：现在按同样方式启动一次（若 DSH 已在运行会跳过）……'
    & $PSCommandPath -StartMinimized
  }
  exit 0
}

# ---------- -Disable ----------
if ($Disable) {
  $did = @()
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($t) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue; $did += '计划任务'; Log ("[自启] 已删除计划任务 {0}" -f $taskName) }
  if (Get-RunEntry) { Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue; $did += 'HKCU Run 项'; Log '[自启] 已删除 HKCU Run 项' }
  if ($did.Count -gt 0) { Write-Host ('✅ 已关闭开机自启（清掉了：' + ($did -join '、') + '；DSH 本身没动）') }
  else { Write-Host '本来就没开' }
  exit 0
}
