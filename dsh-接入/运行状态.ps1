# 运行状态.ps1 —— 把"这一轮到底成功没有"写进一个状态文件，供自检读取
#
# ⚠️ 为什么需要它（另一个 AI 在真机上量出来的）：
#   计划任务是用 run-hidden.vbs 拉起的（为了让 PowerShell 不闪黑窗），而 VBS 里的
#   `sh.Run cmd, 0, False` 是"不等待"→ **拿不到子进程退出码** → 5 个任务的 LastTaskResult 恒为 0。
#   于是 自检 里那两条"任务结果码非 0 → 红灯 / 上一轮自检发现了红灯"**永远不可能触发** ——
#   而"脚本悄悄挂了"正是自检最该发现的事。
#
#   两条路可选：
#     A) 让 VBS 等待并传回退出码（`sh.Run cmd, 0, True` + `WScript.Quit code`）
#        —— 代价：任务长期处于 running 状态（提醒任务每 5 分钟一次会叠加），
#        且与 ExecutionTimeLimit / "忽略新实例"的策略冲突。**我们没走这条。**
#     B) **本文件的做法**：脚本自己把结果写进状态文件，自检去读。
#        —— 不改任务调度行为，只补上"结果可观测"。
#
# 用法（脚本开头 dot-source，然后在**两个出口**各写一次）：
#   . "$PSScriptRoot\运行状态.ps1"                        # dsh-接入 下的脚本
#   . "$PSScriptRoot\..\dsh-接入\运行状态.ps1"             # wx-采集器 下的脚本
#   ...
#   Write-RunStatus -Name '提醒器' -Code 0                 # 正常结束
#   Write-RunStatus -Name '提醒器' -Code 1 -Note $msg      # 出问题时（catch 里）
#
# ⚠️ 为什么不做成"把整个脚本包进 try/finally 自动写"：
#   因为 **PowerShell 的 `exit` 会跳过外层 finally**，而这些脚本里到处是 `exit 0`，
#   包一层根本不可靠（我第一版就是这么写的，等于假的保障）。显式写两次最踏实。

function Write-RunStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Code = 0,
    [string]$Note = '',
    [string]$Path = ''
  )
  try {
    if (-not $Path) {
      # 默认写到 <工作区>\dsh-接入\logs\运行状态.json
      # （$PSScriptRoot 在函数里指向本文件所在目录 = dsh-接入）
      $Path = Join-Path $PSScriptRoot 'logs\运行状态.json'
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $all = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
      try {
        $old = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", ''
        $obj = $old | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $all[$p.Name] = $p.Value }
      } catch { /* 读不动就重建 */ }
    }
    $all[$Name] = [ordered]@{
      code = $Code
      at   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
      note = $Note
    }
    # 无 BOM UTF-8（PS 的 Set-Content -Encoding UTF8 会写 BOM，别的读者会因此解析失败）
    # ⚠️ 2026-10-15 深夜修（外部审查）：原来 WriteAllText 就地截断重写——断电/强杀会留半截 JSON，
    #   之后所有读者解析失败、自检 5b 整段失效。现在 **temp + 原子替换**：先写临时文件再换名。
    $json = ($all | ConvertTo-Json -Depth 5)
    $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
      # File.Replace 的备份参数传 $null 会抛"路径的形式不合法"（实测）→ 给个真备份路径，换完立刻删
      $bak = $Path + '.bak'
      try { [System.IO.File]::Replace($tmp, $Path, $bak) } catch { [System.IO.File]::Delete($Path); [System.IO.File]::Move($tmp, $Path) }
      if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
    } else {
      [System.IO.File]::Move($tmp, $Path)
    }
  } catch {
    # 状态文件写不了就算了：它只是"可观测性"，不该反过来把主流程弄挂
    try { Write-Host ("  [运行状态] 写状态失败（不影响主流程）：" + $_.Exception.Message) -ForegroundColor Yellow } catch { }
  }
}

<#
  自检侧用：读回某个脚本的最近一次结果。
  没记录 → 返回 $null（例如"这个任务今天还没跑过"，不该当成失败）。
#>
function Get-RunStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Path = ''
  )
  try {
    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'logs\运行状态.json' }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $old = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -replace "^\uFEFF", ''
    $obj = $old | ConvertFrom-Json
    if (-not $obj.PSObject.Properties[$Name]) { return $null }
    return $obj.PSObject.Properties[$Name].Value
  } catch { return $null }
}
