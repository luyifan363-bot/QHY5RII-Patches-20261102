@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Manage-PHD2.ps1" -Action Install
