"""Pruebas del RasterizadorCPU contra el RTL del proyecto Quartus.
    python -m unittest discover tests

Tres fuentes de verdad:
  1. Fotogramas reales de ModelSim (tests/datos/rtl_tb_64x48.csv), sacados
     de tb_Acelerador_Grafico_Top.sv.
  2. Las comprobaciones numericas del mismo banco de pruebas (cantidad de
     pixeles por comando, regla de relleno, recortes).
  3. Un oraculo: traduccion literal, estado por estado, de draw_line,
     draw_rect, draw_circle y draw_trian, comparado contra el rasterizador
     con comandos al azar dentro, en el borde y lejos de la pantalla.

Todo a 64 x 48, la resolucion de simulacion del RTL.
"""

import os
import random
import unittest

from gfx import constantes as K
from gfx.interprete import InterpreteComandos
from gfx.raster_cpu import (RasterizadorCPU, rgb888_a_rgb565,
                            rgb565_a_rgb888, _s16)

W, H = 64, 48
CENTINELA = 0x1234          # "nunca escrito" (ningun color de las escenas)
DATOS = os.path.join(os.path.dirname(__file__), "datos", "rtl_tb_64x48.csv")
MODOS = RasterizadorCPU.MODOS

PIX, LIN, TRI, TRF = (K.OP_DRAW_PIXEL, K.OP_DRAW_LINE, K.OP_DRAW_TRIA,
                      K.OP_DRAW_TRIA_FILL)
REC, RCF, CIR, CIF = (K.OP_DRAW_RECT, K.OP_DRAW_RECT_FILL, K.OP_DRAW_CIRC,
                      K.OP_DRAW_CIRC_FILL)
CLR, SWP, NOP, INF = K.OP_CLEAR, K.OP_SWAP_BUFFER, K.OP_NOP, K.OP_INF


def cmd(op, x0=0, y0=0, x1=0, y1=0, x2=0, y2=0, r=255, g=255, b=255,
        param=0):
    """Mismo orden de argumentos que la tarea cmd() del banco de pruebas."""
    return (op, x0, y0, x1, y1, x2, y2, param, r, g, b)


def escritos(cmds, modo="tramos", top_left=True):
    """Pixeles escritos {(x, y): color} y el rasterizador, como el
    monitor fbw/fb del banco de pruebas."""
    ras = RasterizadorCPU(W, H, modo, top_left)
    fb = ras.trasero
    for i in range(W * H):
        fb[i] = CENTINELA
    for c in cmds:
        ras.ejecutar_campos(*c)
    px = {(i % W, i // W): v for i, v in enumerate(ras.trasero)
          if v != CENTINELA}
    return px, ras


def emitidos(c, modo="tramos"):
    """Pixeles que escribe un solo comando (la variable 'emitidos' del tb)."""
    _, ras = escritos([c], modo)
    return ras.ventana.pixeles


# Escenas del banco de pruebas, en el mismo orden que alli
ESCENAS_TB = {
    "lineas_bresenham": [
        cmd(LIN, 0, 0, 10, 0, r=0, g=255, b=0),
        cmd(LIN, 0, 0, 0, 10, r=0, g=255, b=0),
        cmd(LIN, 0, 0, 10, 10, r=0, g=255, b=0),
        cmd(LIN, 0, 0, 20, 7, r=0, g=255, b=0),
        cmd(LIN, 5, 5, 5, 5, r=0, g=255, b=0),
        cmd(LIN, -20, 24, 20, 24, r=0, g=255, b=0)],
    "rectangulos": [
        cmd(RCF, 4, 4, 13, 9, r=0, g=0, b=255),
        cmd(REC, 20, 4, 29, 9, r=255, g=255, b=0)],
    "circulos": [
        cmd(CIR, 32, 24, r=0, g=255, b=255, param=10),
        cmd(CIF, 10, 10, r=255, g=0, b=255, param=5)],
    "triangulos": [
        cmd(TRI, 10, 40, 20, 20, 30, 40, r=255, g=0, b=0),
        cmd(TRF, 34, 40, 44, 20, 54, 40, r=0, g=255, b=0)],
    "escena_de_demostracion": [
        cmd(CLR, r=0, g=0, b=0x20),
        cmd(REC, 1, 1, 62, 46),
        cmd(RCF, 4, 4, 16, 14, r=0, g=0, b=255),
        cmd(CIR, 45, 11, r=0, g=255, b=255, param=8),
        cmd(LIN, 4, 20, 59, 20, r=255, g=255, b=0),
        cmd(LIN, 24, 4, 34, 17, r=255, g=0, b=255),
        cmd(TRI, 5, 43, 14, 25, 23, 43, r=255, g=0, b=0),
        cmd(TRF, 28, 43, 37, 25, 46, 43, r=0, g=255, b=0),
        cmd(CIF, 55, 35, r=255, g=0x80, b=0, param=6)],
}
# Simulados con el draw_trian anterior a la regla top-left
ANTES_DE_TOP_LEFT = {"triangulos", "escena_de_demostracion"}


def leer_fotogramas():
    fotos, actual = {}, None
    with open(DATOS) as f:
        for linea in f:
            p = linea.strip().split(";")
            if p[0] == "F":
                actual = fotos[p[2]] = {}
            elif p[0] == "P":
                actual[(int(p[1]), int(p[2]))] = int(p[3], 16)
    return fotos


class TestFotogramasRTL(unittest.TestCase):
    """Pixel a pixel y color a color contra la simulacion del RTL."""

    @classmethod
    def setUpClass(cls):
        cls.fotos = leer_fotogramas()

    def test_fotogramas(self):
        for nombre, cmds in ESCENAS_TB.items():
            for modo in MODOS:
                with self.subTest(fotograma=nombre, modo=modo):
                    px, _ = escritos(cmds, modo,
                                     nombre not in ANTES_DE_TOP_LEFT)
                    self.assertEqual(px, self.fotos[nombre])


class TestComprobacionesDelBanco(unittest.TestCase):
    """Los numeros que verifica tb_Acelerador_Grafico_Top.sv."""

    def test_conversion_de_color(self):
        for (r, g, b), esp in (((0, 0, 0), 0x0000), ((255, 255, 255), 0xFFFF),
                               ((255, 0, 0), 0xF800), ((0, 255, 0), 0x07E0),
                               ((0, 0, 255), 0x001F), ((7, 3, 7), 0x0000),
                               ((8, 4, 8), 0x0821), ((18, 52, 86), 0x11AA)):
            self.assertEqual(rgb888_a_rgb565(r, g, b), esp)
        self.assertEqual(rgb565_a_rgb888(0xFFFF), (255, 255, 255))

    def test_cantidades_por_comando(self):
        casos = [
            ("linea horizontal", cmd(LIN, 0, 0, 10, 0), 11),
            ("linea vertical", cmd(LIN, 0, 0, 0, 10), 11),
            ("diagonal", cmd(LIN, 0, 0, 10, 10), 11),
            ("pendiente suave", cmd(LIN, 0, 0, 20, 7), 21),
            ("linea degenerada", cmd(LIN, 5, 5, 5, 5), 1),
            ("linea recortada", cmd(LIN, -20, 24, 20, 24), 21),
            ("relleno 10x6", cmd(RCF, 4, 4, 13, 9), 60),
            ("contorno 10x6", cmd(REC, 20, 4, 29, 9), 2 * 10 + 2 * 4),
            ("disco r=5", cmd(CIF, 10, 10, param=5), 81),
            ("CLEAR", cmd(CLR), W * H),
            ("relleno desalineado", cmd(RCF, 3, 5, 40, 30), 38 * 26),
            ("rect recortado", cmd(RCF, -5, -3, 12, 4), 13 * 5),
            ("rect abajo a la derecha", cmd(RCF, W - 3, H - 2, W + 9, H + 4),
             3 * 2),
            ("pixel fuera de pantalla", cmd(PIX, -5, 20), 0),
        ]
        for nombre, c, esp in casos:
            for modo in MODOS:
                with self.subTest(nombre, modo=modo):
                    self.assertEqual(emitidos(c, modo), esp)

    def test_descartados_del_rect_recortado(self):
        _, ras = escritos([cmd(RCF, -5, -3, 12, 4)])
        self.assertEqual(ras.ventana.recortados, 18 * 8 - 13 * 5)

    def test_regla_de_relleno(self):
        for modo in MODOS:
            # Diagonal compartida: 400 pixeles, ninguno repetido
            a, _ = escritos([cmd(TRF, 4, 4, 24, 4, 4, 24)], modo)
            b, _ = escritos([cmd(TRF, 24, 4, 4, 24, 24, 24)], modo)
            self.assertEqual(len(a) + len(b), 400)
            self.assertFalse(set(a) & set(b))
            ambos = set(a) | set(b)
            self.assertIn((4, 4), ambos)
            self.assertIn((23, 23), ambos)
            self.assertNotIn((24, 10), ambos)
            self.assertNotIn((10, 24), ambos)
            # Abanico de cuatro alrededor de (40, 24)
            partes = [escritos([cmd(TRF, *v)], modo)[0] for v in (
                (30, 14, 50, 14, 40, 24), (50, 14, 50, 34, 40, 24),
                (50, 34, 30, 34, 40, 24), (30, 34, 30, 14, 40, 24))]
            self.assertEqual(sum(len(p) for p in partes), 400)
            union = set().union(*partes)
            self.assertEqual(len(union), 400)        # ninguno repetido
            self.assertIn((40, 24), union)


class TestContadores(unittest.TestCase):

    def test_nop_y_swap_cuentan_inf_no(self):
        _, ras = escritos([cmd(PIX, 1, 1), cmd(NOP), cmd(SWP), cmd(INF)])
        v = ras.informes[-1]
        self.assertEqual((v.comandos, v.pixeles), (3, 1))
        self.assertEqual(ras.ventana.comandos, 0)     # ventana nueva

    def test_inf_cierra_y_reabre_la_ventana(self):
        _, ras = escritos([cmd(PIX, 1, 1), cmd(INF), cmd(PIX, 2, 2),
                           cmd(PIX, 3, 3), cmd(INF)])
        self.assertEqual([v.comandos for v in ras.informes], [1, 2])

    def test_errores_del_hardware(self):
        _, ras = escritos([cmd(CIR, 30, 30, param=0),        # EC-07
                           cmd(CIF, 30, 30, param=1024),     # EC-07
                           cmd(0x0C)])                       # EC-06
        v = ras.ventana
        self.assertEqual((v.errores, v.comandos, v.pixeles), (3, 0, 0))

    def test_circulo_repite_pixeles_como_el_hardware(self):
        # Los puntos sobre los ejes salen dos veces: 4 repetidos con r=1
        px, ras = escritos([cmd(CIR, 10, 10, param=1)])
        self.assertEqual(ras.ventana.pixeles, 8)
        self.assertEqual(len(px), 4)

    def test_doble_buffer(self):
        ras = RasterizadorCPU(W, H)
        ras.ejecutar_campos(*cmd(CLR, r=255, g=0, b=0))
        self.assertEqual(ras.pixel(0, 0), 0xF800)             # trasero
        self.assertEqual(ras.delantero[0], 0)                 # aun negro
        ras.ejecutar_campos(*cmd(SWP))
        self.assertEqual(ras.delantero[0], 0xF800)
        self.assertIs(ras.buffer_visible(), ras.delantero)

    def test_comandos_del_interprete(self):
        res = InterpreteComandos().analizar_texto(
            "color 255 0 0\ncirc_fill 320 240 10\nswap\ninf")
        ras = RasterizadorCPU()
        ras.ejecutar(res.comandos)
        v = ras.informes[-1]
        self.assertEqual(v.comandos, 2)
        self.assertEqual(ras.delantero[240 * 640 + 320], 0xF800)

    def test_png(self):
        ras = RasterizadorCPU(W, H)
        ras.ejecutar_campos(*cmd(CLR, r=0, g=255, b=0))
        png = ras.png_bytes()
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))

    def test_modo_invalido(self):
        with self.assertRaises(ValueError):
            RasterizadorCPU(modo="rapido")


# ------------------------------------------------------- oraculo literal

def o_linea(x, y, xe, ye):
    """draw_line, estado L_RUN."""
    dx, dy = abs(xe - x), -abs(ye - y)
    sx, sy = (1 if x < xe else -1), (1 if y < ye else -1)
    err = dx + dy
    while True:
        yield x, y
        if x == xe and y == ye:
            return
        e2 = err + err
        en, xn, yn = err, x, y
        if e2 >= dy:
            en += dy
            xn += sx
        if e2 <= dx:
            en += dx
            yn += sy
        err, x, y = en, xn, yn


def o_rect(x0, y0, x1, y1, fill):
    """draw_rect: R_FILL por tramos alineados de 8, o R_TOP..R_RIGHT."""
    xa, xb, ya, yb = min(x0, x1), max(x0, x1), min(y0, y1), max(y0, y1)
    cx, cy = xa, ya
    if fill:
        while True:
            fin = min(_s16(cx | 7), xb)
            for x in range(cx, fin + 1):
                yield x, cy
            if fin == xb:
                cx = xa
                if cy == yb:
                    return
                cy += 1
            else:
                cx = fin + 1
    st = "TOP"
    while True:
        yield cx, cy
        if st in ("TOP", "BOT"):
            if cx == xb:
                if st == "TOP":
                    cx, cy = xa, yb
                    if yb == ya:
                        return
                    st = "BOT"
                else:
                    cx, cy = xa, ya + 1
                    if yb <= ya + 1:
                        return
                    st = "LEFT"
            else:
                cx += 1
        elif st == "LEFT":
            if cy == yb - 1:
                cy, cx = ya + 1, xb
                if xb == xa:
                    return
                st = "RIGHT"
            else:
                cy += 1
        else:
            if cy == yb - 1:
                return
            cy += 1


def o_circ(cx, cy, rr, fill):
    """draw_circle: K_FILL sobre el cuadrado, o K_OUT / K_UPD."""
    if fill:
        r2 = rr * rr
        dx2 = dy2 = r2
        dx = dy = -rr
        while True:
            if dx2 + dy2 <= r2:
                yield _s16(cx + dx), _s16(cy + dy)
            if dx == rr:
                dx, dx2 = -rr, r2
                if dy == rr:
                    return
                dy2 += 2 * dy + 1
                dy += 1
            else:
                dx2 += 2 * dx + 1
                dx += 1
    x, y, err = rr, 0, 0
    while True:
        for ox, oy in ((cx + x, cy + y), (cx + y, cy + x), (cx - y, cy + x),
                       (cx - x, cy + y), (cx - x, cy - y), (cx - y, cy - x),
                       (cx + y, cy - x), (cx + x, cy - y)):
            yield _s16(ox), _s16(oy)
        e1 = err + 2 * y + 3
        if err > 0:
            ux, uy, ue, fin = x - 1, y, err - 2 * x + 1, x <= y
        elif e1 > 0:
            ux, uy, ue, fin = x - 1, y + 1, err + 2 * y - 2 * x + 4, x <= y + 1
        else:
            ux, uy, ue, fin = x, y + 1, e1, x <= y
        err, x, y = ue, ux, uy
        if fin:
            return


def o_tria(ax, ay, bx, by, gx, gy, fill):
    """draw_trian: T_ORIENT, luego T_E0..T_E2 o T_FILL pixel a pixel."""
    pa, pb = (bx - ax) * (gy - ay), (by - ay) * (gx - ax)
    if pa < pb:
        bx, by, gx, gy = gx, gy, bx, by
    if not fill:
        yield from o_linea(ax, ay, bx, by)
        yield from o_linea(bx, by, gx, gy)
        yield from o_linea(gx, gy, ax, ay)
        return
    if pa == pb:
        return
    bx0, by0 = max(min(ax, bx, gx), 0), max(min(ay, by, gy), 0)
    bx1, by1 = min(max(ax, bx, gx), W - 1), min(max(ay, by, gy), H - 1)
    aristas = ((ax, ay, bx, by), (bx, by, gx, gy), (gx, gy, ax, ay))
    for y in range(by0, by1 + 1):
        for x in range(bx0, bx1 + 1):
            dentro = True
            for ox, oy, ex, ey in aristas:
                ddx, ddy = ex - ox, ey - oy
                e = ddx * (y - oy) - ddy * (x - ox)
                tl = ddy < 0 or (ddy == 0 and ddx > 0)
                dentro &= (e >= 0) if tl else (e > 0)
            if dentro:
                yield x, y


def oraculo(op, a):
    x0, y0, x1, y1, x2, y2, r = a
    gen = {PIX: lambda: iter([(x0, y0)]),
           LIN: lambda: o_linea(x0, y0, x1, y1),
           REC: lambda: o_rect(x0, y0, x1, y1, False),
           RCF: lambda: o_rect(x0, y0, x1, y1, True),
           CLR: lambda: o_rect(0, 0, W - 1, H - 1, True),
           CIR: lambda: o_circ(x0, y0, r, False),
           CIF: lambda: o_circ(x0, y0, r, True),
           TRI: lambda: o_tria(x0, y0, x1, y1, x2, y2, False),
           TRF: lambda: o_tria(x0, y0, x1, y1, x2, y2, True)}[op]()
    vis, dentro, fuera = set(), 0, 0
    for x, y in gen:
        if 0 <= x < W and 0 <= y < H:
            vis.add((x, y))
            dentro += 1
        else:
            fuera += 1
    return vis, dentro, fuera


class TestOraculoRTL(unittest.TestCase):
    """Comandos al azar: mismo conjunto de pixeles, mismos escritos y
    mismos recortados que la traduccion literal del RTL."""

    CASOS = 1800

    def test_al_azar(self):
        rnd = random.Random(1114)
        ops = [PIX, LIN, REC, RCF, CLR, CIR, CIF, TRI, TRF]
        for i in range(self.CASOS):
            op = ops[i % len(ops)]
            margen = rnd.choice([20, 70, 200])      # cerca, borde, lejos
            a = [rnd.randint(-margen, W + margen) for _ in range(6)]
            a.append(rnd.randint(1, 40 if margen < 200 else 300))
            if rnd.random() < 0.15:                 # degenerados
                a[2], a[3] = a[0], a[1]
            if rnd.random() < 0.05:
                a[4], a[5] = a[0], a[1]
            vis, dentro, fuera = oraculo(op, a)
            modo = MODOS[i % 2]
            px, ras = escritos([(op, *a, 0, 0, 0)], modo)
            with self.subTest(op=op, args=a, modo=modo):
                self.assertEqual(set(px), vis)
                self.assertEqual(ras.ventana.pixeles, dentro)
                self.assertEqual(ras.ventana.recortados, fuera)

    def test_extremos_de_16_bits(self):
        for op, a in ((CIR, [32767, 32767, 0, 0, 0, 0, 1023]),
                      (CIR, [-32768, 10, 0, 0, 0, 0, 1023]),
                      (CIF, [32700, -32700, 0, 0, 0, 0, 1023]),
                      (LIN, [-32768, 24, 32767, 24, 0, 0, 0]),
                      (TRF, [-32768, -32768, 32767, 0, 0, 32767, 0])):
            vis, dentro, fuera = oraculo(op, a)
            px, ras = escritos([(op, *a, 1, 1, 1)])
            with self.subTest(op=op, args=a):
                self.assertEqual(set(px), vis)
                self.assertEqual((ras.ventana.pixeles, ras.ventana.recortados),
                                 (dentro, fuera))


if __name__ == "__main__":
    unittest.main()
