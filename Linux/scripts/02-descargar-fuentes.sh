#!/bin/bash
# Paso 2 (opcional): descarga TODAS las fuentes (~1 GB) sin compilar, para luego
# compilar sin red. Uso, desde <repositorio>/Linux:   bash scripts/02-descargar-fuentes.sh
set -e
source "$(dirname "$0")/config.sh"
requiere_buildroot
make -C "$OUT" source
echo "Fuentes en $BASE/dl"
