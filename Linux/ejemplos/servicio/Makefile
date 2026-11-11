# Buildroot pasa CC/CFLAGS cruzados (TARGET_CONFIGURE_OPTS).
# A mano: make CC=<ruta>/arm-...-gcc
CC ?= gcc
CFLAGS ?= -O2
CFLAGS += -Wall -Wextra

gpu2d-servicio: gpu2d-servicio.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f gpu2d-servicio
