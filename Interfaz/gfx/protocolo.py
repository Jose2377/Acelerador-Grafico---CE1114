"""Protocolo de aplicacion sobre TCP entre la interfaz y el servicio del
HPS (IF-03). Ver PROTOCOLO.md y la seccion de protocolo de constantes.py.

Este modulo solo arma y lee mensajes; no abre sockets por su cuenta,
salvo recibir_mensaje(), que lee de un socket ya conectado.
"""

import struct

from gfx import constantes as K

TIPOS = {
    K.TIPO_LOTE: "LOTE",
    K.TIPO_SOLICITUD: "SOLICITUD",
    K.TIPO_REPORTE: "REPORTE",
    K.TIPO_ERROR: "ERROR",
}


class ErrorProtocolo(ValueError):
    """Mensaje mal formado."""


class ConexionCerrada(ConnectionError):
    """El otro extremo cerro la conexion."""


# ------------------------------------------------------------ encabezado

def empaquetar(tipo, carga=b"", secuencia=0, banderas=0):
    """Arma un mensaje completo: encabezado de 8 bytes + carga."""
    _validar(tipo, len(carga))
    return struct.pack(K.FORMATO_ENCABEZADO, tipo, banderas & 0xFF,
                       len(carga), secuencia & 0xFFFFFFFF) + carga


def leer_encabezado(datos):
    """8 bytes -> (tipo, banderas, longitud, secuencia)."""
    if len(datos) != K.TAM_ENCABEZADO:
        raise ErrorProtocolo("El encabezado mide {} bytes, se recibieron {}"
                             .format(K.TAM_ENCABEZADO, len(datos)))
    tipo, banderas, longitud, secuencia = struct.unpack(
        K.FORMATO_ENCABEZADO, datos)
    _validar(tipo, longitud)
    return tipo, banderas, longitud, secuencia


def _validar(tipo, longitud):
    if tipo not in TIPOS:
        raise ErrorProtocolo("Tipo de mensaje desconocido: {}".format(tipo))
    if longitud > K.LONGITUD_MAX:
        raise ErrorProtocolo("Carga de {} bytes, el maximo es {}"
                             .format(longitud, K.LONGITUD_MAX))
    if tipo == K.TIPO_LOTE:
        if longitud == 0 or longitud % K.TAM_PAQUETE:
            raise ErrorProtocolo(
                "Un lote debe medir un multiplo no nulo de {} bytes, "
                "mide {}".format(K.TAM_PAQUETE, longitud))
    elif tipo == K.TIPO_SOLICITUD and longitud:
        raise ErrorProtocolo("La solicitud de reporte no lleva carga")
    elif tipo == K.TIPO_REPORTE and longitud != K.TAM_REPORTE:
        raise ErrorProtocolo("El reporte mide {} bytes, se recibieron {}"
                             .format(K.TAM_REPORTE, longitud))


# ---------------------------------------------------------------- socket

def recibir_exacto(sock, n):
    datos = bytearray()
    while len(datos) < n:
        trozo = sock.recv(n - len(datos))
        if not trozo:
            raise ConexionCerrada("El otro extremo cerro la conexion")
        datos += trozo
    return bytes(datos)


def recibir_mensaje(sock):
    """Lee un mensaje completo -> (tipo, banderas, secuencia, carga)."""
    tipo, banderas, longitud, secuencia = leer_encabezado(
        recibir_exacto(sock, K.TAM_ENCABEZADO))
    carga = recibir_exacto(sock, longitud) if longitud else b""
    return tipo, banderas, secuencia, carga


# ---------------------------------------------------------------- cargas

CAMPOS_REPORTE = ("ciclos", "comandos", "pixeles", "errores", "descartados")


def carga_reporte(ciclos, comandos, pixeles, errores, descartados):
    return struct.pack(K.FORMATO_REPORTE, ciclos & 0xFFFFFFFF,
                       comandos & 0xFFFFFFFF, pixeles & 0xFFFFFFFF,
                       errores & 0xFFFF, descartados & 0xFFFF)


def leer_reporte(carga):
    return dict(zip(CAMPOS_REPORTE, struct.unpack(K.FORMATO_REPORTE, carga)))


def carga_error(codigo, detalle=""):
    """codigo: 'EC-05' o 5."""
    if isinstance(codigo, str):
        codigo = int(codigo.split("-")[1])
    return struct.pack(K.FORMATO_ERROR, codigo, 0) + detalle.encode("utf-8")


def leer_error(carga):
    """-> ('EC-0N', detalle)."""
    if len(carga) < 2:
        raise ErrorProtocolo("Mensaje de error sin codigo")
    num, _ = struct.unpack(K.FORMATO_ERROR, carga[:2])
    return "EC-{:02d}".format(num), carga[2:].decode("utf-8", "replace")
