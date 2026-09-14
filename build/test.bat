@echo off
cd /d "%~dp0"
call _python.bat ..\.agents\tests\RuntimeRegression\check_runtime_regressions.py --fast
