"""InterpreteComandos: lee el script linea por linea, reconoce la
operacion y delega la validacion.

ESTADO: estructura de la interfaz lista; la logica de analisis y
validacion esta PENDIENTE (ver _analizar_linea).
"""

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
        return "Se aceptaron {} comandos.".format(self.aceptados)


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

    # Logica pendiente 

    def _analizar_linea(self, linea, num):
        """Reconoce la operacion, valida argumentos y rangos.

        Debe:
          1. separar nombre y argumentos por espacios;
          2. rechazar operacion inexistente          -> EC-01
          3. rechazar numero de argumentos incorrecto -> EC-02
          4. rechazar argumento no entero / >16 bits  -> EC-03
          5. rechazar argumento fuera de rango        -> EC-04
          6. actualizar EstadoColor si la operacion es 'color'
             y devolver None;
          7. devolver un Comando con el color vigente en otro caso.

        PENDIENTE: logica del interprete.
        """
        raise NotImplementedError(
            "Logica del interprete pendiente (_analizar_linea)")
