@echo off
rem Terry's - exporta los productos de Agora para que Claude los revise (solo lectura).
powershell -ExecutionPolicy Bypass -File "%~dp0exportar-catalogo.ps1"
echo.
pause
