@echo off
rem Wrapper: Windows blocks unsigned .ps1 by default, so bypass the policy here.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fanout.ps1" %*
