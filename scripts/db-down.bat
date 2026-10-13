@echo off
rem Detiene los contenedores de Cuaderno. Los datos se conservan en los volumenes de Docker.
setlocal
pushd "%~dp0.."
docker compose stop
set "CODIGO=%ERRORLEVEL%"
popd
exit /b %CODIGO%
