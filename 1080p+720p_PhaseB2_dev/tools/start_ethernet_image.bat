@echo off
cd /d "%~dp0"
py -3 ethernet_image_host.py --bridge
pause
