@echo off
rem ZCode Windows 7 offline installer (folder form).
rem Run as Administrator: right-click -> Run as administrator.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%errorlevel%"
if not "%RC%"=="0" pause
exit /b %RC%
