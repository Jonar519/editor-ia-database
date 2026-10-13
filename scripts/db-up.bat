@echo off
rem Levanta cuaderno_postgres (127.0.0.1:5435) y cuaderno_redis (127.0.0.1:6381) y espera a que esten sanos.
rem Crea o completa .env (scripts\env-init.mjs) y habilita el LOGIN del rol cuaderno_app.
setlocal
pushd "%~dp0.."
node scripts\env-init.mjs
if errorlevel 1 goto :fallo
docker compose up -d --wait
if errorlevel 1 goto :fallo
node --env-file=.env scripts\usuario-app.mjs
if errorlevel 1 goto :fallo
popd
exit /b 0

:fallo
popd
exit /b 1
