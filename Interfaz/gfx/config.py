"""Archivo de configuracion: direccion del HPS, puerto, tamano de lote,
ruta de reportes."""

import json
import os

PREDETERMINADO = {
    "host": "192.168.1.100",
    "puerto": 5000,
    "tam_lote": 256,
    "ruta_reportes": "reportes/rendimiento.csv",
    "ruta_log_errores": "reportes/errores_sesion.log",
    "sys_clk_hz": 50000000,
    "timeout_s": 5.0,
}


def cargar(ruta="config.json"):
    cfg = dict(PREDETERMINADO)
    if os.path.exists(ruta):
        with open(ruta, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
    return cfg


def guardar_predeterminado(ruta="config.json"):
    with open(ruta, "w", encoding="utf-8") as f:
        json.dump(PREDETERMINADO, f, indent=2)
