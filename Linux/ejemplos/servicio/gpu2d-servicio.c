/*
 * gpu2d-servicio.c - Esqueleto del servicio del HPS.
 * Escucha en TCP, recibe lotes de paquetes de 24 bytes y los escribe en
 * /dev/gpu2d; luego lee el bloque de rendimiento y lo devuelve al cliente.
 *
 * PENDIENTE: este protocolo es provisional y NO es el de la interfaz.
 * Reemplazar por el de Acelerador-Grafico---CE1114/Interfaz/PROTOCOLO.md
 * (encabezado de 8 bytes; LOTE, SOLICITUD, REPORTE, ERROR).
 *
 * Protocolo provisional:
 *   cliente -> servidor: u32 n (paquetes, little-endian) + n*24 bytes
 *   servidor -> cliente: bloque leído de /dev/gpu2d (estado + contadores)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <endian.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define PKT_BYTES  24
#define MAX_BATCH  256
#define PORT_DEF   5000

static int read_full(int fd, void *buf, size_t len)
{
	size_t got = 0;
	while (got < len) {
		ssize_t r = read(fd, (char *)buf + got, len - got);
		if (r <= 0)
			return -1;
		got += r;
	}
	return 0;
}

int main(int argc, char **argv)
{
	int port = argc > 1 ? atoi(argv[1]) : PORT_DEF;
	const char *devpath = argc > 2 ? argv[2] : "/dev/gpu2d";
	static uint8_t batch[MAX_BATCH * PKT_BYTES];
	uint8_t perf[64];
	int one = 1;

	int dev = open(devpath, O_RDWR);
	if (dev < 0) { perror(devpath); return 1; }

	int srv = socket(AF_INET, SOCK_STREAM, 0);
	setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in a = { .sin_family = AF_INET,
				 .sin_port = htons(port),
				 .sin_addr.s_addr = htonl(INADDR_ANY) };
	if (bind(srv, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(srv, 1) < 0) {
		perror("socket");
		return 1;
	}
	printf("gpu2d-servicio escuchando en el puerto %d (%s)\n", port, devpath);

	for (;;) {
		int c = accept(srv, NULL, NULL);
		if (c < 0)
			continue;
		uint32_t n;
		while (read_full(c, &n, 4) == 0) {
			n = le32toh(n);
			if (n == 0 || n > MAX_BATCH)
				break;
			if (read_full(c, batch, n * PKT_BYTES) < 0)
				break;
			if (write(dev, batch, n * PKT_BYTES) < 0)
				perror("write dev");
			ssize_t p = read(dev, perf, sizeof(perf));
			if (p > 0 && write(c, perf, p) < 0)
				break;
		}
		close(c);
	}
}
