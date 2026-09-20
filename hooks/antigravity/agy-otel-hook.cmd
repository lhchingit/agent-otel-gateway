@echo off
rem Antigravity CLI hook wrapper: cmd.exe mangles a command line that starts with a
rem quoted path and contains further quotes, so hooks.json points here instead.
"%~dp0Scripts\python.exe" "%~dp0hook.py" %*
