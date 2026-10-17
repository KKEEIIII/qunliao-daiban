# 测试-模型告警.ps1 —— 用**假日志 + 真自检**验证"模型变慢/半失败/token 用尽"的判定
#
# 为什么要这个：这类判定最容易写成"看着有逻辑、其实永远不触发"（2026-10-15 上午连 12 轮超时没报警，
# 就是因为失败正则写的是 '本轮失败' 而插件写的是 '模型调用失败'）。所以每条分支都要有对应场景。
#
# 跑法：powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\测试-模型告警.ps1
#       powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-接入\测试-模型告警.ps1 -AllowTestPush
#         （-AllowTestPush 会真的给你手机发一条"模型劣化"告警，用来确认推送链路通）
#
# ⚠️ 场景只留 6 个（另一个 AI 复测指出：10 个场景各起一个子进程 → 自检整体 61.7 秒，
#    对每 2 小时跑一次的任务太重）。这 6 个覆盖红灯/黄灯/两个假阳性，总耗时约 15~20 秒。
#    曾经有过的 3 个"绿灯场景"（一直正常 / 个别一轮慢 / 单轮偶发失败）已删：它们判的都是绿灯，
#    风险最低；"一直正常"这条的语义也被"提示词过长"那条部分覆盖了。
param([switch]$AllowTestPush)
$ErrorActionPreference = 'Continue'

# ⚠️ 护栏（2026-10-15 踩过无限递归）：本脚本要"用真自检验证判定"，而自检又会回头调本脚本 →
#    自检→测试→自检→测试…几分钟起了上千个 powershell 进程。
#    这里先把"测试正在跑"标出来，自检看到它就不再回头调测试；同时强制跳过自检里的自测环节。
$env:DSH_SELFTEST_RUNNING = '1'
$env:DSH_SKIP_SELFTEST = '1'

$root = Split-Path -Parent $PSScriptRoot
$selfCheck = Join-Path $PSScriptRoot '自检.ps1'
$tmpDir = Join-Path $env:TEMP ('dsh-model-watch-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

function New-FakeLog([string[]]$roundLines) {
  $path = Join-Path $tmpDir ('log-' + [guid]::NewGuid().ToString('N') + '.txt')
  $lines = @()
  $t = (Get-Date).AddMinutes(-30)
  $lines += ('[{0}] 插件已装载：每 600s 扫一次，首次 20s 后运行，模型 deepseek-account/deepseek-flash' -f $t.ToString('yyyy/MM/dd HH:mm:ss'))
  foreach ($r in $roundLines) {
    $t = $t.AddMinutes(1)
    $lines += ('[{0}] {1}' -f $t.ToString('yyyy/MM/dd HH:mm:ss'), $r)
  }
  # UTF-8（带 BOM 无妨：自检按 UTF8 读）；时间戳是"最近"的，避免被判成陈旧行
  [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($true)))
  return $path
}

function Get-ModelCheck([string]$logPath) {
  # 每次都开**真子进程**跑完整自检（最忠实：连自检自己的加载/收尾都一起验）
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $selfCheck -Quiet -PluginLogPath $logPath 2>&1
  # 注意：判定为"还没跑过一轮"时这条叫 '模型观测'（故意的，见 自检.ps1 里那段注释）
  $line = @($out | Where-Object { $_ -match '\[(GREEN|YELLOW|RED)\] *(模型|模型 token|模型观测) ' })
  if ($line.Count -eq 0) { return @{ level = '(没找到这条检查)'; text = ($out -join ' / ') } }
  $l = $line[-1]
  $m = [regex]::Match($l, '\[(GREEN|YELLOW|RED)\]')
  return @{ level = $m.Groups[1].Value; text = ($l -replace '^\s*\[[^\]]+\]\s*', '') }
}

$ok10 = '抽出 2 条，新增 1 条，累计 10 条（2500ms；预筛保留 2/2）'
$fail = '模型调用失败（模型调用超时（180000ms））'

$cases = @(
  @{
    name = '连续 10 轮全部超时（当天上午那种）'
    expect = 'RED'
    lines = @(1..10 | ForEach-Object { '本轮处理 1 条采集记录（本地预筛保留 1 条候选、筛掉 0 条 0 字），调用模型 deepseek-account/deepseek-flash …' }) +
            @(1..10 | ForEach-Object { $fail })
  },
  @{
    name = '最近 2 轮明确 token 错误（401 insufficient）'
    expect = 'RED'
    lines = @($ok10, $ok10, $ok10, '模型调用失败（401 Unauthorized: insufficient balance）', '模型调用失败（401 Unauthorized: insufficient balance）')
  },
  @{
    name = '一半成功一半超时（劣化，但还没全挂）'
    expect = 'YELLOW'
    lines = @($ok10, $fail, $ok10, $fail, $ok10, $fail, $ok10)
  },
  @{
    name = '调用没失败，但成功轮普遍很慢（95s）'
    expect = 'YELLOW'
    lines = @(1..5 | ForEach-Object { '抽出 1 条，新增 0 条，累计 10 条（95000ms；预筛保留 1/1）' })
  },
  @{
    name = '【假阳性】单轮"提示词过长"（不是额度问题，不该报 token 红灯）'
    expect = 'GREEN'
    lines = @($ok10, $ok10, $ok10, $ok10, '模型调用失败（maximum context length is 65536 tokens）')
  },
  @{
    name = '【假阳性】全新机器：只有"插件已装载"、还没跑过一轮'
    expect = 'GREEN'
    lines = @()
  }
)

Write-Host '=== 模型告警判定测试（假日志 + 真子进程跑自检）===' -ForegroundColor Cyan
$pass = 0
foreach ($c in $cases) {
  $log = New-FakeLog $c.lines
  $r = Get-ModelCheck $log
  $ok = ($r.level -eq $c.expect)
  if ($ok) { $pass++ }
  $mark = if ($ok) { 'PASS' } else { 'FAIL' }
  $color = if ($ok) { 'Green' } else { 'Red' }
  Write-Host ("{0}  {1,-34} 期望={2,-6} 实际={3}" -f $mark, $c.name, $c.expect, $r.level) -ForegroundColor $color
  if (-not $ok) { Write-Host ("        {0}" -f ($r.text.Substring(0, [Math]::Min(160, $r.text.Length)))) -ForegroundColor DarkGray }
}
Write-Host ("`n{0}/{1} 通过" -f $pass, $cases.Count)

# ── 附加：真推一条到手机（确认"劣化"这条黄灯真的会推，而不是只写日志）──
if ($AllowTestPush) {
  Write-Host "`n=== 真实推送测试（会给你手机发一条 模型劣化 告警）===" -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'logs') | Out-Null
  # ⚠️ 自检的"告警去重状态"要先备份：这次真跑会往里写签名，不还原的话真出事时同类告警会被压 6 小时
  $alertFile = Join-Path $PSScriptRoot 'logs\自检-已告警.json'
  $alertBak = $null
  if (Test-Path -LiteralPath $alertFile) {
    $alertBak = Get-Content -LiteralPath $alertFile -Raw -Encoding UTF8
    Write-Host '  （已备份去重状态，跑完会还原）' -ForegroundColor DarkGray
  }
  $log = New-FakeLog @($ok10, $fail, $ok10, $fail, $ok10, $fail, $ok10)
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $selfCheck -PluginLogPath $log -StaleMinutes 900 2>&1
  foreach ($l in @($out | Where-Object { $_ -match '已推手机|手机推送失败|不打扰|不重复打扰|夜间' })) {
    Write-Host ('  ' + ($l -replace '^\s*\[[^\]]+\]\s*', ''))
  }
  $tail = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'logs\自检.log') -Encoding UTF8 -Tail 25 -ErrorAction SilentlyContinue)
  $pushed = @($tail | Where-Object { $_ -match '已推手机：\s*(wecom|dingtalk|email|ntfy|wecomApp|wechat)' })
  $noneLine = @($tail | Where-Object { $_ -match '已推手机：\s*(none|disabled)' })
  if ($pushed.Count -gt 0) { Write-Host ('  ✅ 推送成功且走了通道：' + ($pushed[-1] -replace '^\s*\[[^\]]+\]\s*', '')) -ForegroundColor Green }
  elseif ($noneLine.Count -gt 0) { Write-Host '  ❌ 推送没走通（返回 none/disabled）—— 手机上收不到！检查 提醒配置.json 与网络/代理' -ForegroundColor Red }
  else { Write-Host '  ⚠️ 没看到推送结果（可能刚好被 6 小时去重挡住，属正常）' -ForegroundColor Yellow }
  Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
  if ($null -ne $alertBak) {
    [System.IO.File]::WriteAllText($alertFile, $alertBak, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '  🧹 已还原去重状态' -ForegroundColor DarkGray
  }
}

Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
exit $(if ($pass -eq $cases.Count) { 0 } else { 1 })
