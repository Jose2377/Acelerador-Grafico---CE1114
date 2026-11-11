"""Comando y EstadoColor: tipos del camino de ida."""

from gfx import constantes as K


class EstadoColor:
    """Conserva el color vigente entre instrucciones.

    El color no se repite en cada instruccion: se fija con 'color' y
    permanece vigente hasta el siguiente cambio.
    """

    def __init__(self, r=255, g=255, b=255):
        self.r, self.g, self.b = r, g, b

    def fijar(self, r, g, b):
        self.r, self.g, self.b = r, g, b

    def rgb888(self):
        return (self.r, self.g, self.b)

    def __repr__(self):
        return "EstadoColor({}, {}, {})".format(self.r, self.g, self.b)


class Comando:
    """Instruccion ya reconocida y validada, lista para codificar."""

    def __init__(self, nombre, opcode, args, color, linea_num=0):
        self.nombre = nombre          # nombre textual, p.ej. "rect_fill"
        self.opcode = opcode          # OpCode de 8 bits
        self.args = list(args)        # enteros ya validados
        self.color = color            # tupla (r, g, b) vigente
        self.linea_num = linea_num    # origen en el script

    def __repr__(self):
        return "Comando({} op=0x{:02X} args={} color={})".format(
            self.nombre, self.opcode, self.args, self.color)
