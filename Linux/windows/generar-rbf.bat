@echo off
REM generar-rbf.bat  (Windows, Quartus Prime 18.1 Lite)
REM Convierte FPGA\output_files\Acelerador_Grafico.sof en un .rbf comprimido
REM (lo que U-Boot carga con "fpga load") y lo deja en
REM Linux\br2-external\board\de1soc\fpga\soc_system.rbf, dentro del repositorio.
REM Las rutas se calculan desde la ubicacion de este archivo: doble clic y listo.
REM Despues: commit + push, y en Linux: git pull && bash scripts/05-actualizar-rbf.sh

set "QBIN=C:\intelFPGA_lite\18.1\quartus\bin64"
set "SOF=%~dp0..\..\FPGA\output_files\Acelerador_Grafico.sof"
set "DEST=%~dp0..\br2-external\board\de1soc\fpga\soc_system.rbf"

if not exist "%QBIN%\quartus_cpf.exe" (
  echo No se encontro Quartus en "%QBIN%". Ajusta QBIN en este archivo.
  pause & exit /b 1
)
if not exist "%SOF%" (
  echo No se encontro "%SOF%". Compila el proyecto en Quartus primero.
  pause & exit /b 1
)

"%QBIN%\quartus_cpf.exe" -c -o bitstream_compression=on "%SOF%" "%DEST%"
if errorlevel 1 (
  echo quartus_cpf fallo.
  pause & exit /b 1
)
echo.
echo Generado: "%DEST%"
echo Ahora: git add Linux/br2-external/board/de1soc/fpga/soc_system.rbf, commit y push.
pause
