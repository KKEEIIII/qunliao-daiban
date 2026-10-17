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
function Find-DshExe {
  if ($ExePath -and (Test-Path -LiteralPath $ExePath)) { return $ExePath }
  $p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -notmatch 'app.asar' } | Select-Object -First 1
  if ($p -and $p.Path) { return $p.Path }
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe')
  )
  # 再扫一遍常见根目录（有人装在 D:\ / E:\ 自定义目录）
  foreach ($root in @('D:\', 'E:\', 'C:\')) {
    if (Test-Path -LiteralPath $root) {
      $cands += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'DeepSeek Harness.exe' })
    }
  }
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
  return $null
}

# ---------- 内部：启动并最小化 ----------
if ($StartMinimized) {
  $exe = Find-DshExe
  if (-not $exe) { Log '[自启] ❌ 找不到 DSH 主程序，放弃'; exit 1 }
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
  Write-Host '  无感程度   : 登录后后台最小化启动，不抢焦点不弹窗；任务栏会有一个 DSH 图标；采集/提醒照常跑'
  exit 0
}

# ---------- -Enable ----------
if ($Enable) {
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
