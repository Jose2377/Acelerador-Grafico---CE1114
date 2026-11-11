/*
 * gpu2d-servicio.c - Servicio del HPS (nivel 2, ServidorComandos).
 *
 * Puente entre la interfaz de comandos (Interfaz/, ClienteTransporte) y el
 * acelerador (/dev/gpu2d). Implementa el protocolo de Interfaz/PROTOCOLO.md:
 *
 *   Encabezado de 8 bytes, orden de red:
 *     tipo (u8) | banderas (u8) | longitud (u16) | secuencia (u32)
 *
 *   1 LOTE       cliente -> HPS   N paquetes de 24 bytes (1..256). Sin respuesta.
 *                                 Bandera 0x01 INICIO_VENTANA: abre una ventana
 *                                 de medicion antes de escribir el lote.
 *   2 SOLICITUD  cliente -> HPS   Sin carga. Se responde REPORTE con la misma
 *                                 secuencia cuando el hardware publica (MOE-05).
 *   3 REPORTE    HPS -> cliente   16 bytes: ciclos, comandos, pixeles (u32),
 *                                 errores, descartados (u16), orden de red.
 *   4 ERROR      HPS -> cliente   codigo (u8) | 0 | texto UTF-8.
 *
 * Errores que se envian como mensaje ERROR:
 *   EC-05  mensaje mal formado (y se cierra la conexion), fallo al escribir en
 *          /dev/gpu2d o el hardware no publico el informe a tiempo.
 *   EC-08  la cola del hardware descarto paquetes (no deberia ocurrir: el
 *          driver aplica contrapresion).
 * EC-06 y EC-07 (comando invalido en hardware) NO se envian como ERROR: el
 * hardware los ignora (RF-20) y se informan en el campo "errores" del REPORTE.
 * Asi un error de hardware no aborta la espera del reporte en el cliente.
 *
 * Cola de espera (RF-12): los mensajes se atienden en orden de llegada; los
 * que llegan mientras se procesa uno quedan en el buffer del socket TCP.
 *
 * Uso:  gpu2d-servicio [puerto] [dispositivo] [-v]
 *       por defecto 5000 y /dev/gpu2d. -v escribe cada mensaje en la salida.
 *
 * Para probar en una PC sin la placa:  make sim && ./gpu2d-servicio-sim 5000 x -v
 * (el dispositivo se reemplaza por un modelo en memoria; ver hw_sim.c).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

#include "hw.h"

#define PUERTO_DEF		5000
#define TAM_ENCABEZADO		8
#define LONGITUD_MAX		(GPU2D_MAX_BATCH * GPU2D_PKT_BYTES)	/* 6144 */
#define ESPERA_INFORME_MS	4000	/* el cliente espera 5 s por defecto */

enum { TIPO_LOTE = 1, TIPO_SOLICITUD = 2, TIPO_REPORTE = 3, TIPO_ERROR = 4 };
#define BANDERA_INICIO_VENTANA	0x01
#define OPCODE_INF		0x0B

static int verboso;

static void log_v(const char *fmt, ...)
{
	va_list ap;

	if (!verboso)
		return;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

/* ------------------------------------------------------------- socket */

static int leer_exacto(int fd, void *buf, size_t len)
{
	size_t got = 0;

	while (got < len) {
		ssize_t r = recv(fd, (char *)buf + got, len - got, 0);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		got += r;
	}
	return 0;
}

static int enviar_todo(int fd, const void *buf, size_t len)
{
	size_t sent = 0;

	while (sent < len) {
		ssize_t r = send(fd, (const char *)buf + sent, len - sent, MSG_NOSIGNAL);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		sent += r;
	}
	return 0;
}

static int enviar_mensaje(int fd, uint8_t tipo, uint32_t seq,
			  const void *carga, uint16_t len)
{
	uint8_t msg[TAM_ENCABEZADO + 512];
	uint16_t l = htons(len);
	uint32_t s = htonl(seq);

	if (len > sizeof(msg) - TAM_ENCABEZADO)
		len = sizeof(msg) - TAM_ENCABEZADO;
	msg[0] = tipo;
	msg[1] = 0;
	memcpy(msg + 2, &l, 2);
	memcpy(msg + 4, &s, 4);
	if (len)
		memcpy(msg + TAM_ENCABEZADO, carga, len);
	return enviar_todo(fd, msg, TAM_ENCABEZADO + len);
}

static int enviar_error(int fd, uint32_t seq, int codigo, const char *fmt, ...)
{
	uint8_t carga[256];
	va_list ap;
	int n;

	carga[0] = (uint8_t)codigo;
	carga[1] = 0;
	va_start(ap, fmt);
	n = vsnprintf((char *)carga + 2, sizeof(carga) - 2, fmt, ap);
	va_end(ap);
	if (n < 0)
		n = 0;
	if (n > (int)sizeof(carga) - 3)
		n = sizeof(carga) - 3;
	log_v("  -> ERROR EC-%02d seq=%u: %s", codigo, seq, (char *)carga + 2);
	return enviar_mensaje(fd, TIPO_ERROR, seq, carga, (uint16_t)(2 + n));
}

/* ------------------------------------------------------------ sesion */

struct sesion {
	int inf_pendiente;	/* se envio un INF que aun no se reporta */
	uint16_t err_base;	/* err_count al abrir la ventana */
	uint32_t drop_base;	/* PERF_DROP visto por ultima vez */
};

/* Revisa irq_err tras un lote: informa EC-08 y registra EC-06/EC-07. */
static int revisar_errores_hw(int c, uint32_t seq, struct sesion *s)
{
	uint32_t r[GPU2D_NREGS];
	unsigned int ec;

	if (hw_leer_registros(r))
		return enviar_error(c, seq, 5, "No se pudieron leer los registros (%s)",
				    strerror(errno));
	if (!(r[GPU2D_R_CONTROL] & GPU2D_CTRL_IRQ_ERR))
		return 0;

	ec = r[GPU2D_R_ERR_INFO] & 0xF;
	hw_ack(GPU2D_CTRL_IRQ_ERR);
	if (ec == 8 || (r[GPU2D_R_STATUS] & GPU2D_ST_OVERFLOW &&
			r[GPU2D_R_PERF_DROP] != s->drop_base)) {
		s->drop_base = r[GPU2D_R_PERF_DROP];
		return enviar_error(c, seq, 8, "La cola del hardware descarto paquetes");
	}
	log_v("  hardware: EC-%02u (se informa en el reporte)", ec);
	return 0;
}

static int atender_lote(int c, uint8_t banderas, uint32_t seq,
			const uint8_t *carga, size_t len, struct sesion *s)
{
	size_t i, hecho = 0;

	if (banderas & BANDERA_INICIO_VENTANA) {
		uint32_t r[GPU2D_NREGS];

		if (hw_abrir_ventana())
			return enviar_error(c, seq, 5, "No se pudo abrir la ventana (%s)",
					    strerror(errno));
		if (hw_leer_registros(r) == 0) {
			s->err_base = r[GPU2D_R_ERR_INFO] >> 16;
			s->drop_base = r[GPU2D_R_PERF_DROP];
		}
		s->inf_pendiente = 0;
	}

	/* W0 en little-endian: el byte 3 es el OPCODE */
	for (i = 0; i < len; i += GPU2D_PKT_BYTES)
		if (carga[i + 3] == OPCODE_INF)
			s->inf_pendiente = 1;

	while (hecho < len) {
		ssize_t w = hw_escribir(carga + hecho, len - hecho);
		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			return enviar_error(c, seq, 5,
				"Lote %u: se escribieron %zu de %zu paquetes en el acelerador (%s)",
				seq, hecho / GPU2D_PKT_BYTES, len / GPU2D_PKT_BYTES,
				w < 0 ? strerror(errno) : "cola detenida");
		hecho += (size_t)w;
	}
	return revisar_errores_hw(c, seq, s);
}

static void be32(uint8_t *p, uint32_t v) { v = htonl(v); memcpy(p, &v, 4); }
static void be16(uint8_t *p, uint16_t v) { v = htons(v); memcpy(p, &v, 2); }

static int atender_solicitud(int c, uint32_t seq, struct sesion *s)
{
	uint32_t r[GPU2D_NREGS];
	uint8_t rep[16];
	uint16_t errores;

	if (s->inf_pendiente) {
		/* Esperar a que la cola se vacie y el INF publique (MOE-05) */
		if (hw_esperar(ESPERA_INFORME_MS))
			return enviar_error(c, seq, 5,
				"El acelerador no termino la escena en %d ms",
				ESPERA_INFORME_MS);
		if (hw_leer_registros(r))
			return enviar_error(c, seq, 5, "No se pudieron leer los registros");
		if (!(r[GPU2D_R_CONTROL] & GPU2D_CTRL_IRQ_INF))
			return enviar_error(c, seq, 5, "El acelerador no publico el informe");
		hw_ack(GPU2D_CTRL_IRQ_INF);
		s->inf_pendiente = 0;
	} else if (hw_leer_registros(r)) {
		return enviar_error(c, seq, 5, "No se pudieron leer los registros");
	}

	/* errores de esta ventana: err_count es acumulado desde el reinicio */
	errores = (uint16_t)((r[GPU2D_R_ERR_INFO] >> 16) - s->err_base);

	be32(rep + 0, r[GPU2D_R_PERF_CYCLES]);
	be32(rep + 4, r[GPU2D_R_PERF_CMDS]);
	be32(rep + 8, r[GPU2D_R_PERF_PIXELS]);
	be16(rep + 12, errores);
	be16(rep + 14, (uint16_t)r[GPU2D_R_PERF_DROP]);
	log_v("  -> REPORTE seq=%u ciclos=%u comandos=%u pixeles=%u errores=%u descartados=%u",
	      seq, r[GPU2D_R_PERF_CYCLES], r[GPU2D_R_PERF_CMDS],
	      r[GPU2D_R_PERF_PIXELS], errores, r[GPU2D_R_PERF_DROP] & 0xFFFF);
	return enviar_mensaje(c, TIPO_REPORTE, seq, rep, sizeof(rep));
}

static void atender_conexion(int c)
{
	static uint8_t carga[LONGITUD_MAX];
	struct sesion s = { 0 };
	uint32_t r[GPU2D_NREGS];

	if (hw_leer_registros(r) == 0) {
		s.err_base = r[GPU2D_R_ERR_INFO] >> 16;
		s.drop_base = r[GPU2D_R_PERF_DROP];
	}

	for (;;) {
		uint8_t h[TAM_ENCABEZADO];
		uint8_t tipo, banderas;
		uint16_t len;
		uint32_t seq;

		if (leer_exacto(c, h, sizeof(h)))
			return;					/* el cliente cerro */
		tipo = h[0];
		banderas = h[1];
		memcpy(&len, h + 2, 2);
		len = ntohs(len);
		memcpy(&seq, h + 4, 4);
		seq = ntohl(seq);

		/* Validacion del encabezado: si falla, EC-05 y se cierra */
		if (tipo == TIPO_LOTE) {
			if (len == 0 || len % GPU2D_PKT_BYTES || len > LONGITUD_MAX) {
				enviar_error(c, seq, 5,
					"Lote de %u bytes: debe ser multiplo no nulo de %d y no mayor que %d",
					len, GPU2D_PKT_BYTES, LONGITUD_MAX);
				return;
			}
		} else if (tipo == TIPO_SOLICITUD) {
			if (len != 0) {
				enviar_error(c, seq, 5, "La solicitud de reporte no lleva carga");
				return;
			}
		} else {
			enviar_error(c, seq, 5, "Tipo de mensaje no admitido: %u", tipo);
			return;
		}

		if (len && leer_exacto(c, carga, len))
			return;

		if (tipo == TIPO_LOTE) {
			log_v("  LOTE seq=%u paquetes=%u banderas=0x%02X",
			      seq, len / GPU2D_PKT_BYTES, banderas);
			if (atender_lote(c, banderas, seq, carga, len, &s))
				return;
		} else {
			log_v("  SOLICITUD seq=%u", seq);
			if (atender_solicitud(c, seq, &s))
				return;
		}
	}
}

int main(int argc, char **argv)
{
	int puerto = PUERTO_DEF, srv, uno = 1, pos = 0, i;
	const char *dev = "/dev/gpu2d";
	struct sockaddr_in a;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v"))
			verboso = 1;
		else if (pos++ == 0)
			puerto = atoi(argv[i]);
		else
			dev = argv[i];
	}
	signal(SIGPIPE, SIG_IGN);

	if (hw_abrir(dev)) {
		perror(dev);
		return 1;
	}

	srv = socket(AF_INET, SOCK_STREAM, 0);
	if (srv < 0) {
		perror("socket");
		return 1;
	}
	setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &uno, sizeof(uno));
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons(puerto);
	a.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(srv, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(srv, 4) < 0) {
		perror("bind/listen");
		return 1;
	}
	printf("gpu2d-servicio escuchando en el puerto %d (%s)\n", puerto, dev);
	fflush(stdout);

	for (;;) {
		struct sockaddr_in o;
		socklen_t ol = sizeof(o);
		int c = accept(srv, (struct sockaddr *)&o, &ol);

		if (c < 0)
			continue;
		setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &uno, sizeof(uno));
		log_v("Conexion desde %s:%d", inet_ntoa(o.sin_addr), ntohs(o.sin_port));
		atender_conexion(c);
		close(c);
		log_v("Conexion cerrada");
	}
}
