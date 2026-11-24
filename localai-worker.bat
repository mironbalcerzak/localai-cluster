@echo off
rem LocalAI cluster worker for Windows. Double-click, or: localai-worker.bat [start|stop|logs|status|update]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0localai-worker.ps1" %*
set RC=%ERRORLEVEL%
rem Keep the window open when started by double-click.
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %RC%
