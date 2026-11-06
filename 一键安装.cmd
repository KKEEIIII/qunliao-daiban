@echo off
rem ============================================================
rem  一键安装.cmd -- 双击我，全程自动装完（不用回答任何问题）
rem
rem  为什么有这个文件：
rem    从 GitHub 下载后，老流程要"解压 → 打开 PowerShell → 敲一长串命令 → 回答问题"，
rem    对普通用户太啰嗦。这里把能自动的都自动掉，只留"双击"这一个动作。
rem
rem  它能自己处理两种情况：
rem    1) 你旁边有 群聊待办-部署包-*.zip  -> 自动解压到 %LOCALAPPDATA%\群聊待办-安装 再装
rem    2) 你已经解压好了（本文件旁边就有 安装.ps1 或 发布\安装.ps1）-> 直接装
rem
rem  本文件必须按 ANSI/GBK 保存且**不能有 BOM**（cmd.exe 按 ANSI 读，BOM 会让第 1 行就语法错）
rem ============================================================
chcp 936 >nul
setlocal enabledelayedexpansion
title 群聊待办 - 一键安装
cd /d "%~dp0"

echo.
echo  ============================================================
echo    群聊待办 - 一键安装
echo  ============================================================
echo.

rem ---------- 找安装器：先看当前目录，再看 发布\ 子目录 ----------
set "PS1="
if exist "%~dp0安装.ps1"          set "PS1=%~dp0安装.ps1"
if not defined PS1 if exist "%~dp0发布\安装.ps1" set "PS1=%~dp0发布\安装.ps1"

rem ---------- 没找到安装器：看看旁边有没有部署包 zip，自动解压 ----------
if not defined PS1 (
  set "ZIP="
  for %%f in ("%~dp0群聊待办-部署包-*.zip") do set "ZIP=%%~ff"
  if not defined ZIP (
    echo  [错误] 这里既没有 安装.ps1，也没有 群聊待办-部署包-*.zip
    echo.
    echo  请确认：下载的是发布包 zip，或已经把 zip 解压出来了。
    echo  下载地址：https://github.com/KKEEIIII/qunliao-daiban/releases/latest
    echo.
    pause
    exit /b 1
  )
  echo  发现部署包：!ZIP!
  set "DEST=%LOCALAPPDATA%\群聊待办-安装"
  echo  正在解压到：!DEST!
  if exist "!DEST!" rd /s /q "!DEST!" 2>nul
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '!ZIP!' -DestinationPath '!DEST!' -Force"
  if errorlevel 1 (
    echo  [错误] 解压失败。请手动右键 zip 解压，然后双击里面的 一键安装.cmd
    pause
    exit /b 1
  )
  if exist "!DEST!\安装.ps1"          set "PS1=!DEST!\安装.ps1"
  if not defined PS1 if exist "!DEST!\发布\安装.ps1" set "PS1=!DEST!\发布\安装.ps1"
  if not defined PS1 (
    rem 有些包会多套一层目录
    for /d %%d in ("!DEST!\*") do (
      if exist "%%d\安装.ps1"          set "PS1=%%d\安装.ps1"
      if not defined PS1 if exist "%%d\发布\安装.ps1" set "PS1=%%d\发布\安装.ps1"
    )
  )
  if not defined PS1 (
    echo  [错误] 解压后在包里找不到 安装.ps1 —— 包可能不完整，请重新下载。
    pause
    exit /b 1
  )
)

echo  安装器：!PS1!
echo.
echo  接下来全自动，不需要你回答问题。
echo  预计 1-3 分钟（首次会下载 Maa 后台组件约 79MB，网慢会更久）。
echo.
echo  ------------------------------------------------------------
echo.

rem -Yes = 全部用默认值（无人值守）。其余参数保持默认：
rem   · 会建计划任务、挂插件、注册通知、做布局标定、最后打开控制台
rem 额外参数透传（例如 -DryRun 只看会做什么；-SkipMaa 跳过 79MB 下载）
powershell -NoProfile -ExecutionPolicy Bypass -File "!PS1!" -Yes %*
set "RC=%errorlevel%"

echo.
echo  ------------------------------------------------------------
if not "%RC%"=="0" (
  echo  [安装未完成] 退出码 %RC%
  echo.
  echo  常见原因：
  echo    · 没装 DSH（本工具是 DSH 的插件，必须先有 DSH）
  echo    · DSH 从没启动过（第一次启动会创建 profile，之后重跑本文件即可）
  echo    · 被安全软件拦了 PowerShell
  echo  详细日志就在上面，往上翻能看到停在哪一步。
  echo.
  pause
  exit /b %RC%
)

echo   [装好了] 最后一步：重启 DSH（插件是启动时装载的）
echo.
echo   重启后会自动帮你打开控制台页面，不用再找。
echo   以后想再打开：双击 群聊待办\打开控制台.cmd
echo.
timeout /t 20 >nul
exit /b 0
