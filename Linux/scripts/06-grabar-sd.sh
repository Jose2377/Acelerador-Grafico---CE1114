#!/bin/bash
# Paso 6: graba sdcard.img en la microSD.
# Uso, desde <repositorio>/Linux:   bash scripts/06-grabar-sd.sh /dev/sdX   (ver con: lsblk)
set -e
source "$(dirname "$0")/config.sh"
DEV="$1"; IMG="$OUT/images/sdcard.img"
[ -f "$IMG" ] || { echo "No existe $IMG. Corre primero: bash scripts/03-compilar.sh"; exit 1; }
[ -b "$DEV" ] || { echo "Uso: bash $0 /dev/sdX"; lsblk -d -o NAME,SIZE,MODEL,TRAN; exit 1; }
case "$DEV" in /dev/sda|/dev/nvme0n1|/dev/vda) echo "Eso parece tu disco del sistema. Abortado."; exit 1;; esac
lsblk "$DEV"
read -r -p "Se BORRARA todo $DEV. Escribe SI para continuar: " ok
[ "$ok" = "SI" ] || exit 1
sudo umount "${DEV}"* 2>/dev/null || true
sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
echo "Listo. Inserta la SD en la DE1-SoC."
