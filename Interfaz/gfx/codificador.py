"""CodificadorPaquete: convierte un Comando en los 24 bytes del
PaqueteComando (seis palabras de 32 bits, W0 a W5), segun la Figura 4
del documento de diseno:

        31      24 23      16 15       8 7        0
  W0  | OPCODE    | FLAGS     | SEQ_ID              |
  W1  | X0 (int16 con signo)  | Y0 (int16 con signo)|
  W2  | X1                    | Y1                  |
  W3  | X2                    | Y2                  |
  W4  | RESERVADO | R         | G        | B        |
  W5  | RESERVADO             | PARAM (radio)       |

Cada palabra se serializa en little-endian (K.ORDEN_BYTES), W0 primero.
Los campos que una operacion no usa, y los reservados, van en cero.
"""

import struct

from gfx import constantes as K

_FORMATO = K.ORDEN_BYTES + "I" * K.PALABRAS_PAQUETE   # "<IIIIII"

# Que campos llena cada opcode a partir de Comando.args
#   coords: cuantas coordenadas (x, y) toma de args
#   param:  si el ultimo argumento va en PARAM
#   color:  si se transmite el color vigente
_CAMPOS = {
    K.OP_NOP:            dict(coords=0, param=False, color=False),
    K.OP_DRAW_PIXEL:     dict(coords=1, param=False, color=True),
    K.OP_DRAW_LINE:      dict(coords=2, param=False, color=True),
    K.OP_DRAW_TRIA:      dict(coords=3, param=False, color=True),
    K.OP_DRAW_TRIA_FILL: dict(coords=3, param=False, color=True),
    K.OP_DRAW_RECT:      dict(coords=2, param=False, color=True),
    K.OP_DRAW_RECT_FILL: dict(coords=2, param=False, color=True),
    K.OP_DRAW_CIRC:      dict(coords=1, param=True,  color=True),
    K.OP_DRAW_CIRC_FILL: dict(coords=1, param=True,  color=True),
    K.OP_CLEAR:          dict(coords=0, param=False, color=True),
    K.OP_SWAP_BUFFER:    dict(coords=0, param=False, color=False),
    K.OP_INF:            dict(coords=0, param=False, color=False),
}


def _u16(v):
    """Entero con signo de 16 bits -> patron sin signo (complemento a dos)."""
    return v & 0xFFFF


def _s16(v):
    """Patron de 16 bits -> entero con signo."""
    return v - 0x10000 if v & 0x8000 else v


class CodificadorPaquete:

    def __init__(self, seq_inicial=0):
        self.seq_id = seq_inicial & K.SEQ_MAX

    def _siguiente_seq(self):
        seq = self.seq_id
        self.seq_id = (self.seq_id + 1) & K.SEQ_MAX
        return seq

    def palabras(self, comando, flags=0):
        """Devuelve las seis palabras W0..W5 como enteros sin signo.

        Consume un SEQ_ID.
        """
        try:
            campos = _CAMPOS[comando.opcode]
        except KeyError:
            raise ValueError("OpCode desconocido: 0x{:02X}"
                             .format(comando.opcode))

        args = list(comando.args)
        coords = [0] * 6                                 # x0 y0 x1 y1 x2 y2
        n = campos["coords"] * 2
        coords[:n] = args[:n]
        param = args[n] if campos["param"] else 0
        r, g, b = comando.color if campos["color"] else (0, 0, 0)

        w0 = ((comando.opcode & 0xFF) << 24) | ((flags & 0xFF) << 16) \
            | self._siguiente_seq()
        w1 = (_u16(coords[0]) << 16) | _u16(coords[1])
        w2 = (_u16(coords[2]) << 16) | _u16(coords[3])
        w3 = (_u16(coords[4]) << 16) | _u16(coords[5])
        w4 = ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)
        w5 = param & 0xFFFF
        return [w0, w1, w2, w3, w4, w5]

    def codificar(self, comando, flags=0):
        """Comando -> bytes de longitud K.TAM_PAQUETE (24)."""
        return struct.pack(_FORMATO, *self.palabras(comando, flags))

    def codificar_lote(self, comandos):
        return b"".join(self.codificar(c) for c in comandos)


# ---------------------------------------------------------------- inverso

def decodificar(paquete):
    """24 bytes -> dict con todos los campos. Para pruebas y depuracion
    (es la mitad Python de la prueba de ida y vuelta)."""
    if len(paquete) != K.TAM_PAQUETE:
        raise ValueError("Un paquete mide {} bytes, se recibieron {}"
                         .format(K.TAM_PAQUETE, len(paquete)))
    w0, w1, w2, w3, w4, w5 = struct.unpack(_FORMATO, paquete)
    return {
        "opcode": (w0 >> 24) & 0xFF,
        "flags":  (w0 >> 16) & 0xFF,
        "seq_id": w0 & 0xFFFF,
        "x0": _s16(w1 >> 16), "y0": _s16(w1 & 0xFFFF),
        "x1": _s16(w2 >> 16), "y1": _s16(w2 & 0xFFFF),
        "x2": _s16(w3 >> 16), "y2": _s16(w3 & 0xFFFF),
        "r": (w4 >> 16) & 0xFF, "g": (w4 >> 8) & 0xFF, "b": w4 & 0xFF,
        "res_w4": (w4 >> 24) & 0xFF,
        "param": w5 & 0xFFFF,
        "res_w5": (w5 >> 16) & 0xFFFF,
    }


def volcado(paquete):
    """Una linea legible: las seis palabras en hexadecimal."""
    ws = struct.unpack(_FORMATO, paquete)
    return " ".join("{:08X}".format(w) for w in ws)


def tabla_paquetes(comandos):
    """Tabla de texto con las palabras W0..W5 de cada comando."""
    cod = CodificadorPaquete()
    lineas = ["{:>5}  {:<10} {}".format(
        "linea", "comando", "W0       W1       W2       W3       W4       W5")]
    for c in comandos:
        lineas.append("{:>5}  {:<10} {}".format(
            c.linea_num, c.nombre, volcado(cod.codificar(c))))
    lineas.append("")
    lineas.append("{} paquetes, {} bytes".format(
        len(comandos), len(comandos) * K.TAM_PAQUETE))
    return "\n".join(lineas)
