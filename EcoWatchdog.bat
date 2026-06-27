@echo off
rem Run the watchdog from the batch file's directory
powershell -ExecutionPolicy Bypass -File "%~dp0EcoWatchdog.ps1"