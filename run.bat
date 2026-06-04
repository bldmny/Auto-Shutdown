@echo off
start "" powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -WindowStyle Hidden -File "%~dp0NetworkAutoShutdown-GUI.ps1"
