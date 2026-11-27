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
 *   3 REPORTE    HPS -> cliente   20 bytes: ciclos, comandos, pixeles (u32),
 *                                 errores, descartados (u16), cpu_ns (u32),
 *                                 orden de red.
 *
 * cpu_ns (26/11/2026) es la carga de la CPU del HPS en la ventana: tiempo de
 * CPU (usuario + nucleo, CLOCK_THREAD_CPUTIME_ID) que este proceso gasto en
 * hacer dibujar la escena. Con el acelerador es entregar los paquetes a
 * /dev/gpu2d; con la bandera CPU es rasterizarlos en raster_ref.c. Las esperas
 * (el driver duerme si la cola esta llena) no cuentan. Es la metrica del
 * proposito del producto: cuanto trabajo se le quita a la CPU.
 *   4 ERROR      HPS -> cliente   codigo (u8) | 0 | texto UTF-8.
 *
 * Bandera 0x02 CPU (en LOTE y SOLICITUD): el lote no va al acelerador sino a
 * la implementacion de referencia exclusivamente en CPU (raster_ref.c, CU-04),
 * que corre en este mismo procesador; la solicitud devuelve su informe. En ese
 * REPORTE el campo ciclos es el tiempo en nanosegundos (satura en 2^32 - 1).
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
 * Bitacora (RSH-03, CU-05): con -l RUTA cada evento (conexiones, lotes con sus
 * comandos, errores del hardware y reportes) se anota con fecha y hora en RUTA.
 * -v escribe lo mismo en la salida estandar.
 *
 * Uso:  gpu2d-servicio [puerto] [dispositivo] [-v] [-l bitacora]
 *       por defecto 5000 y /dev/gpu2d.
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
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

#include "hw.h"
#include "raster_ref.h"

#define PUERTO_DEF		5000
#define TAM_ENCABEZADO		8
#define LONGITUD_MAX		(GPU2D_MAX_BATCH * GPU2D_PKT_BYTES)	/* 6144 */
#define ESPERA_INFORME_MS	4000	/* el cliente espera 5 s por defecto */

enum { TIPO_LOTE = 1, TIPO_SOLICITUD = 2, TIPO_REPORTE = 3, TIPO_ERROR = 4 };
#define BANDERA_INICIO_VENTANA	0x01
#define BANDERA_CPU		0x02

/* Implementacion de referencia en CPU, compartida por todas las conexiones */
static struct raster_ref ref;
static uint64_t ref_cpu;	/* carga de CPU de la ventana de la referencia */
#define OPCODE_INF		0x0B

static int verboso;

/* Tiempo de CPU de este hilo, en ns: solo lo que de verdad ejecuto */
static uint64_t cpu_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static uint32_t sat32(uint64_t v)
{
	return v > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)v;
}
static FILE *bitacora;

/* Anota un evento en la bitacora (con fecha y hora) y, con -v, en la salida. */
static void log_v(const char *fmt, ...)
{
	va_list ap;

	if (verboso) {
		va_start(ap, fmt);
		vprintf(fmt, ap);
		va_end(ap);
		putchar('\n');
		fflush(stdout);
	}
	if (bitacora) {
		char fecha[32];
		time_t t = time(NULL);
		struct tm tm;

		localtime_r(&t, &tm);
		strftime(fecha, sizeof(fecha), "%Y-%m-%d %H:%M:%S", &tm);
		fprintf(bitacora, "%s ", fecha);
		va_start(ap, fmt);
		vfprintf(bitacora, fmt, ap);
		va_end(ap);
		fputc('\n', bitacora);
		fflush(bitacora);
	}
}

static const char *nombre_opcode(unsigned int op)
{
	static const char *n[] = { "NOP", "PIXEL", "LINE", "TRIA", "TRIA_FILL",
		"RECT", "RECT_FILL", "CIRC", "CIRC_FILL", "CLEAR", "SWAP", "INF" };

	return op < sizeof(n) / sizeof(n[0]) ? n[op] : "DESCONOCIDO";
}

/* Una linea por lote: rango de SEQ_ID y cuantos comandos de cada tipo. */
static void anotar_comandos(const uint8_t *carga, size_t len)
{
	unsigned int cuenta[13] = { 0 };
	unsigned int seq_ini, seq_fin;
	char linea[400];
	size_t i, n = 0;

	if (!verboso && !bitacora)
		return;
	for (i = 0; i < len; i += GPU2D_PKT_BYTES)
		cuenta[carga[i + 3] <= 0x0B ? carga[i + 3] : 12]++;
	/* W0 en little-endian: SEQ_ID en los bytes 0 y 1 */
	seq_ini = carga[0] | (carga[1] << 8);
	seq_fin = carga[len - GPU2D_PKT_BYTES] | (carga[len - GPU2D_PKT_BYTES + 1] << 8);
	linea[0] = '\0';
	for (i = 0; i < 13 && n < sizeof(linea) - 40; i++)
		if (cuenta[i])
			n += snprintf(linea + n, sizeof(linea) - n, " %s=%u",
				      nombre_opcode((unsigned int)i), cuenta[i]);
	log_v("    comandos SEQ_ID %u..%u:%s", seq_ini, seq_fin, linea);
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
	uint64_t cpu;		/* carga de CPU de la ventana: entregar los paquetes */
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
	log_v("  hardware: EC-%02u, %u errores desde el reinicio (se informa en el reporte)",
	      ec, r[GPU2D_R_ERR_INFO] >> 16);
	return 0;
}

static int atender_lote(int c, uint8_t banderas, uint32_t seq,
			const uint8_t *carga, size_t len, struct sesion *s)
{
	size_t i, hecho = 0;

	uint64_t t0;

	if (banderas & BANDERA_CPU) {		/* referencia en CPU, no el acelerador */
		if (banderas & BANDERA_INICIO_VENTANA) {
			ref_abrir_ventana(&ref);
			ref_cpu = 0;
		}
		t0 = cpu_ns();
		ref_ejecutar(&ref, carga, len);
		ref_cpu += cpu_ns() - t0;
		return 0;
	}

	if (banderas & BANDERA_INICIO_VENTANA) {
		uint32_t r[GPU2D_NREGS];

		/* La ventana nueva no debe recibir ciclos ni pixeles de una escena
		 * anterior que el hardware aun este dibujando. */
		if (hw_esperar(ESPERA_INFORME_MS))
			return enviar_error(c, seq, 5,
				"El acelerador no termino la escena anterior en %d ms",
				ESPERA_INFORME_MS);
		if (hw_abrir_ventana())
			return enviar_error(c, seq, 5, "No se pudo abrir la ventana (%s)",
					    strerror(errno));
		if (hw_leer_registros(r) == 0) {
			s->err_base = r[GPU2D_R_ERR_INFO] >> 16;
			s->drop_base = r[GPU2D_R_PERF_DROP];
		}
		s->inf_pendiente = 0;
		s->cpu = 0;
	}

	/* Carga de CPU: desde aqui hasta que el ultimo paquete esta en la cola */
	t0 = cpu_ns();

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
	s->cpu += cpu_ns() - t0;
	return revisar_errores_hw(c, seq, s);
}

static void be32(uint8_t *p, uint32_t v) { v = htonl(v); memcpy(p, &v, 4); }
static void be16(uint8_t *p, uint16_t v) { v = htons(v); memcpy(p, &v, 2); }

static int atender_solicitud_cpu(int c, uint32_t seq)
{
	const struct ref_ventana *v = ref.hay_publicado ? &ref.publicado : &ref.ventana;
	uint8_t rep[20];
	uint32_t ns = v->ns > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)v->ns;

	be32(rep + 0, ns);
	be32(rep + 4, v->comandos);
	be32(rep + 8, v->pixeles);
	be16(rep + 12, (uint16_t)v->errores);
	be16(rep + 14, 0);
	be32(rep + 16, sat32(ref_cpu));
	log_v("  -> REPORTE CPU seq=%u ns=%u comandos=%u pixeles=%u errores=%u cpu_ns=%u",
	      seq, ns, v->comandos, v->pixeles, v->errores, sat32(ref_cpu));
	ref.hay_publicado = 0;
	return enviar_mensaje(c, TIPO_REPORTE, seq, rep, sizeof(rep));
}

static int atender_solicitud(int c, uint32_t seq, struct sesion *s)
{
	uint32_t r[GPU2D_NREGS];
	uint8_t rep[20];
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
	be32(rep + 16, sat32(s->cpu));
	log_v("  -> REPORTE seq=%u ciclos=%u comandos=%u pixeles=%u errores=%u descartados=%u cpu_ns=%u",
	      seq, r[GPU2D_R_PERF_CYCLES], r[GPU2D_R_PERF_CMDS],
	      r[GPU2D_R_PERF_PIXELS], errores, r[GPU2D_R_PERF_DROP] & 0xFFFF,
	      sat32(s->cpu));
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
			anotar_comandos(carga, len);
			if (atender_lote(c, banderas, seq, carga, len, &s))
				return;
		} else {
			log_v("  SOLICITUD seq=%u banderas=0x%02X", seq, banderas);
			if (banderas & BANDERA_CPU ? atender_solicitud_cpu(c, seq)
						   : atender_solicitud(c, seq, &s))
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
		else if (!strcmp(argv[i], "-l") && i + 1 < argc) {
			bitacora = fopen(argv[++i], "a");
			if (!bitacora)
				perror(argv[i]);
		}
		else if (pos++ == 0)
			puerto = atoi(argv[i]);
		else
			dev = argv[i];
	}
	signal(SIGPIPE, SIG_IGN);
	if (ref_iniciar(&ref, REF_ANCHO, REF_ALTO)) {
		perror("raster_ref");
		return 1;
	}

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
	log_v("Servicio iniciado: puerto %d, dispositivo %s", puerto, dev);

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
