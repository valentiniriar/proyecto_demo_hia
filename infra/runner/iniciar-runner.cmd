@echo off
rem Lanzador del runner de GymHub (SCRUM-57).
rem Pone Git Bash antes que C:\Windows\System32\bash.exe (WSL): los pasos "shell: bash" del CD usan Git Bash.
title Runner GymHub (NO CERRAR)
set PATH=C:\Program Files\Git\bin;%PATH%
cd /d "%~dp0"
echo Carpeta: %CD%
call "%~dp0run.cmd"
