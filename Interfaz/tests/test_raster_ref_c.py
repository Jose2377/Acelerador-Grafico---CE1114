"""Referencia en C del HPS (Linux/ejemplos/servicio/raster_ref.c) contra
RasterizadorCPU, que a su vez esta comparado con el RTL.

    python -m unittest tests.test_raster_ref_c

Compila prueba_raster_ref.c con el compilador de C de la PC (cc o gcc).
Si no hay compilador la prueba se omite.
"""

import os
import random
import shutil
import struct
import subprocess
import tempfile
import unittest
from array import array

from gfx import constantes as K
from gfx.codificador import CodificadorPaquete
from gfx.comando import Comando
from gfx.raster_cpu import RasterizadorCPU

W, H = 64, 48
SERVICIO = os.path.join(os.path.dirname(__file__), "..", "..", "Linux",
                        "ejemplos", "servicio")
CC = shutil.which("cc") or shutil.which("gcc")
NOMBRES = {K.OP_DRAW_PIXEL: "pixel", K.OP_DRAW_LINE: "line",
           K.OP_DRAW_RECT: "rect", K.OP_DRAW_RECT_FILL: "rect_fill",
           K.OP_DRAW_CIRC: "circ", K.OP_DRAW_CIRC_FILL: "circ_fill",
           K.OP_DRAW_TRIA: "tria", K.OP_DRAW_TRIA_FILL: "tria_fill",
           K.OP_CLEAR: "clear", K.OP_SWAP_BUFFER: "swap", K.OP_NOP: "nop"}
NARGS = {"pixel": 2, "line": 4, "rect": 4, "rect_fill": 4, "circ": 3,
         "circ_fill": 3, "tria": 6, "tria_fill": 6, "clear": 0, "swap": 0,
         "nop": 0}


@unittest.skipUnless(CC, "no hay compilador de C")
class TestReferenciaC(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.exe = os.path.join(cls.dir, "prueba_raster_ref")
        subprocess.run([CC, "-O2", "-o", cls.exe,
                        os.path.join(SERVICIO, "prueba_raster_ref.c"),
                        os.path.join(SERVICIO, "raster_ref.c")], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def ejecutar_c(self, comandos):
        datos = comandos if isinstance(comandos, bytes) else \
            CodificadorPaquete().codificar_lote(comandos)
        out = subprocess.run([self.exe, str(W), str(H)], input=datos,
                             capture_output=True, check=True).stdout
        cmds, pix, errs = struct.unpack("<III", out[:12])
        fb = array("H")
        fb.frombytes(out[12:])
        return (cmds, pix, errs), list(fb)

    def ejecutar_py(self, comandos):
        ras = RasterizadorCPU(W, H)
        ras.ejecutar(comandos)
        v = ras.ventana
        return (v.comandos, v.pixeles, v.errores), list(ras.trasero)

    def comparar(self, comandos, nombre):
        c, fc = self.ejecutar_c(comandos)
        p, fp = self.ejecutar_py(comandos)
        with self.subTest(nombre):
            self.assertEqual(c, p)
            self.assertEqual(fc, fp)

    def test_al_azar(self):
        rnd = random.Random(2026)
        ops = list(NARGS)
        for i in range(600):
            margen = rnd.choice([20, 70, 200, 40000])
            cmds = []
            for _ in range(rnd.randint(1, 6)):
                nombre = rnd.choice(ops)
                if margen == 40000:
                    args = [rnd.randint(-32768, 32767)
                            for _ in range(NARGS[nombre])]
                else:
                    args = [rnd.randint(-margen, W + margen)
                            for _ in range(NARGS[nombre])]
                if nombre in ("circ", "circ_fill"):
                    args[2] = rnd.randint(1, 1023 if margen > 70 else 40)
                op = K.TABLA_COMANDOS.get(nombre, (K.OP_NOP, 0))[0]
                color = tuple(rnd.randint(0, 255) for _ in range(3))
                cmds.append(Comando(nombre, op, args, color, 0))
            self.comparar(cmds, "caso {}".format(i))

    def test_errores_de_hardware(self):
        # radio 0 (EC-07), opcode 0x0C (EC-06) y un pixel valido
        cod = CodificadorPaquete()
        datos = (cod.codificar(Comando("circ", K.OP_DRAW_CIRC, [10, 10, 0],
                                       (1, 2, 3), 0))
                 + struct.pack("<6I", 0x0C << 24, 0, 0, 0, 0, 0)
                 + cod.codificar(Comando("pixel", K.OP_DRAW_PIXEL, [3, 3],
                                         (255, 0, 0), 0)))
        (c, p, e), _ = self.ejecutar_c(datos)
        self.assertEqual((c, p, e), (1, 1, 2))


if __name__ == "__main__":
    unittest.main()
