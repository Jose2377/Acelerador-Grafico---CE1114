/*
 * prueba_raster_ref.c - Banco de pruebas de raster_ref.c para la PC.
 *
 *   ./prueba_raster_ref ANCHO ALTO < paquetes > salida
 *
 * Lee paquetes de 24 bytes de la entrada estandar, los ejecuta con la
 * referencia en CPU y escribe en la salida estandar los contadores de la
 * ventana abierta (comandos, pixeles, errores como tres u32 little-endian)
 * seguidos del buffer trasero (ANCHO * ALTO u16 little-endian).
 * Lo usa Interfaz/tests/test_raster_ref_c.py para compararla con
 * RasterizadorCPU, que a su vez se compara con el RTL.
 */
#include <stdio.h>
#include <stdlib.h>
#include "raster_ref.h"

int main(int argc, char **argv)
{
	static uint8_t buf[1 << 20];
	struct raster_ref r;
	size_t n;
	uint32_t c[3];

	if (argc != 3 || ref_iniciar(&r, atoi(argv[1]), atoi(argv[2])))
		return 2;
	n = fread(buf, 1, sizeof(buf), stdin);
	ref_ejecutar(&r, buf, n - n % 24);
	c[0] = r.ventana.comandos;
	c[1] = r.ventana.pixeles;
	c[2] = r.ventana.errores;
	fwrite(c, sizeof(c[0]), 3, stdout);	/* el HPS y la PC son little-endian */
	fwrite(ref_trasero(&r), sizeof(uint16_t), (size_t)r.ancho * r.alto, stdout);
	ref_liberar(&r);
	return 0;
}
