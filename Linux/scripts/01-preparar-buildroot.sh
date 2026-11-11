#!/bin/bash
# Paso 1 (una vez): descarga Buildroot LTS y aplica la configuracion de la DE1-SoC.
# Uso, desde <repositorio>/Linux:   bash scripts/01-preparar-buildroot.sh
set -e
source "$(dirname "$0")/config.sh"
preparar_permisos
mkdir -p "$BASE"
if [ ! -d "$BR_DIR" ]; then
    git clone --depth 1 --branch "$BR_VERSION" https://gitlab.com/buildroot.org/buildroot.git "$BR_DIR"
fi
make -C "$BR_DIR" O="$OUT" BR2_EXTERNAL="$EXT" de1soc_defconfig
echo "Configuracion aplicada en $OUT"
echo "Siguiente: bash scripts/02-descargar-fuentes.sh  (opcional)  o  bash scripts/03-compilar.sh"
