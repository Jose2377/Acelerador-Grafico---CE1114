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


def _reporte(cli, cfg, log, escena="", cpu=False, detalle=True):
    rep = _rep(cfg)
    fila = rep.parsear_respuesta(cli.solicitar_reporte(cpu), escena, cpu)
    rep.anexar(fila)
    if detalle:
        log(rep.como_texto(fila, "Reporte de rendimiento ({})".format(
            "CPU del HPS" if cpu else "FPGA")), None)
        log("Reporte anexado a {}".format(cfg["ruta_reportes"]), "ok")
    return fila


# ------------------------------------------------------------------- FPGA

def _enviar(comandos, cfg, log, escena="", cpu=False, detalle=True):
    """Transmite la escena; devuelve la fila del reporte si la escena
    tiene 'inf', True si no lo tiene, o None si fallo. Con cpu=True la
    ejecuta la referencia en CPU del HPS en vez del acelerador."""
    if not comandos:
        log("No hay comandos que enviar.", "err")
        return None
    paquetes = CodificadorPaquete().codificar_lote(comandos)
    pide_reporte = any(c.opcode == K.OP_INF for c in comandos)

    if detalle:
        log("Conectando con {}:{} ...".format(cfg["host"], cfg["puerto"]),
            None)
    try:
        with _cliente(cfg) as cli:
            cli.conectar()
            n_lotes = cli.enviar_escena(paquetes, cpu=cpu)
            cli.vaciar()
            cli.revisar_errores()
            if detalle:
                log("Transmitidos {} paquetes ({} bytes) en {} lote(s){}."
                    .format(len(comandos), len(paquetes), n_lotes,
                            " a la referencia en CPU del HPS" if cpu else ""),
                    "ok")
            if pide_reporte:
                return _reporte(cli, cfg, log, escena, cpu, detalle)
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


def comparar(comandos, cfg, log, modo="tramos", escena="", repeticiones=3):
    """Caso de uso CU-04 y verificacion de RR-01: la misma escena en la
    referencia en CPU del HPS (raster_ref.c, el mismo procesador que el
    acelerador descarga) y en el acelerador, 'repeticiones' veces cada una
    (al menos 3 segun RR-01). Informa la razon de tiempos CPU / FPGA de cada
    repeticion y su promedio, y comprueba que los dos lados y el modelo
    local (RasterizadorCPU) informen los mismos comandos y pixeles.

    Devuelve (rasterizador_local, fila_cpu, fila_fpga) de la ultima
    repeticion; las filas son None si ese lado fallo. El rasterizador local
    sirve para mostrar la imagen esperada."""
    comandos, agregado = _con_inf(comandos)
    if agregado:
        log("Se agrego 'inf' al final para cerrar la ventana de medicion.",
            None)
    if sum(c.opcode == K.OP_INF for c in comandos) > 1:
        log("La escena tiene varios 'inf': se compara la ultima ventana.",
            None)
    ras = RasterizadorCPU(modo=modo)
    ras.ejecutar(comandos)
    modelo = ras.informes[-1]

    repeticiones = max(1, int(repeticiones))
    filas_cpu, filas_hw = [], []
    log("Conectando con {}:{} ({} repeticiones) ...".format(
        cfg["host"], cfg["puerto"], repeticiones), None)
    for i in range(repeticiones):
        cpu = _enviar(comandos, cfg, log, escena, cpu=True, detalle=False)
        if not isinstance(cpu, dict):
            log("No se pudo completar la comparacion: falta el lado CPU del "
                "HPS (repeticion {}).".format(i + 1), "err")
            return ras, None, None
        hw = _enviar(comandos, cfg, log, escena, detalle=False)
        if not isinstance(hw, dict):
            log("No se pudo completar la comparacion: falta el lado FPGA "
                "(repeticion {}).".format(i + 1), "err")
            return ras, cpu, None
        filas_cpu.append(cpu)
        filas_hw.append(hw)

    lineas = ["--- Comparacion CPU del HPS vs FPGA ({} repeticiones) ---"
              .format(repeticiones),
              "  {:<6} {:>16} {:>16} {:>12}".format(
                  "rep", "CPU (s)", "FPGA (s)", "CPU / FPGA")]
    razones = []
    for i, (c, h) in enumerate(zip(filas_cpu, filas_hw), 1):
        t_cpu, t_hw = c["rasterizacion_s"], h["rasterizacion_s"]
        razon = t_cpu / t_hw if t_hw else None
        if razon is not None:
            razones.append(razon)
        lineas.append("  {:<6} {:>16} {:>16} {:>12}".format(
            i, t_cpu, t_hw, "-" if razon is None else "{:.2f}".format(razon)))
    for k in ("comandos", "pixeles", "errores"):
        lineas.append("  {:<18} CPU {:>10}   FPGA {:>10}   modelo {:>10}".format(
            k, filas_cpu[-1][k], filas_hw[-1][k], getattr(modelo, k)))
    log("\n".join(lineas), None)
    log("Filas anexadas a {}".format(cfg["ruta_reportes"]), "ok")

    if razones:
        promedio = sum(razones) / len(razones)
        log("Razon promedio de tiempos CPU / FPGA: {:.2f} ({})".format(
            promedio, "RR-01 se cumple (> 2)" if promedio > 2
            else "RR-01 no se cumple (debe ser > 2)"),
            "ok" if promedio > 2 else "err")
    else:
        log("El hardware informo 0 ciclos: no se puede calcular la razon.",
            "err")

    dif = sorted({k for c, h in zip(filas_cpu, filas_hw)
                  for k in ("comandos", "pixeles", "errores")
                  if not c[k] == h[k] == getattr(modelo, k)})
    if dif:
        log("Los contadores NO coinciden en: {}. Los dos lados o el modelo de "
            "referencia dibujaron distinto.".format(", ".join(dif)), "err")
    else:
        log("Comandos, pixeles y errores coinciden en la CPU, la FPGA y el "
            "modelo de referencia.", "ok")
    return ras, filas_cpu[-1], filas_hw[-1]
