/*
 * raster_ref.h - Implementacion de referencia exclusivamente en CPU (CU-04).
 *
 * Rasteriza en la CPU del HPS los mismos paquetes de 24 bytes que recibe el
 * acelerador, con los mismos algoritmos y los mismos contadores que el RTL
 * (y que Interfaz/gfx/raster_cpu.py), para comparar tiempos en el mismo
 * procesador que el acelerador descarga (RR-01).
 *
 * El framebuffer es doble, RGB565, en memoria del proceso; nunca toca la FPGA.
 * El tiempo es de reloj monotono y abarca decodificar y dibujar cada comando
 * de la ventana, sin contar la publicacion del informe.
 */
#ifndef RASTER_REF_H
#define RASTER_REF_H

#include <stddef.h>
#include <stdint.h>

#define REF_ANCHO	640
#define REF_ALTO	480

struct ref_ventana {
	uint32_t comandos;	/* como PERF_COMMANDS: dibujo, NOP y SWAP; no INF */
	uint32_t pixeles;	/* como PERF_PIXELS: pixeles escritos en pantalla */
	uint32_t errores;	/* EC-06 y EC-07, que el hardware detecta solo */
	uint64_t ns;		/* tiempo de CPU de los comandos de la ventana */
};

struct raster_ref {
	int ancho, alto;
	uint16_t *fb[2];		/* buffer A y B */
	int sel;			/* delantero, 0 = A; se dibuja en el otro */
	struct ref_ventana ventana;	/* ventana abierta */
	struct ref_ventana publicado;	/* la que cerro el ultimo INF */
	int hay_publicado;
};

/* ancho y alto: los de la pantalla. Devuelve 0, o -1 sin memoria. */
int  ref_iniciar(struct raster_ref *r, int ancho, int alto);
void ref_liberar(struct raster_ref *r);
/* Reinicia los contadores (bandera INICIO_VENTANA). */
void ref_abrir_ventana(struct raster_ref *r);
/* Ejecuta len / 24 paquetes. Un INF cierra la ventana y la publica. */
void ref_ejecutar(struct raster_ref *r, const uint8_t *paquetes, size_t len);
/* Buffer trasero (donde se dibuja), para pruebas. */
const uint16_t *ref_trasero(const struct raster_ref *r);

#endif
