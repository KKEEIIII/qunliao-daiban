@echo off
rem 固定用 GBK 代码页：本文件是 ANSI/GBK 保存的，在 chcp 65001 的终端里也能正确解析中文路径
chcp 936 >nul
rem 打开控制台.cmd -- 双击我：起本地控制台服务（页面上点确定即生效）并自动打开页面。
rem 本文件按 ANSI/GBK 保存是有意的：.cmd 按 ANSI 读取，写成 UTF-8 的话中文路径会乱码找不到脚本。
setlocal
set "HERE=%~dp0"
if not exist "%HERE%控制台.ps1" (
  echo [错误] 找不到 "%HERE%控制台.ps1" —— 这个 .cmd 必须和 控制台.ps1 放在同一个目录。
  pause
  exit /b 1
)
rem 用 wscript 静默拉起（不弹控制台窗口）。用户要求"窗口别碍事"：
rem   你的默认终端是 Windows Terminal，它**忽略最小化指令**，所以这里直接不建窗口 = 比最小化更干净。
rem   服务状态看页面（右下角有「停止服务」）；地址留在 群聊待办\控制台-服务地址.txt，日志在 dsh-接入\logs\控制台服务.log。
if not exist "%HERE%..\dsh-接入\run-hidden.vbs" (
  echo [提示] 没找到 run-hidden.vbs，改用可见窗口启动（关掉窗口即停服务）。
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%控制台.ps1"
  pause
  exit /b 0
)
wscript.exe "%HERE%..\dsh-接入\run-hidden.vbs" "%HERE%控制台.ps1" -Hidden
echo 已启动（无窗口）。页面会自动打开；用完点页面右下角「停止服务」，或让它自己停。
timeout /t 3 >nul
