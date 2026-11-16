@echo off
rem Validate cordis.patch.yml and the route/whitelist cross-check.
node "%~dp0check-patch.cjs" %*
