"""CodificadorPaquete: convierte un Comando en los 24 bytes del
PaqueteComando (seis palabras de 32 bits, W0 a W5).

ESTADO: PENDIENTE.
"""

from gfx import constantes as K


class CodificadorPaquete:

    def __init__(self):
        self.seq_id = 0     # Numero de secuencia de 16 bits

    def codificar(self, comando):
        """Devuelve bytes de longitud K.TAM_PAQUETE.

        Disposicion prevista:
          W0: opcode (8) | flags | seq_id (16)
          W1: x0 (16) | y0 (16)
          W2: x1 (16) | y1 (16)
          W3: x2 (16) | y2 (16)
          W4: color RGB888 (24) + reservado
          W5: param (radio) + reservado

        PENDIENTE.
        """
        raise NotImplementedError("Codificacion de paquete pendiente")

    def codificar_lote(self, comandos):
        return b"".join(self.codificar(c) for c in comandos)
