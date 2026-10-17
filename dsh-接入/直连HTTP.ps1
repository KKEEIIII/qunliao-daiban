# 直连HTTP.ps1 —— 出站 HTTP 统一助手：**默认直连（绕开系统代理）+ 失败重试**
#
# ⚠️ 为什么必须有这个（2026-10-15 实测踩的"静默全挂"）：
#   这台机器开着**系统代理**（HKCU Internet Settings: ProxyEnable=1, ProxyServer=127.0.0.1:<旧代理端口>），
#   而那个代理进程经常不在（netstat 显示 <旧代理端口> 一直 SYN_SENT、没人监听）。
#   PowerShell 的 `Invoke-RestMethod` / `Invoke-WebRequest` **默认走系统代理** →
#   报"无法连接到远程服务器" → **所有手机推送、入站拉取全部静默失败**
#   （而模型调用走的是另一条路，所以会出现"待办能抽出来、手机却收不到任何提醒"这种诡异组合）。
#   实测对照（同一时刻、同一 URL）：
#     Invoke-RestMethod 默认       → 失败：无法连接到远程服务器
#     .NET WebClient 且 Proxy=$null → OK：{"errcode":0,"errmsg":"ok"}
#   `curl.exe` 也正常（它不吃 Windows 系统代理设置）。
#   注意：`-Proxy ''` 在 PS 5.1 上不可用（会报"相对 URI 不支持此操作"），别走那条路。
#   另外 `127.0.0.1` 通常被代理绕过列表覆盖（本地 DSH API 不受影响），但**外网一律受影响**。
#
# 用法：. "$PSScriptRoot\直连HTTP.ps1"
#        $r = Invoke-DirectHttp -Uri $url -Body ([Text.Encoding]::UTF8.GetBytes($json))
#        $r2 = Invoke-DirectHttpGet -Uri $url

# ⚠️ 2026-10-15 修「-TimeoutSec 是死参数」（另一个 AI 在真机上量出来的）：
# 原来只 new 一个 WebClient —— 它**不接受超时设置**，实际超时是 .NET 默认（约 100 秒），
# 于是"20 秒超时"是假的。后果链：一次黑洞连接（正是 127.0.0.1:<旧代理端口> SYN_SENT 那类）最坏
# 2 次重试 × 2 个分支 × 100s；而提醒器的单实例锁只保护 5 分钟 → 慢推送与下一轮重叠、锁被抢走
# → **同一条待办重复提醒**（正是提醒器注释里说踩过的坑）。
# 修法：派生一个 WebClient 覆写 GetWebRequest，把 Timeout / ReadWriteTimeout 真正设上。
if (-not ('DshDirectWebClient' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Net;
public class DshDirectWebClient : WebClient {
    public int TimeoutMs = 20000;
    public bool UseDefaultProxy = false;
    protected override WebRequest GetWebRequest(Uri address) {
        WebRequest r = base.GetWebRequest(address);
        if (r != null) {
            r.Timeout = TimeoutMs;
            if (r is HttpWebRequest) { ((HttpWebRequest)r).ReadWriteTimeout = TimeoutMs; }
        }
        if (!UseDefaultProxy) { this.Proxy = null; }
        return r;
    }
}
'@ -ErrorAction Stop
}

function New-DirectClient([int]$TimeoutSec, [bool]$UseProxy = $false, [string]$ContentType = 'application/json; charset=utf-8', [hashtable]$Headers = @{}) {
  $c = New-Object DshDirectWebClient
  $c.TimeoutMs = [Math]::Max(1, $TimeoutSec) * 1000
  $c.UseDefaultProxy = $UseProxy
  $c.Proxy = $null
  if ($ContentType) { $c.Headers.Add('Content-Type', $ContentType) }
  foreach ($k in $Headers.Keys) { $c.Headers.Add([string]$k, [string]$Headers[$k]) }
  return $c
}

function Invoke-DirectHttp {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][byte[]]$Body,
    [string]$ContentType = 'application/json; charset=utf-8',
    [int]$TimeoutSec = 20,
    [int]$Retry = 2,
    [hashtable]$Headers = @{}
  )
  $lastErr = ''
  for ($i = 1; $i -le [Math]::Max(1, $Retry); $i++) {
    # ① 直连（绕开系统代理）
    try {
      $wc = New-DirectClient -TimeoutSec $TimeoutSec -ContentType $ContentType -Headers $Headers
      $resp = [Text.Encoding]::UTF8.GetString($wc.UploadData($Uri, 'POST', $Body))
      # 非 JSON 响应不要静默当成"成功"（排障时看到 errcode= 全空会一头雾水）
      try { return ($resp | ConvertFrom-Json) }
      catch {
        Write-Host ("  [直连HTTP] 响应不是 JSON（前 120 字）：" + $resp.Substring(0, [Math]::Min(120, $resp.Length)))
        return $resp
      }
    } catch {
      $lastErr = $_.Exception.Message
      # ② 兜底：万一以后真的需要代理（比如被墙的通道），再试一次"走系统代理"
      try {
        $wcp = New-DirectClient -TimeoutSec $TimeoutSec -UseProxy $true -ContentType $ContentType -Headers $Headers
        $resp2 = [Text.Encoding]::UTF8.GetString($wcp.UploadData($Uri, 'POST', $Body))
        try { return ($resp2 | ConvertFrom-Json) } catch { return $resp2 }
      } catch { $lastErr = $_.Exception.Message }
    }
    if ($i -lt $Retry) { Start-Sleep -Milliseconds 800 }   # 网络抖动：等一下再试
  }
  throw (New-Object System.Exception("直连失败（已重试 $Retry 次）：$lastErr"))
}

function Invoke-DirectHttpGet {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = 20
  )
  try {
    $wc = New-DirectClient -TimeoutSec $TimeoutSec -ContentType ''
    return ([Text.Encoding]::UTF8.GetString($wc.DownloadData($Uri)) | ConvertFrom-Json)
  } catch {
    $wc2 = New-DirectClient -TimeoutSec $TimeoutSec -UseProxy $true -ContentType ''   # 兜底：走系统代理
    return ([Text.Encoding]::UTF8.GetString($wc2.DownloadData($Uri)) | ConvertFrom-Json)
  }
}

function Get-DirectHttpText {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$Retry = 2,
    [int]$TimeoutSec = 20
  )
  $lastErr = ''
  for ($i = 1; $i -le [Math]::Max(1, $Retry); $i++) {
    try {
      $wc = New-DirectClient -TimeoutSec $TimeoutSec -ContentType ''
      return [Text.Encoding]::UTF8.GetString($wc.DownloadData($Uri))
    } catch { $lastErr = $_.Exception.Message }
    if ($i -lt $Retry) { Start-Sleep -Milliseconds 800 }
  }
  throw (New-Object System.Exception("直连失败（已重试 $Retry 次）：$lastErr"))
}
