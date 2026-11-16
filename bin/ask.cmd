@echo off
rem One-shot question to the free models, with automatic fallback.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ask.ps1" %*
