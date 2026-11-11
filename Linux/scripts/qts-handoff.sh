#!/bin/bash
# Regenera los encabezados del preloader (SPL) desde FPGA/hps_isw_handoff/ con
# el generador incluido en U-Boot (tools/cv_bsp_generator). No necesita SoC EDS.
# Solo hace falta si cambias el HPS en Platform Designer.
# Uso, desde <repositorio>/Linux:   bash scripts/qts-handoff.sh   [carpeta del proyecto Quartus]
set -e
source "$(dirname "$0")/config.sh"
requiere_buildroot
PROJ="$(cd "${1:-$REPO/FPGA}" && pwd)"
HANDOFF="$(ls -d "$PROJ"/hps_isw_handoff/*/ | head -1)"
[ -f "$HANDOFF/hps.xml" ] || { echo "No hay hps_isw_handoff/*/hps.xml en $PROJ"; exit 1; }
UBOOT_SRC="$(ls -d "$OUT"/build/uboot-*/ 2>/dev/null | head -1)"
if [ -z "$UBOOT_SRC" ]; then
    make -C "$OUT" uboot-extract
    UBOOT_SRC="$(ls -d "$OUT"/build/uboot-*/ | head -1)"
fi
QTS_OUT="$EXT/board/de1soc/qts"
( cd "$UBOOT_SRC/tools/cv_bsp_generator" && \
  python3 cv_bsp_generator.py -i "$HANDOFF" -o "$QTS_OUT" )
ls -l "$QTS_OUT"
echo "Ahora: make -C $OUT uboot-dirclean all"
