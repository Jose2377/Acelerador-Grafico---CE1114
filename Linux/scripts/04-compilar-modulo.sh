#!/bin/bash
# Paso 4 (cuando cambies el driver o el servicio): recompila SOLO esos dos
# paquetes (segundos) y regenera la imagen. Requiere haber corrido 03 una vez.
# Uso, desde <repositorio>/Linux:   bash scripts/04-compilar-modulo.sh
set -e
source "$(dirname "$0")/config.sh"
requiere_buildroot
preparar_permisos
make -C "$OUT" gpu2d-driver-rebuild gpu2d-servicio-rebuild all
KO="$(find "$OUT/target/lib/modules" -name gpu2d.ko)"
echo "Modulo: $KO"
echo
echo "Para probarlo en la placa encendida sin regrabar la SD:"
echo "  scp $KO $OUT/target/usr/bin/gpu2d-servicio root@192.168.10.2:/tmp/"
echo "  ssh root@192.168.10.2 'sh /etc/init.d/S90gpu2d.sh stop; rmmod gpu2d; insmod /tmp/gpu2d.ko; /tmp/gpu2d-servicio 5000 &'"
