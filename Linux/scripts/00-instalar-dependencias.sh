#!/bin/bash
# Paso 0 (una vez): paquetes del host para Buildroot (Ubuntu 22.04 o 24.04).
# Uso, desde <repositorio>/Linux:   bash scripts/00-instalar-dependencias.sh
set -e
source "$(dirname "$0")/config.sh"
sudo apt-get update
sudo apt-get install -y \
    build-essential git rsync bc cpio unzip file wget curl patch perl \
    python3 python3-setuptools libncurses-dev libssl-dev \
    gawk diffutils findutils bzip2 gzip tar ccache u-boot-tools
preparar_permisos
echo "Listo. Nucleos: $(nproc), RAM: $(free -g | awk '/Mem/{print $2}') GB, libre en $HOME: $(df -h "$HOME" | awk 'NR==2{print $4}')"
