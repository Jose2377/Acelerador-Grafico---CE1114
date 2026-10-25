"""Pruebas del interprete. Ejecutar desde la carpeta Interfaz:
    python -m unittest discover tests
"""

import unittest

from gfx import constantes as K
from gfx.interprete import InterpreteComandos


def analizar(texto):
    return InterpreteComandos().analizar_texto(texto)


def codigo(texto):
    res = analizar(texto)
    return res.errores[0].codigo if res.errores else None


class TestValidos(unittest.TestCase):

    def test_todas_las_operaciones(self):
        res = analizar("""
            color 10 20 30
            pixel 1 2
            line 0 0 639 479
            rect 0 0 10 10
            rect_fill 0 0 10 10
            tria 0 0 10 0 5 5
            tria_fill 0 0 10 0 5 5
            circ 100 100 50
            circ_fill 100 100 1023
            clear
            swap
            inf
        """)
        self.assertEqual(res.rechazados, 0)
        self.assertEqual(res.total_lineas, 12)
        self.assertEqual(res.aceptados, 11)    # 'color' no genera paquete

    def test_opcodes(self):
        res = analizar("pixel 1 2\nswap\ninf")
        self.assertEqual([c.opcode for c in res.comandos],
                         [K.OP_DRAW_PIXEL, K.OP_SWAP_BUFFER, K.OP_INF])

    def test_color_vigente(self):
        res = analizar("pixel 0 0\ncolor 1 2 3\npixel 1 1\nline 0 0 1 1\n"
                       "color 9 9 9\nclear")
        colores = [c.color for c in res.comandos]
        self.assertEqual(colores[0], (255, 255, 255))   # color inicial
        self.assertEqual(colores[1], (1, 2, 3))
        self.assertEqual(colores[2], (1, 2, 3))
        self.assertEqual(colores[3], (9, 9, 9))

    def test_color_rechazado_no_cambia_estado(self):
        res = analizar("color 1 2 3\ncolor 300 0 0\npixel 0 0")
        self.assertEqual(res.comandos[0].color, (1, 2, 3))

    def test_fuera_de_pantalla_es_valido(self):
        res = analizar("rect_fill -100 -100 2000 2000\n"
                       "pixel -32768 32767")
        self.assertEqual(res.rechazados, 0)

    def test_comentarios_y_lineas_vacias(self):
        res = analizar("# solo comentario\n\n   \npixel 1 1  # al final\n")
        self.assertEqual(res.total_lineas, 1)
        self.assertEqual(res.comandos[0].args, [1, 1])

    def test_signo_explicito_y_mayusculas(self):
        res = analizar("PIXEL +5 -5")
        self.assertEqual(res.comandos[0].args, [5, -5])
        self.assertEqual(res.comandos[0].nombre, "pixel")

    def test_numero_de_linea(self):
        res = analizar("\n\npixel 1 1")
        self.assertEqual(res.comandos[0].linea_num, 3)


class TestErrores(unittest.TestCase):

    def test_ec01_operacion_inexistente(self):
        self.assertEqual(codigo("dibujar 1 2"), K.EC_01)

    def test_ec02_faltan_argumentos(self):
        res = analizar("rect 40 40 280")
        e = res.errores[0]
        self.assertEqual(e.codigo, K.EC_02)
        self.assertIn("espera 4 argumentos enteros, se recibieron 3",
                      e.razon)

    def test_ec02_sobran_argumentos(self):
        self.assertEqual(codigo("swap 1"), K.EC_02)
        self.assertEqual(codigo("pixel 1 2 3"), K.EC_02)

    def test_ec03_no_entero(self):
        for t in ("pixel 1.5 2", "pixel a 2", "pixel 0x10 2", "pixel 1e3 2"):
            self.assertEqual(codigo(t), K.EC_03, t)

    def test_ec03_fuera_de_16_bits(self):
        self.assertEqual(codigo("pixel 32768 0"), K.EC_03)
        self.assertEqual(codigo("pixel -32769 0"), K.EC_03)
        self.assertEqual(codigo("color 40000 0 0"), K.EC_03)

    def test_ec04_radio(self):
        res = analizar("circ 160 380 0")
        e = res.errores[0]
        self.assertEqual(e.codigo, K.EC_04)
        self.assertIn("entre 1 y 1023, se recibio 0", e.razon)
        self.assertEqual(codigo("circ_fill 0 0 1024"), K.EC_04)

    def test_ec04_color(self):
        self.assertEqual(codigo("color 256 0 0"), K.EC_04)
        self.assertEqual(codigo("color 0 -1 0"), K.EC_04)

    def test_resumen_con_errores(self):
        res = analizar("pixel 1 1\ncirc 0 0 0\nrect 1 1 1")
        self.assertEqual(res.resumen(),
                         "Se rechazaron 2 de 3 comandos. "
                         "No se transmitio ningun paquete.")

    def test_formato_mensaje(self):
        res = analizar("rect 40 40 280")
        self.assertTrue(str(res.errores[0]).startswith(
            "Error EC-02: 'rect 40 40 280'"))


if __name__ == "__main__":
    unittest.main()
