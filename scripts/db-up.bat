@echo off
rem Levanta cuaderno_postgres (127.0.0.1:5435) y cuaderno_redis (127.0.0.1:6381) y espera a que esten sanos.
rem Si no existe .env, lo genera primero con una contrasena local aleatoria (scripts\env-init.mjs).
setlocal
pushd "%~dp0.."
if not exist ".env" (
  node scripts\env-init.mjs
  if errorlevel 1 (
    popd
    exit /b 1
  )
)
docker compose up -d --wait
set "CODIGO=%ERRORLEVEL%"
popd
exit /b %CODIGO%
