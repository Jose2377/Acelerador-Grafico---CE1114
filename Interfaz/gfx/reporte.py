"""ReporteRendimiento: presenta y archiva los contadores devueltos por
el hardware. Archivo CSV acumulativo, una fila por ventana de medicion.

ESTADO: estructura lista; lectura de los contadores PENDIENTE.
"""

import csv
import os
from datetime import datetime

CAMPOS = ["marca_tiempo", "ciclos", "comandos", "pixeles",
          "errores", "descartados", "segundos"]


class ReporteRendimiento:

    def __init__(self, ruta_csv):
        self.ruta_csv = ruta_csv

    def desde_contadores(self, ciclos, comandos, pixeles,
                         errores, descartados, sys_clk_hz):
        return {
            "marca_tiempo": datetime.now().isoformat(timespec="seconds"),
            "ciclos": ciclos,
            "comandos": comandos,
            "pixeles": pixeles,
            "errores": errores,
            "descartados": descartados,
            "segundos": round(ciclos / sys_clk_hz, 6) if sys_clk_hz else 0,
        }

    def anexar(self, fila):
        """Acumulativo: nunca se sobrescribe."""
        nuevo = not os.path.exists(self.ruta_csv)
        os.makedirs(os.path.dirname(self.ruta_csv) or ".", exist_ok=True)
        with open(self.ruta_csv, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=CAMPOS)
            if nuevo:
                w.writeheader()
            w.writerow(fila)

    def mostrar(self, fila):
        print("\n--- Reporte de rendimiento ---")
        for k in CAMPOS:
            print("  {:<14} {}".format(k, fila.get(k, "-")))
        print()

    def parsear_respuesta(self, datos):
        """Interpreta la estructura de contadores del camino de vuelta.

        PENDIENTE.
        """
        raise NotImplementedError("Parseo del reporte pendiente")
