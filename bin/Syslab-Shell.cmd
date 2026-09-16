@echo off
rem Open a Julia REPL inside the MWORKS Syslab environment.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-SyslabShell.ps1" %*
endlocal
