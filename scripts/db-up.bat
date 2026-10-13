@echo off
rem Levanta cuaderno_postgres (127.0.0.1:5435) y cuaderno_redis (127.0.0.1:6381) y espera a que esten sanos.
setlocal
pushd "%~dp0.."
if not exist ".env" (
  echo Falta .env. Ejecuta primero: scripts\env-init.bat
  popd
  exit /b 1
)
docker compose up -d --wait
set "CODIGO=%ERRORLEVEL%"
popd
exit /b %CODIGO%
