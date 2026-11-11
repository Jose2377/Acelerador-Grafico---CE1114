#!/usr/bin/env python3
"""Servidor que simula el servicio del HPS, para probar la interfaz sin
la tarjeta. Habla el mismo protocolo (PROTOCOLO.md): recibe lotes,
decodifica los paquetes, lleva contadores aproximados y responde las
solicitudes de reporte.

Uso:
  python servidor_simulado.py                  escucha en 127.0.0.1:5000
  python servidor_simulado.py --puerto 6000 -v
  python servidor_simulado.py --fallar-lote 2  responde EC-05 al 2do lote

Para usarlo, poner "host": "127.0.0.1" en config.json (o en la barra de
la ventana).

Los contadores son estimaciones, no los del hardware: sirven para
comprobar el camino de ida y vuelta, no para medir rendimiento.
"""

import argparse
import math
import socket
import threading

from gfx import constantes as K
from gfx import protocolo as P
from gfx.codificador import decodificar

AREA = K.ANCHO_PANTALLA * K.ALTO_PANTALLA
CICLOS_POR_COMANDO = 8       # costo fijo estimado de decodificacion


def _recorte(x0, y0, x1, y1):
    """Area visible de un rectangulo, en pixeles."""
    xa, xb = sorted((x0, x1))
    ya, yb = sorted((y0, y1))
    ancho = min(xb, K.ANCHO_PANTALLA - 1) - max(xa, 0) + 1
    alto = min(yb, K.ALTO_PANTALLA - 1) - max(ya, 0) + 1
    return max(ancho, 0) * max(alto, 0)


def pixeles_estimados(d):
    """Pixeles que escribiria el comando (aprox., sin recorte fino)."""
    op = d["opcode"]
    x0, y0, x1, y1, x2, y2 = (d[k] for k in ("x0", "y0", "x1", "y1", "x2", "y2"))
    if op == K.OP_DRAW_PIXEL:
        return 1 if 0 <= x0 < K.ANCHO_PANTALLA and 0 <= y0 < K.ALTO_PANTALLA else 0
    if op == K.OP_DRAW_LINE:
        return max(abs(x1 - x0), abs(y1 - y0)) + 1
    if op == K.OP_DRAW_RECT:
        return 2 * (abs(x1 - x0) + abs(y1 - y0))
    if op == K.OP_DRAW_RECT_FILL:
        return _recorte(x0, y0, x1, y1)
    if op == K.OP_DRAW_TRIA:
        return sum(max(abs(a - c), abs(b - e)) for a, b, c, e in
                   ((x0, y0, x1, y1), (x1, y1, x2, y2), (x2, y2, x0, y0)))
    if op == K.OP_DRAW_TRIA_FILL:
        return abs((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)) // 2
    if op == K.OP_DRAW_CIRC:
        return int(2 * math.pi * d["param"])
    if op == K.OP_DRAW_CIRC_FILL:
        return int(math.pi * d["param"] ** 2)
    if op == K.OP_CLEAR:
        return AREA
    return 0


class ServidorSimulado:

    def __init__(self, host="127.0.0.1", puerto=K.PUERTO_PREDETERMINADO,
                 fallar_lote=0, verboso=False, anunciar=True):
        self.anunciar = anunciar
        self.fallar_lote = fallar_lote
        self.verboso = verboso
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, puerto))
        self.sock.listen(1)
        self.host, self.puerto = self.sock.getsockname()
        self._parar = threading.Event()
        self._reiniciar_ventana()
        self.publicado = dict(self.ventana)
        self.lotes_recibidos = 0
        self.historial = []          # (opcode, seq_id) de cada paquete

    def _reiniciar_ventana(self):
        self.ventana = dict(ciclos=0, comandos=0, pixeles=0,
                            errores=0, descartados=0)

    def _log(self, texto):
        if self.verboso:
            print(texto, flush=True)

    # -- procesamiento ----------------------------------------------------

    def procesar_lote(self, banderas, carga):
        if banderas & K.BANDERA_INICIO_VENTANA:
            self._reiniciar_ventana()
        for i in range(0, len(carga), K.TAM_PAQUETE):
            d = decodificar(carga[i:i + K.TAM_PAQUETE])
            self.historial.append((d["opcode"], d["seq_id"]))
            v = self.ventana
            if d["opcode"] > K.OP_INF:                       # EC-06
                v["errores"] += 1
                continue
            if d["opcode"] == K.OP_INF:
                self.publicado = dict(self.ventana)
                continue
            px = pixeles_estimados(d)
            v["comandos"] += 1
            v["pixeles"] += px
            v["ciclos"] += px + CICLOS_POR_COMANDO

    def atender(self, conn):
        with conn:
            while not self._parar.is_set():
                try:
                    tipo, banderas, seq, carga = P.recibir_mensaje(conn)
                except (P.ConexionCerrada, OSError):
                    return              # el cliente se fue, esperar otro
                except P.ErrorProtocolo as e:
                    self._log("  mensaje invalido: {}".format(e))
                    conn.sendall(P.empaquetar(K.TIPO_ERROR,
                                              P.carga_error(K.EC_05, str(e))))
                    return

                if tipo == K.TIPO_LOTE:
                    self.lotes_recibidos += 1
                    n = len(carga) // K.TAM_PAQUETE
                    self._log("  LOTE seq={} paquetes={} banderas=0x{:02X}"
                              .format(seq, n, banderas))
                    if self.fallar_lote and self.lotes_recibidos == self.fallar_lote:
                        self._log("  -> EC-05 simulado")
                        conn.sendall(P.empaquetar(
                            K.TIPO_ERROR,
                            P.carga_error(K.EC_05, "Fallo simulado al "
                                          "reconstruir el lote {}".format(seq)),
                            seq))
                        continue
                    self.procesar_lote(banderas, carga)

                elif tipo == K.TIPO_SOLICITUD:
                    r = self.publicado
                    self._log("  SOLICITUD seq={} -> REPORTE {}".format(seq, r))
                    conn.sendall(P.empaquetar(
                        K.TIPO_REPORTE, P.carga_reporte(**r), seq))

    def servir(self):
        if self.anunciar:
            print("Servidor simulado del HPS en {}:{} (Ctrl+C para salir)"
                  .format(self.host, self.puerto), flush=True)
        self.sock.settimeout(0.5)
        while not self._parar.is_set():
            try:
                conn, origen = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            conn.settimeout(None)
            self._log("Conexion desde {}:{}".format(*origen))
            try:
                self.atender(conn)
            except OSError as e:
                self._log("  conexion interrumpida: {}".format(e))
            self._log("Conexion cerrada")

    def parar(self):
        self._parar.set()
        self.sock.close()


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--puerto", type=int, default=K.PUERTO_PREDETERMINADO)
    p.add_argument("--fallar-lote", type=int, default=0, metavar="N",
                   help="responder EC-05 al N-esimo lote recibido")
    p.add_argument("-v", "--verboso", action="store_true")
    a = p.parse_args()
    srv = ServidorSimulado(a.host, a.puerto, a.fallar_lote, a.verboso)
    try:
        srv.servir()
    except KeyboardInterrupt:
        pass
    finally:
        srv.parar()


if __name__ == "__main__":
    main()
