"""Pruebas del codificador de paquetes (Figura 4).
    python -m unittest discover tests
"""

import struct
import unittest

from gfx import constantes as K
from gfx.codificador import CodificadorPaquete, decodificar, volcado
from gfx.interprete import InterpreteComandos


def comandos(texto):
    res = InterpreteComandos().analizar_texto(texto)
    assert not res.errores, res.errores
    return res.comandos


def un_paquete(texto):
    return CodificadorPaquete().codificar(comandos(texto)[0])


class TestFormato(unittest.TestCase):

    def test_longitud(self):
        for t in ("pixel 1 1", "tria_fill 0 0 1 1 2 2", "swap", "clear"):
            self.assertEqual(len(un_paquete(t)), 24, t)

    def test_disposicion_exacta_w0_a_w5(self):
        # tria_fill: usa los tres vertices y el color
        p = un_paquete("color 18 0 0\ntria_fill 1 2 3 4 5 6")
        ws = struct.unpack("<6I", p)
        self.assertEqual(ws[0], 0x04000000)                 # op, flags, seq 0
        self.assertEqual(ws[1], 0x00010002)
        self.assertEqual(ws[2], 0x00030004)
        self.assertEqual(ws[3], 0x00050006)
        self.assertEqual(ws[4], 0x00120000)                 # R=18, G=0, B=0
        self.assertEqual(ws[5], 0)

    def test_color_en_w4(self):
        p = un_paquete("color 1 2 3\npixel 0 0")
        self.assertEqual(struct.unpack("<6I", p)[4], 0x00010203)

    def test_little_endian_por_palabra(self):
        p = un_paquete("pixel 0 0")
        self.assertEqual(p[0:4], bytes([0x00, 0x00, 0x00, 0x01]))  # opcode en byte 3

    def test_coordenadas_negativas_complemento_a_dos(self):
        ws = struct.unpack("<6I", un_paquete("pixel -1 -32768"))
        self.assertEqual(ws[1], 0xFFFF8000)

    def test_radio_en_param(self):
        d = decodificar(un_paquete("circ 100 200 1023"))
        self.assertEqual((d["x0"], d["y0"], d["param"]), (100, 200, 1023))
        self.assertEqual((d["x1"], d["y1"]), (0, 0))

    def test_campos_no_usados_y_reservados_en_cero(self):
        d = decodificar(un_paquete("color 9 9 9\nswap"))
        self.assertEqual(d["opcode"], K.OP_SWAP_BUFFER)
        for k in ("x0", "y0", "x1", "y1", "x2", "y2", "r", "g", "b",
                  "param", "res_w4", "res_w5", "flags"):
            self.assertEqual(d[k], 0, k)

    def test_clear_lleva_color(self):
        d = decodificar(un_paquete("color 10 20 30\nclear"))
        self.assertEqual((d["opcode"], d["r"], d["g"], d["b"]),
                         (K.OP_CLEAR, 10, 20, 30))

    def test_flags(self):
        d = decodificar(CodificadorPaquete().codificar(
            comandos("inf")[0], flags=0xA5))
        self.assertEqual((d["opcode"], d["flags"]), (K.OP_INF, 0xA5))


class TestSecuencia(unittest.TestCase):

    def test_seq_incrementa(self):
        cod = CodificadorPaquete()
        lote = cod.codificar_lote(comandos("pixel 0 0\npixel 1 1\nswap"))
        seqs = [decodificar(lote[i:i + 24])["seq_id"]
                for i in range(0, len(lote), 24)]
        self.assertEqual(seqs, [0, 1, 2])

    def test_seq_da_la_vuelta(self):
        cod = CodificadorPaquete(seq_inicial=0xFFFF)
        c = comandos("swap")[0]
        self.assertEqual(decodificar(cod.codificar(c))["seq_id"], 0xFFFF)
        self.assertEqual(decodificar(cod.codificar(c))["seq_id"], 0)


class TestIdaYVuelta(unittest.TestCase):

    def test_todas_las_operaciones(self):
        texto = """color 255 128 7
                   pixel -5 479
                   line 0 0 639 479
                   rect -32768 0 32767 10
                   rect_fill 1 2 3 4
                   tria 10 20 30 40 50 60
                   tria_fill -1 -2 -3 -4 -5 -6
                   circ 320 240 1
                   circ_fill 0 0 1023
                   clear
                   swap
                   inf"""
        cod = CodificadorPaquete()
        for c in comandos(texto):
            d = decodificar(cod.codificar(c))
            self.assertEqual(d["opcode"], c.opcode, c)
            nombres = ["x0", "y0", "x1", "y1", "x2", "y2"]
            if c.nombre in ("circ", "circ_fill"):
                self.assertEqual([d["x0"], d["y0"], d["param"]], c.args)
            else:
                self.assertEqual([d[k] for k in nombres[:len(c.args)]],
                                 c.args, c)
            if c.nombre not in ("swap", "inf"):
                self.assertEqual((d["r"], d["g"], d["b"]), c.color)

    def test_longitud_invalida(self):
        with self.assertRaises(ValueError):
            decodificar(b"\x00" * 23)

    def test_volcado(self):
        self.assertEqual(volcado(un_paquete("swap")),
                         "0A000000 00000000 00000000 00000000 "
                         "00000000 00000000")


if __name__ == "__main__":
    unittest.main()
