@echo off
rem Crea .env desde .env.example con una contrasena local aleatoria (no sobrescribe un .env existente).
setlocal
pushd "%~dp0.."
call npm run -s env:init
set "CODIGO=%ERRORLEVEL%"
popd
exit /b %CODIGO%
