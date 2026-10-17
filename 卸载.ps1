#Requires -Version 5.1
<#
  卸载.ps1 —— 把「群聊待办自动提取」从这台机器上拆掉（安装.ps1 的逆操作）

  默认只做**可逆**的三件事：
    ① 删除 5 个计划任务
    ② 删掉 profile 里的 node_modules\@local\dsh-msg-memo junction
    ③ 从 profile 的 package.json 里去掉依赖 + bundles 条目（改前自动备份成 .bak-uninstall-<时间>）

  **默认不动任何数据**。要连数据一起清，必须显式加开关：
    -DeleteRuntimeData   删 群聊待办\（todos.json / MEMO.md / 日志 / 游标 / 归档）—— 你的待办就没了
    -DeleteSpool         删 wx-采集器\{spool,state,logs,screenshots}
    -DeleteProfileBackups 删 .bak-msgmemo / .bak-uninstall-* 这类备份

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\卸载.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\卸载.ps1 -DeleteRuntimeData -DeleteSpool

  ⚠️ 本脚本**不会**删 DSH 的会话历史，也不会碰 .dsh\undo-snapshots（要回滚用 DSH 的撤回快照）。
#>
[CmdletBinding()]
param(
  [string]$WorkspaceRoot,
  [string]$ProfileDir,
  [switch]$DeleteRuntimeData,
  [switch]$DeleteSpool,
  [switch]$DeleteProfileBackups,
  [switch]$KeepTasks
)

$ErrorActionPreference = 'Continue'
# 定位工作区根目录：同 安装.ps1（脚本就在工作区根目录，不能再 Split-Path -Parent）
function Test-WorkspaceRoot([string]$p) {
  return (Test-Path -LiteralPath (Join-Path $p 'wx-采集器')) -and (Test-Path -LiteralPath (Join-Path $p 'dsh-接入'))
}
if (-not $WorkspaceRoot) {
  $probe = $PSScriptRoot
  for ($i = 0; $i -lt 3 -and $probe; $i++) {
    if (Test-WorkspaceRoot $probe) { $WorkspaceRoot = $probe; break }
    $probe = Split-Path -Parent $probe
  }
  if (-not $WorkspaceRoot) { $WorkspaceRoot = $PSScriptRoot }
}
if (-not (Test-WorkspaceRoot $WorkspaceRoot)) {
  Write-Host "错误：$WorkspaceRoot 看起来不是工作区（找不到 wx-采集器 或 dsh-接入）" -ForegroundColor Red
  Write-Host '      用 -WorkspaceRoot "C:\...\default-workspace" 显式指定。'
  exit 1
}
if (-not $ProfileDir) {
  if ($env:DSH_PROFILE_DIR) { $ProfileDir = $env:DSH_PROFILE_DIR }
  else { $ProfileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop' }
}
$pluginSrc = Join-Path $WorkspaceRoot 'dsh-msg-memo'
$junction = Join-Path $ProfileDir 'node_modules\@local\dsh-msg-memo'
$profilePkg = Join-Path $ProfileDir 'package.json'
$todoDir = Join-Path $WorkspaceRoot '群聊待办'
$spoolDirs = @(
  (Join-Path $WorkspaceRoot 'wx-采集器\spool'),
  (Join-Path $WorkspaceRoot 'wx-采集器\state'),
  (Join-Path $WorkspaceRoot 'wx-采集器\logs'),
  (Join-Path $WorkspaceRoot 'wx-采集器\screenshots')
)
$problems = @()
$changed = @()

function Say([string]$m) { Write-Host $m }
function Step([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [警告] $m" -ForegroundColor Yellow }
function Bad([string]$m) { Write-Host "  [错误] $m" -ForegroundColor Red }

function Write-BomlessUtf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ── 危险操作前先确认"解析后的绝对路径"确实是我想要的那个 ──
function Assert-SafePath([string]$path, [string]$expectLeaf) {
  $full = [System.IO.Path]::GetFullPath($path)
  $leaf = Split-Path -Leaf $full
  if ($leaf -ne $expectLeaf) { throw "拒绝删除：$full 的末级目录是 '$leaf'，不是预期的 '$expectLeaf'" }
  if (-not $full.StartsWith([System.IO.Path]::GetFullPath($WorkspaceRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝删除：$full 不在工作区 $WorkspaceRoot 里"
  }
  return $full
}

$nodeExe = $null
foreach ($c in @(
    (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
    'C:\Program Files\nodejs\node.exe'
  )) { if (Test-Path -LiteralPath $c) { $nodeExe = $c; break } }
if (-not $nodeExe) { $cmd = Get-Command node -ErrorAction SilentlyContinue; if ($cmd) { $nodeExe = $cmd.Source } }

Say "工作区   : $WorkspaceRoot"
Say "Profile  : $ProfileDir"
Say "数据清理 : 运行数据=$(if ($DeleteRuntimeData) { '删' } else { '保留' })  采集缓存=$(if ($DeleteSpool) { '删' } else { '保留' })"

# ───────────────────────── ① 计划任务 ─────────────────────────
Step '① 删除计划任务'
$taskNames = @('微信待办-采集', 'QQ待办-采集', '微信待办-提醒', '微信待办-自检', '微信待办-转发接收')
if ($KeepTasks) {
  Warn '-KeepTasks：跳过（任务保留，采集/提醒还会继续跑）'
} else {
  foreach ($tn in $taskNames) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if (-not $t) { Ok "$tn ：本来就没有" ; continue }
    $res = & schtasks.exe /delete /tn $tn /f 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "$tn 已删除"; $changed += "任务 $tn" }
    else { Bad "$tn 删除失败：$res"; $problems += "任务 $tn 删不掉" }
  }
}

# ───────────────────────── ② junction ─────────────────────────
Step '② 删除插件 junction'
if (Test-Path -LiteralPath $junction) {
  $item = Get-Item -LiteralPath $junction -Force
  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Remove-Item -LiteralPath $junction -Recurse -Force
    Ok "已删除 junction（只删链接，插件源码 $pluginSrc 不动）"
    $changed += 'junction'
  } else {
    Bad "$junction 不是 junction/符号链接（是真目录）→ 不敢删，请人工确认"
    $problems += 'junction 是真目录'
  }
} else { Ok 'junction 本来就没有' }

# ───────────────────────── ③ profile package.json ─────────────────────────
Step '③ 清理 profile 的 package.json'
if ($nodeExe -and (Test-Path -LiteralPath $profilePkg)) {
  $js = @'
// argv[0]=node、argv[1]=本脚本自身 → 参数从 slice(2) 开始
// （踩过：slice(1) 会把脚本源码当成 JSON 文件读，报 "... is not valid JSON"）
const fs = require('fs')
const [pkgPath, name] = process.argv.slice(2)
const raw = fs.readFileSync(pkgPath, 'utf8')
const doc = JSON.parse(raw.replace(/^\uFEFF/, ''))
const out = []
if (doc.dependencies && Object.prototype.hasOwnProperty.call(doc.dependencies, name)) {
  delete doc.dependencies[name]
  out.push('dependencies 去掉 ' + name)
}
const bundles = doc.dsh && doc.dsh.profile && doc.dsh.profile.bundles
if (Array.isArray(bundles)) {
  const i = bundles.indexOf(name)
  if (i >= 0) { bundles.splice(i, 1); out.push('bundles 去掉 ' + name) }
}
if (out.length) {
  const bak = pkgPath + '.bak-uninstall-' + new Date().toISOString().replace(/[:.]/g, '-')
  fs.copyFileSync(pkgPath, bak)
  fs.writeFileSync(pkgPath, JSON.stringify(doc, null, 2) + '\n', 'utf8')
  console.log('CHANGED: ' + out.join(' ; ') + ' | 备份 ' + bak)
} else {
  console.log('UNCHANGED: package.json 里本来就没有它')
}
'@
  $tmpJs = Join-Path $env:TEMP ("dsh-uninstall-pkg-" + [guid]::NewGuid().ToString('N') + '.cjs')
  Write-BomlessUtf8 $tmpJs $js
  $r = & $nodeExe $tmpJs $profilePkg '@local/dsh-msg-memo' 2>&1
  Remove-Item -LiteralPath $tmpJs -Force -ErrorAction SilentlyContinue
  if ($r -match '^CHANGED') { Ok ("package.json 已清理：" + ($r -replace '^CHANGED: ', '')); $changed += 'profile package.json' }
  elseif ($r -match '^UNCHANGED') { Ok 'package.json 本来就没有它（没动）' }
  else { Bad "改 package.json 失败：$r"; $problems += 'package.json 未清理' }
} else {
  Warn '没有 node 或找不到 profile package.json → 请手动删 dependencies["@local/dsh-msg-memo"] 和 bundles 里的同名条目'
}

# ───────────────────────── ④ 可选：清数据 ─────────────────────────
if ($DeleteRuntimeData) {
  Step '④ 删除运行数据（群聊待办\）'
  if (Test-Path -LiteralPath $todoDir) {
    try {
      $safe = Assert-SafePath $todoDir '群聊待办'
      Say "  将删除：$safe"
      Say "  其中包含：todos.json（你的待办！）、MEMO.md、插件日志.txt、.spool-cursor.json、archive\"
      Remove-Item -LiteralPath $safe -Recurse -Force
      Ok '已删除 群聊待办\'
      $changed += '群聊待办\\'
    } catch { Bad "$_"; $problems += '群聊待办\ 删除被拒' }
  } else { Ok '群聊待办\ 本来就没有' }
} else {
  Step '④ 运行数据：保留'
  Say "  群聊待办\ 保留不动（你的待办数据在 $todoDir）"
  Say '  想一起删就加 -DeleteRuntimeData'
}

if ($DeleteSpool) {
  Step '⑤ 删除采集缓存'
  foreach ($d in $spoolDirs) {
    if (-not (Test-Path -LiteralPath $d)) { Ok "$(Split-Path -Leaf $d)\ 本来就没有"; continue }
    try {
      $safe = Assert-SafePath $d (Split-Path -Leaf $d)
      Remove-Item -LiteralPath $safe -Recurse -Force
      Ok "已删除 $safe"
      $changed += (Split-Path -Leaf $d) + '\'
    } catch { Bad "$_"; $problems += "$d 删除被拒" }
  }
} else {
  Step '⑤ 采集缓存：保留'
  Say '  spool/state/logs/screenshots 保留（想删加 -DeleteSpool）'
}

if ($DeleteProfileBackups) {
  Step '⑥ 删除 profile 里的备份文件'
  Get-ChildItem -LiteralPath $ProfileDir -Filter 'package.json.bak*' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
    Ok "已删除 $($_.Name)"
    $changed += $_.Name
  }
}

# ───────────────────────── 汇总 ─────────────────────────
Step '汇总'
if ($changed.Count) { Say ("本次改动：" + ($changed -join '、')) } else { Say '什么都没改（本来就没装？）' }
if ($problems.Count) {
  Say ''
  Warn ("有 $($problems.Count) 项需要人工处理：")
  $problems | ForEach-Object { Say "    - $_" }
  exit 1
}
Say ''
Ok '卸载完成'
Say '  注意：**重启 DSH 后插件才真正不再装载**（进程里还留着已加载的模块）'
Say '  插件源码、脚本、文档都留在工作区里没动，想再装回来跑 .\安装.ps1 即可'
Say '  想彻底清掉（含内置的约 89MB MaaFramework 运行库）：确认数据不要了之后，把整个安装目录删掉即可 —— 项目不会把文件写到目录以外的地方'
exit 0
