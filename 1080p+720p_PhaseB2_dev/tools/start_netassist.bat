@echo off
setlocal
set "NETASSIST_EXE=%~dp0NetAssist\NetAssistv4325.exe"
if not exist "%NETASSIST_EXE%" (
    echo NetAssistv4325.exe was not found in tools\NetAssist.
    pause
    exit /b 1
)
start "" /D "%~dp0NetAssist" "%NETASSIST_EXE%"
endlocal
