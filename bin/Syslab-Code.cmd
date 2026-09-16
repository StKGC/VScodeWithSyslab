@echo off
rem Launch VS Code with the full MWORKS Syslab environment.
rem Usage: Syslab-Code.cmd [vscode arguments...]
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-SyslabCode.ps1" %*
endlocal
