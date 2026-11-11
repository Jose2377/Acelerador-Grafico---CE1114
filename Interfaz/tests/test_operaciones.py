"""Pruebas de los flujos de gfx/operaciones.py: CPU, reporte CSV y la
comparacion CPU vs FPGA (CU-04) contra el servidor simulado.
    python -m unittest discover tests
"""

import csv
import os
import shutil
import tempfile
import threading
import unittest

from gfx import config as cfgmod
from gfx import operaciones
from gfx.interprete import InterpreteComandos
from gfx.reporte import CAMPOS
from servidor_simulado import ServidorSimulado

ESCENA = """color 0 0 64
clear
color 255 255 0
circ_fill 320 240 100
tria_fill 0 479 639 479 320 200
line 0 0 639 479
"""


def comandos(texto):
    res = InterpreteComandos().analizar_texto(texto)
    assert not res.errores
    return res.comandos


class ConCarpeta(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.cfg = dict(cfgmod.PREDETERMINADO)
        self.cfg["ruta_reportes"] = os.path.join(self.dir, "r.csv")
        self.log = []

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def registrar(self, texto, tag=None):
        self.log.append((texto, tag))

    def filas(self):
        with open(self.cfg["ruta_reportes"], newline="") as f:
            return list(csv.DictReader(f))


class TestCPU(ConCarpeta):

    def test_reporte_y_png(self):
        png = os.path.join(self.dir, "e.png")
        ras, filas = operaciones.ejecutar_cpu(
            comandos(ESCENA + "inf"), self.cfg, self.registrar, "tramos",
            "escena", png)
        self.assertEqual(len(filas), 1)
        self.assertTrue(os.path.getsize(png) > 0)
        f = self.filas()
        self.assertEqual(f[0]["origen"], "cpu-tramos")
        self.assertEqual(f[0]["escena"], "escena")
        self.assertEqual(int(f[0]["comandos"]), 4)

    def test_mismos_contadores_en_los_dos_modos(self):
        _, a = operaciones.ejecutar_cpu(comandos(ESCENA + "inf"), self.cfg,
                                        self.registrar, "tramos")
        _, b = operaciones.ejecutar_cpu(comandos(ESCENA + "inf"), self.cfg,
                                        self.registrar, "pixel")
        for k in ("comandos", "pixeles", "recortados"):
            self.assertEqual(a[0][k], b[0][k])

    def test_csv_viejo_se_renombra(self):
        with open(self.cfg["ruta_reportes"], "w") as f:
            f.write("marca_tiempo,ciclos\n2026-01-01,5\n")
        operaciones.ejecutar_cpu(comandos("clear"), self.cfg, self.registrar)
        self.assertEqual(self.filas()[0].keys(), set(CAMPOS) | set())
        viejos = [n for n in os.listdir(self.dir) if n.startswith("r_")]
        self.assertEqual(len(viejos), 1)


class TestComparar(ConCarpeta):

    def setUp(self):
        super().setUp()
        self.srv = ServidorSimulado(puerto=0, anunciar=False)
        self.hilo = threading.Thread(target=self.srv.servir, daemon=True)
        self.hilo.start()
        self.cfg.update(host="127.0.0.1", puerto=self.srv.puerto,
                        timeout_s=5.0)

    def tearDown(self):
        self.srv.parar()
        self.hilo.join(timeout=2)
        super().tearDown()

    def test_contadores_coinciden(self):
        _, cpu, hw = operaciones.comparar(comandos(ESCENA), self.cfg,
                                          self.registrar, escena="e")
        self.assertIsNotNone(hw)
        self.assertEqual(cpu["pixeles"], hw["pixeles"])
        self.assertEqual(cpu["comandos"], hw["comandos"])
        textos = " ".join(t for t, _ in self.log)
        self.assertIn("Se agrego 'inf'", textos)
        self.assertIn("Razon de tiempos", textos)
        self.assertIn("coinciden", textos)
        origenes = [f["origen"] for f in self.filas()]
        self.assertEqual(origenes, ["cpu-tramos", "fpga"])

    def test_sin_servidor(self):
        self.cfg["puerto"] = 1
        _, cpu, hw = operaciones.comparar(comandos("clear"), self.cfg,
                                          self.registrar)
        self.assertIsNone(hw)
        self.assertIsNotNone(cpu)


if __name__ == "__main__":
    unittest.main()
