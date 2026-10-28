#!/usr/bin/env python3
"""Interfaz de comandos graficos del acelerador DE1-SoC.

Uso:
  python3 gfxcli.py check  escenas/ejemplo.gfx      valida sin transmitir
  python3 gfxcli.py send   escenas/ejemplo.gfx      valida y transmite
  python3 gfxcli.py paquetes escenas/ejemplo.gfx    muestra los paquetes W0..W5
  python3 gfxcli.py cpu    escenas/ejemplo.gfx      ejecuta en CPU (referencia)
  python3 gfxcli.py inf                             pide el reporte al hardware
  python3 gfxcli.py comandos                        tabla de comandos
"""

import argparse
import sys

from gfx import config as cfgmod
from gfx import constantes as K
from gfx.interprete import InterpreteComandos
from gfx.codificador import tabla_paquetes
from gfx import operaciones
from gfx.raster_cpu import RasterizadorCPU


# Salida

def imprimir_resultado(res):
    for e in res.errores:
        print(e)
        print()
    print(res.resumen())


def guardar_log(res, ruta):
    if not res.errores:
        return
    import os
    os.makedirs(os.path.dirname(ruta) or ".", exist_ok=True)
    with open(ruta, "a", encoding="utf-8") as f:
        for e in res.errores:
            f.write(e.como_fila_log() + "\n")


def analizar(ruta, cfg):
    try:
        res = InterpreteComandos().analizar_archivo(ruta)
    except FileNotFoundError:
        print("No se encontro el script: {}".format(ruta))
        return None
    except NotImplementedError as e:
        print("[pendiente] {}".format(e))
        return None
    imprimir_resultado(res)
    guardar_log(res, cfg["ruta_log_errores"])
    return res


# Ordenes

def orden_check(args, cfg):
    res = analizar(args.script, cfg)
    if res is None:
        return 2
    return 1 if res.rechazados else 0


def log_consola(texto, tag=None):
    print(texto)


def orden_send(args, cfg):
    res = analizar(args.script, cfg)
    if res is None:
        return 2
    if res.rechazados:
        return 1                     # no se transmite nada
    return 0 if operaciones.enviar_escena(res.comandos, cfg, log_consola) else 2


def orden_paquetes(args, cfg):
    res = analizar(args.script, cfg)
    if res is None:
        return 2
    if res.rechazados:
        return 1
    print()
    print(tabla_paquetes(res.comandos))
    return 0


def orden_inf(args, cfg):
    return 0 if operaciones.pedir_reporte(cfg, log_consola) else 2


def orden_cpu(args, cfg):
    res = analizar(args.script, cfg)
    if res is None or res.rechazados:
        return 1
    try:
        RasterizadorCPU().ejecutar(res.comandos)
    except NotImplementedError as e:
        print("[pendiente] {}".format(e))
        return 2
    return 0


def orden_comandos(args, cfg):
    print("{:<22}{:<6}{}".format("Comando", "Args", "OpCode"))
    print("-" * 44)
    for nombre, (op, n) in K.TABLA_COMANDOS.items():
        print("{:<22}{:<6}{}".format(
            nombre, n, "-" if op is None else "0x{:02X}".format(op)))
    print("\nRangos: coordenadas {}..{}, color {}..{}, radio {}..{}".format(
        K.COORD_MIN, K.COORD_MAX, K.COLOR_MIN, K.COLOR_MAX,
        K.RADIO_MIN, K.RADIO_MAX))
    print("Pantalla visible: {} x {}".format(
        K.ANCHO_PANTALLA, K.ALTO_PANTALLA))
    return 0


# main

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="gfxcli",
        description="Interfaz de comandos del acelerador grafico DE1-SoC.")
    p.add_argument("-c", "--config", default="config.json",
                   help="archivo de configuracion (por omision config.json)")
    p.add_argument("--host", help="direccion del HPS (sobrescribe config)")
    p.add_argument("--puerto", type=int, help="puerto (sobrescribe config)")
    sub = p.add_subparsers(dest="orden", required=True)

    s = sub.add_parser("check", help="valida el script sin transmitir")
    s.add_argument("script")
    s.set_defaults(func=orden_check)

    s = sub.add_parser("send", help="valida y transmite el script")
    s.add_argument("script")
    s.set_defaults(func=orden_send)

    s = sub.add_parser("paquetes", help="muestra los paquetes codificados")
    s.add_argument("script")
    s.set_defaults(func=orden_paquetes)

    s = sub.add_parser("cpu", help="ejecuta el script en CPU (referencia)")
    s.add_argument("script")
    s.set_defaults(func=orden_cpu)

    s = sub.add_parser("inf", help="solicita el reporte de rendimiento")
    s.set_defaults(func=orden_inf)

    s = sub.add_parser("comandos", help="muestra la tabla de comandos")
    s.set_defaults(func=orden_comandos)

    args = p.parse_args(argv)
    cfg = cfgmod.cargar(args.config)
    if args.host:
        cfg["host"] = args.host
    if args.puerto:
        cfg["puerto"] = args.puerto
    return args.func(args, cfg)


if __name__ == "__main__":
    sys.exit(main())
