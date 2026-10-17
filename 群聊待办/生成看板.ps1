#Requires -Version 5.1
<#
  生成看板.ps1 —— 群聊待办看板的"一键"入口（帮你找 node，省得手敲绝对路径）

  用法（2026-10-16 起：**只保留"点确定即写回"的服务版**，和 控制台.ps1 同一套）：
    # 1) 默认：生成/刷新看板 → 起本地服务（只监听 127.0.0.1）→ 自动打开能写回的页面
    powershell -NoProfile -ExecutionPolicy Bypass -File .\群聊待办\生成看板.ps1
    # 2) 双击 群聊待办\打开看板.cmd 也一样（隐藏起服务、不弹窗口）
    # 3) 页面里勾完成/忽略 → 点「确定」= 立刻写回 todos.json（自动备份、MEMO.md 一起重建）

    -NoOpen     只生成 看板.html，不打开浏览器、不起服务（打包自测/自检工具用）
    -NoBrowser  起/复用服务，但不打开浏览器
    -Hidden     隐藏启动（打开看板.cmd 与安装器用；经 run-hidden.vbs，不阻塞）
    -NoMemo     只看不改：生成看板但不重建 MEMO.md
    -Apply <补丁>  把补丁写回 todos.json（**服务内部用的通路**，也可以手工调；JSON 一律 Node 写）

  说明：
    · 浏览器写不了本地文件 → 所以由**只监听本机**的小服务（看板-服务.mjs）代劳：
      页面从它打开，点「确定」= POST 给它 = 它调用 `生成看板.mjs --apply` 写回，再把结果回给页面。
    · 老"下载 看板改动-*.json 再自己跑 -Apply"的**文件模式已停用**（用户 2026-10-16 要求）：
      把 看板.html 当文件双击打开时，页面会直接提示"请用 打开看板.cmd 打开"。
    · 合并时会写 closedAt（插件靠它归档已完成/已忽略的条目）。
#>
[CmdletBinding()]
param(
  [string]$Apply,
  [switch]$NoMemo,
  # ⚠️ 2026-10-16 加（外部复测建议）：原来"生成完只落盘、不打开"——而控制台.ps1 是生成完自动弹浏览器，
  #   同一个项目的两个入口行为不一致，落差正好落在"每天都要用"的看板上。
  #   现在默认**生成后自动打开**（-Apply 成功后也打开一次），要给计划任务/脚本用就显式传 -NoOpen。
  [switch]$NoOpen,
  [switch]$NoBrowser,
  [switch]$Hidden
)

$ErrorActionPreference = 'Continue'
$todoDir = $PSScriptRoot

# ⚠️ 2026-10-15 大改：**看板不再依赖 Node.js**。
# 原来这一步硬依赖 node（找不到就 exit 1），而 DSH 自己带的 node 各家路径不同、很多机器上干脆没有
# （另一台机器实测：全盘没有 node.exe → 看板功能完全不可用，而 版本.txt 还把看板列为重点功能）。
# 现在：
#   · 「生成看板」= 纯 PowerShell（读 todos.json → 拼内嵌数据 → 套 HTML 模板），零依赖
#   · 「-Apply 写回」仍走 Node（写 JSON 必须避开 PowerShell 的 BOM / 单元素数组两个历史坑），
#     并给出清楚的提示而不是一句 exit 1
function Find-NodeExe {
  $cands = @(
    (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
    (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
  )
  # DSH Desktop 版可能把运行时放在自己目录下：扫一遍
  foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $base) { continue }
    foreach ($sub in @('Programs\DSH Desktop', 'DSH Desktop', 'DeepSeek Harness')) {
      $p = Join-Path $base $sub
      if (Test-Path -LiteralPath $p) {
        $cands += @(Get-ChildItem -LiteralPath $p -Recurse -Filter 'node.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName })
      }
    }
  }
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# 把 HTML 模板里的占位符换成真实数据（纯文本替换，不解析 JSON，因此不受 ConvertTo-Json 怪癖影响）
function New-Board {
  $todosPath = Join-Path $todoDir 'todos.json'
  $tplPath = Join-Path $todoDir '看板模板.html'
  $boardPath = Join-Path $todoDir '看板.html'
  if (-not (Test-Path -LiteralPath $todosPath)) {
    # 新装、或插件还没跑过一轮 → 没有 todos.json。这时**当成空清单**，不要报错退出
    # （别人装完第一次点看板就是这个场景；装包自测第一版正是死在这里）
    Write-Host ("提示：还没有 todos.json（插件跑过一轮才会有）→ 本次按空清单生成") -ForegroundColor Yellow
    [System.IO.File]::WriteAllText($todosPath, ('{"items":[],"updatedAt":"' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') + '"}'), (New-Object System.Text.UTF8Encoding($false)))
  }
  if (-not (Test-Path -LiteralPath $tplPath)) { Write-Host "❌ 找不到 $tplPath（部署包缺文件？）"; exit 1 }

  $txt = [System.IO.File]::ReadAllText($todosPath, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", ''
  try { $doc = $txt | ConvertFrom-Json } catch { Write-Host ("❌ todos.json 解析失败：" + $_.Exception.Message) -ForegroundColor Red; exit 1 }
  $items = @($doc.items)          # @() 保证"单元素"也是数组

  # 自己拼 JSON 数组（保证每个元素都是对象、字符串转义可靠）
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('[')
  for ($i = 0; $i -lt $items.Count; $i++) {
    if ($i -gt 0) { [void]$sb.Append(',') }
    [void]$sb.Append(($items[$i] | ConvertTo-Json -Depth 12 -Compress))
  }
  [void]$sb.Append(']')
  $itemsJson = $sb.ToString()
  $generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')   # 不经过 ConvertTo-Json，避免被转义
  $payloadJson = '{"generatedAt":"' + $generatedAt + '","items":' + $itemsJson + '}'
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))

  $tpl = [System.IO.File]::ReadAllText($tplPath, [System.Text.Encoding]::UTF8)
  $outHtml = $tpl.Replace('__DATA__', $b64)
  # 校验：解析得动、且占位符真的被换掉了
  try { $null = $payloadJson | ConvertFrom-Json } catch { Write-Host ("❌ 生成的看板数据不是合法 JSON：" + $_.Exception.Message) -ForegroundColor Red; exit 1 }
  if ($outHtml.Contains('__DATA__')) { Write-Host '❌ 模板里的 __DATA__ 没被替换掉' -ForegroundColor Red; exit 1 }
  [System.IO.File]::WriteAllText($boardPath, $outHtml, (New-Object System.Text.UTF8Encoding($false)))
  $open = @($items | Where-Object { $_.status -notin @('done', 'ignored', 'expired') }).Count
  Write-Host ("看板已生成：{0}" -f $boardPath)
  Write-Host ("  待办 {0} 条（未完成 {1} 条）· 纯 PowerShell 生成，不需要 Node.js" -f $items.Count, $open)
}

# 打开看板：包在 try/catch 里——没设 .html 关联的机器上 Start-Process 会抛，但那不该让脚本算失败
function Open-Board {
  $board = Join-Path $todoDir '看板.html'
  if (-not (Test-Path -LiteralPath $board)) { return }
  try { Start-Process $board } catch { Write-Host ("看板已生成，请手动打开：" + $board) }
}

if (-not $Apply) {
  New-Board
  if ($NoMemo) { Write-Host '  （-NoMemo：没动 MEMO.md）' }
  $htmlPath = Join-Path $todoDir '看板.html'
  if ($NoOpen) { Write-Host ("看板.html 已生成：{0}" -f $htmlPath); exit 0 }

  # ---------- 默认：起/复用"一键写回"本地服务（只监听 127.0.0.1）+ 打开页面 ----------
  $ws = Split-Path -Parent $todoDir
  $accessDir = Join-Path $ws 'dsh-接入'
  $serveScript = Join-Path $todoDir '看板-服务.mjs'
  $nodeExe = Find-NodeExe
  if (-not $nodeExe -or -not (Test-Path -LiteralPath $serveScript)) {
    # 没有 node 就没有服务 → 只能"看"，写回用不了。别装死：明确说清缺什么。
    if (-not $nodeExe) { Write-Host '⚠️ 本机没有 Node.js → 起不了"一键写回"服务；这一页只能**看**，勾了也写不回去。' }
    else { Write-Host ('⚠️ 缺少 {0} → 起不了服务；这一页只能**看**，勾了也写不回去。' -f $serveScript) }
    Write-Host '   装一下 Node.js（一路下一步）再跑本脚本：https://nodejs.org/zh-cn/download'
    if (-not $NoBrowser) { Start-Process $htmlPath }
    exit 0
  }

  # 已经有一个服务在跑就直接用它（避免"双击两次 → 两个服务 + 两个页面"）
  $addrFile = Join-Path $todoDir '看板-服务地址.txt'
  if (Test-Path -LiteralPath $addrFile) {
    $prev = ([System.IO.File]::ReadAllText($addrFile, [System.Text.Encoding]::UTF8)).Trim()
    if ($prev -match '^http://127\.0\.0\.1:(\d+)/\?t=([0-9a-fA-F]{32})$') {
      try {
        $resp0 = Invoke-WebRequest -Uri ($prev -replace '/\?t=', '/ping?t=') -UseBasicParsing -TimeoutSec 2
        if ($resp0.StatusCode -eq 200) {
          Write-Host ''
          Write-Host '=== 已经有一个看板服务在跑，直接用它（不再起第二个）==='
          Write-Host ("  地址：{0}" -f $prev)
          Write-Host '  想重开一个干净的：点页面右下角「停止服务」，或删掉 群聊待办\看板-服务地址.txt 再来一次。'
          if (-not $NoBrowser) { Start-Process $prev } else { Write-Host '  （-NoBrowser：只复用服务，没有打开浏览器）' }
          exit 0
        }
      } catch { }
    }
  }

  $port = 0
  foreach ($p in 19400..19409) {
    try {
      $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
      $probe.Start(); $probe.Stop(); $port = $p; break
    } catch { try { $probe.Stop() } catch { } }
  }
  if ($port -eq 0) { Write-Host '❌ 19400-19409 端口全被占用 → 起不了看板服务。先关掉占用这些端口的程序再试。'; exit 1 }

  $token = [guid]::NewGuid().ToString('N')
  $url = "http://127.0.0.1:{0}/?t={1}" -f $port, $token
  # 服务可能以隐藏方式启动（打开看板.cmd）→ 窗口看不见，地址必须留痕
  try {
    $logDir = Join-Path $accessDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    Add-Content -LiteralPath (Join-Path $logDir '看板服务.log') -Encoding UTF8 -Value ("[{0}] 启动服务：{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $url)
    [System.IO.File]::WriteAllText($addrFile, ($url + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
  } catch { }
  Write-Host ''
  Write-Host '=== 看板服务（点确定即写回）==='
  Write-Host ("  地址：{0}" -f $url)
  if ($Hidden) { Write-Host '  （隐藏启动：没有可见窗口；地址见 群聊待办\看板-服务地址.txt，日志见 dsh-接入\logs\看板服务.log）' }
  Write-Host '  只监听本机回环地址（127.0.0.1）；页面里勾完点「确定」= 立刻写回 todos.json（自动备份 + 重建 MEMO.md）。'
  Write-Host '  停止：页面右下角「停止服务」/ 写回成功后自动停 / 空闲 30 分钟自动退出。'
  Write-Host ''
  $proc = Start-Process -FilePath $nodeExe -ArgumentList @($serveScript, $token, "$port") -WorkingDirectory $todoDir -NoNewWindow -PassThru
  $up = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try {
      $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/ping?t={1}" -f $port, $token) -UseBasicParsing -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $up = $true; break }
    } catch { }
    if ($proc.HasExited) { break }
  }
  if ($up) { if ($NoBrowser) { Write-Host '  （-NoBrowser：服务已就绪，没有打开浏览器）' } else { Start-Process $url } }
  else { Write-Host '❌ 服务没起来（看上面的报错）—— 请把这段输出发回给作者。'; exit 1 }
  Wait-Process -Id $proc.Id -ErrorAction SilentlyContinue
  Write-Host ''
  Write-Host '看板服务已停止。要再写回，双击 群聊待办\打开看板.cmd 重新打开。'
  exit 0
}

# ---- 下面是 -Apply（把看板导出的改动写回 todos.json）：这一步必须用 Node ----
$node = Find-NodeExe
$script = Join-Path $todoDir '生成看板.mjs'
if (-not $node -or -not (Test-Path -LiteralPath $script)) {
  Write-Host '❌ 写回改动需要 Node.js（为了避免 PowerShell 写 JSON 的两个老坑：BOM、单元素数组被写成对象）。' -ForegroundColor Red
  Write-Host '   两个办法：'
  Write-Host '   ① 装一下 Node.js（一路下一步即可）：https://nodejs.org/zh-cn/download'
  Write-Host '   ② 直接手改 群聊待办\todos.json（把该条的 "status" 改成 "done" 或 "ignored"），再重新生成看板'
  Write-Host ('   找不到的理由：node 不在 PATH，也不在 {0}\.dsh\dsh-runtimes 下' -f $env:USERPROFILE)
  exit 1
}

$args2 = @($script, '--apply', $Apply)
if ($NoMemo) { $args2 += '--noMemo' }
& $node @args2
$code = $LASTEXITCODE
if ($code -eq $null) { $code = 1 }   # node 起不来时 $LASTEXITCODE 可能是 $null（外部审查发现会 exit $null=0 假成功）
# 写回成功后再打开一次看板：用户刚勾完，最想看到的就是"结果已经写回去了"
if ($code -eq 0 -and -not $NoOpen) { Open-Board }
exit $code
# ⚠️ 2026-10-15 深夜删掉（外部审查：exit 之后的两行是死代码，永远执行不到；留着会误导后来者）
# ⚠️ 2026-10-16：若将来把 生成看板.ps1 加进计划任务，**必须显式传 -NoOpen**，否则到点会弹出浏览器。
