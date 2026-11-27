/*
 * raster_ref.c - Implementacion de referencia exclusivamente en CPU (CU-04).
 * Ver raster_ref.h. Cada primitiva sigue al modulo del RTL indicado; los
 * rellenos escriben tramos horizontales enteros, como haria un rasterizador
 * de software, pero producen los mismos pixeles que el hardware.
 */
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "raster_ref.h"

#define PKT		24
#define OP_NOP		0x00
#define OP_PIXEL	0x01
#define OP_LINE		0x02
#define OP_TRIA		0x03
#define OP_TRIA_FILL	0x04
#define OP_RECT		0x05
#define OP_RECT_FILL	0x06
#define OP_CIRC		0x07
#define OP_CIRC_FILL	0x08
#define OP_CLEAR	0x09
#define OP_SWAP		0x0A
#define OP_INF		0x0B
#define RADIO_MAX	1023

static uint64_t ahora_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static uint32_t le32(const uint8_t *p)
{
	return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Acelerador_pkg::rgb888_to_rgb565 */
static uint16_t a_rgb565(uint32_t w4)
{
	unsigned int r = (w4 >> 16) & 0xFF, g = (w4 >> 8) & 0xFF, b = w4 & 0xFF;

	return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

static int imin(int a, int b) { return a < b ? a : b; }
static int imax(int a, int b) { return a > b ? a : b; }

/* Raiz entera: mayor m con m*m <= v */
static int raiz(int64_t v)
{
	int64_t m = 0, b = (int64_t)1 << 30;

	while (b > v)
		b >>= 2;
	while (b) {
		if (v >= m + b) {
			v -= m + b;
			m = (m >> 1) + b;
		} else {
			m >>= 1;
		}
		b >>= 2;
	}
	return (int)m;
}

/* Division entera con piso (b > 0) */
static int64_t piso(int64_t a, int64_t b)
{
	int64_t q = a / b;

	return (a % b != 0 && a < 0) ? q - 1 : q;
}

/* ------------------------------------------------- escritura con recorte */

struct lienzo {
	struct raster_ref *r;
	uint16_t *fb;
	uint16_t color;
};

static void pixel(struct lienzo *l, int x, int y)
{
	if (x >= 0 && x < l->r->ancho && y >= 0 && y < l->r->alto) {
		l->fb[y * l->r->ancho + x] = l->color;
		l->r->ventana.pixeles++;
	}
}

/* Tramo horizontal xa..xb en la fila y, recortado (clip_scissor) */
static void tramo(struct lienzo *l, int y, int xa, int xb)
{
	uint16_t *p;
	int n;

	if (y < 0 || y >= l->r->alto)
		return;
	xa = imax(xa, 0);
	xb = imin(xb, l->r->ancho - 1);
	if (xa > xb)
		return;
	p = l->fb + y * l->r->ancho + xa;
	for (n = xb - xa + 1; n; n--)
		*p++ = l->color;
	l->r->ventana.pixeles += (uint32_t)(xb - xa + 1);
}

/* ------------------------------------------------------------ primitivas */

/* draw_line: Bresenham; termina al salir de la pantalla alejandose */
static void linea(struct lienzo *l, int x, int y, int xe, int ye)
{
	int w = l->r->ancho, h = l->r->alto;
	int dx = abs(xe - x), dy = -abs(ye - y);
	int sx = x < xe ? 1 : -1, sy = y < ye ? 1 : -1;
	int err = dx + dy, e2;

	for (;;) {
		pixel(l, x, y);
		if (x == xe && y == ye)
			return;
		if ((x >= w && (sx > 0 || dx == 0)) || (x < 0 && (sx < 0 || dx == 0)) ||
		    (y >= h && (sy > 0 || dy == 0)) || (y < 0 && (sy < 0 || dy == 0)))
			return;
		e2 = err + err;
		if (e2 >= dy) {
			err += dy;
			x += sx;
		}
		if (e2 <= dx) {
			err += dx;
			y += sy;
		}
	}
}

/* draw_rect, fill = 0: solo las aristas visibles, sin repetir esquinas */
static void rect(struct lienzo *l, int x0, int y0, int x1, int y1)
{
	int w = l->r->ancho, h = l->r->alto, y;
	int xa = imin(x0, x1), xb = imax(x0, x1), ya = imin(y0, y1), yb = imax(y0, y1);
	int vxa = imax(xa, 0), vxb = imin(xb, w - 1);
	int lya = imax(ya + 1, 0), lyb = imin(yb - 1, h - 1);
	int x_vis = vxa <= vxb, lados = yb > ya + 1 && lya <= lyb;

	if (x_vis && ya >= 0 && ya < h)
		tramo(l, ya, vxa, vxb);
	if (x_vis && yb >= 0 && yb < h && yb != ya)
		tramo(l, yb, vxa, vxb);
	if (lados && xa >= 0 && xa < w)
		for (y = lya; y <= lyb; y++)
			pixel(l, xa, y);
	if (lados && xb >= 0 && xb < w && xb != xa)
		for (y = lya; y <= lyb; y++)
			pixel(l, xb, y);
}

/* draw_rect, fill = 1 (y CLEAR): filas visibles */
static void rect_fill(struct lienzo *l, int x0, int y0, int x1, int y1)
{
	int ya = imax(imin(y0, y1), 0), yb = imin(imax(y0, y1), l->r->alto - 1), y;

	for (y = ya; y <= yb; y++)
		tramo(l, y, imin(x0, x1), imax(x0, x1));
}

/* draw_circle, fill = 0: punto medio, ocho octantes por paso, con las
 * mismas repeticiones que el hardware (cuentan como pixeles). Las sumas
 * dan la vuelta en 16 bits, como los registros del RTL. */
static void circ(struct lienzo *l, int cx, int cy, int r)
{
	int x = r, y = 0, err = 0, fin, e1;

	for (;;) {
		pixel(l, (int16_t)(cx + x), (int16_t)(cy + y));
		pixel(l, (int16_t)(cx + y), (int16_t)(cy + x));
		pixel(l, (int16_t)(cx - y), (int16_t)(cy + x));
		pixel(l, (int16_t)(cx - x), (int16_t)(cy + y));
		pixel(l, (int16_t)(cx - x), (int16_t)(cy - y));
		pixel(l, (int16_t)(cx - y), (int16_t)(cy - x));
		pixel(l, (int16_t)(cx + y), (int16_t)(cy - x));
		pixel(l, (int16_t)(cx + x), (int16_t)(cy - y));
		if (err > 0) {
			fin = x <= y;
			err = err - 2 * x + 1;
			x--;
		} else {
			e1 = err + 2 * y + 3;
			if (e1 > 0) {
				fin = x <= y + 1;
				err = err + 2 * y - 2 * x + 4;
				x--;
				y++;
			} else {
				fin = x <= y;
				err = e1;
				y++;
			}
		}
		if (fin)
			return;
	}
}

/* draw_circle, fill = 1: dx^2 + dy^2 <= r^2, un tramo por fila visible */
static void circ_fill(struct lienzo *l, int cx, int cy, int r)
{
	int dxi = imax(-r, -cx), dxf = imin(r, l->r->ancho - 1 - cx);
	int dyi = imax(-r, -cy), dyf = imin(r, l->r->alto - 1 - cy);
	int dy, m;

	if (dxi > dxf || dyi > dyf)
		return;
	for (dy = dyi; dy <= dyf; dy++) {
		m = raiz((int64_t)r * r - (int64_t)dy * dy);
		tramo(l, cy + dy, imax(cx - m, cx + dxi), imin(cx + m, cx + dxf));
	}
}

/* draw_trian: orientacion; contorno con tres lineas o relleno por funciones
 * de arista con regla top-left sobre la caja recortada, un tramo por fila */
static void tria(struct lienzo *l, int ax, int ay, int bx, int by, int gx, int gy,
		 int relleno)
{
	int64_t pa = (int64_t)(bx - ax) * (gy - ay), pb = (int64_t)(by - ay) * (gx - ax);
	int64_t e[3], sx[3], sy[3], k[3], lo, hi;
	int o[3][4], i, y, bx0, by0, bx1, by1, t;

	if (pa < pb) {
		t = bx; bx = gx; gx = t;
		t = by; by = gy; gy = t;
	}
	if (!relleno) {
		linea(l, ax, ay, bx, by);
		linea(l, bx, by, gx, gy);
		linea(l, gx, gy, ax, ay);
		return;
	}
	if (pa == pb)
		return;
	bx0 = imax(imin(ax, imin(bx, gx)), 0);
	by0 = imax(imin(ay, imin(by, gy)), 0);
	bx1 = imin(imax(ax, imax(bx, gx)), l->r->ancho - 1);
	by1 = imin(imax(ay, imax(by, gy)), l->r->alto - 1);
	if (bx0 > bx1 || by0 > by1)
		return;
	o[0][0] = ax; o[0][1] = ay; o[0][2] = bx; o[0][3] = by;
	o[1][0] = bx; o[1][1] = by; o[1][2] = gx; o[1][3] = gy;
	o[2][0] = gx; o[2][1] = gy; o[2][2] = ax; o[2][3] = ay;
	for (i = 0; i < 3; i++) {
		int64_t ddx = o[i][2] - o[i][0], ddy = o[i][3] - o[i][1];
		int tl = ddy < 0 || (ddy == 0 && ddx > 0);

		e[i] = ddx * (by0 - o[i][1]) - ddy * (bx0 - o[i][0]);
		sx[i] = -ddy;
		sy[i] = ddx;
		k[i] = tl ? 0 : 1;	/* E >= 0 en aristas top-left, E >= 1 en el resto */
	}
	for (y = by0; y <= by1; y++) {
		lo = 0;
		hi = bx1 - bx0;
		for (i = 0; i < 3; i++) {
			/* e + sx * t >= k para t en [lo, hi] */
			if (sx[i] > 0)
				lo = lo > -piso(e[i] - k[i], sx[i]) ? lo : -piso(e[i] - k[i], sx[i]);
			else if (sx[i] < 0)
				hi = hi < piso(e[i] - k[i], -sx[i]) ? hi : piso(e[i] - k[i], -sx[i]);
			else if (e[i] < k[i])
				lo = 1, hi = 0;
			e[i] += sy[i];
		}
		if (lo <= hi)
			tramo(l, y, bx0 + (int)lo, bx0 + (int)hi);
	}
}

/* ------------------------------------------------------------- interfaz */

int ref_iniciar(struct raster_ref *r, int ancho, int alto)
{
	memset(r, 0, sizeof(*r));
	r->ancho = ancho;
	r->alto = alto;
	r->fb[0] = calloc((size_t)ancho * alto, sizeof(uint16_t));
	r->fb[1] = calloc((size_t)ancho * alto, sizeof(uint16_t));
	if (!r->fb[0] || !r->fb[1]) {
		ref_liberar(r);
		return -1;
	}
	return 0;
}

void ref_liberar(struct raster_ref *r)
{
	free(r->fb[0]);
	free(r->fb[1]);
	r->fb[0] = r->fb[1] = NULL;
}

void ref_abrir_ventana(struct raster_ref *r)
{
	memset(&r->ventana, 0, sizeof(r->ventana));
}

const uint16_t *ref_trasero(const struct raster_ref *r)
{
	return r->fb[1 - r->sel];
}

void ref_ejecutar(struct raster_ref *r, const uint8_t *p, size_t len)
{
	uint64_t t0 = ahora_ns(), t;
	size_t i;

	for (i = 0; i + PKT <= len; i += PKT) {
		const uint8_t *q = p + i;
		uint32_t w0 = le32(q), w1 = le32(q + 4), w2 = le32(q + 8);
		uint32_t w3 = le32(q + 12), w4 = le32(q + 16), w5 = le32(q + 20);
		unsigned int op = w0 >> 24, param = w5 & 0xFFFF;
		int x0 = (int16_t)(w1 >> 16), y0 = (int16_t)w1;
		int x1 = (int16_t)(w2 >> 16), y1 = (int16_t)w2;
		int x2 = (int16_t)(w3 >> 16), y2 = (int16_t)w3;
		struct lienzo l = { r, r->fb[1 - r->sel], a_rgb565(w4) };

		if (op == OP_INF) {		/* cierra la ventana y la publica */
			t = ahora_ns();
			r->ventana.ns += t - t0;
			r->publicado = r->ventana;
			r->hay_publicado = 1;
			ref_abrir_ventana(r);
			t0 = ahora_ns();
			continue;
		}
		if (op > OP_INF ||					/* EC-06 */
		    ((op == OP_CIRC || op == OP_CIRC_FILL) &&
		     (param == 0 || param > RADIO_MAX))) {		/* EC-07 */
			r->ventana.errores++;
			continue;
		}
		switch (op) {
		case OP_PIXEL:		pixel(&l, x0, y0); break;
		case OP_LINE:		linea(&l, x0, y0, x1, y1); break;
		case OP_RECT:		rect(&l, x0, y0, x1, y1); break;
		case OP_RECT_FILL:	rect_fill(&l, x0, y0, x1, y1); break;
		case OP_CLEAR:		rect_fill(&l, 0, 0, r->ancho - 1, r->alto - 1); break;
		case OP_CIRC:		circ(&l, x0, y0, (int)param); break;
		case OP_CIRC_FILL:	circ_fill(&l, x0, y0, (int)param); break;
		case OP_TRIA:		tria(&l, x0, y0, x1, y1, x2, y2, 0); break;
		case OP_TRIA_FILL:	tria(&l, x0, y0, x1, y1, x2, y2, 1); break;
		case OP_SWAP:		r->sel ^= 1; break;	/* sin VSYNC que esperar */
		default:		break;			/* NOP */
		}
		r->ventana.comandos++;
	}
	r->ventana.ns += ahora_ns() - t0;
}
