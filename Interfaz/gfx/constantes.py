"""Constantes de interfaz

Fuente unica de verdad para opcodes, rangos y codigos de error.
Debe mantenerse sincronizado con el encabezado de C y el paquete de SystemVerilog
"""

# Codigos de operacion (OpCode, 8 bits)
OP_NOP            = 0x00
OP_DRAW_PIXEL     = 0x01
OP_DRAW_LINE      = 0x02
OP_DRAW_TRIA      = 0x03
OP_DRAW_TRIA_FILL = 0x04
OP_DRAW_RECT      = 0x05
OP_DRAW_RECT_FILL = 0x06
OP_DRAW_CIRC      = 0x07
OP_DRAW_CIRC_FILL = 0x08
OP_CLEAR          = 0x09
OP_SWAP_BUFFER    = 0x0A
OP_INF            = 0x0B

# Tabla de comandos de la interfaz de usuario 
# nombre -> (opcode, numero de argumentos)
# "color" no tiene opcode propio: fija el EstadoColor del interprete.
TABLA_COMANDOS = {
    "color":     (None,              3),
    "pixel":     (OP_DRAW_PIXEL,     2),
    "line":      (OP_DRAW_LINE,      4),
    "rect":      (OP_DRAW_RECT,      4),
    "rect_fill": (OP_DRAW_RECT_FILL, 4),
    "tria":      (OP_DRAW_TRIA,      6),
    "tria_fill": (OP_DRAW_TRIA_FILL, 6),
    "circ":      (OP_DRAW_CIRC,      3),
    "circ_fill": (OP_DRAW_CIRC_FILL, 3),
    "clear":     (OP_CLEAR,          0),
    "swap":      (OP_SWAP_BUFFER,    0),
    "inf":       (OP_INF,            0),
}

# Rangos admitidos
COORD_MIN, COORD_MAX = -32768, 32767   # entero de 16 bits con signo
COLOR_MIN, COLOR_MAX = 0, 255          # RGB888 por componente
RADIO_MIN, RADIO_MAX = 1, 1023

# Geometria visible
ANCHO_PANTALLA = 640
ALTO_PANTALLA  = 480

# Protocolo
TAM_PAQUETE   = 24     # bytes, seis palabras de 32 bits (W0..W5)
TAM_LOTE_MAX  = 256    # paquetes por lote
TAM_ENCABEZADO = 8     # bytes: tipo, banderas, longitud, secuencia

TIPO_LOTE      = 0x01
TIPO_SOLICITUD = 0x02
TIPO_REPORTE   = 0x03
TIPO_ERROR     = 0x04

# Codigos de error
EC_01 = "EC-01"  # Operacion inexistente                     (Interfaz)
EC_02 = "EC-02"  # Numero de argumentos incorrecto           (Interfaz)
EC_03 = "EC-03"  # Argumento no entero o fuera de 16 bits    (Interfaz)
EC_04 = "EC-04"  # Argumento fuera del rango admitido        (Interfaz)
EC_05 = "EC-05"  # Caida de conexion / lote fallido          (Servicio HPS)
EC_06 = "EC-06"  # Operacion no reconocida en hardware       (Decodificador)
EC_07 = "EC-07"  # Argumento inconsistente en hardware       (Decodificador)
EC_08 = "EC-08"  # Desbordamiento de la cola de comandos     (Avalon-MM)

DESCRIPCION_EC = {
    EC_01: "Operacion inexistente.",
    EC_02: "Numero de argumentos incorrecto.",
    EC_03: "Argumento no entero o fuera del rango de 16 bits.",
    EC_04: "Argumento fuera del rango admitido.",
    EC_05: "Caida de conexion o reconstruccion de lote fallida.",
    EC_06: "Operacion no reconocida en hardware.",
    EC_07: "Argumento inconsistente en hardware.",
    EC_08: "Desbordamiento de la cola de comandos.",
}

# Modos de operacion
MODOS = {
    0b000: "MOE-01 Inicio",
    0b001: "MOE-02 Espera",
    0b010: "MOE-03 Procesamiento",
    0b011: "MOE-04 Swap Buffer",
    0b100: "MOE-05 Informe de rendimiento",
    0b111: "MOE-06 Error",
}
