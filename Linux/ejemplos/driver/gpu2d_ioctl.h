/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * gpu2d_ioctl.h - Interfaz de /dev/gpu2d compartida por el driver (gpu2d.c)
 * y el servicio del HPS (gpu2d-servicio.c). Ambos deben compilarse con este
 * mismo archivo.
 *
 * write(): N paquetes de 24 bytes (1 <= N <= 256). Bloquea mientras la cola
 *          del hardware esta llena, de modo que no se descarta ningun paquete.
 *          Puede devolver menos bytes si vence GPU2D_TIMEOUT_COLA_MS o llega
 *          una senal; el que llama reintenta con el resto.
 * read():  los 16 registros (0x00..0x3C) como u32 little-endian, en el orden
 *          del mapa (GPU2D_R_*).
 */
#ifndef GPU2D_IOCTL_H
#define GPU2D_IOCTL_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define GPU2D_PKT_BYTES		24
#define GPU2D_MAX_BATCH		256
#define GPU2D_NREGS		16

/* Indices de palabra en el bloque que devuelve read() */
#define GPU2D_R_ID		0	/* 0x00 */
#define GPU2D_R_CONTROL		1	/* 0x04 */
#define GPU2D_R_STATUS		2	/* 0x08 */
#define GPU2D_R_ERR_INFO	4	/* 0x10 */
#define GPU2D_R_PERF_CYCLES	5	/* 0x14 */
#define GPU2D_R_PERF_CMDS	6	/* 0x18 */
#define GPU2D_R_PERF_PIXELS	7	/* 0x1C */
#define GPU2D_R_PERF_DROP	8	/* 0x20 */

/* Bits de CONTROL (0x04) */
#define GPU2D_CTRL_IRQ_INF	(1u << 4)	/* R/W1C: un INF publico un informe */
#define GPU2D_CTRL_IRQ_ERR	(1u << 5)	/* R/W1C: se registro un error */

/* Bits de STATUS (0x08) */
#define GPU2D_ST_BUSY		(1u << 0)
#define GPU2D_ST_FIFO_FULL	(1u << 4)
#define GPU2D_ST_FIFO_EMPTY	(1u << 5)
#define GPU2D_ST_OVERFLOW	(1u << 6)

#define GPU2D_IOC_MAGIC		'g'
/* Abre una ventana de medicion nueva (CONTROL.perf_window) y limpia un
 * irq_inf pendiente de una escena anterior. Usar solo con INICIO_VENTANA. */
#define GPU2D_IOC_VENTANA	_IO(GPU2D_IOC_MAGIC, 1)
/* Limpia banderas W1C de CONTROL. Argumento: mascara GPU2D_CTRL_IRQ_*. */
#define GPU2D_IOC_ACK		_IOW(GPU2D_IOC_MAGIC, 2, __u32)
/* Espera a que el hardware vacie la cola y termine (fifo_empty y !busy).
 * Argumento: tiempo maximo en ms. Devuelve 0, o -1 con errno ETIMEDOUT. */
#define GPU2D_IOC_ESPERAR	_IOW(GPU2D_IOC_MAGIC, 3, __u32)

#endif
