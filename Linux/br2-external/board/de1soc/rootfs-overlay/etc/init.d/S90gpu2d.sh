#!/bin/sh
# Carga el driver y lanza el servicio TCP de la unidad grafica.
# Termina en .sh a proposito: /etc/init.d/rcS "sourcea" los S??*.sh, asi que no
# necesita permiso de ejecucion (git en Windows no lo conserva).
# A mano: sh /etc/init.d/S90gpu2d.sh {start|stop|restart}
case "$1" in
  start)
    if ! grep -q "gpu2d.fpga=1" /proc/cmdline; then
        echo "gpu2d: la FPGA no se programo en el arranque (ver consola de U-Boot); servicio no iniciado"
        return 0 2>/dev/null || exit 0
    fi
    modprobe gpu2d 2>/dev/null
    if [ -c /dev/gpu2d ] && [ -x /usr/bin/gpu2d-servicio ]; then
        start-stop-daemon -S -b -m -p /var/run/gpu2d.pid -x /usr/bin/gpu2d-servicio -- 5000
        echo "gpu2d-servicio iniciado (puerto 5000)"
    else
        echo "gpu2d: /dev/gpu2d no disponible (¿FPGA sin programar o driver no cargado?)"
    fi
    ;;
  stop)
    start-stop-daemon -K -p /var/run/gpu2d.pid 2>/dev/null
    ;;
  restart) sh /etc/init.d/S90gpu2d.sh stop; sh /etc/init.d/S90gpu2d.sh start ;;
esac
