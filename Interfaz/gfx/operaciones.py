"""Flujos completos, compartidos por gfxcli y gfxgui.

Cada funcion recibe un 'log(texto, tag)' para informar el progreso;
tag es None, "ok" o "err".
"""

from gfx import constantes as K
from gfx.codificador import CodificadorPaquete
from gfx.comando import Comando
from gfx.raster_cpu import RasterizadorCPU
from gfx.reporte import ReporteRendimiento
from gfx.transporte import ClienteTransporte, ErrorTransporte


def _cliente(cfg):
    return ClienteTransporte(cfg["host"], cfg["puerto"], cfg["tam_lote"],
                             cfg.get("timeout_s", K.TIMEOUT_PREDETERMINADO))


def _rep(cfg):
    return ReporteRendimiento(cfg["ruta_reportes"], cfg["sys_clk_hz"])


def _reporte(cli, cfg, log, escena=""):
    rep = _rep(cfg)
    fila = rep.parsear_respuesta(cli.solicitar_reporte(), escena)
    log(rep.como_texto(fila, "Reporte de rendimiento (FPGA)"), None)
    rep.anexar(fila)
    log("Reporte anexado a {}".format(cfg["ruta_reportes"]), "ok")
    return fila


# ------------------------------------------------------------------- FPGA

def _enviar(comandos, cfg, log, escena=""):
    """Transmite la escena; devuelve la fila del reporte si la escena
    tiene 'inf', True si no lo tiene, o None si fallo."""
    if not comandos:
        log("No hay comandos que enviar.", "err")
        return None
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
                return _reporte(cli, cfg, log, escena)
        return True
    except ErrorTransporte as e:
        log(str(e), "err")
        return None


def enviar_escena(comandos, cfg, log, escena=""):
    """Codifica, transmite y, si la escena contiene 'inf', pide el
    reporte y lo archiva. Devuelve True si todo salio bien."""
    return _enviar(comandos, cfg, log, escena) is not None


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


# -------------------------------------------------------------------- CPU

def ejecutar_cpu(comandos, cfg, log, modo="tramos", escena="", ruta_png=None):
    """Ejecuta la escena en RasterizadorCPU, informa y archiva cada
    ventana cerrada por 'inf' (o la ventana abierta si no hay 'inf').

    Devuelve (rasterizador, filas)."""
    ras = RasterizadorCPU(modo=modo)
    ras.ejecutar(comandos)
    rep = _rep(cfg)

    ventanas = list(ras.informes)
    if not ventanas:
        ventanas = [ras.ventana]
    elif ras.ventana.comandos:
        log("Hay {} comando(s) despues del ultimo 'inf': quedan en una "
            "ventana sin cerrar y no se informan.".format(
                ras.ventana.comandos), None)

    filas = []
    for v in ventanas:
        fila = rep.desde_cpu(v, modo, escena)
        log(rep.como_texto(fila, "Reporte de rendimiento (CPU, {})"
                           .format(modo)), None)
        rep.anexar(fila)
        filas.append(fila)
    log("Reporte anexado a {}".format(cfg["ruta_reportes"]), "ok")

    if not ras.swaps:
        log("La escena no tiene 'swap': el monitor no la mostraria; la "
            "imagen es la del buffer trasero.", None)
    if ruta_png:
        ras.a_png(ruta_png)
        log("Imagen guardada en {}".format(ruta_png), "ok")
    return ras, filas


# ------------------------------------------------------------- comparacion

def _con_inf(comandos):
    """La comparacion necesita una ventana cerrada en los dos lados."""
    if comandos and comandos[-1].opcode == K.OP_INF:
        return list(comandos), False
    color = comandos[-1].color if comandos else (255, 255, 255)
    return list(comandos) + [Comando("inf", K.OP_INF, [], color, 0)], True


def comparar(comandos, cfg, log, modo="tramos", escena=""):
    """Caso de uso CU-04: la misma escena en CPU y en el acelerador.

    Calcula la razon de tiempos CPU / FPGA y comprueba que los dos
    informen los mismos comandos y pixeles (los errores del hardware son
    acumulados desde el reinicio, asi que solo se muestran). Devuelve
    (rasterizador, fila_cpu, fila_fpga); fila_fpga es None si fallo."""
    comandos, agregado = _con_inf(comandos)
    if agregado:
        log("Se agrego 'inf' al final para cerrar la ventana de medicion.",
            None)
    if sum(c.opcode == K.OP_INF for c in comandos) > 1:
        log("La escena tiene varios 'inf': se compara la ultima ventana.",
            None)

    ras, filas = ejecutar_cpu(comandos, cfg, log, modo, escena)
    cpu = filas[-1]
    hw = _enviar(comandos, cfg, log, escena)
    if not isinstance(hw, dict):
        log("No se pudo completar la comparacion: falta el lado FPGA.", "err")
        return ras, cpu, None

    lineas = ["--- Comparacion CPU ({}) vs FPGA ---".format(modo),
              "  {:<18} {:>14} {:>14}".format("", "CPU", "FPGA")]
    for k in ("comandos", "pixeles", "errores", "rasterizacion_s",
              "pixeles_por_s"):
        lineas.append("  {:<18} {:>14} {:>14}".format(
            k, str(cpu[k]), str(hw[k])))
    log("\n".join(lineas), None)

    t_cpu, t_hw = cpu["rasterizacion_s"], hw["rasterizacion_s"]
    if t_hw:
        log("Razon de tiempos CPU / FPGA: {:.2f}  ({})".format(
            t_cpu / t_hw,
            "el acelerador es mas rapido" if t_cpu > t_hw
            else "la CPU es mas rapida"), "ok")
    else:
        log("El hardware informo 0 ciclos: no se puede calcular la razon.",
            "err")

    # errores no se compara: en el RTL err_count es acumulado desde el
    # ultimo reinicio (solo MOE-01 lo limpia), no de la ventana.
    dif = [k for k in ("comandos", "pixeles") if cpu[k] != hw[k]]
    if dif:
        log("Los contadores NO coinciden en: {}. El hardware y el modelo de "
            "referencia dibujaron distinto.".format(", ".join(dif)), "err")
    else:
        log("Comandos y pixeles coinciden con el modelo de referencia.",
            "ok")
    return ras, cpu, hw
