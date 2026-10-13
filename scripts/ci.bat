@echo off
rem Corre localmente los mismos pasos que el CI de GitHub Actions y muestra el codigo de salida REAL de cada uno.
rem Requiere los contenedores arriba (scripts\db-up.bat).
setlocal EnableDelayedExpansion
pushd "%~dp0.."
set "N=0"
set "FALLOS=0"

call :paso "lint"        "npm run -s lint"
call :paso "typecheck"   "npm run -s typecheck"
call :paso "test:unit"   "npm run -s test:unit"
call :paso "test:sql"    "npm run -s test:sql"
call :paso "mutaciones"  "npm run -s mutate"
call :paso "npm audit"   "npm audit --audit-level=high"
call :paso "gitleaks"    "scripts\gitleaks.bat"

echo.
echo ===== Resumen CI local =====
for /l %%i in (1,1,!N!) do echo   !R%%i!
echo (este repo no tiene paso de build: no hay nada que compilar)
popd
if "!FALLOS!"=="0" (
  echo RESULTADO: OK
  exit /b 0
)
echo RESULTADO: FALLO
exit /b 1

:paso
set "NOMBRE=%~1"
echo.
echo ===== !NOMBRE! =====
call %~2
set "CODIGO=!ERRORLEVEL!"
set /a N+=1
set "R!N!=!NOMBRE!: exit !CODIGO!"
if not "!CODIGO!"=="0" set "FALLOS=1"
exit /b 0
