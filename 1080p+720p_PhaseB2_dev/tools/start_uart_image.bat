@echo off
cd /d "%~dp0"
python -X utf8 uart_image_sender.py --gui
if errorlevel 1 pause
