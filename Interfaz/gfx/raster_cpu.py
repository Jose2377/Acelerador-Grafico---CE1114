"""RasterizadorCPU: implementacion de referencia exclusivamente en CPU,
usada para la comparacion con el acelerador grafico (caso de uso CU-04).
Consume los mismos objetos Comando que el camino de ida, pero nunca toca
la tarjeta.

Reproduce pixel a pixel los algoritmos del RTL del proyecto Quartus
(processor_raster y los modulos draw_*), de modo que para el mismo
script produce el mismo framebuffer RGB565 y los mismos contadores que el
hardware:

  pixel      draw_pixel      un pixel
  line       draw_line       Bresenham, ambos extremos incluidos
  rect       draw_rect       filas superior e inferior completas y aristas
                             verticales sin las esquinas
  rect_fill  draw_rect       relleno fila a fila
  clear      draw_rect       rect_fill del tamano de la pantalla
  circ       draw_circle     punto medio con simetria de ocho; los puntos
                             sobre los ejes y la diagonal salen repetidos,
                             igual que en el hardware, y cuentan como pixeles
  circ_fill  draw_circle     dx^2 + dy^2 <= r^2 sobre el cuadrado de lado 2r+1
  tria       draw_trian      orienta los vertices y traza A-B, B-C, C-A
                             con la misma linea de Bresenham
  tria_fill  draw_trian      funciones de arista con regla top-left sobre la
                             caja envolvente recortada a la pantalla

Recorte y conteo (clip_scissor / pixel_gen / rend_counter):
  pixeles     pixeles escritos en pantalla (PERF_PIXELS); un pixel repetido
              cuenta dos veces, igual que en el hardware
  recortados  pixeles generados fuera de la pantalla (CLIP_COUNT)
  comandos    comandos completados (PERF_COMMANDS): los de dibujo, NOP y
              SWAP; INF cierra la ventana y no se cuenta a si mismo
  errores     EC-06 (opcode desconocido) y EC-07 (radio fuera de 1..1023),
              que el hardware detecta por su cuenta

Dos modos, con el mismo framebuffer y los mismos contadores:
  "tramos"  (por omision) los rellenos (rect_fill, clear, circ_fill,
            tria_fill) calculan el tramo visible de cada fila y lo
            escriben de una vez, como haria un rasterizador de software
            razonable. Dentro de una fila el conjunto es contiguo, asi que
            el resultado es identico; solo cambia el orden de escritura,
            que no se observa porque el comando tiene un solo color.
  "pixel"   hace el mismo trabajo que el hardware: escribe de a un pixel,
            recorre el cuadrado entero en circ_fill y evalua las tres
            funciones de arista en cada pixel de la caja en tria_fill.
            Es la referencia mas lenta y la mas parecida al algoritmo.
Lineas, contornos y pixeles sueltos son iguales en los dos modos.

Otras diferencias que no cambian el resultado:
  - SWAP es inmediato: no hay VSYNC que esperar.
  - El tiempo es tiempo de CPU (time.perf_counter) de los comandos de la
    ventana, no ciclos de reloj.

Solo usa la biblioteca estandar, para poder correr tambien en el HPS.
"""

import struct
import time
from math import isqrt
import zlib
from array import array

from gfx import constantes as K

RADIO_MAX = 1023


def rgb888_a_rgb565(r, g, b):
    """Igual que Acelerador_pkg::rgb888_to_rgb565: desplazamiento y OR."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def rgb565_a_rgb888(c):
    """Igual que Acelerador_pkg::rgb565_to_rgb888: replica los bits altos."""
    r5, g6, b5 = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
    return ((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2))


def _s16(v):
    """Entero con signo de 16 bits, como los registros del RTL."""
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


class Ventana:
    """Contadores de una ventana de medicion."""

    def __init__(self):
        self.comandos = 0
        self.pixeles = 0
        self.recortados = 0
        self.errores = 0
        self.tiempo_s = 0.0

    def como_dict(self):
        return dict(comandos=self.comandos, pixeles=self.pixeles,
                    recortados=self.recortados, errores=self.errores,
                    tiempo_s=self.tiempo_s)


class RasterizadorCPU:

    MODOS = ("tramos", "pixel")

    def __init__(self, ancho=K.ANCHO_PANTALLA, alto=K.ALTO_PANTALLA,
                 modo="tramos", top_left=True):
        if modo not in self.MODOS:
            raise ValueError("modo debe ser uno de {}".format(self.MODOS))
        self.ancho = ancho
        self.alto = alto
        self.modo = modo
        # top_left=False reproduce el draw_trian anterior a la regla de
        # relleno (todas las aristas inclusivas). Solo para comparar con
        # simulaciones viejas del RTL.
        self.top_left = top_left
        # Dos buffers RGB565, como el framebuffer de doble buffer.
        # buffer_sel es el delantero (0 = A); se dibuja en el otro.
        self.buffers = [array("H", bytes(2 * ancho * alto)),
                        array("H", bytes(2 * ancho * alto))]
        self.buffer_sel = 0
        self.swaps = 0
        self.ventana = Ventana()
        self.informes = []          # una Ventana por cada INF

    # -- consulta ---------------------------------------------------------

    @property
    def trasero(self):
        return self.buffers[1 - self.buffer_sel]

    @property
    def delantero(self):
        return self.buffers[self.buffer_sel]

    def pixel(self, x, y, buffer=None):
        """Color RGB565 de (x, y) en el buffer trasero (o el indicado)."""
        fb = self.trasero if buffer is None else buffer
        return fb[y * self.ancho + x]

    # -- ejecucion --------------------------------------------------------

    def ejecutar(self, comandos):
        """Ejecuta una lista de Comando (los del interprete).

        Devuelve la ventana en curso al terminar. Cada 'inf' cierra una
        ventana y la agrega a self.informes.
        """
        for c in comandos:
            self.ejecutar_campos(c.opcode, *_campos(c))
        return self.ventana

    def ejecutar_campos(self, opcode, x0=0, y0=0, x1=0, y1=0, x2=0, y2=0,
                        param=0, r=0, g=0, b=0):
        """Ejecuta un comando dado por los campos del paquete decodificado.
        Es la entrada que usa el servidor simulado."""
        v = self.ventana
        if opcode == K.OP_INF:
            self.informes.append(v)
            self.ventana = Ventana()
            return
        if opcode > K.OP_INF:                                   # EC-06
            v.errores += 1
            return
        if opcode in (K.OP_DRAW_CIRC, K.OP_DRAW_CIRC_FILL) and \
                not 1 <= param <= RADIO_MAX:                    # EC-07
            v.errores += 1
            return

        t0 = time.perf_counter()
        color = rgb888_a_rgb565(r, g, b)
        if opcode == K.OP_NOP:
            pass
        elif opcode == K.OP_SWAP_BUFFER:
            self.buffer_sel ^= 1
            self.swaps += 1
        elif opcode == K.OP_DRAW_PIXEL:
            self._pixel(x0, y0, color)
        elif opcode == K.OP_DRAW_LINE:
            self._linea(x0, y0, x1, y1, color)
        elif opcode == K.OP_DRAW_RECT:
            self._rect(x0, y0, x1, y1, color)
        elif opcode == K.OP_DRAW_RECT_FILL:
            self._rect_fill(x0, y0, x1, y1, color)
        elif opcode == K.OP_CLEAR:
            self._rect_fill(0, 0, self.ancho - 1, self.alto - 1, color)
        elif opcode == K.OP_DRAW_CIRC:
            self._circ(x0, y0, param, color)
        elif opcode == K.OP_DRAW_CIRC_FILL:
            self._circ_fill(x0, y0, param, color)
        elif opcode in (K.OP_DRAW_TRIA, K.OP_DRAW_TRIA_FILL):
            self._tria(x0, y0, x1, y1, x2, y2, color,
                       opcode == K.OP_DRAW_TRIA_FILL)
        v.tiempo_s += time.perf_counter() - t0
        v.comandos += 1

    # -- escritura con recorte (clip_scissor) -----------------------------

    def _pixel(self, x, y, color):
        if 0 <= x < self.ancho and 0 <= y < self.alto:
            self.trasero[y * self.ancho + x] = color
            self.ventana.pixeles += 1
        else:
            self.ventana.recortados += 1

    def _tramo(self, y, xa, xb, color):
        """Tramo horizontal xa..xb (xa <= xb) en la fila y."""
        n = xb - xa + 1
        if not 0 <= y < self.alto:
            self.ventana.recortados += n
            return
        va, vb = max(xa, 0), min(xb, self.ancho - 1)
        if va > vb:
            self.ventana.recortados += n
            return
        vis = vb - va + 1
        base = y * self.ancho
        if self.modo == "pixel":
            fb = self.trasero
            for i in range(base + va, base + vb + 1):
                fb[i] = color
        else:
            self.trasero[base + va:base + vb + 1] = array("H", [color]) * vis
        self.ventana.pixeles += vis
        self.ventana.recortados += n - vis

    # -- primitivas -------------------------------------------------------

    def _linea(self, x0, y0, x1, y1, color):
        """draw_line: Bresenham para cualquier pendiente y sentido."""
        w, h, fb = self.ancho, self.alto, self.trasero
        dx = abs(x1 - x0)
        dy = -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        x, y = x0, y0
        dentro = fuera = 0
        while True:
            if 0 <= x < w and 0 <= y < h:
                fb[y * w + x] = color
                dentro += 1
            else:
                fuera += 1
            if x == x1 and y == y1:
                break
            e2 = err + err
            if e2 >= dy:
                err += dy
                x += sx
            if e2 <= dx:
                err += dx
                y += sy
        self.ventana.pixeles += dentro
        self.ventana.recortados += fuera

    def _rect(self, x0, y0, x1, y1, color):
        """draw_rect con fill = 0."""
        xa, xb = min(x0, x1), max(x0, x1)
        ya, yb = min(y0, y1), max(y0, y1)
        self._tramo(ya, xa, xb, color)                       # R_TOP
        if yb == ya:
            return
        self._tramo(yb, xa, xb, color)                       # R_BOT
        if yb <= ya + 1:
            return
        for y in range(ya + 1, yb):                          # R_LEFT
            self._pixel(xa, y, color)
        if xb == xa:
            return
        for y in range(ya + 1, yb):                          # R_RIGHT
            self._pixel(xb, y, color)

    def _rect_fill(self, x0, y0, x1, y1, color):
        """draw_rect con fill = 1 (tambien CLEAR)."""
        xa, xb = min(x0, x1), max(x0, x1)
        ya, yb = min(y0, y1), max(y0, y1)
        ancho_fila = xb - xa + 1
        # Filas fuera de la pantalla: todo recortado, sin recorrerlas
        vya, vyb = max(ya, 0), min(yb, self.alto - 1)
        filas_vis = max(0, vyb - vya + 1)
        self.ventana.recortados += ((yb - ya + 1) - filas_vis) * ancho_fila
        for y in range(vya, vyb + 1):
            self._tramo(y, xa, xb, color)

    def _circ(self, cx, cy, r, color):
        """draw_circle con fill = 0: punto medio, ocho octantes por paso.

        Sigue exactamente K_OUT / K_UPD, incluido el criterio de fin, de
        modo que emite los mismos puntos (y las mismas repeticiones)."""
        px = self._pixel
        x, y, err = r, 0, 0
        while True:
            # K_OUT: oct 0..7, en el mismo orden del multiplexor
            px(_s16(cx + x), _s16(cy + y), color)
            px(_s16(cx + y), _s16(cy + x), color)
            px(_s16(cx - y), _s16(cy + x), color)
            px(_s16(cx - x), _s16(cy + y), color)
            px(_s16(cx - x), _s16(cy - y), color)
            px(_s16(cx - y), _s16(cy - x), color)
            px(_s16(cx + y), _s16(cy - x), color)
            px(_s16(cx + x), _s16(cy - y), color)
            # K_UPD
            if err > 0:
                fin = x <= y
                x, err = x - 1, err - 2 * x + 1
            else:
                e1 = err + 2 * y + 3
                if e1 > 0:
                    fin = x <= y + 1
                    x, y, err = x - 1, y + 1, err + 2 * y - 2 * x + 4
                else:
                    fin = x <= y
                    y, err = y + 1, e1
            if fin:
                return

    def _circ_fill(self, cx, cy, r, color):
        """draw_circle con fill = 1: el hardware recorre el cuadrado de
        lado 2r+1 y deja pasar dx^2 + dy^2 <= r^2. Aqui se calcula el
        tramo de cada fila directamente; los pixeles son los mismos."""
        r2 = r * r
        if self.modo == "pixel":
            px = self._pixel
            for dy in range(-r, r + 1):            # K_FILL, fila a fila
                dy2 = dy * dy
                for dx in range(-r, r + 1):
                    if dx * dx + dy2 <= r2:
                        px(_s16(cx + dx), _s16(cy + dy), color)
            return
        for dy in range(-r, r + 1):
            m = isqrt(r2 - dy * dy)     # mayor dx con dx^2 <= r^2 - dy^2
            self._tramo(cy + dy, cx - m, cx + m, color)

    def _tria(self, x0, y0, x1, y1, x2, y2, color, relleno):
        """draw_trian: orientacion, luego contorno o relleno."""
        ax, ay, bx, by, gx, gy = x0, y0, x1, y1, x2, y2
        pa = (bx - ax) * (gy - ay)                           # T_AREA
        pb = (by - ay) * (gx - ax)
        if pa < pb:                                          # T_ORIENT
            bx, by, gx, gy = gx, gy, bx, by
        if not relleno:
            self._linea(ax, ay, bx, by, color)               # T_E0
            self._linea(bx, by, gx, gy, color)               # T_E1
            self._linea(gx, gy, ax, ay, color)               # T_E2
            return
        if pa == pb:                                         # area nula
            return
        # T_BOX: caja recortada a la pantalla
        bx0 = max(min(ax, bx, gx), 0)
        by0 = max(min(ay, by, gy), 0)
        bx1 = min(max(ax, bx, gx), self.ancho - 1)
        by1 = min(max(ay, by, gy), self.alto - 1)
        if bx0 > bx1 or by0 > by1:
            return
        # Aristas A->B, B->C, C->A: E(x,y) = dx*(y - y0) - dy*(x - x0)
        aristas = []
        for (ox, oy, ex, ey) in ((ax, ay, bx, by), (bx, by, gx, gy),
                                 (gx, gy, ax, ay)):
            ddx, ddy = ex - ox, ey - oy
            tl = ddy < 0 or (ddy == 0 and ddx > 0)           # top-left
            tl = tl or not self.top_left
            e_fila = ddx * (by0 - oy) - ddy * (bx0 - ox)     # T_EVAL/T_SUM
            # dentro: E >= 0 en aristas top-left, E > 0 (E >= 1) en el resto
            aristas.append([e_fila, -ddy, ddx, 0 if tl else 1])
        ultimo = bx1 - bx0
        if self.modo == "pixel":
            (e0, s0, f0, k0), (e1, s1, f1, k1), (e2, s2, f2, k2) = aristas
            w, fb, n = self.ancho, self.trasero, 0
            for y in range(by0, by1 + 1):          # T_FILL
                a0, a1, a2 = e0, e1, e2
                base = y * w
                for x in range(bx0, bx1 + 1):
                    if a0 >= k0 and a1 >= k1 and a2 >= k2:
                        fb[base + x] = color
                        n += 1
                    a0 += s0; a1 += s1; a2 += s2
                e0 += f0; e1 += f1; e2 += f2
            self.ventana.pixeles += n               # la caja ya esta recortada
            return
        for y in range(by0, by1 + 1):
            lo, hi = 0, ultimo
            for a in aristas:
                e, sx, k = a[0], a[1], a[3]
                # e + sx*t >= k  para t en [0, ultimo]
                if sx > 0:
                    lo = max(lo, -((e - k) // sx))           # techo de (k-e)/sx
                elif sx < 0:
                    hi = min(hi, (e - k) // (-sx))           # piso de (e-k)/-sx
                elif e < k:
                    lo, hi = 1, 0
                a[0] = e + a[2]                              # siguiente fila
            if lo <= hi:
                self._tramo(y, bx0 + lo, bx0 + hi, color)

    # -- salida -----------------------------------------------------------

    def buffer_visible(self):
        """El buffer que mostraria el monitor: el delantero si hubo algun
        SWAP; si no, el trasero, donde quedo lo dibujado."""
        return self.delantero if self.swaps else self.trasero

    def png_bytes(self, buffer=None, escala=1):
        """PNG RGB de un buffer (por omision buffer_visible())."""
        fb = self.buffer_visible() if buffer is None else buffer
        w, h = self.ancho, self.alto
        lut = {}
        filas = bytearray()
        for y in range(h):
            fila = bytearray()
            for c in fb[y * w:(y + 1) * w]:
                rgb = lut.get(c)
                if rgb is None:
                    rgb = lut[c] = bytes(rgb565_a_rgb888(c))
                fila += rgb * escala
            for _ in range(escala):
                filas += b"\x00" + fila
        return _png(w * escala, h * escala, bytes(filas))

    def a_png(self, ruta, buffer=None, escala=1):
        """Guarda un buffer (por omision buffer_visible()) como PNG."""
        with open(ruta, "wb") as f:
            f.write(self.png_bytes(buffer, escala))


# --------------------------------------------------------------- auxiliares

def _campos(c):
    """Comando del interprete -> campos del paquete (mismo reparto que el
    codificador): x0 y0 x1 y1 x2 y2 param r g b."""
    a = list(c.args)
    coords = [0] * 6
    if c.nombre in ("circ", "circ_fill"):
        coords[0], coords[1] = a[0], a[1]
        param = a[2]
    else:
        coords[:len(a)] = a
        param = 0
    r, g, b = c.color
    return coords + [param, r, g, b]


def _png(w, h, crudo):
    def bloque(tipo, datos):
        c = tipo + datos
        return (struct.pack(">I", len(datos)) + c
                + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + bloque(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + bloque(b"IDAT", zlib.compress(crudo, 6))
            + bloque(b"IEND", b""))
