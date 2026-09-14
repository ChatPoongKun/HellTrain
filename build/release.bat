@echo off
cd /d "%~dp0"
call _python.bat ..\.agents\tests\RuntimeRegression\check_runtime_regressions.py
if errorlevel 1 exit /b %errorlevel%
call build.bat
