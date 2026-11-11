#!/bin/bash
# Paso 5 (cada vez que cambie el hardware): mete un bitstream nuevo en la imagen
# sin recompilar nada mas (segundos). No necesita Quartus en Linux.
#
# Uso, desde <repositorio>/Linux:
#   git pull && bash scripts/05-actualizar-rbf.sh          (el .rbf llego por git)
#   bash scripts/05-actualizar-rbf.sh /ruta/soc_system.rbf  (desde una USB u otra ruta)
set -e
source "$(dirname "$0")/config.sh"
requiere_buildroot
preparar_permisos

if [ -n "$1" ]; then
    [ -f "$1" ] || { echo "No existe $1"; exit 1; }
    case "$1" in *.rbf) ;; *) echo "Se esperaba un .rbf (el .sof se convierte en Windows con windows/generar-rbf.bat)"; exit 1;; esac
    cp -v "$1" "$RBF"
fi
[ -f "$RBF" ] || { echo "No hay $RBF. Generalo en Windows con windows/generar-rbf.bat y haz git pull."; exit 1; }
echo "Bitstream: $RBF ($(du -h "$RBF" | cut -f1), $(date -r "$RBF" '+%d/%m/%Y %H:%M'))"

[ -f "$OUT/images/rootfs.ext4" ] || { echo "Aun no hay imagen base. Corre primero: bash scripts/03-compilar.sh"; exit 1; }
make -C "$OUT"
echo "Imagen actualizada: $OUT/images/sdcard.img  ->  bash scripts/06-grabar-sd.sh /dev/sdX"
