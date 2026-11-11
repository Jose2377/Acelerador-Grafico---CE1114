/*
 * hw_sim.c - Modelo en memoria del acelerador, SOLO para probar el protocolo
 * en una PC (make sim). Cuenta comandos, publica el informe con INF y marca
 * EC-06 si el opcode no existe. No dibuja ni mide ciclos reales.
 */
#include <string.h>
#include "hw.h"

static uint32_t R[GPU2D_NREGS];
static uint32_t cmds, err_count;

int hw_abrir(const char *dev)
{
	(void)dev;
	memset(R, 0, sizeof(R));
	R[GPU2D_R_ID] = 0xACE11140;
	R[GPU2D_R_STATUS] = GPU2D_ST_FIFO_EMPTY;
	return 0;
}

ssize_t hw_escribir(const void *p, size_t len)
{
	const uint8_t *b = p;
	size_t i;

	for (i = 0; i < len; i += GPU2D_PKT_BYTES) {
		uint8_t op = b[i + 3];
		if (op == 0 || op > 0x0B) {
			err_count++;
			R[GPU2D_R_ERR_INFO] = (err_count << 16) | 6;
			R[GPU2D_R_CONTROL] |= GPU2D_CTRL_IRQ_ERR;
		} else if (op == 0x0B) {
			R[GPU2D_R_PERF_CYCLES] = 1000 * cmds;
			R[GPU2D_R_PERF_CMDS] = cmds;
			R[GPU2D_R_PERF_PIXELS] = 10 * cmds;
			R[GPU2D_R_CONTROL] |= GPU2D_CTRL_IRQ_INF;
			cmds = 0;
		} else {
			cmds++;
		}
	}
	return (ssize_t)len;
}

int hw_leer_registros(uint32_t regs[GPU2D_NREGS])
{
	memcpy(regs, R, sizeof(R));
	return 0;
}

int hw_abrir_ventana(void)
{
	cmds = 0;
	R[GPU2D_R_CONTROL] &= ~GPU2D_CTRL_IRQ_INF;
	return 0;
}

int hw_ack(uint32_t m)
{
	R[GPU2D_R_CONTROL] &= ~(m & (GPU2D_CTRL_IRQ_INF | GPU2D_CTRL_IRQ_ERR));
	return 0;
}

int hw_esperar(unsigned int t)
{
	(void)t;
	return 0;
}
