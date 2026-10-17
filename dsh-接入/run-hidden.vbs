' run-hidden.vbs -- launch a PowerShell script with NO console window at all.
'
' Why this exists:
'   The scheduled tasks used to call:  powershell -WindowStyle Hidden -File xxx.ps1
'   That still FLASHES a console window every run: Windows allocates the console for
'   powershell.exe first, and PowerShell only hides it after it has started parsing.
'   With a task running every 1-5 minutes the user sees a black window popping up all day.
'
'   wscript.exe is a GUI-subsystem host (no console of its own), so a process it starts
'   with window style 0 (SW_HIDE) never gets a visible console window.
'
' Usage (this is what the scheduled tasks now call):
'   wscript.exe "C:\...\run-hidden.vbs" "C:\...\some.ps1" -Arg1 -Arg2
'
' Note: keep this file ASCII-only -- VBScript files are read as ANSI, so non-ASCII
'       characters would be garbled.
Option Explicit
Dim sh, cmd, i, a
If WScript.Arguments.Count = 0 Then
  WScript.Quit 2
End If
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
  a = WScript.Arguments(i)
  If InStr(a, " ") > 0 Then
    a = """" & a & """"
  End If
  cmd = cmd & " " & a
Next
' 0 = hidden window, False = do not wait for it to finish
sh.Run cmd, 0, False
