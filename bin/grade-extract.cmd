@echo off
rem Grade available models on the shared 10 KB extraction task.
rem   grade-extract.cmd                - every model
rem   grade-extract.cmd -Light         - free + keyless only
rem   grade-extract.cmd -Only zhipu    - labels containing "zhipu"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0grade-extract.ps1" %*
