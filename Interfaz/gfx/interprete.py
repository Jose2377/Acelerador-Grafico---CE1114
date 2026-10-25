"""InterpreteComandos: lee el script linea por linea, reconoce la
operacion y delega la validacion.

Reglas del lenguaje: una instruccion por linea, la operacion primero y
sus argumentos separados por espacios; '#' inicia un comentario. El
color se fija con 'color r g b' y queda vigente hasta el siguiente
cambio.

Validacion (en este orden, se reporta el primer fallo de cada linea):
  EC-01  operacion inexistente
  EC-02  numero de argumentos incorrecto
  EC-03  argumento no entero o fuera de 16 bits con signo
  EC-04  argumento fuera del rango admitido (color 0..255, radio 1..1023)

Las coordenadas fuera de la pantalla visible NO son error: el recorte
lo hace el hardware.
"""

import re

from gfx import constantes as K
from gfx.comando import Comando, EstadoColor
from gfx.errores import ErrorComando


class ResultadoAnalisis:
    """Lo que devuelve el interprete tras recorrer un script."""

    def __init__(self):
        self.comandos = []      # list[Comando] aceptados
        self.errores = []       # list[ErrorComando] rechazados
        self.total_lineas = 0   # lineas con contenido

    @property
    def aceptados(self):
        return len(self.comandos)

    @property
    def rechazados(self):
        return len(self.errores)

    def resumen(self):
        if self.rechazados:
            return ("Se rechazaron {} de {} comandos. "
                    "No se transmitio ningun paquete."
                    .format(self.rechazados, self.total_lineas))
        return ("Script valido: {} instrucciones, {} paquetes."
                .format(self.total_lineas, self.aceptados))


class InterpreteComandos:
    """Analiza un script de escena y produce objetos Comando."""

    COMENTARIO = "#"

    def __init__(self):
        self.estado_color = EstadoColor()

    # API publica

    def analizar_archivo(self, ruta):
        with open(ruta, "r", encoding="utf-8") as f:
            return self.analizar_texto(f.read())

    def analizar_texto(self, texto):
        resultado = ResultadoAnalisis()
        self.estado_color = EstadoColor()

        for num, linea in enumerate(texto.splitlines(), start=1):
            limpia = linea.split(self.COMENTARIO, 1)[0].strip()
            if not limpia:
                continue
            resultado.total_lineas += 1
            try:
                cmd = self._analizar_linea(limpia, num)
                if cmd is not None:          # 'color' no genera paquete
                    resultado.comandos.append(cmd)
            except ErrorComando as e:
                resultado.errores.append(e)

        return resultado

    # -- Analisis y validacion -------------------------------------------

    _PATRON_ENTERO = re.compile(r"^[+-]?\d+$")

    def _analizar_linea(self, linea, num):
        """Reconoce la operacion, valida argumentos y rangos.

        Devuelve un Comando con el color vigente, o None si la linea es
        'color' (solo actualiza el EstadoColor, no genera paquete).
        Lanza ErrorComando ante el primer fallo encontrado.
        """
        partes = linea.split()
        nombre = partes[0].lower()
        textos = partes[1:]

        # EC-01: operacion inexistente
        if nombre not in K.TABLA_COMANDOS:
            raise ErrorComando(
                K.EC_01, num, linea,
                "La operacion '{}' no existe".format(partes[0]))

        opcode, esperados = K.TABLA_COMANDOS[nombre]

        # EC-02: numero de argumentos
        if len(textos) != esperados:
            if esperados == 0:
                razon = ("La operacion {} no admite argumentos, "
                         "se recibieron {}".format(nombre, len(textos)))
            else:
                razon = ("La operacion {} espera {} argumentos enteros, "
                         "se recibieron {}".format(
                             nombre, esperados, len(textos)))
            raise ErrorComando(K.EC_02, num, linea, razon)

        # EC-03: enteros de 16 bits con signo
        valores = []
        for pos, texto in enumerate(textos, start=1):
            if not self._PATRON_ENTERO.match(texto):
                raise ErrorComando(
                    K.EC_03, num, linea,
                    "El argumento {} ('{}') no es un entero".format(
                        pos, texto))
            valor = int(texto)
            if not K.COORD_MIN <= valor <= K.COORD_MAX:
                raise ErrorComando(
                    K.EC_03, num, linea,
                    "El argumento {} ({}) no cabe en 16 bits con signo "
                    "({} a {})".format(pos, valor, K.COORD_MIN, K.COORD_MAX))
            valores.append(valor)

        # EC-04: rangos propios de cada operacion
        self._validar_rangos(nombre, valores, num, linea)

        if nombre == "color":
            self.estado_color.fijar(*valores)
            return None

        return Comando(nombre, opcode, valores,
                       self.estado_color.rgb888(), num)

    def _validar_rangos(self, nombre, valores, num, linea):
        if nombre == "color":
            for comp, v in zip("rgb", valores):
                if not K.COLOR_MIN <= v <= K.COLOR_MAX:
                    raise ErrorComando(
                        K.EC_04, num, linea,
                        "La componente {} debe estar entre {} y {}, "
                        "se recibio {}".format(
                            comp, K.COLOR_MIN, K.COLOR_MAX, v))
        elif nombre in ("circ", "circ_fill"):
            r = valores[2]
            if not K.RADIO_MIN <= r <= K.RADIO_MAX:
                raise ErrorComando(
                    K.EC_04, num, linea,
                    "El radio debe estar entre {} y {}, se recibio {}"
                    .format(K.RADIO_MIN, K.RADIO_MAX, r))
