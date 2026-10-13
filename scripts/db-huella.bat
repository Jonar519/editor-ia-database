@echo off
rem Huella de SOLO LECTURA de la base de desarrollo (filas por tabla y hash del esquema).
rem Uso: scripts\db-huella.bat tomar <etiqueta>
rem      scripts\db-huella.bat comparar <etiqueta> [<otra>]
setlocal
pushd "%~dp0.."
call npm run -s huella -- %*
set "CODIGO=%ERRORLEVEL%"
popd
exit /b %CODIGO%
