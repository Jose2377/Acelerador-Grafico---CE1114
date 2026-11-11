/* hw_dev.c - Backend real: /dev/gpu2d (driver gpu2d.ko). */
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "hw.h"

static int fd = -1;

int hw_abrir(const char *dev)
{
	fd = open(dev, O_RDWR);
	return fd < 0 ? -1 : 0;
}

ssize_t hw_escribir(const void *p, size_t len)
{
	return write(fd, p, len);
}

int hw_leer_registros(uint32_t regs[GPU2D_NREGS])
{
	ssize_t n = read(fd, regs, GPU2D_NREGS * sizeof(uint32_t));
	return n == (ssize_t)(GPU2D_NREGS * sizeof(uint32_t)) ? 0 : -1;
}

int hw_abrir_ventana(void)
{
	return ioctl(fd, GPU2D_IOC_VENTANA);
}

int hw_ack(uint32_t mascara)
{
	return ioctl(fd, GPU2D_IOC_ACK, &mascara);
}

int hw_esperar(unsigned int timeout_ms)
{
	uint32_t t = timeout_ms;
	return ioctl(fd, GPU2D_IOC_ESPERAR, &t);
}
