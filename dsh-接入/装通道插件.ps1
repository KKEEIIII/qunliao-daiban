# 装通道插件.ps1 —— 自动把「微信通道 / QQ 通道」插件装进 DSH 的 desktop profile
#
# 为什么要有它：以前让对方"自己去插件市场搜 dsh-wechat-plugin / dsh-qq-plugin"，
# 步骤多、名字还容易打错（少个 -plugin 就搜不到）。这里用 DSH 自带的 CLI 一步装好：
#     <DSH安装目录>\resources\runtime\cli\bin\dsh.cmd plugin --profile desktop add <包名>
# 它 = 在 profile 目录里 pnpm add + 让 DSH 插件管理器重建 bundles 清单（装完**必须重启 DSH** 才装载）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\装通道插件.ps1 -Status          # 只看状态（只读，不改任何东西）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\装通道插件.ps1 -Which both      # 装微信 + QQ（默认）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\装通道插件.ps1 -Which qq        # 只装 QQ
#   ... -DshDir 'D:\DSH'    # 装在非默认目录时显式指定（一般不用，会自动探测）
#
# 说明：
#   · 装完**只是把通道能力装上**；扫码绑定还得人工做（DSH 设置 → 微信 / QQ → 开始扫码）。
#   · 需要联网（走 npm/pnpm）。失败会把 CLI 的原话打出来，并给出"手动装"的两条路。
param(
  [ValidateSet('wechat', 'qq', 'both')][string]$Which = 'both',
  [switch]$Status,
  [string]$DshDir = ''
)

$ErrorActionPreference = 'Continue'
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profileDir = Join-Path $dshHome 'profiles\desktop'
$profilePkg = Join-Path $profileDir 'package.json'

$channels = [ordered]@{
  wechat = @{ pkg = 'dsh-wechat-plugin'; name = '微信通道'; note = '提醒主通道 + 微信里回"完成"标记待办' }
  qq     = @{ pkg = 'dsh-qq-plugin';     name = 'QQ 通道';   note = '腾讯官方 QQ 机器人平台（扫码绑定）；QQ 允许主动推送' }
}
$want = if ($Which -eq 'both') { @('wechat', 'qq') } else { @($Which) }

function Find-NodeExe {
  foreach ($c in @((Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
      (Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
    if (Test-Path -LiteralPath $c) { return $c }
  }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# 返回 @{ kind='cmd'|'node'; path=…; node=… }；找不到返回 $null
# ⚠️ 2026-10-16 修（外部复测 §六.2）：原来只按进程名 `DeepSeek Harness` 找，而**新版桌面端的进程名是
#    `DSH Desktop`**，且它的 CLI **不在** resources\runtime\cli\bin\dsh.cmd，而是
#    `resources\app\node_modules\@deepseek-ai\dsh\lib\bin.js`（要用 node 跑）。两条布局现在都支持。
function Find-DshCli {
  $dirs = @()
  if ($DshDir) { $dirs += $DshDir }
  foreach ($pname in @('DSH Desktop', 'DeepSeek Harness')) {
    $p = Get-Process -Name $pname -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and $_.Path -notmatch 'app\.asar' } | Select-Object -First 1
    if ($p -and $p.Path) { $dirs += (Split-Path -Parent $p.Path) }
  }
  foreach ($base in @('DSH Desktop', 'DeepSeek Harness')) {
    $dirs += (Join-Path $env:LOCALAPPDATA ('Programs\' + $base))
    $dirs += (Join-Path $env:ProgramFiles $base)
    $dirs += (Join-Path ${env:ProgramFiles(x86)} $base)
  }
  foreach ($root in @('D:\', 'E:\', 'C:\')) {
    if (Test-Path -LiteralPath $root) {
      $dirs += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
  }
  $dirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)
  # ① 老布局：resources\runtime\cli\bin\dsh.cmd
  foreach ($d in $dirs) {
    $c = Join-Path $d 'resources\runtime\cli\bin\dsh.cmd'
    if (Test-Path -LiteralPath $c -PathType Leaf) { return @{ kind = 'cmd'; path = $c; node = '' } }
  }
  # ② 新布局：resources\app\node_modules\@deepseek-ai\dsh\lib\bin.js（用 node 跑）
  $nodeExe = Find-NodeExe
  if ($nodeExe) {
    foreach ($d in $dirs) {
      $js = Join-Path $d 'resources\app\node_modules\@deepseek-ai\dsh\lib\bin.js'
      if (Test-Path -LiteralPath $js -PathType Leaf) { return @{ kind = 'node'; path = $js; node = $nodeExe } }
    }
  }
  return $null
}

# 按找到的入口形状调用（统一返回输出文本）
function Invoke-DshCli {
  param($Cli, [string[]]$CliArgs)
  if ($Cli.kind -eq 'cmd') { return (& $Cli.path @CliArgs 2>&1 | Out-String) }
  return (& $Cli.node $Cli.path @CliArgs 2>&1 | Out-String)
}

function Get-ProfileDeps {
  if (-not (Test-Path -LiteralPath $profilePkg)) { return $null }
  try {
    $j = ([System.IO.File]::ReadAllText($profilePkg, [System.Text.Encoding]::UTF8)) -replace '^\uFEFF', '' | ConvertFrom-Json
    return $j
  } catch { return $null }
}

$j = Get-ProfileDeps
if (-not $j) {
  Write-Host ('❌ 读不到 DSH 的 desktop profile：{0}' -f $profilePkg)
  Write-Host '   说明 DSH 还没初始化过（或 DSH_HOME 不在默认位置）。先启动一次 DSH，再重跑本脚本。'
  exit 1
}
$deps = @($j.dependencies.PSObject.Properties | ForEach-Object { $_.Name })
$bundles = @($j.dsh.profile.bundles)

Write-Host '=== 通道插件状态 ==='
foreach ($k in $channels.Keys) {
  $ch = $channels[$k]
  $installed = $deps -contains $ch.pkg
  $inBundle = $bundles -contains $ch.pkg
  $ver = ''
  if ($installed) { $ver = [string]$j.dependencies.($ch.pkg) }
  Write-Host ('  {0,-8} {1,-18} {2}' -f $ch.name, $ch.pkg, $(if ($installed) { "已安装 $ver" + $(if ($inBundle) { '，已启用' } else { '，⚠️ 未在 bundles 里（需补）' }) } else { '未安装' }))
}

if ($Status) {
  $cli = Find-DshCli
  Write-Host ('  DSH CLI：' + $(if ($cli) { $cli.path + '（' + $cli.kind + ' 入口）' } else { '未找到（装在非常规目录时用 -DshDir 指定）' }))
  Write-Host '  （-Status 只读：没有改动任何文件）'
  exit 0
}

$cli = Find-DshCli
if (-not $cli) {
  Write-Host '❌ 找不到 DSH 自带的 CLI（resources\runtime\cli\bin\dsh.cmd）'
  Write-Host '   手动装（两条路）：'
  Write-Host '   ① DSH 侧栏 → 插件 → 添加插件 → 填包名 → 立即启用 → 重启 DSH'
  Write-Host '   ② 命令行：<DSH安装目录>\resources\runtime\cli\bin\dsh.cmd plugin --profile desktop add <包名>'
  exit 1
}
Write-Host ('  用 CLI：{0}（{1} 入口）' -f $cli.path, $cli.kind)

$failed = @()
foreach ($k in $want) {
  $ch = $channels[$k]
  $depsNow = @((Get-ProfileDeps).dependencies.PSObject.Properties | ForEach-Object { $_.Name })
  if ($depsNow -contains $ch.pkg) { Write-Host ('  ✓ {0} 已经装过（{1}），跳过安装' -f $ch.name, $ch.pkg) }
  else {
    Write-Host ''
    Write-Host ('--- 正在安装 {0}（{1}）…… 需要联网，可能要一两分钟 ---' -f $ch.name, $ch.pkg)
    $out = Invoke-DshCli -Cli $cli -CliArgs @('plugin', '--profile', 'desktop', 'add', $ch.pkg)
    $code = $LASTEXITCODE
    if ($out) { $out.Trim().Split("`n") | Select-Object -Last 12 | ForEach-Object { Write-Host ('    ' + $_.TrimEnd()) } }
    $depsNow = @((Get-ProfileDeps).dependencies.PSObject.Properties | ForEach-Object { $_.Name })
    if ($depsNow -contains $ch.pkg) { Write-Host ('  ✓ {0} 安装成功' -f $ch.name) }
    else { Write-Host ('  ❌ {0} 安装失败（CLI 退出码 {1}）' -f $ch.name, $code); $failed += $ch.name }
  }
}

# 兜底：包在 dependencies 里但不在 bundles 里（DSH 插件管理器重建失败时常这样）→ 用 Node 补上（JSON 只能 Node 写）
$j2 = Get-ProfileDeps
$bundles2 = @($j2.dsh.profile.bundles)
$needFix = @()
foreach ($k in $want) { $ch = $channels[$k]; if ((@($j2.dependencies.PSObject.Properties | ForEach-Object { $_.Name }) -contains $ch.pkg) -and ($bundles2 -notcontains $ch.pkg)) { $needFix += $ch.pkg } }
if ($needFix.Count -gt 0) {
  $node = $null
  foreach ($c in @((Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'), (Join-Path $env:ProgramFiles 'nodejs\node.exe'))) {
    if (Test-Path -LiteralPath $c) { $node = $c; break }
  }
  if (-not $node) { $cmdN = Get-Command node -ErrorAction SilentlyContinue; if ($cmdN) { $node = $cmdN.Source } }
  if ($node) {
    # ⚠️ 必须走**临时 .cjs 文件**：Node 24 的 `node -e` 会按 TS 处理、`require` 不可用（2026-10-16 实测踩过：
    #    CLI 装包成功、bundles 却静默没补上，靠人肉复查才发现）。JSON 也一律由 Node 写（项目铁律）。
    $tmpJs = Join-Path $env:TEMP ('fixbundles-' + [guid]::NewGuid().ToString('N') + '.cjs')
    $js = @'
const fs = require('fs');
const p = process.argv[2];
const add = process.argv.slice(3);
const j = JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
j.dsh = j.dsh || {}; j.dsh.profile = j.dsh.profile || {}; j.dsh.profile.bundles = j.dsh.profile.bundles || [];
let n = 0;
for (const a of add) { if (!j.dsh.profile.bundles.includes(a)) { j.dsh.profile.bundles.push(a); n++; } }
fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n', 'utf8');
console.log('  bundles 补了 ' + n + ' 项，现在 = ' + JSON.stringify(j.dsh.profile.bundles));
'@
    [System.IO.File]::WriteAllText($tmpJs, $js, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('  补 bundles 清单（CLI 的重建步骤常报错，这里兜底）：' + ($needFix -join ', '))
    & $node $tmpJs $profilePkg @needFix
    Remove-Item -LiteralPath $tmpJs -Force -ErrorAction SilentlyContinue
  } else {
    Write-Host ('  ⚠️ 包已装但不在 bundles 里，且本机没有 node 来补：请手动把 {0} 加进 profile 的 dsh.profile.bundles' -f ($needFix -join ', '))
  }
}

Write-Host ''
if ($failed.Count -gt 0) {
  Write-Host ('❌ 有 {0} 个通道没装上：{1}' -f $failed.Count, ($failed -join '、'))
  Write-Host '   常见原因：没联网 / npm 源不通 / 公司网络拦了。可重跑本脚本，或改用插件市场手动装。'
  exit 1
}
Write-Host '✅ 通道插件就绪。**请重启 DSH**（插件在启动时装载），然后：'
foreach ($k in $want) { Write-Host ('   · {0}：DSH 设置 → {1} → 开始扫码绑定' -f $channels[$k].name, $(if ($k -eq 'qq') { 'QQ' } else { '微信' })) }
exit 0
