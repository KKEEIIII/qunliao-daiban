# 安装.ps1 —— 群聊待办：一键部署
#
# 干这些事（每一步都会打印，出错会停下来告诉你）：
#   ① 检查环境（PowerShell 版本 / DSH 在哪 / 微信、QQ 装了没 / 中文 OCR）
#   ② 拷文件到你指定的目录
#   ③ 生成配置（只需要你回答几个问题：企业微信 webhook、你的微信昵称、要盯的群）
#   ④ 把插件挂进 DSH（profile 的 package.json + node_modules junction）
#   ⑤ 生成配置（占位符替换，不需要 Node.js）
#   ⑥ 挂进 DSH（插件）  ⑦ 创建 5 个计划任务  ⑧ 注册通知身份(AUMID)  ⑨ 自检  ⑩ 规则填路径 + 打开控制台
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\安装.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\安装.ps1 -DryRun     # 只看会做什么，不真改
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\安装.ps1 -Yes        # 全部用默认值（无人值守）
param(
  [switch]$DryRun,
  [switch]$SkipAumid,     # 跳过 AUMID 注册
  [switch]$SkipTasks,     # 跳过第⑦步（建计划任务）—— 自测/演示用，避免覆盖本机正在跑的任务
  [switch]$SkipMaa,       # 跳过 MaaFramework 自动下载（79MB）—— 自测用；不装只是 QQ 退回屏幕模式
  [switch]$SkipProfile,   # 跳过第⑥步（改 profile package.json + junction）—— 打包自测用：自测环境无权写 DSH profile，且验证目标是包内容而非本机 profile
  [switch]$SkipConsole,   # 跳过第⑩步（生成并打开控制台页）—— 自测/无人值守环境用，避免自测时弹浏览器
  [switch]$Yes,
  [string]$InstallDir = '',
  [string]$DshDir = '',
  [string]$ProfileName = 'desktop',
  [string]$WecomWebhook = '',
  [string]$MyAliases = '',
  [string]$QqGroups = '',
  [string]$WxGroups = ''
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot          # 部署包解压出来的目录（就是本脚本所在目录）

function Say([string]$m) { Write-Host $m }
function Head([string]$m) { Write-Host ''; Write-Host ("=== " + $m + " ===") -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host ("  [OK] " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("  [!]  " + $m) -ForegroundColor Yellow }
function Die([string]$m) { Write-Host ("  [X]  " + $m) -ForegroundColor Red; exit 1 }

Say '群聊待办 · 一键部署'
Say ("部署包目录: {0}" -f $src)
if ($DryRun) { Write-Host ''; Warn '这是 -DryRun：只打印计划，不会真的改任何东西' }

# ---------------- ① 环境检查 ----------------
Head '① 环境检查'
if ($PSVersionTable.PSVersion.Major -lt 5) { Die '需要 PowerShell 5.1 或更高（Windows 10/11 自带）' }
Ok ("PowerShell {0}" -f $PSVersionTable.PSVersion)

# DSH（自动探测）
$dshCandidates = @()
if ($DshDir) { $dshCandidates += $DshDir }
$dshCandidates += @(
  (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
  (Join-Path $env:ProgramFiles 'DeepSeek Harness')
)
# 只对**确实存在的盘根**做 Join-Path：盘符不存在时 Join-Path 抛 DriveNotFoundException，
# 而本脚本开头是 $ErrorActionPreference='Stop' → 别人没 E 盘就会当场死在第①步（实测复现）
foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
  if (-not $drv.Root) { continue }
  # 说明：DEEPSSEEKHARDNESS 是**作者机器上的**DSH 目录名（作者把它装在这个文件夹里）。
# 你自己的 DSH 大概率是 'DeepSeek Harness' 或 'DSH'，下面几个候选都会试；
# 都不中就加 -DshDir "你的DSH目录" 参数。
    foreach ($nm in @('DEEPSSEEKHARDNESS', 'DeepSeek Harness', 'DSH Desktop', 'DSH')) { try { $dshCandidates += (Join-Path $drv.Root $nm) } catch { } }
}
$dshFound = ''
foreach ($c in $dshCandidates) { if (-not $c) { continue }; foreach ($en in @('DeepSeek Harness.exe', 'DSH Desktop.exe', 'dsh.exe')) { try { if (Test-Path -LiteralPath (Join-Path $c $en)) { $dshFound = $c; break } } catch { } }; if ($dshFound) { break } }
if (-not $dshFound) {
  # 退一步：从开始菜单快捷方式找
  $sm = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' -and $_.Name -match 'DeepSeek|DSH' } -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($sm) {
    $sh0 = New-Object -ComObject WScript.Shell
    $t = $sh0.CreateShortcut($sm.FullName).TargetPath
    if ($t) { $dshFound = Split-Path -Parent $t }
  }
}
if ($dshFound) { Ok ("DSH 安装目录: {0}" -f $dshFound) } else { Warn '没找到 DSH —— 插件那一步会跳过，装好 DSH 后重跑本脚本即可（其他步骤照常）' }

# 微信 / QQ（各家装的位置不同，这里只探测常见位置 + 运行中进程）
$wxExe = ''
foreach ($p in @("$env:ProgramFiles\Tencent\Weixin\Weixin.exe", "$env:LOCALAPPDATA\Tencent\Weixin\Weixin.exe")) {
  if (Test-Path -LiteralPath $p) { $wxExe = $p; break }
}
if (-not $wxExe) { $p = Get-Process -Name Weixin -ErrorAction SilentlyContinue | Select-Object -First 1; if ($p) { $wxExe = $p.Path } }
if ($wxExe) { Ok ("微信: {0}" -f $wxExe) } else { Warn '没找到微信客户端 —— 微信采集需要它（可以后装）' }

$qqExe = ''
foreach ($p in @("$env:ProgramFiles\Tencent\QQNT\QQ.exe", "$env:ProgramFiles\Tencent\QQ\Bin\QQ.exe")) {
  if (Test-Path -LiteralPath $p) { $qqExe = $p; break }
}
if (-not $qqExe) { $p = Get-Process -Name QQ -ErrorAction SilentlyContinue | Select-Object -First 1; if ($p) { $qqExe = $p.Path } }
if ($qqExe) { Ok ("QQ: {0}" -f $qqExe) } else { Warn '没找到 QQ 客户端 —— QQ 采集需要它（可以后装）' }

# 中文 OCR（Windows.Media.Ocr 的中文识别器）
$ocrOk = $false
try {
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $langs = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
  $ocrOk = @($langs | Where-Object { $_.LanguageTag -like 'zh*' }).Count -gt 0
  if ($ocrOk) { Ok ("Windows OCR 中文可用（{0} 种语言）" -f @($langs).Count) } else { Warn 'Windows OCR 缺少中文识别器：设置 → 时间和语言 → 语言 → 添加"中文(简体)"并安装语言包' }
} catch { Warn '无法调用 Windows OCR（需要 Win10/11；缺中文语言包时截图识别会失败）' }

# ---------------- ② 规划路径 ----------------
Head '② 安装位置'
# 参数里显式给过目录就不再问（无人值守 `-Yes -InstallDir X` 的语义）
$installDirGiven = [bool]$InstallDir
if (-not $InstallDir) {
  $InstallDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) '群聊待办'
}
# ⚠️ 2026-10-15 修两个坑（另一台机器无人值守实测暴露）：
#   ① `-Yes` 本意是"全部用默认值（无人值守）"，但提问块只判断了 `-not $Yes`，
#      参数没给全时它**照样提问**；在重定向/无人值守环境下 Read-Host 返回 $null →
#      `$ans.Trim()` 抛 "You cannot call a method on a null-valued expression"，脚本当场退出码 1。
#   ② 即使参数已经给了，也会再多问一遍 —— 现在改成"**参数没给 && 不是 -Yes && 不是 -DryRun** 才问"，
#      并且所有 Read-Host 结果都做 null 安全处理。
function Read-HostSafe([string]$prompt) {
  $a = Read-Host $prompt
  if ($null -eq $a) { return '' }
  return ([string]$a).Trim()
}
if (-not $Yes -and -not $DryRun -and -not $installDirGiven) {
  $ans = Read-HostSafe ("  安装到哪个目录？[回车用默认: {0}]" -f $InstallDir)
  if ($ans) { $InstallDir = $ans }
}
Ok ("安装目录: {0}" -f $InstallDir)
if ($DryRun) { Say '  （DryRun：下面都只是计划）' }

# ---------------- ③ 问几个必须由你提供的值 ----------------
Head '③ 配置（直接回车=用默认/以后再说）'
if (-not $Yes -and -not $DryRun) {
  if (-not $WecomWebhook) {
    Say '  企业微信机器人 webhook（手机提醒用）：企业微信 → 建个只有自己的群 → 右上角 → 群机器人 → 添加 → 复制地址'
    $WecomWebhook = Read-HostSafe '  粘 webhook（可留空，之后再填）'
  }
  if (-not $MyAliases) {
    Say '  你的微信昵称（用来识别 @我，多个用逗号分隔）'
    $MyAliases = Read-HostSafe '  例如: 张三,小张'
  }
  if (-not $WxGroups) {
    Say '  要盯的微信群名（原样写，多个用逗号分隔；留空=所有会话都看）'
    $WxGroups = Read-HostSafe '  例如: 班级群A'
  }
  if (-not $QqGroups) {
    Say '  要盯的 QQ 群名（原样写，多个用逗号分隔；留空=不采 QQ）'
    $QqGroups = Read-HostSafe '  例如: 2026级计算机2班（官方）123456,校学生会通知群'
  }
}
if ($WecomWebhook) { Ok '企业微信 webhook 已提供' } else { Warn '没填 webhook → 手机不会收到提醒（之后可改 提醒配置.json）' }
if ($MyAliases) { Ok ("微信昵称: {0}" -f $MyAliases) } else { Warn '没填微信昵称 → 微信侧只会按"群规则"采，不会识别 @我' }
if ($QqGroups) { Ok ("QQ 群: {0}" -f $QqGroups) } else { Warn '没填 QQ 群 → QQ 采集会跑但读不到白名单群' }

# ---------------- ④ 拷文件 ----------------
Head '④ 拷贝文件'
$cfgNames = @('wx-采集器\config.json', 'wx-采集器\config-qq.json', 'dsh-接入\提醒配置.json', 'dsh-msg-memo\config.json')
$cfgBackup = Join-Path $env:TEMP ('dsh-cfg-bak-' + (Get-Date -Format 'HHmmss'))
$kept = 0
if (-not $DryRun) {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  foreach ($n in $cfgNames) {
    $p = Join-Path $InstallDir $n
    if (Test-Path -LiteralPath $p) {
      New-Item -ItemType Directory -Force -Path (Join-Path $cfgBackup (Split-Path -Parent $n)) | Out-Null
      Copy-Item -LiteralPath $p -Destination (Join-Path $cfgBackup $n) -Force
      $kept++
    }
  }
  if ($kept -gt 0) { Ok ('检测到已有 ' + $kept + ' 个配置文件 → 重装会保留你的设置') }
}
# 存量检测（2026-10-18，外部复测 P1-1）：
#   已经装了旧版的机器上，dsh-msg-memo 的清单可能带 BOM → 下次重启 DSH 会**静默跳过整个插件**。
if (Test-Path -LiteralPath $InstallDir) {
  $staleBom = @()
  foreach ($n in @('dsh-msg-memo\package.json', 'dsh-msg-memo\cordis.patch.yml', 'dsh-msg-memo\config.json')) {
    $p0 = Join-Path $InstallDir $n
    if (-not (Test-Path -LiteralPath $p0)) { continue }
    $b0 = [System.IO.File]::ReadAllBytes($p0)
    if ($b0.Length -ge 3 -and $b0[0] -eq 0xEF -and $b0[1] -eq 0xBB -and $b0[2] -eq 0xBF) { $staleBom += $n }
  }
  if ($staleBom.Count -gt 0) {
    Warn ('检测到旧安装的插件清单带 BOM（DSH 会静默跳过整个插件）：' + ($staleBom -join '、'))
    Say '  → 本次安装会覆盖/修复成无 BOM 版本；装完请**重启 DSH 一次**，插件才会真正装载'
  }
}
# 版本提示（2026-10-18）：明确告诉用户"这次是升级到最新版"还是"已是最新"
$pkgVer = ''
$pkgVerFile = Join-Path $src '版本.txt'
if (Test-Path -LiteralPath $pkgVerFile) {
  $mpv = [regex]::Match([System.IO.File]::ReadAllText($pkgVerFile, [System.Text.Encoding]::UTF8), '(?m)^版本\s*:\s*(\S+)')
  if ($mpv.Success) { $pkgVer = $mpv.Groups[1].Value.Trim() }
}
$oldVer = ''
$oldVerFile = Join-Path $InstallDir '版本.txt'
if (Test-Path -LiteralPath $oldVerFile) {
  $mov = [regex]::Match([System.IO.File]::ReadAllText($oldVerFile, [System.Text.Encoding]::UTF8), '(?m)^版本\s*:\s*(\S+)')
  if ($mov.Success) { $oldVer = $mov.Groups[1].Value.Trim() }
}
if ($pkgVer -and $oldVer -and $oldVer -ne $pkgVer) {
  Warn ('检测到已安装 ' + $oldVer + '，本次升级到最新版 ' + $pkgVer)
} elseif ($pkgVer -and $oldVer -eq $pkgVer) {
  Ok ('本机已是这一版（' + $pkgVer + '）—— 重装会保留你的配置')
}
$subs = @('dsh-接入', 'wx-采集器', 'maafw-probe', 'dsh-msg-memo', '群聊待办')
foreach ($d in $subs) {
  $from = Join-Path $src $d
  if (-not (Test-Path -LiteralPath $from)) { Warn ("包里没有 {0}，跳过" -f $d); continue }
  if ($DryRun) { Say ("  将拷贝 {0} → {1}" -f $from, (Join-Path $InstallDir $d)); continue }
  Copy-Item -LiteralPath $from -Destination $InstallDir -Recurse -Force
  Ok ("{0} → {1}" -f $d, $InstallDir)
}
# 装完立刻在**文件层面**修一次清单 BOM（2026-10-18，外部复测 P1-1）
# 第⑥步在 -SkipProfile 时被跳过，但"清单带 BOM"必须在这里治掉。
if (-not $DryRun) {
  $fixedBom = 0
  foreach ($n in @('dsh-msg-memo\package.json', 'dsh-msg-memo\cordis.patch.yml', 'dsh-msg-memo\config.json')) {
    $p1 = Join-Path $InstallDir $n
    if (-not (Test-Path -LiteralPath $p1)) { continue }
    $b1 = [System.IO.File]::ReadAllBytes($p1)
    if ($b1.Length -ge 3 -and $b1[0] -eq 0xEF -and $b1[1] -eq 0xBB -and $b1[2] -eq 0xBF) {
      if ($b1.Length -gt 3) { [System.IO.File]::WriteAllBytes($p1, $b1[3..($b1.Length - 1)]) }
      else { [System.IO.File]::WriteAllBytes($p1, (New-Object byte[] 0)) }
      $fixedBom++
    }
  }
  if ($fixedBom -gt 0) { Ok ('已修复旧清单 BOM：' + $fixedBom + ' 个（重启 DSH 后插件才会真正装载）') }
  else { Ok '插件清单无 BOM（不会被 DSH 静默跳过）' }
  try {
    $null = [System.IO.File]::ReadAllText((Join-Path $InstallDir 'dsh-msg-memo\package.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Ok '插件清单可解析（裸 JSON.parse 不会报错）'
  } catch { Warn ('插件清单解析失败：' + $_.Exception.Message) }
}

# ⚠️ 2026-10-15 修：`群聊待办\`（看板三个文件）原来不在 $subs 里 → 装完是个空目录、看板功能不存在，
#    而 版本.txt 还把"新增 HTML 看板"列为这一版重点。
# 另外：根目录下的零散文件（install/uninstall、几个说明文档、版本.txt）也要拷，
# 否则用户装完在安装目录里找不到说明书（另一台机器实测：包内 34 个文件，安装目录只有 28 个）。
if (-not $DryRun) {
  foreach ($f in @('安装.ps1', '卸载.ps1', '快速开始.md', '使用手册.md', '版本.txt', '遗留问题与修复清单.md', '任务链.md', '运维手册-持续稳定.md', '手机通知转发-配置指南.md', '项目交接.md', '借鉴与致谢.md')) {
    $from = Join-Path $src $f
    if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $InstallDir -Force }
  }
  # run-hidden.vbs 是 5 个计划任务的入口，**必须**进安装目录，否则任务全部指向不存在的文件而静默失败
  $vbsFrom = Join-Path $src 'dsh-接入\run-hidden.vbs'
  $vbsTo = Join-Path $InstallDir 'dsh-接入\run-hidden.vbs'
  if (Test-Path -LiteralPath $vbsFrom) {
    Copy-Item -LiteralPath $vbsFrom -Destination $vbsTo -Force
    Ok 'run-hidden.vbs → dsh-接入\（计划任务入口）'
  } else {
    Warn '包里没有 dsh-接入\run-hidden.vbs —— 计划任务会起不来（见 遗留问题与修复清单.md）'
  }
} else {
  Say '  将拷贝根目录的 安装/卸载 脚本与说明文档、以及 dsh-接入\run-hidden.vbs'
}
if (-not $DryRun) {
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'wx-采集器\spool') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'wx-采集器\logs') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'wx-采集器\state') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'wx-采集器\shots') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'dsh-接入\logs') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir '群聊待办') | Out-Null
  # 全新安装时先建好空的 todos.json：插件第一轮也会写，但"看板"要能立刻打开，
  # 没有它会报"找不到 todos.json"（装包自测第一版就是这么抓到的）。
  $todosNew = Join-Path $InstallDir '群聊待办\todos.json'
  if (-not (Test-Path -LiteralPath $todosNew)) {
    [System.IO.File]::WriteAllText($todosNew, ('{"items":[],"updatedAt":"' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') + '"}'), (New-Object System.Text.UTF8Encoding($false)))
    Ok '初始化 群聊待办\todos.json（空清单）'
  }
}
# MaaFramework（QQ 后台采集需要）：**新包已内置** maafw-probe\maa\bin\（约 89MB，随包解压即用）。
# 老包没有 → 才走下面的 GitHub 自动下载兜底。
$maaDll = Join-Path $InstallDir 'maafw-probe\maa\bin\MaaFramework.dll'
if ($SkipMaa) {
  Warn '-SkipMaa：跳过 MaaFramework 检查/下载（QQ 采集会退回屏幕模式，需要 QQ 窗口在前台）'
} elseif (-not $DryRun) {
  if (Test-Path -LiteralPath $maaDll) {
    Ok 'MaaFramework 已随包内置（QQ 后台采集可用，无需联网下载）'
  } elseif (-not (Test-Path -LiteralPath $maaDll)) {
    Warn 'MaaFramework 没装 → 正在尝试自动下载（79MB，从 GitHub 官方 release 取最新版）…'
    $maaRoot = Join-Path $InstallDir 'maafw-probe\maa'
    try {
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/MaaXYZ/MaaFramework/releases/latest' -TimeoutSec 30 -Headers @{ 'User-Agent' = 'dsh-msg-memo-installer' }
      $asset = $rel.assets | Where-Object { $_.name -match 'win-x86_64.*\.zip$' } | Select-Object -First 1
      if (-not $asset) { throw 'release 里没找到 win-x86_64 的 zip' }
      Say ("  下载 {0}（{1} MB）…" -f $asset.name, [math]::Round($asset.size / 1MB, 1))
      $tmpZip = Join-Path $env:TEMP $asset.name
      # ⚠️ 2026-10-15 改（另一台机器实测：卡在 70.5MB 且 14 分钟不再增长，控制台全程没有输出，
      #    用户无法判断是在下载还是已经死了；下载完也没校验完整性就解压）：
      #    · 换成 WebClient 分块下载 + 每 2 秒报一次进度（能看出"还在动"还是"卡住了"）
      #    · 卡住超过 60 秒没有任何新字节 → 主动放弃（而不是无限等）
      #    · 下完校验大小（不少于 release 声明大小的 95%）
      $expected = [long]$asset.size
      $dl = New-Object System.Net.WebClient
      $dl.Proxy = $null
      $dl.Headers.Add('User-Agent', 'dsh-msg-memo-installer')
      $fs = [System.IO.File]::Create($tmpZip)
      $stream = $dl.OpenRead($asset.browser_download_url)
      try {
        $buf = New-Object byte[] 1048576
        $got = [long]0
        $lastReport = Get-Date
        $lastBytes = [long]0
        $lastChange = Get-Date
        while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
          $fs.Write($buf, 0, $read)
          $got += $read
          if ($got -gt $lastBytes) { $lastBytes = $got; $lastChange = Get-Date }
          if (((Get-Date) - $lastReport).TotalSeconds -ge 2) {
            $pct = if ($expected -gt 0) { [int]($got * 100 / $expected) } else { 0 }
            Write-Host ("`r    {0} / {1} MB（{2}%）   " -f [math]::Round($got / 1MB, 1), [math]::Round($expected / 1MB, 1), $pct) -NoNewline
            $lastReport = Get-Date
          }
          if (((Get-Date) - $lastChange).TotalSeconds -gt 60) { throw ("下载卡住了（60 秒没有新数据，停在 {0} MB）" -f [math]::Round($got / 1MB, 1)) }
        }
        Write-Host ''
      } finally {
        $stream.Close(); $fs.Close(); $dl.Dispose()
      }
      if ($expected -gt 0 -and (Get-Item -LiteralPath $tmpZip).Length -lt ($expected * 0.95)) {
        throw ("下载不完整：拿到 {0} MB，release 声明 {1} MB" -f [math]::Round((Get-Item -LiteralPath $tmpZip).Length / 1MB, 1), [math]::Round($expected / 1MB, 1))
      }
      Ok ("下载完成（{0} MB）" -f [math]::Round((Get-Item -LiteralPath $tmpZip).Length / 1MB, 1))
      $tmpDir = Join-Path $env:TEMP ('maa-unzip-' + (Get-Date -Format 'HHmmss'))
      Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
      # 找到含 bin\MaaFramework.dll 的那层，把内容搬进 maafw-probe\maa\
      $dll = Get-ChildItem -LiteralPath $tmpDir -Recurse -Filter 'MaaFramework.dll' | Select-Object -First 1
      if (-not $dll) { throw '解压后没找到 MaaFramework.dll' }
      $srcRoot = Split-Path -Parent (Split-Path -Parent $dll.FullName)   # …\bin\MaaFramework.dll → 上两级
      New-Item -ItemType Directory -Force -Path $maaRoot | Out-Null
      Copy-Item -Path (Join-Path $srcRoot '*') -Destination $maaRoot -Recurse -Force
      Remove-Item -LiteralPath $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath (Join-Path $maaRoot 'bin\MaaFramework.dll')) { Ok 'MaaFramework 下载并安装完成（QQ 后台采集可用）' }
      else { throw '搬运后仍找不到 bin\MaaFramework.dll' }
    } catch {
      Warn ('MaaFramework 自动下载失败：' + $_.Exception.Message)
      Warn '不影响使用：QQ 采集会退回"屏幕模式"（需要 QQ 窗口在前台）。想要后台采集可手动下载 github.com/MaaXYZ/MaaFramework/releases 的 MAA-win-x86_64-*.zip，解压到 maafw-probe\maa\'
    }
  }
  if (Test-Path -LiteralPath $maaDll) { Ok 'MaaFramework 已就位（QQ 后台采集可用）' }
  else { Warn 'MaaFramework 没装 → QQ 采集会退回"屏幕模式"（需要 QQ 窗口在前台，能用但会抢焦点）。想要后台采集：另外拿 maa-win.zip 解压到 maafw-probe\maa\' }
}

# VC++ 2015-2022 运行库检查（MaaFramework 是 C++ 原生库：缺运行库 → DLL 加载失败 → QQ 后台采集不可用。
# 外部复测 2136 版在一台没装 VC++ 的机器上实测撞到：DLL 在、加载崩。
# ⚠️ 2026-10-16 收紧（同一份复测报告 §5.2）：只查 vcruntime140 **不够** —— 实测依赖至少 5 个文件，
#   其中 msvcp140_atomic_wait.dll 只有**较新**的 redist 才有（装过老版 2015-2019 的机器会缺它，
#   而 MaaFramework 的 webgpu_dawn_maa.dll 需要它）。现在两个关键文件都在才算通过；
#   提示语也直接说"装最新版"，不去逐个列举文件名。）
if ((-not $DryRun) -and (Test-Path -LiteralPath $maaDll)) {
  $sys32 = Join-Path $env:SystemRoot 'System32'
  $vcHits = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_atomic_wait.dll') |
    Where-Object { Test-Path (Join-Path $sys32 $_) }
  if ($vcHits.Count -eq 4) { Say '  ✓ VC++ 2015-2022 运行库齐全（MaaFramework 的依赖，检查通过）' }
  else {
    Warn ("检测到 VC++ 2015-2022 运行库**不齐**（System32 里只找到 {0}/4 个关键 DLL）→ MaaFramework 会加载失败，QQ 采集将退回屏幕模式" -f $vcHits.Count)
    Warn '  修复：装**最新版**微软官方运行库 https://aka.ms/vs/17/release/vc_redist.x64.exe（装完重跑一次 QQ 采集即可）'
    Warn '  注意：装过很老的 2015-2019 版也可能缺文件（尤其是 msvcp140_atomic_wait.dll）—— 直接覆盖装最新版最省事'
  }
}

# ---------------- ⑤ 生成配置 ----------------
# 重装保护：把刚才备份的"你原来的配置"还原回来，覆盖掉模板（第⑤步只改你这次明确填的项）
if ((-not $DryRun) -and (Test-Path -LiteralPath $cfgBackup)) {
  foreach ($n in $cfgNames) {
    $b = Join-Path $cfgBackup $n
    if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination (Join-Path $InstallDir $n) -Force }
  }
  Remove-Item -LiteralPath $cfgBackup -Recurse -Force -ErrorAction SilentlyContinue
  Ok '已还原你原来的配置（本次只覆盖你这次明确填写的项）'
}

Head '⑤ 写配置'
if ($DryRun) { Say '  将按 JSON 键写入: wx-采集器\config.json、config-qq.json、dsh-接入\提醒配置.json、dsh-msg-memo\config.json' }
else {
  # 写配置 = **按 JSON 键改写**，故意不依赖 node.exe（DSH 自带的 node 各家路径不同、别人机器上常常没有）：
  #   ConvertFrom-Json → 改属性 → 转回文本写盘。
  #
  # ⚠️ 2026-10-15 大改（另一台机器实测暴露）：原来这里做的是**占位符文本替换**，而打包器
  #    把配置清成了**空值**（`[]` / `""`），根本没有占位符 → 整段替换落空 →
  #    `workspaceDir` 永远是空串 → 插件把 `群聊待办\` 写到 **DSH 进程的工作目录**去（真机复现过：
  #    日志出现在 DSH 安装目录下）。而且如果模板真是 `"__KEY__"` 形状，替换值自己又裹了一层引号，
  #    会写出 `""https://...""` 这种非法 JSON。
  #    → 改成按键改写后，**空值模板 / 占位符模板 / 已有真实值的模板，三种都能正确吃下**。
  # 另外：不整份 ConvertTo-Json 重写（PS 5.1 会把中文转成 \uXXXX 转义），只替换命中的那一小段文本。
  function ConvertTo-JsonArrayText([string]$csv) {
    $items = @($csv -split '[,，;；]' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($items.Count -eq 0) { return '[]' }
    return '[' + (($items | ForEach-Object { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' }) -join ', ') + ']'
  }
  function ConvertTo-JsonStringText([string]$s) { return '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

  # 按 JSON 路径改写一个键；返回 $true/$false（键不存在→false），并在写盘前校验 JSON 可解析。
  #
  # ⚠️ 2026-10-15 第二次修（另一个 AI 复测抓到我新引入的 bug，**每次安装必现**）：
  #    我上一版想用 `[regex]::Replace($txt, $re, $evaluator, 1)` 表达"只替换第 1 处"，
  #    但 **[regex]::Replace 根本没有 4 参的 count 重载** —— 唯一的 4 参重载第 3 参是 MatchEvaluator、
  #    第 4 参是 **RegexOptions**。于是那个字面量 `1` 被当成 `IgnoreCase`，**count 被静默忽略 → 替换全部**。
  #    后果：`提醒配置.json` 里 `"webhook"` 出现两次（wecom + dingtalk），结果**企业微信的 webhook
  #    被写进了钉钉字段** → 每次推送都多打一次钉钉格式的请求（必然失败、日志永远多一条噪音）。
  #    修法（报告推荐的 B 方案）：**让 $path 真正起作用** —— 先用括号配对圈出父键的作用域，
  #    只在作用域内替换；并用 `[regex]::new()` 的**实例方法** Replace(…, count)（这个重载是存在的）。
  function Get-JsonScope([string]$s, [string]$parentKey) {
    $m = [regex]::Match($s, '"' + [regex]::Escape($parentKey) + '"\s*:\s*\{')
    if (-not $m.Success) { return $null }
    $open = $s.IndexOf('{', $m.Index)
    $depth = 0
    for ($i = $open; $i -lt $s.Length; $i++) {
      if ($s[$i] -eq '{') { $depth++ }
      elseif ($s[$i] -eq '}') { $depth--; if ($depth -eq 0) { return @{ start = $open; end = $i } } }
    }
    return $null
  }
  function Set-CfgValue([string]$file, [string[]]$path, [string]$jsonValueText, [string]$label) {
    $full = Join-Path $InstallDir $file
    if (-not (Test-Path -LiteralPath $full)) { Warn ("没找到 {0}，跳过" -f $file); return $false }
    $txt = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", ''
    try { $null = $txt | ConvertFrom-Json } catch { Die ("{0} 不是合法 JSON：{1}" -f $file, $_.Exception.Message) }

    $leaf = $path[$path.Count - 1]
    $re = '(?s)("' + [regex]::Escape($leaf) + '"\s*:\s*)(' + '\[[^\[\]]*\]|"[^"]*"|[^,}\s]+)'
    $rx = [regex]::new($re)
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $jsonValueText }

    # 有父键就只在父键作用域内替换（这样"同名键"永远不会串）
    $parent = if ($path.Count -ge 2) { $path[$path.Count - 2] } else { '' }
    $scope = if ($parent) { Get-JsonScope $txt $parent } else { $null }
    if ($parent -and -not $scope) {
      Warn ("{0} 里找不到父键 {1}（模板可能被改过），跳过 {2}" -f $file, $parent, $leaf)
      return $false
    }
    if ($scope) {
      $target = $txt.Substring($scope.start, $scope.end - $scope.start + 1)
    } else {
      $target = $txt
    }
    if (-not $rx.IsMatch($target)) {
      Warn ("{0} 里找不到键 {1}（模板可能被改过），跳过" -f $file, $leaf)
      return $false
    }
    # 作用域内理论上只剩一处；仍然只替换第 1 处（实例方法的重载才有 count）
    $newTarget = $rx.Replace($target, $ev, 1)
    $out = if ($scope) { $txt.Substring(0, $scope.start) + $newTarget + $txt.Substring($scope.end + 1) } else { $newTarget }

    try { $null = $out | ConvertFrom-Json } catch { Die ("改写 {0}.{1} 后 JSON 非法：{2}" -f $file, $leaf, $_.Exception.Message) }
    # 写盘前确认"这次改的到底是哪一处"：把改后的 JSON 解析出来核对路径上的值
    try {
      $chk = $out | ConvertFrom-Json
      $cur = $chk
      foreach ($seg in $path) { $cur = $cur.$seg }
      $want = ($jsonValueText.Trim('"'))
      if ($jsonValueText.StartsWith('[')) {
        # 数组：比对元素
        $got = (@($cur) | ForEach-Object { [string]$_ }) -join ','
        $exp = (@($jsonValueText.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"') }) | Where-Object { $_ }) -join ','
        if ($got -ne $exp) { Die ("{0}: 写入后核对失败（{1} 期望 [{2}] 实际 [{3}]）" -f $file, ($path -join '.'), $exp, $got) }
      } elseif ([string]$cur -ne $want) {
        Die ("{0}: 写入后核对失败（{1} 期望 '{2}' 实际 '{3}'）" -f $file, ($path -join '.'), $want, $cur)
      }
    } catch {
      if ($_.Exception.Message -like '*核对失败*') { throw }
    }
    [System.IO.File]::WriteAllText($full, $out, (New-Object System.Text.UTF8Encoding($false)))
    Ok ('写入 ' + $file + ' → ' + $label + ' = ' + $jsonValueText)
    return $true
  }

  $wsDir = $InstallDir.Replace('\', '/')
  # 必须写进去的（写不进去就是坏的，直接报错）
  if (-not (Set-CfgValue 'dsh-msg-memo\config.json' @('workspaceDir') (ConvertTo-JsonStringText $wsDir) '工作区目录')) {
    Die 'dsh-msg-memo\config.json 的 workspaceDir 写不进去 —— 不修好插件会把待办写到别的地方去'
  }
  if ($MyAliases) {
    $aliasesText = ConvertTo-JsonArrayText $MyAliases
    # ⚠️ myAliases 有**两份**（采集器 + 插件），插件两处都会读，必须都写，否则"点名我"判断不一致
    $null = Set-CfgValue 'wx-采集器\config.json' @('myAliases') $aliasesText '微信昵称（采集器）'
    $null = Set-CfgValue 'dsh-msg-memo\config.json' @('myAliases') $aliasesText '微信昵称（插件）'
  }
  if ($WxGroups) { $null = Set-CfgValue 'wx-采集器\config.json' @('groupWhitelist') (ConvertTo-JsonArrayText $WxGroups) '微信群白名单' }
  if ($QqGroups) { $null = Set-CfgValue 'wx-采集器\config-qq.json' @('groupWhitelist') (ConvertTo-JsonArrayText $QqGroups) 'QQ群白名单' }
  if ($WecomWebhook) { $null = Set-CfgValue 'dsh-接入\提醒配置.json' @('phonePush', 'wecom', 'webhook') (ConvertTo-JsonStringText $WecomWebhook) '企业微信 webhook' }

  # 复查：四个文件都能解析 + workspaceDir 真的不是空的（这条断言就是为上面那个真机 bug 加的）
  foreach ($rel in @('wx-采集器\config.json', 'wx-采集器\config-qq.json', 'dsh-接入\提醒配置.json', 'dsh-msg-memo\config.json')) {
    $full = Join-Path $InstallDir $rel
    if (-not (Test-Path -LiteralPath $full)) { continue }
    try { $null = ([System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", '') | ConvertFrom-Json }
    catch { Die ("{0} 写完后 JSON 解析不了：{1}" -f $rel, $_.Exception.Message) }
  }
  $memCfg = ([System.IO.File]::ReadAllText((Join-Path $InstallDir 'dsh-msg-memo\config.json'), [System.Text.Encoding]::UTF8) -replace "^\uFEFF", '') | ConvertFrom-Json
  if (-not ([string]$memCfg.workspaceDir).Trim()) { Die '复查失败：workspaceDir 还是空的（插件会写错地方），请把这份报告发给作者' }
  Ok ('复查通过：workspaceDir = ' + $memCfg.workspaceDir)

  # 复查：只填了企业微信，就**不该**有别的推送通道被写值
  # （这条断言是另一个 AI 复测后建议加的：`提醒配置.json` 里 "webhook" 出现两次，
  #   "只替换第一处"的意图一旦失效就会把企业微信地址写进钉钉字段，而安装过程本身不报错）
  $pushCfg = ([System.IO.File]::ReadAllText((Join-Path $InstallDir 'dsh-接入\提醒配置.json'), [System.Text.Encoding]::UTF8) -replace "^\uFEFF", '') | ConvertFrom-Json
  if ($WecomWebhook -and ([string]$pushCfg.phonePush.dingtalk.webhook).Trim()) {
    Die ('企业微信 webhook 被误写进了 dingtalk.webhook（键改写时串键了）：' + $pushCfg.phonePush.dingtalk.webhook + '｜请把这份报告发给作者')
  }
  if ($WecomWebhook -and ([string]$pushCfg.phonePush.wecom.webhook).Trim() -ne $WecomWebhook) {
    Die ('wecom.webhook 没写对：期望 ' + $WecomWebhook + '，实际 ' + $pushCfg.phonePush.wecom.webhook)
  }
  Ok '复查通过：推送通道没有串键（wecom 有值、dingtalk 仍为空）'
}

# ---------------- ⑥ 把插件挂进 DSH ----------------
Head '⑥ 挂进 DSH（插件）'
$profileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $ProfileName)
if ($SkipProfile) {
  Warn '-SkipProfile：跳过挂进 DSH（打包自测模式，不碰本机 profile）'
} elseif (-not (Test-Path -LiteralPath $profileDir)) {
  Warn ("没找到 DSH profile 目录 {0} —— 先启动一次 DSH（它会创建 profile），再重跑本脚本" -f $profileDir)
} elseif ($DryRun) {
  Say ("  将修改 {0}\package.json：加依赖 @local/dsh-msg-memo = link:{1}" -f $profileDir, (Join-Path $InstallDir 'dsh-msg-memo'))
  Say ("  将创建 junction {0}\node_modules\@local\dsh-msg-memo → 插件目录" -f $profileDir)
} else {
  $pkgFile = Join-Path $profileDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgFile)) { Warn 'profile 里没有 package.json，跳过（先启动 DSH 再重跑）' }
  else {
    Copy-Item -LiteralPath $pkgFile -Destination ($pkgFile + '.bak-install') -Force
    $plugPath = (Join-Path $InstallDir 'dsh-msg-memo').Replace('\', '/')
    # 纯 PowerShell 文本插入改 package.json（不依赖 node，也不碰 ConvertTo-Json —— 它会把单元素数组塌成字符串）
    $raw = [System.IO.File]::ReadAllText($pkgFile, [System.Text.Encoding]::UTF8) -replace '^\uFEFF', ''
    if ($raw -notmatch [regex]::Escape('@local/dsh-msg-memo')) {
      $link = 'link:' + ($InstallDir.Replace('\', '/') + '/dsh-msg-memo')
      $raw = $raw -replace '("dependencies"\s*:\s*\{)', ('$1' + "`r`n    ""@local/dsh-msg-memo"": ""$link"",")
      $raw = $raw -replace '("bundles"\s*:\s*\[)', ('$1' + "`r`n        ""@local/dsh-msg-memo"",")
      # ⚠️ 空对象 `{}` 被插入后会留下尾逗号（`{ "x": 1, }`）→ JSON 非法 → ConvertFrom-Json 抛错，
      #    而本脚本是 EAP=Stop → 整个安装死在第⑥步，变成一个"文件在、插件没挂、任务没建"的半装状态。
      #    DSH 新建 profile 的 dependencies 恰好就是空对象，所以这是必现的（测试机实测）。
      $raw = $raw -replace ',\s*\}', " }"
      $raw = $raw -replace ',\s*\]', " ]"
      try {
        $null = $raw | ConvertFrom-Json
        [System.IO.File]::WriteAllText($pkgFile, $raw, (New-Object System.Text.UTF8Encoding($false)))
        Ok 'profile/package.json 已更新（依赖 + bundles）'
      } catch {
        Warn ('插件没挂上（profile/package.json 改动失败），安装继续：' + $_.Exception.Message)
        Warn ('  手动补救：在 ' + $pkgFile + ' 的 dependencies 和 dsh.profile.bundles 里各加一行 @local/dsh-msg-memo')
      }
    }    Ok '原 profile/package.json 已备份为 package.json.bak-install'

    # ⚠️ 2026-10-17 加（外部复测的阻断级缺陷）：DSH 的 profile 加载器读 bundle 的 package.json 是
    #   **裸 JSON.parse**，不剥 BOM → 带 BOM 就 SyntaxError → 整包被静默跳过（界面无任何报错）→ 插件永远不装载。
    #   所以挂上去之前，强制把插件清单的 BOM 去掉并断言能被 JSON.parse；万一是旧包也能装上。
    $plugManifest = Join-Path $InstallDir 'dsh-msg-memo\package.json'
    foreach ($mf in @($plugManifest, (Join-Path $InstallDir 'dsh-msg-memo\cordis.patch.yml'), (Join-Path $InstallDir 'dsh-msg-memo\config.json'))) {
      if (Test-Path -LiteralPath $mf) {
        $mb = [System.IO.File]::ReadAllBytes($mf)
        if ($mb.Length -ge 3 -and $mb[0] -eq 0xEF -and $mb[1] -eq 0xBB -and $mb[2] -eq 0xBF) {
          $nb = New-Object byte[] ($mb.Length - 3)
          [Array]::Copy($mb, 3, $nb, 0, $nb.Length)
          [System.IO.File]::WriteAllBytes($mf, $nb)
          Warn ('已去掉 BOM：' + (Split-Path -Leaf $mf) + '（DSH 读 bundle 清单不剥 BOM，带 BOM 会整包被跳过）')
        }
      }
    }
    if (Test-Path -LiteralPath $plugManifest) {
      $mj = ([System.IO.File]::ReadAllText($plugManifest, [System.Text.Encoding]::UTF8)) -replace '^\uFEFF', ''
      try { $null = $mj | ConvertFrom-Json; Ok '插件清单可解析（不会因 BOM/语法被 DSH 跳过）' }
      catch { Warn ('插件清单解析失败：' + $_.Exception.Message + ' —— 插件可能装不上，请把包内 dsh-msg-memo\package.json 换成无 BOM 的版本') }
    }
    $linkDir = Join-Path $profileDir 'node_modules\@local'
    New-Item -ItemType Directory -Force -Path $linkDir | Out-Null
    $linkPath = Join-Path $linkDir 'dsh-msg-memo'
    if (Test-Path -LiteralPath $linkPath) {
      $it = Get-Item -LiteralPath $linkPath -Force
      if ($it.LinkType -eq 'Junction') { Remove-Item -LiteralPath $linkPath -Force -Recurse }
    }
    New-Item -ItemType Junction -Path $linkPath -Target (Join-Path $InstallDir 'dsh-msg-memo') | Out-Null
    Ok ("junction 已建立: {0}" -f $linkPath)
    Warn '**要让插件生效必须重启 DSH**'
  }
}

# ---------------- ⑦ 计划任务（wscript 外壳，不闪窗） ----------------
Head '⑦ 创建计划任务'
# 判断"包里有没有"要用 $src（DryRun 时目标目录还没建，用 $InstallDir 会误报"没有"）
$vbsInPkg = Join-Path $src 'dsh-接入\run-hidden.vbs'
$vbs = Join-Path $InstallDir 'dsh-接入\run-hidden.vbs'
if (-not (Test-Path -LiteralPath $vbsInPkg)) { Warn '包里没有 run-hidden.vbs，跳过计划任务' }
else {
  # 周期从 运行配置.json 读（控制台页可改：生成页面 → 导出改动 → -Apply；自检阈值也读它，必须一致）
  $runCfgFile = Join-Path $InstallDir 'dsh-接入\运行配置.json'
  $cM = 60; $rM = 5; $sM = 120
  if (Test-Path -LiteralPath $runCfgFile) {
    try {
      $rc = ((Get-Content -LiteralPath $runCfgFile -Raw -Encoding UTF8) -replace '^\uFEFF','' | ConvertFrom-Json)
      if ($rc.collectMinutes) { $cM = [int]$rc.collectMinutes }
      if ($rc.remindMinutes) { $rM = [int]$rc.remindMinutes }
      if ($rc.selfcheckMinutes) { $sM = [int]$rc.selfcheckMinutes }
    } catch { }
  } elseif (-not $DryRun) {
    # 老包没有这个文件 → 播种默认值（无 BOM，别用 Set-Content）
    [System.IO.File]::WriteAllText($runCfgFile, '{
  "collectMinutes": 60,
  "remindMinutes": 5,
  "selfcheckMinutes": 120,
  "_note": "三个计划任务的周期（分钟）。用 群聊待办\\控制台.ps1 改（生成页面 → 导出改动 → -Apply），自检阈值跟着它走。"
}
', (New-Object System.Text.UTF8Encoding($false)))
    Say '  已播种默认 运行配置.json（采集 60 / 提醒 5 / 自检 120 分钟，控制台页可改）'
  }
  $tasks = @(
    @{ name = '微信待办-采集';   ps1 = 'wx-采集器\采集器.ps1';     args = '-Once -AllowClick -MaxClicks 3 -Pseudo'; every = $cM; desc = ("每 {0} 分钟采集微信（最小化也能采）" -f $cM) }
    @{ name = 'QQ待办-采集';     ps1 = 'wx-采集器\采集器-QQ.ps1';   args = '-Once';                                 every = $cM; desc = ("每 {0} 分钟采集 QQ（后台，不抢焦点）" -f $cM) }
    @{ name = '微信待办-提醒';   ps1 = 'dsh-接入\提醒器.ps1';        args = '';                                      every = $rM; desc = ("每 {0} 分钟检查到点待办并提醒" -f $rM) }
    @{ name = '微信待办-自检';   ps1 = 'dsh-接入\自检.ps1';          args = '';                                      every = $sM; desc = ("每 {0} 分钟自检（红灯会推手机）" -f $sM) }
    @{ name = '微信待办-转发接收'; ps1 = 'dsh-接入\接收端.ps1'; args = ''; every = 1; desc = '手机通知转发进来（默认停用；要就在任务计划程序里启用）'; disabled = $true }
  )
  foreach ($t in $tasks) {
    if ($SkipTasks) { Warn '-SkipTasks：跳过建计划任务'; break }
    $script = Join-Path $InstallDir $t.ps1
    $arg = '"' + $vbs + '" "' + $script + '"'
    if ($t.args) { $arg += ' ' + $t.args }
    if ($DryRun) { Say ("  将创建任务 {0}（每 {1} 分钟）: wscript {2}" -f $t.name, $t.every, $arg); continue }
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $t.every)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $t.name -Action $action -Trigger $trigger -Settings $settings -Description $t.desc -Force | Out-Null
    if ($t.disabled) { Disable-ScheduledTask -TaskName $t.name -ErrorAction SilentlyContinue | Out-Null }
    Ok ("任务 {0}（每 {1} 分钟）" -f $t.name, $t.every)
  }
}

# ---------------- ⑧ 自检 ----------------
Head '⑧ 注册通知身份（AUMID）'
if ($SkipAumid) { Warn '-SkipAumid：跳过（Win11 可能静默丢弃通知横幅）' }
elseif ($DryRun) { Say '  将写 HKCU\Software\Classes\AppUserModelId\DSH.Todo 和 PushNotifications\ToastEnabled=1' }
else {
  try {
    $k1 = 'HKCU:\Software\Classes\AppUserModelId\DSH.Todo'
    $k2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
    New-Item -Path $k1 -Force | Out-Null
    Set-ItemProperty -Path $k1 -Name 'DisplayName' -Value '群聊待办'
    Set-ItemProperty -Path $k1 -Name 'ShowInSettings' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    # PushNotifications 是系统预置键（已有子键）：New-Item -Force 会先删后建 → 抛 Cannot delete a subkey tree（实测），EAP=Stop 下还会中断脚本
    if (-not (Test-Path -LiteralPath $k2)) { New-Item -Path $k2 -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $k2 -Name 'ToastEnabled' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Ok '已注册通知身份 DSH.Todo（不注册的话 Win11 可能把横幅静默丢掉）'
  } catch { Warn ('注册 AUMID 失败（不影响其它功能）：' + $_.Exception.Message) }
}

Head '⑨ 自检'
if ($DryRun) { Say '  将运行 dsh-接入\自检.ps1' }
else {
  $check = Join-Path $InstallDir 'dsh-接入\自检.ps1'
  if (Test-Path -LiteralPath $check) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $check -Quiet
  } else { Warn '没找到自检脚本' }
}

# ---------------- ⑩ 待办管家规则填本机路径 + 打开控制台 ----------------
# ① 规则文件：随包的 待办管家-规则.txt 是**带占位符的模板**（打包机路径不能给别人用）。
#    外部复测 §5.1 实测：老版发出去的是打包机旧路径、而控制台页里那份是对的 → 两个来源打架。
#    现在安装时按本机 InstallDir / node 路径就地替换，两边一致。
if (-not $DryRun) {
  $ruleFile = Join-Path $InstallDir '群聊待办\待办管家-规则.txt'
  if (Test-Path -LiteralPath $ruleFile) {
    $nodeForRules = ''
    foreach ($c in @((Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
      if (Test-Path -LiteralPath $c) { $nodeForRules = $c; break }
    }
    if (-not $nodeForRules) { $cmdN = Get-Command node -ErrorAction SilentlyContinue; if ($cmdN) { $nodeForRules = $cmdN.Source } }
    if (-not $nodeForRules) { $nodeForRules = '<node.exe 的绝对路径——本机没找到，请装 Node.js 或从控制台页复制>' }
    try {
      $raw = [System.IO.File]::ReadAllText($ruleFile, [System.Text.Encoding]::UTF8)
      $raw = $raw.Replace('__INSTALL_DIR__', $InstallDir).Replace('__NODE__', $nodeForRules)
      [System.IO.File]::WriteAllText($ruleFile, $raw, (New-Object System.Text.UTF8Encoding($true)))   # 带 BOM：记事本能正确认出中文
      Say '  待办管家-规则.txt 已按本机路径填好（可直接整段复制给微信机器人）'
    } catch { Warn ('规则文件写入失败（不影响主功能）：' + $_.Exception.Message) }
  }
}

# ② 装完自动打开控制台页：新用户第一眼就看到"装好了、长这样、能改什么"（外部复测 §4.3 建议）
Head '⑩ 控制台'
if ($DryRun) { Say '  将运行 群聊待办\控制台.ps1（生成并打开配置页）' }
elseif ($SkipConsole) { Warn '-SkipConsole：跳过（不生成/不打开控制台页）' }
else {
  $console = Join-Path $InstallDir '群聊待办\控制台.ps1'
  if (-not (Test-Path -LiteralPath $console)) { Warn '没找到 控制台.ps1，跳过' }
  else {
    # 控制台要 node；没有 node 时它自己会打印"手改哪个文件哪个键"的清单（不静默失败）
    $hasNode = $false
    foreach ($c in @((Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) { if (Test-Path -LiteralPath $c) { $hasNode = $true; break } }
    if (-not $hasNode) { $cmdN2 = Get-Command node -ErrorAction SilentlyContinue; if ($cmdN2) { $hasNode = $true } }
    if ($hasNode) {
      # 2026-10-16 起：只保留"一键应用"（本地服务版）。安装阶段用**隐藏启动**：
      #   run-hidden.vbs → 控制台.ps1 -Hidden → 起本地服务（只监听 127.0.0.1）+ 浏览器打开页面。
      #   wscript 是 GUI 宿主、不建控制台窗口，而且**立刻返回**（直接调用会阻塞安装）。
      $vbs = Join-Path $InstallDir 'dsh-接入\run-hidden.vbs'
      if (Test-Path -LiteralPath $vbs) {
        & wscript.exe $vbs $console -Hidden
        Say '  控制台页已在浏览器打开（改周期/webhook/昵称/白名单都在那一页）——点「确定」当场生效'
        Say '  以后想再打开：双击 群聊待办\打开控制台.cmd'
      } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $console -Hidden
        Say '  控制台服务已启动并打开页面（点「确定」当场生效）'
      }
    } else {
      Warn '本机没有 Node.js → 控制台页生成不了（不影响采集/提醒）。要看"手改哪个文件哪个键"，直接跑：'
      Say  ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $console)
    }
  }
}

# ---------------- 收尾 ----------------
Head '装完了，接下来要做的'
Say '  1) 重启 DSH（插件是启动时装载的）—— 这一步不做，待办永远不会更新'
if (-not $WecomWebhook) { Say '  2) 填企业微信 webhook：dsh-接入\提醒配置.json → phonePush.wecom.webhook（手机提醒必需）' } else { Say '  2) 手机提醒已配好（企业微信 @所有人）' }

Say '  3) 微信/QQ 保持登录（最小化、收托盘都行，退出进程就不采了）'
Say '  4) 想改盯的群/关键词：改 wx-采集器\config.json 和 config-qq.json，或直接问 DSH 里的 AI'
Say ''
Say ("安装目录: {0}" -f $InstallDir)
Say '详细说明见同目录的 快速开始.md'
