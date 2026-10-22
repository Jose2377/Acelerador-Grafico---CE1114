"""ClienteTransporte: mantiene la conexion con el servicio del HPS,
agrupa en lotes de hasta 256 paquetes y encola mientras hay un envio{
en curso (socket TCP sobre Ethernet).

ESTADO: PENDIENTE.
"""

from gfx import constantes as K


class ClienteTransporte:

    def __init__(self, host, puerto, tam_lote=K.TAM_LOTE_MAX):
        self.host = host
        self.puerto = puerto
        self.tam_lote = min(tam_lote, K.TAM_LOTE_MAX)
        self.sock = None

    def conectar(self):
        raise NotImplementedError("Transporte TCP pendiente")

    def enviar_lote(self, paquetes):
        """Encabezado de 8 bytes + carga util. Escritura no bloqueante."""
        raise NotImplementedError("Transporte TCP pendiente")

    def solicitar_reporte(self):
        raise NotImplementedError("Transporte TCP pendiente")

    def cerrar(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None
