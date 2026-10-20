# 读微信发来的图片 → Windows OCR（PS 5.1 WinRT 投影）
param([string]$Img)
. (Join-Path $PSScriptRoot 'wxlib.ps1') | Out-Null
$rows = Invoke-WxOcr -Path $Img -Scale 1
$rows | Sort-Object y | ForEach-Object { Write-Output ("{0,5} | {1}" -f $_.y, $_.text) }
Write-Output ("[rows: " + $rows.Count + "]")
