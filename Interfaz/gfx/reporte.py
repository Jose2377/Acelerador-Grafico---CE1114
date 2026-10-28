"""ReporteRendimiento: presenta y archiva los contadores devueltos por
el hardware. Archivo CSV acumulativo, una fila por ventana de medicion.
"""

import csv
import os
from datetime import datetime

CAMPOS = ["marca_tiempo", "ciclos", "comandos", "pixeles", "errores",
          "descartados", "rasterizacion_s", "extremo_a_extremo_s",
          "pixeles_por_s"]


class ReporteRendimiento:

    def __init__(self, ruta_csv, sys_clk_hz=50000000):
        self.ruta_csv = ruta_csv
        self.sys_clk_hz = sys_clk_hz

    def parsear_respuesta(self, contadores):
        """dict de ClienteTransporte.solicitar_reporte() -> fila del CSV."""
        ciclos = contadores["ciclos"]
        seg = ciclos / self.sys_clk_hz if self.sys_clk_hz else 0.0
        return {
            "marca_tiempo": datetime.now().isoformat(timespec="seconds"),
            "ciclos": ciclos,
            "comandos": contadores["comandos"],
            "pixeles": contadores["pixeles"],
            "errores": contadores["errores"],
            "descartados": contadores["descartados"],
            "rasterizacion_s": round(seg, 6),
            "extremo_a_extremo_s": contadores.get("extremo_a_extremo_s", ""),
            "pixeles_por_s": round(contadores["pixeles"] / seg) if seg else "",
        }

    def anexar(self, fila):
        """Acumulativo: nunca se sobrescribe."""
        nuevo = (not os.path.exists(self.ruta_csv)
                 or os.path.getsize(self.ruta_csv) == 0)
        os.makedirs(os.path.dirname(self.ruta_csv) or ".", exist_ok=True)
        with open(self.ruta_csv, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=CAMPOS)
            if nuevo:
                w.writeheader()
            w.writerow(fila)

    def como_texto(self, fila):
        lineas = ["--- Reporte de rendimiento ---"]
        for k in CAMPOS:
            v = fila.get(k, "")
            lineas.append("  {:<20} {}".format(k, "-" if v == "" else v))
        return "\n".join(lineas)

    def mostrar(self, fila):
        print("\n" + self.como_texto(fila) + "\n")
