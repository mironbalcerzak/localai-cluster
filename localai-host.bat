@echo off
rem LocalAI host (cluster server) for Windows. Double-click, or:
rem   localai-host.bat [start|stop|update|status|logs|worker-env|nodes|api-key]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0localai-host.ps1" %*
set RC=%ERRORLEVEL%
rem Keep the window open when started by double-click.
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %RC%
