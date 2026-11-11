#!/bin/bash
# Paso 3: compilacion completa (toolchain -> U-Boot/SPL -> kernel + dtb -> rootfs
# -> sdcard.img). La primera vez tarda 30-60 min; las siguientes, minutos.
# Uso, desde <repositorio>/Linux:   bash scripts/03-compilar.sh
#
# Toma el bitstream de br2-external/board/de1soc/fpga/soc_system.rbf, que llega
# por git (lo genera windows/generar-rbf.bat). Si no esta, la imagen se arma
# igual pero U-Boot no programa la FPGA ni habilita los puentes.
set -e
source "$(dirname "$0")/config.sh"
requiere_buildroot
preparar_permisos

if [ -f "$RBF" ]; then
    echo "Bitstream: $RBF ($(du -h "$RBF" | cut -f1), $(date -r "$RBF" '+%d/%m/%Y %H:%M'))"
else
    echo "AVISO: no hay $RBF"
    echo "       La imagen arrancara Linux SIN programar la FPGA."
    echo "       Generalo en Windows (windows/generar-rbf.bat), haz commit + push y aqui: git pull"
    read -r -p "Continuar sin bitstream? [s/N] " r
    [ "$r" = "s" ] || [ "$r" = "S" ] || exit 1
fi

LOG="$OUT/build-$(date +%Y%m%d-%H%M).log"
echo "Compilando con $(nproc) nucleos. Bitacora: $LOG"
time make -C "$OUT" 2>&1 | tee "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "Fallo la compilacion. Revisa el final de $LOG"; exit 1; }
echo
ls -lh "$OUT/images/"
echo "Imagen para la SD: $OUT/images/sdcard.img"
