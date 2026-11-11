"""ClienteTransporte: mantiene la conexion con el servicio del HPS,
agrupa en lotes de hasta 256 paquetes y encola mientras hay un envio
en curso (socket TCP sobre Ethernet, IF-03).

El camino de ida no bloquea: enviar_lote() solo encola y un hilo de
envio escribe en el socket. vaciar() espera a que la cola termine.
"""

import queue
import select
import socket
import threading
import time

from gfx import constantes as K
from gfx import protocolo as P


class ErrorTransporte(OSError):
    """Fallo del camino de comunicacion. Lleva el codigo EC asociado."""

    def __init__(self, mensaje, codigo=K.EC_05):
        super().__init__(mensaje)
        self.codigo = codigo
        self.mensaje = mensaje

    def __str__(self):
        return "Error {}: {}".format(self.codigo, self.mensaje)


class ClienteTransporte:

    def __init__(self, host, puerto, tam_lote=K.TAM_LOTE_MAX,
                 timeout=K.TIMEOUT_PREDETERMINADO):
        self.host = host
        self.puerto = int(puerto)
        self.tam_lote = max(1, min(int(tam_lote), K.TAM_LOTE_MAX))
        self.timeout = float(timeout)
        self.sock = None

        self._secuencia = 0
        self._cola = queue.Queue()
        self._hilo = None
        self._error = None
        self._candado = threading.Lock()

        self.lotes_enviados = 0
        self.bytes_enviados = 0
        self.t_inicio_escena = None

    # -- conexion ---------------------------------------------------------

    def conectar(self):
        try:
            self.sock = socket.create_connection(
                (self.host, self.puerto), timeout=self.timeout)
        except OSError as e:
            raise ErrorTransporte("No se pudo conectar con {}:{} ({})"
                                  .format(self.host, self.puerto, e))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._error = None
        self._hilo = threading.Thread(target=self._trabajador, daemon=True)
        self._hilo.start()

    def cerrar(self):
        if self._hilo is not None:
            self._cola.put(None)
            self._hilo.join(timeout=self.timeout)
            self._hilo = None
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cerrar()

    # -- camino de ida ----------------------------------------------------

    def enviar_lote(self, paquetes, inicio_ventana=False):
        """Encola los paquetes (multiplo de 24 bytes) en lotes de hasta
        tam_lote. No espera. Devuelve cuantos lotes encolo."""
        self._exigir_conexion()
        if not paquetes or len(paquetes) % K.TAM_PAQUETE:
            raise ValueError("Se esperaba un multiplo no nulo de {} bytes"
                             .format(K.TAM_PAQUETE))
        paso = self.tam_lote * K.TAM_PAQUETE
        n = 0
        for i in range(0, len(paquetes), paso):
            banderas = K.BANDERA_INICIO_VENTANA if (inicio_ventana and i == 0) else 0
            self._cola.put(self._mensaje(K.TIPO_LOTE, paquetes[i:i + paso],
                                         banderas))
            n += 1
        return n

    def enviar_escena(self, paquetes):
        """Primer lote con la bandera de inicio de ventana de medicion;
        marca el inicio del tiempo de extremo a extremo."""
        self.t_inicio_escena = time.perf_counter()
        return self.enviar_lote(paquetes, inicio_ventana=True)

    def vaciar(self):
        """Espera a que se transmita todo lo encolado."""
        self._cola.join()
        if self._error is not None:
            raise self._error

    # -- camino de vuelta -------------------------------------------------

    def revisar_errores(self, espera=0.0):
        """Lee, sin bloquear mas de 'espera' segundos, los avisos de error
        que el servicio haya enviado. Lanza el primero que encuentre."""
        self._exigir_conexion()
        while True:
            listos, _, _ = select.select([self.sock], [], [], espera)
            if not listos:
                return
            tipo, _, _, carga = self._recibir()
            if tipo == K.TIPO_ERROR:
                codigo, detalle = P.leer_error(carga)
                raise ErrorTransporte(detalle or K.DESCRIPCION_EC.get(codigo, ""),
                                      codigo)
            espera = 0.0

    def solicitar_reporte(self):
        """Envia SOLICITUD y espera el REPORTE correspondiente.

        Devuelve el dict de contadores; si hubo enviar_escena() en esta
        conexion agrega 'extremo_a_extremo_s'."""
        self._exigir_conexion()
        self.vaciar()
        msg = self._mensaje(K.TIPO_SOLICITUD)
        seq = self._secuencia - 1
        self._enviar_ahora(msg)

        limite = time.monotonic() + self.timeout
        while True:
            restante = limite - time.monotonic()
            if restante <= 0:
                raise ErrorTransporte("Sin reporte del HPS tras {:.1f} s"
                                      .format(self.timeout))
            listos, _, _ = select.select([self.sock], [], [], restante)
            if not listos:
                continue
            tipo, _, secuencia, carga = self._recibir()
            if tipo == K.TIPO_ERROR:
                codigo, detalle = P.leer_error(carga)
                raise ErrorTransporte(detalle or K.DESCRIPCION_EC.get(codigo, ""),
                                      codigo)
            if tipo == K.TIPO_REPORTE and secuencia == seq:
                contadores = P.leer_reporte(carga)
                if self.t_inicio_escena is not None:
                    contadores["extremo_a_extremo_s"] = round(
                        time.perf_counter() - self.t_inicio_escena, 6)
                return contadores
            # cualquier otro mensaje (reporte viejo) se ignora

    # -- internos ---------------------------------------------------------

    def _exigir_conexion(self):
        if self.sock is None:
            raise ErrorTransporte("No hay conexion con el HPS")

    def _mensaje(self, tipo, carga=b"", banderas=0):
        with self._candado:
            seq = self._secuencia
            self._secuencia = (self._secuencia + 1) & 0xFFFFFFFF
        return P.empaquetar(tipo, carga, seq, banderas)

    def _enviar_ahora(self, msg):
        try:
            self.sock.sendall(msg)
            self.bytes_enviados += len(msg)
        except OSError as e:
            raise ErrorTransporte("Caida de conexion al enviar ({})".format(e))

    def _recibir(self):
        try:
            return P.recibir_mensaje(self.sock)
        except P.ErrorProtocolo as e:
            raise ErrorTransporte("Respuesta mal formada del HPS: {}".format(e))
        except OSError as e:
            raise ErrorTransporte("Caida de conexion al recibir ({})".format(e))

    def _trabajador(self):
        while True:
            msg = self._cola.get()
            try:
                if msg is None:
                    return
                if self._error is None:          # tras un fallo se descarta
                    self._enviar_ahora(msg)
                    self.lotes_enviados += 1
            except ErrorTransporte as e:
                self._error = e
            finally:
                self._cola.task_done()
