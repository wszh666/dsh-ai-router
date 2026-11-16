@echo off
rem Smoke-test every model channel and print one table.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0smoke.ps1" %*
