@echo off
setlocal

if defined PYTHON_EXE goto run

if exist "%~dp0..\.venv\Scripts\python.exe" set "PYTHON_EXE=%~dp0..\.venv\Scripts\python.exe"
if defined PYTHON_EXE goto run

for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python*") do if not defined PYTHON_EXE if exist "%%~fD\python.exe" set "PYTHON_EXE=%%~fD\python.exe"
if not defined PYTHON_EXE set "PYTHON_EXE=python"

:run
"%PYTHON_EXE%" %*
exit /b %errorlevel%
