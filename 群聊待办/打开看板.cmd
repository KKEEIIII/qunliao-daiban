@echo off
rem 固定用 GBK 代码页：本文件是 ANSI/GBK 保存的，在 chcp 65001 的终端里也能正确解析中文路径
chcp 936 >nul
rem 打开看板.cmd -- 双击我：起本地看板服务（勾完点确定即写回）并自动打开页面。
rem 本文件按 ANSI/GBK 保存是有意的：.cmd 按 ANSI 读，写成 UTF-8 的话下面的中文路径会乱码找不到脚本。
setlocal
set "HERE=%~dp0"
if not exist "%HERE%生成看板.ps1" (
  echo [错误] 找不到 "%HERE%生成看板.ps1" —— 这个 .cmd 必须和 生成看板.ps1 放在同一个目录。
  pause
  exit /b 1
)
rem 用 wscript 静默拉起（不弹控制台窗口）：Windows Terminal 会忽略最小化指令，所以直接不建窗口更干净。
if not exist "%HERE%..\dsh-接入\run-hidden.vbs" (
  echo [提示] 没找到 run-hidden.vbs，改用可见窗口启动（关掉窗口即停服务）。
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%生成看板.ps1"
  pause
  exit /b 0
)
wscript.exe "%HERE%..\dsh-接入\run-hidden.vbs" "%HERE%生成看板.ps1" -Hidden
echo 已启动（无窗口）。页面会自动打开；勾完点确定即写回。
timeout /t 3 >nul
