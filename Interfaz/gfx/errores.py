"""ErrorComando: describe un rechazo con su codigo, su linea y su razon."""

from gfx import constantes as K


class ErrorComando(Exception):
    """Rechazo de un comando detectado por la interfaz.

    El mensaje indica siempre tres elementos: donde ocurrio, que se
    rechazo y por que no puede ejecutarse.
    """

    def __init__(self, codigo, linea_num, texto_linea, razon):
        self.codigo = codigo
        self.linea_num = linea_num
        self.texto_linea = texto_linea
        self.razon = razon
        super().__init__(str(self))

    def __str__(self):
        return ("Error {}: '{}'\n  {}"
                .format(self.codigo, self.texto_linea.strip(), self.razon))

    def como_fila_log(self):
        """Una linea de texto plano para el registro de errores de sesion."""
        return "{}\tlinea {}\t{}\t{}".format(
            self.codigo, self.linea_num,
            self.texto_linea.strip(), self.razon)
