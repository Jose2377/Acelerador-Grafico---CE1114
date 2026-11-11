#!/usr/bin/env python3
"""Servidor que simula el servicio del HPS, para probar la interfaz sin
la tarjeta. Habla el mismo protocolo (PROTOCOLO.md): recibe lotes,
decodifica los paquetes, los dibuja con RasterizadorCPU y responde las
solicitudes de reporte.

Uso:
  python servidor_simulado.py                  escucha en 127.0.0.1:5000
  python servidor_simulado.py --puerto 6000 -v
  python servidor_simulado.py --fallar-lote 2  responde EC-05 al 2do lote

Para usarlo, poner "host": "127.0.0.1" en config.json (o en la barra de
la ventana).

Contadores:
  comandos, pixeles, errores  exactos: salen del modelo de referencia, que
                              reproduce el RTL pixel a pixel
  ciclos                      ESTIMACION a partir de las maquinas de estado
                              del RTL, sin la contrapresion de la SDRAM; sirve
                              para probar el camino de vuelta, no para medir
"""

import argparse
import socket
import threading

from gfx import constantes as K
from gfx import protocolo as P
from gfx.codificador import decodificar
from gfx.raster_cpu import RasterizadorCPU, Ventana

# Estimacion de ciclos (reloj de 100 MHz, sin esperas de SDRAM)
SOBRECARGA = 5          # decoder_fsm + arranque de processor_raster
SPAN = 8                # pixeles por tramo en rect_fill / clear (BURST_LEN)
# SWAP espera el flanco de VSYNC con busy en alto, y esos ciclos cuentan
# en PERF_CYCLES. En promedio, medio cuadro: 800*525/2 relojes de pixel
# de 25,175 MHz, pasados a ciclos de 100 MHz.
CICLOS_SWAP = int(800 * 525 / 2 * 100e6 / 25.175e6)


def ciclos_estimados(d, emitidos, ancho, alto):
    """Ciclos de un comando ya ejecutado; 'emitidos' son los pixeles que
    genero (escritos + recortados)."""
    op = d["opcode"]
    if op == K.OP_NOP:
        m = 0
    elif op == K.OP_DRAW_PIXEL:
        m = 2                                   # P_OUT, P_DONE
    elif op == K.OP_DRAW_LINE:
        m = emitidos + 2                        # L_SETUP, L_RUN x n, L_DONE
    elif op == K.OP_DRAW_RECT:
        m = emitidos + 1                        # un pixel por ciclo
    elif op in (K.OP_DRAW_RECT_FILL, K.OP_CLEAR):
        if op == K.OP_CLEAR:
            xa, xb, ya, yb = 0, ancho - 1, 0, alto - 1
        else:
            xa, xb = sorted((d["x0"], d["x1"]))
            ya, yb = sorted((d["y0"], d["y1"]))
        tramos = (xb // SPAN) - (xa // SPAN) + 1     # grupos alineados
        m = (yb - ya + 1) * tramos + 1
    elif op == K.OP_DRAW_CIRC:
        m = 2 + (emitidos // 8) * 9             # 8 octantes + K_UPD
    elif op == K.OP_DRAW_CIRC_FILL:
        m = (2 * d["param"] + 1) ** 2 + 2       # cuadrado completo
    elif op == K.OP_DRAW_TRIA:
        m = 2 + emitidos + 3 * 3 + 1            # tres draw_line
    elif op == K.OP_DRAW_TRIA_FILL:
        xs = (d["x0"], d["x1"], d["x2"])
        ys = (d["y0"], d["y1"], d["y2"])
        w = min(max(xs), ancho - 1) - max(min(xs), 0) + 1
        h = min(max(ys), alto - 1) - max(min(ys), 0) + 1
        m = 6 + max(w, 0) * max(h, 0)           # preparacion + caja
    elif op == K.OP_SWAP_BUFFER:
        m = CICLOS_SWAP
    else:
        m = 0
    return m + SOBRECARGA


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
        self.raster = RasterizadorCPU()
        self.ciclos = 0
        self.publicado = dict(ciclos=0, comandos=0, pixeles=0,
                              errores=0, descartados=0)
        self.lotes_recibidos = 0
        self.historial = []          # (opcode, seq_id) de cada paquete

    def _log(self, texto):
        if self.verboso:
            print(texto, flush=True)

    # -- procesamiento ----------------------------------------------------

    def procesar_lote(self, banderas, carga):
        ras = self.raster
        if banderas & K.BANDERA_INICIO_VENTANA:
            ras.ventana = Ventana()
            self.ciclos = 0
        for i in range(0, len(carga), K.TAM_PAQUETE):
            d = decodificar(carga[i:i + K.TAM_PAQUETE])
            self.historial.append((d["opcode"], d["seq_id"]))
            v = ras.ventana
            antes = v.pixeles + v.recortados
            errores = v.errores
            ras.ejecutar_campos(d["opcode"], d["x0"], d["y0"], d["x1"],
                                d["y1"], d["x2"], d["y2"], d["param"],
                                d["r"], d["g"], d["b"])
            if d["opcode"] == K.OP_INF:
                c = ras.informes[-1]
                self.publicado = dict(ciclos=self.ciclos,
                                      comandos=c.comandos, pixeles=c.pixeles,
                                      errores=c.errores, descartados=0)
                self.ciclos = 0
            elif v.errores > errores:
                self.ciclos += 3                         # PROC + MOE-06
            else:
                self.ciclos += ciclos_estimados(
                    d, v.pixeles + v.recortados - antes,
                    ras.ancho, ras.alto)

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
