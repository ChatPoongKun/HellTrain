@echo off
cd /d "%~dp0"
call _python.bat -m pip install --disable-pip-version-check -r requirements.txt
