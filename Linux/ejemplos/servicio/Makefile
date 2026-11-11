# Buildroot llama a este Makefile con CC/CFLAGS cruzados (TARGET_CONFIGURE_OPTS)
# y DRIVER_DIR apuntando a ejemplos/driver (donde vive gpu2d_ioctl.h).
# Como esas variables llegan por linea de ordenes, las opciones propias van
# en variables aparte (EXTRA), que no se pisan.
#
#   make            servicio real para la placa (usa /dev/gpu2d)
#   make sim        version para la PC con el acelerador simulado en memoria
CC ?= gcc
CFLAGS ?= -O2
DRIVER_DIR ?= ../driver
EXTRA = -Wall -Wextra -I$(DRIVER_DIR) -I.

gpu2d-servicio: gpu2d-servicio.c hw_dev.c hw.h
	$(CC) $(CFLAGS) $(EXTRA) $(LDFLAGS) -o $@ gpu2d-servicio.c hw_dev.c

sim: gpu2d-servicio-sim
gpu2d-servicio-sim: gpu2d-servicio.c hw_sim.c hw.h
	$(CC) $(CFLAGS) $(EXTRA) -o $@ gpu2d-servicio.c hw_sim.c

clean:
	rm -f gpu2d-servicio gpu2d-servicio-sim

.PHONY: sim clean
