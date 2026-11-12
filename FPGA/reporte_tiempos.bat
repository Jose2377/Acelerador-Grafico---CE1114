@echo off
REM Genera output_files\caminos_criticos.txt con los caminos que fallan a 100 MHz
cd /d "%~dp0"
"C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sta.exe" -t reporte_tiempos.tcl
echo.
echo Listo: output_files\caminos_criticos.txt
pause
