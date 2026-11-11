"""Flujos completos de envio y reporte, compartidos por gfxcli y gfxgui.

Cada funcion recibe un 'log(texto, tag)' para informar el progreso;
tag es None, "ok" o "err". Devuelven True si todo salio bien.
"""

from gfx import constantes as K
from gfx.codificador import CodificadorPaquete
from gfx.reporte import ReporteRendimiento
from gfx.transporte import ClienteTransporte, ErrorTransporte


def _cliente(cfg):
    return ClienteTransporte(cfg["host"], cfg["puerto"], cfg["tam_lote"],
                             cfg.get("timeout_s", K.TIMEOUT_PREDETERMINADO))


def _reporte(cli, cfg, log):
    rep = ReporteRendimiento(cfg["ruta_reportes"], cfg["sys_clk_hz"])
    fila = rep.parsear_respuesta(cli.solicitar_reporte())
    log(rep.como_texto(fila), None)
    rep.anexar(fila)
    log("Reporte anexado a {}".format(cfg["ruta_reportes"]), "ok")


def enviar_escena(comandos, cfg, log):
    """Codifica, transmite y, si la escena contiene 'inf', pide el
    reporte y lo archiva."""
    if not comandos:
        log("No hay comandos que enviar.", "err")
        return False
    paquetes = CodificadorPaquete().codificar_lote(comandos)
    pide_reporte = any(c.opcode == K.OP_INF for c in comandos)

    log("Conectando con {}:{} ...".format(cfg["host"], cfg["puerto"]), None)
    try:
        with _cliente(cfg) as cli:
            cli.conectar()
            n_lotes = cli.enviar_escena(paquetes)
            cli.vaciar()
            cli.revisar_errores()
            log("Transmitidos {} paquetes ({} bytes) en {} lote(s)."
                .format(len(comandos), len(paquetes), n_lotes), "ok")
            if pide_reporte:
                _reporte(cli, cfg, log)
        return True
    except ErrorTransporte as e:
        log(str(e), "err")
        return False


def pedir_reporte(cfg, log):
    """Solicita el reporte de la ultima ventana de medicion."""
    try:
        with _cliente(cfg) as cli:
            cli.conectar()
            _reporte(cli, cfg, log)
        return True
    except ErrorTransporte as e:
        log(str(e), "err")
        return False
