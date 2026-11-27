# Buildroot llama a este Makefile con CC/CFLAGS cruzados (TARGET_CONFIGURE_OPTS)
# y DRIVER_DIR apuntando a ejemplos/driver (donde vive gpu2d_ioctl.h).
# Como esas variables llegan por linea de ordenes, las opciones propias van
# en variables aparte (EXTRA), que no se pisan.
#
#   make            servicio real para la placa (usa /dev/gpu2d)
#   make sim        version para la PC con el acelerador simulado en memoria
#   make prueba     banco de pruebas de la referencia en CPU (raster_ref.c)
CC ?= gcc
CFLAGS ?= -O2
DRIVER_DIR ?= ../driver
EXTRA = -Wall -Wextra -I$(DRIVER_DIR) -I.

gpu2d-servicio: gpu2d-servicio.c hw_dev.c raster_ref.c hw.h raster_ref.h
	$(CC) $(CFLAGS) $(EXTRA) $(LDFLAGS) -o $@ gpu2d-servicio.c hw_dev.c raster_ref.c

sim: gpu2d-servicio-sim
gpu2d-servicio-sim: gpu2d-servicio.c hw_sim.c raster_ref.c hw.h raster_ref.h
	$(CC) $(CFLAGS) $(EXTRA) -o $@ gpu2d-servicio.c hw_sim.c raster_ref.c

# Banco de pruebas de la referencia en CPU (lo usa Interfaz/tests)
prueba: prueba_raster_ref
prueba_raster_ref: prueba_raster_ref.c raster_ref.c raster_ref.h
	$(CC) $(CFLAGS) $(EXTRA) -o $@ prueba_raster_ref.c raster_ref.c

clean:
	rm -f gpu2d-servicio gpu2d-servicio-sim prueba_raster_ref

.PHONY: sim prueba clean
