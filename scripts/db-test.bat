@echo off
rem Pruebas unitarias e integracion (Vitest) y pruebas SQL. Solo usan bases *_test.
rem Uso: scripts\db-test.bat [filtro de archivo SQL]
setlocal
pushd "%~dp0.."
call npm run -s test:unit
set "C1=%ERRORLEVEL%"
call npm run -s test:sql -- %*
set "C2=%ERRORLEVEL%"
echo.
echo test:unit exit=%C1%   test:sql exit=%C2%
popd
if not "%C1%"=="0" exit /b 1
if not "%C2%"=="0" exit /b 1
exit /b 0
