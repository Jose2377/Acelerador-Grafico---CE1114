"""RasterizadorCPU: implementacion de referencia exclusivamente en CPU,
usada para la comparacion contra el acelerador grafico. Consume los
mismos objetos Comando pero nunca toca la tarjeta.

ESTADO: PENDIENTE.
"""

from gfx import constantes as K


class RasterizadorCPU:

    def __init__(self, ancho=K.ANCHO_PANTALLA, alto=K.ALTO_PANTALLA):
        self.ancho = ancho
        self.alto = alto
        self.framebuffer = bytearray(ancho * alto * 2)   # RGB565
        self.pixeles_escritos = 0

    def ejecutar(self, comandos):
        """Ejecuta la lista de comandos y devuelve el tiempo empleado.

        PENDIENTE.
        """
        raise NotImplementedError("Rasterizador de referencia pendiente")
