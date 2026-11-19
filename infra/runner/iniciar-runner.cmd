@echo off
rem Lanzador del runner de GymHub (SCRUM-57).
rem Pone Git Bash antes que C:\Windows\System32\bash.exe (WSL): los pasos "shell: bash" del CD usan Git Bash.
title Runner GymHub (NO CERRAR)
set PATH=C:\Program Files\Git\bin;%PATH%
rem Configuracion propia del servidor (no versionada): por ejemplo GYMHUB_ENV_FILE con la ruta a
rem produccion\.env.prod del proyecto. Ver PRODUCCION.md, seccion 17.
if exist "%~dp0gymhub-env.cmd" call "%~dp0gymhub-env.cmd"
cd /d "%~dp0"
echo Carpeta: %CD%
echo GYMHUB_ENV_FILE=%GYMHUB_ENV_FILE%
call "%~dp0run.cmd"
