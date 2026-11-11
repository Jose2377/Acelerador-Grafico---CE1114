/*
 * hw.h - Acceso al acelerador desde el servicio. hw_dev.c usa /dev/gpu2d;
 * hw_sim.c es un modelo en memoria para probar el protocolo en una PC.
 * Todas devuelven 0 (o bytes escritos) y -1 con errno en caso de error.
 */
#ifndef HW_H
#define HW_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include "gpu2d_ioctl.h"

int     hw_abrir(const char *dev);
ssize_t hw_escribir(const void *paquetes, size_t len);
int     hw_leer_registros(uint32_t regs[GPU2D_NREGS]);
int     hw_abrir_ventana(void);
int     hw_ack(uint32_t mascara);
int     hw_esperar(unsigned int timeout_ms);

#endif
