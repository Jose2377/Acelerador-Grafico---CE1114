"""ReporteRendimiento: presenta y archiva los contadores de rendimiento.
Archivo CSV acumulativo, una fila por ventana de medicion.

Las filas vienen de dos origenes, para la comparacion del caso de uso
CU-04 en un mismo archivo:
  fpga         contadores devueltos por el hardware (camino de vuelta)
  cpu-tramos   RasterizadorCPU en modo "tramos"
  cpu-pixel    RasterizadorCPU en modo "pixel"

En las filas de CPU no hay ciclos de reloj: rasterizacion_s es el tiempo
de CPU de los comandos de la ventana.
"""

import csv
import os
from datetime import datetime

CAMPOS = ["marca_tiempo", "origen", "escena", "ciclos", "comandos",
          "pixeles", "recortados", "errores", "descartados",
          "rasterizacion_s", "extremo_a_extremo_s", "pixeles_por_s"]


def _ahora():
    return datetime.now().isoformat(timespec="seconds")


class ReporteRendimiento:

    def __init__(self, ruta_csv, sys_clk_hz=100000000):
        self.ruta_csv = ruta_csv
        self.sys_clk_hz = sys_clk_hz

    def parsear_respuesta(self, contadores, escena=""):
        """dict de ClienteTransporte.solicitar_reporte() -> fila del CSV."""
        ciclos = contadores["ciclos"]
        seg = ciclos / self.sys_clk_hz if self.sys_clk_hz else 0.0
        return {
            "marca_tiempo": _ahora(),
            "origen": "fpga",
            "escena": escena,
            "ciclos": ciclos,
            "comandos": contadores["comandos"],
            "pixeles": contadores["pixeles"],
            "recortados": "",          # CLIP_COUNT no viaja en el reporte
            "errores": contadores["errores"],
            "descartados": contadores["descartados"],
            "rasterizacion_s": round(seg, 6),
            "extremo_a_extremo_s": contadores.get("extremo_a_extremo_s", ""),
            "pixeles_por_s": round(contadores["pixeles"] / seg) if seg else "",
        }

    def desde_cpu(self, ventana, modo, escena=""):
        """Ventana de RasterizadorCPU -> fila del CSV."""
        seg = ventana.tiempo_s
        return {
            "marca_tiempo": _ahora(),
            "origen": "cpu-" + modo,
            "escena": escena,
            "ciclos": "",
            "comandos": ventana.comandos,
            "pixeles": ventana.pixeles,
            "recortados": ventana.recortados,
            "errores": ventana.errores,
            "descartados": 0,
            "rasterizacion_s": round(seg, 6),
            "extremo_a_extremo_s": "",
            "pixeles_por_s": round(ventana.pixeles / seg) if seg else "",
        }

    def anexar(self, fila):
        """Acumulativo: nunca se sobrescribe. Si el archivo existente tiene
        otras columnas (version anterior), se renombra con la fecha y se
        empieza uno nuevo, para no mezclar formatos."""
        os.makedirs(os.path.dirname(self.ruta_csv) or ".", exist_ok=True)
        nuevo = (not os.path.exists(self.ruta_csv)
                 or os.path.getsize(self.ruta_csv) == 0)
        if not nuevo:
            with open(self.ruta_csv, newline="", encoding="utf-8") as f:
                encabezado = next(csv.reader(f), [])
            if encabezado != CAMPOS:
                base, ext = os.path.splitext(self.ruta_csv)
                os.replace(self.ruta_csv, "{}_{}{}".format(
                    base, datetime.now().strftime("%Y%m%d_%H%M%S"), ext))
                nuevo = True
        with open(self.ruta_csv, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=CAMPOS)
            if nuevo:
                w.writeheader()
            w.writerow(fila)

    def como_texto(self, fila, titulo="Reporte de rendimiento"):
        lineas = ["--- {} ---".format(titulo)]
        for k in CAMPOS:
            if k == "marca_tiempo":
                continue
            v = fila.get(k, "")
            lineas.append("  {:<20} {}".format(k, "-" if v == "" else v))
        return "\n".join(lineas)

    def mostrar(self, fila):
        print("\n" + self.como_texto(fila) + "\n")
