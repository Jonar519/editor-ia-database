@echo off
rem Uso: scripts\db-migrate.bat dev [--estado]    aplica (o muestra) migraciones en la base de desarrollo
rem      scripts\db-migrate.bat test [--estado]   aplica (o muestra) migraciones en la base de pruebas
setlocal
pushd "%~dp0.."
call npm run -s migrate -- %*
set "CODIGO=%ERRORLEVEL%"
popd
exit /b %CODIGO%
