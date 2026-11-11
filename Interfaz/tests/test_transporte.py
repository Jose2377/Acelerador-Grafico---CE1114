"""Pruebas del protocolo TCP y de ClienteTransporte contra el servidor
simulado del HPS (sin tarjeta).
    python -m unittest discover tests
"""

import socket
import struct
import threading
import unittest

from gfx import constantes as K
from gfx import protocolo as P
from gfx.codificador import CodificadorPaquete
from gfx.interprete import InterpreteComandos
from gfx.transporte import ClienteTransporte, ErrorTransporte
from servidor_simulado import ServidorSimulado


def paquetes(texto):
    res = InterpreteComandos().analizar_texto(texto)
    assert not res.errores
    return CodificadorPaquete().codificar_lote(res.comandos)


class TestProtocolo(unittest.TestCase):

    def test_encabezado_8_bytes_orden_de_red(self):
        m = P.empaquetar(K.TIPO_LOTE, b"\x00" * 48, secuencia=0x01020304,
                         banderas=K.BANDERA_INICIO_VENTANA)
        self.assertEqual(m[:8], bytes([1, 1, 0, 48, 1, 2, 3, 4]))
        self.assertEqual(len(m), 8 + 48)

    def test_ida_y_vuelta_encabezado(self):
        m = P.empaquetar(K.TIPO_SOLICITUD, secuencia=77)
        self.assertEqual(P.leer_encabezado(m), (K.TIPO_SOLICITUD, 0, 0, 77))

    def test_lote_debe_ser_multiplo_de_24(self):
        for n in (0, 23, 25):
            with self.assertRaises(P.ErrorProtocolo):
                P.empaquetar(K.TIPO_LOTE, b"\x00" * n)

    def test_lote_maximo(self):
        P.empaquetar(K.TIPO_LOTE, b"\x00" * K.LONGITUD_MAX)
        with self.assertRaises(P.ErrorProtocolo):
            P.empaquetar(K.TIPO_LOTE, b"\x00" * (K.LONGITUD_MAX + 24))

    def test_tipo_desconocido(self):
        with self.assertRaises(P.ErrorProtocolo):
            P.leer_encabezado(bytes([9, 0, 0, 0, 0, 0, 0, 0]))

    def test_reporte(self):
        c = P.carga_reporte(1, 2, 3, 4, 5)
        self.assertEqual(len(c), K.TAM_REPORTE)
        self.assertEqual(P.leer_reporte(c), dict(
            ciclos=1, comandos=2, pixeles=3, errores=4, descartados=5))

    def test_error(self):
        self.assertEqual(P.leer_error(P.carga_error("EC-08", "cola llena")),
                         ("EC-08", "cola llena"))


class ConServidor(unittest.TestCase):

    fallar_lote = 0

    def setUp(self):
        self.srv = ServidorSimulado(puerto=0, fallar_lote=self.fallar_lote,
                                    anunciar=False)
        self.hilo = threading.Thread(target=self.srv.servir, daemon=True)
        self.hilo.start()
        self.cli = ClienteTransporte("127.0.0.1", self.srv.puerto,
                                     timeout=3.0)

    def tearDown(self):
        self.cli.cerrar()
        self.srv.parar()
        self.hilo.join(timeout=2)


class TestTransporte(ConServidor):

    def test_escena_y_reporte(self):
        self.cli.conectar()
        n = self.cli.enviar_escena(paquetes(
            "clear\nrect_fill 0 0 9 9\npixel 1 1\ninf"))
        self.assertEqual(n, 1)
        r = self.cli.solicitar_reporte()
        self.assertEqual(r["comandos"], 3)                 # inf no cuenta
        self.assertEqual(r["pixeles"], 640 * 480 + 100 + 1)
        self.assertIn("extremo_a_extremo_s", r)

    def test_division_en_lotes_y_orden(self):
        self.cli.tam_lote = 4
        self.cli.conectar()
        texto = "\n".join("pixel {} 0".format(i) for i in range(10))
        n = self.cli.enviar_escena(paquetes(texto))
        self.cli.vaciar()
        self.cli.solicitar_reporte()
        self.assertEqual(n, 3)                             # 4 + 4 + 2
        self.assertEqual(self.srv.lotes_recibidos, 3)
        self.assertEqual([s for _, s in self.srv.historial], list(range(10)))

    def test_bandera_inicio_ventana_reinicia_contadores(self):
        self.cli.conectar()
        self.cli.enviar_escena(paquetes("pixel 1 1\ninf"))
        self.cli.solicitar_reporte()
        self.cli.enviar_escena(paquetes("pixel 1 1\npixel 2 2\ninf"))
        self.assertEqual(self.cli.solicitar_reporte()["comandos"], 2)

    def test_sin_conexion(self):
        with self.assertRaises(ErrorTransporte):
            self.cli.enviar_lote(paquetes("swap"))

    def test_rechaza_bytes_sueltos(self):
        self.cli.conectar()
        with self.assertRaises(ValueError):
            self.cli.enviar_lote(b"\x00" * 10)


class TestFallos(ConServidor):

    fallar_lote = 1

    def test_ec05_del_servicio(self):
        self.cli.conectar()
        self.cli.enviar_escena(paquetes("pixel 1 1\ninf"))
        with self.assertRaises(ErrorTransporte) as ctx:
            self.cli.solicitar_reporte()
        self.assertEqual(ctx.exception.codigo, K.EC_05)


class TestSinServidor(unittest.TestCase):

    def test_conexion_rechazada_es_ec05(self):
        s = socket.socket(); s.bind(("127.0.0.1", 0))
        puerto = s.getsockname()[1]; s.close()            # puerto libre
        cli = ClienteTransporte("127.0.0.1", puerto, timeout=1.0)
        with self.assertRaises(ErrorTransporte) as ctx:
            cli.conectar()
        self.assertEqual(ctx.exception.codigo, K.EC_05)

    def test_timeout_sin_reporte(self):
        srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
        mudo = []
        threading.Thread(target=lambda: mudo.append(srv.accept()),
                         daemon=True).start()
        cli = ClienteTransporte("127.0.0.1", srv.getsockname()[1],
                                timeout=0.5)
        try:
            cli.conectar()
            with self.assertRaises(ErrorTransporte):
                cli.solicitar_reporte()
        finally:
            cli.cerrar(); srv.close()
            for conn, _ in mudo:
                conn.close()


if __name__ == "__main__":
    unittest.main()
