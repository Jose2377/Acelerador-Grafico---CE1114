#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ver_raster.py
Visualizador del volcado del banco de pruebas del rasterizador.

Lee los dos archivos que produce tb_Acelerador_Grafico_Top.sv y genera las
imagenes correspondientes, mas un resumen de las comprobaciones.

    raster_dump.csv     un fotograma por escena
    raster_pruebas.csv  una fila por comprobacion

    salida/NN_nombre.png     un PNG por fotograma
    salida/contactos.png     todos los fotogramas en una sola hoja

Solo usa la biblioteca estandar de Python 3: no hay nada que instalar, ni
numpy, ni matplotlib, ni Pillow. El escritor de PNG son las tres funciones
del final del archivo y se apoya en zlib, que viene con el interprete.

Uso:
    python ver_raster.py                      todo, con escala 8
    python ver_raster.py --escala 12
    python ver_raster.py --ascii              tambien en la consola
    python ver_raster.py --solo escena        un fotograma por su nombre
    python ver_raster.py --dir ../simulacion  si los .csv estan en otra parte
"""

import argparse
import os
import struct
import sys
import zlib

# El pixel nunca escrito se dibuja con este color, para distinguirlo del
# negro, que es un color legitimo del framebuffer.
COLOR_VACIO = (24, 24, 28)

# Caracteres del modo consola, de menos a mas luminoso.
RAMPA_ASCII = " .:-=+*#%@"


# ----------------------------------------------------------------- lectura
def rgb565_a_rgb888(valor):
    """Expande RGB565 a RGB888 replicando los bits altos en los bajos.

    Es la inversa de la conversion del hardware. Replicar en lugar de
    rellenar con ceros es lo que hace que el blanco 0xFFFF salga (255,255,255)
    y no (248,252,248).
    """
    r5 = (valor >> 11) & 0x1F
    g6 = (valor >> 5) & 0x3F
    b5 = valor & 0x1F
    r = (r5 << 3) | (r5 >> 2)
    g = (g6 << 2) | (g6 >> 4)
    b = (b5 << 3) | (b5 >> 2)
    return (r, g, b)


class Fotograma:
    def __init__(self, indice, nombre, ancho, alto, n_pixeles, n_descartados):
        self.indice = indice
        self.nombre = nombre
        self.ancho = ancho
        self.alto = alto
        self.n_pixeles = n_pixeles
        self.n_descartados = n_descartados
        # None = pixel nunca escrito; un entero = color RGB565
        self.pixeles = [[None] * ancho for _ in range(alto)]

    def rgb(self, x, y):
        valor = self.pixeles[y][x]
        return COLOR_VACIO if valor is None else rgb565_a_rgb888(valor)

    def escritos(self):
        return sum(1 for fila in self.pixeles for v in fila if v is not None)


def leer_volcado(ruta):
    """Lee raster_dump.csv y devuelve la lista de fotogramas."""
    fotogramas = []
    actual = None
    with open(ruta, "r", encoding="utf-8", errors="replace") as f:
        for n_linea, linea in enumerate(f, start=1):
            linea = linea.strip()
            if not linea or linea.startswith("#"):
                continue
            campos = linea.split(";")
            try:
                if campos[0] == "F":
                    actual = Fotograma(
                        indice=int(campos[1]),
                        nombre=campos[2],
                        ancho=int(campos[3]),
                        alto=int(campos[4]),
                        n_pixeles=int(campos[5]),
                        n_descartados=int(campos[6]),
                    )
                    fotogramas.append(actual)
                elif campos[0] == "P":
                    if actual is None:
                        raise ValueError("pixel antes de la cabecera F")
                    x, y = int(campos[1]), int(campos[2])
                    actual.pixeles[y][x] = int(campos[3], 16)
                else:
                    raise ValueError("tipo de registro desconocido")
            except (IndexError, ValueError) as e:
                print("  aviso: linea %d ignorada (%s): %s"
                      % (n_linea, e, linea), file=sys.stderr)
    return fotogramas


def leer_pruebas(ruta):
    """Lee raster_pruebas.csv y devuelve la lista de filas como diccionarios."""
    filas = []
    with open(ruta, "r", encoding="utf-8", errors="replace") as f:
        cabecera = f.readline()          # se descarta
        for linea in f:
            linea = linea.rstrip("\n")
            if not linea.strip():
                continue
            campos = linea.split(";")
            if len(campos) < 4:
                continue
            filas.append({
                "prueba": campos[0],
                "obtenido": campos[1],
                "esperado": campos[2],
                "resultado": campos[3],
            })
    return filas


# ------------------------------------------------------------- presentacion
def resumen_pruebas(filas):
    fallas = [f for f in filas if f["resultado"] != "OK"]
    print("")
    print("=" * 66)
    print(" Comprobaciones: %d en total, %d pasaron, %d fallaron"
          % (len(filas), len(filas) - len(fallas), len(fallas)))
    print("=" * 66)
    if fallas:
        print("")
        print(" %-44s %-12s %s" % ("PRUEBA FALLIDA", "OBTENIDO", "ESPERADO"))
        print(" " + "-" * 64)
        for f in fallas:
            print(" %-44s %-12s %s"
                  % (f["prueba"][:44], f["obtenido"][:12], f["esperado"]))
    return len(fallas)


def imprimir_ascii(fot):
    """Vista rapida en la consola, por luminosidad del pixel."""
    print("")
    print("  %s  (%d x %d, %d pixeles escritos)"
          % (fot.nombre, fot.ancho, fot.alto, fot.escritos()))
    print("  +" + "-" * fot.ancho + "+")
    for y in range(fot.alto):
        fila = []
        for x in range(fot.ancho):
            if fot.pixeles[y][x] is None:
                fila.append(" ")
            else:
                r, g, b = rgb565_a_rgb888(fot.pixeles[y][x])
                # luminosidad perceptual, en enteros para no arrastrar floats
                lum = (r * 299 + g * 587 + b * 114) // 1000
                fila.append(RAMPA_ASCII[min(lum * len(RAMPA_ASCII) // 256,
                                            len(RAMPA_ASCII) - 1)])
        print("  |" + "".join(fila) + "|")
    print("  +" + "-" * fot.ancho + "+")


def rasterizar(fot, escala):
    """Devuelve las filas de pixeles RGB del fotograma, ya ampliado."""
    filas = []
    for y in range(fot.alto):
        fila = bytearray()
        for x in range(fot.ancho):
            fila += bytes(fot.rgb(x, y)) * escala
        for _ in range(escala):
            filas.append(bytes(fila))
    return filas


def hoja_de_contactos(fotogramas, escala, columnas=3, margen=6):
    """Compone todos los fotogramas en una sola rejilla."""
    if not fotogramas:
        return []
    an = max(f.ancho for f in fotogramas) * escala
    al = max(f.alto for f in fotogramas) * escala
    filas_rejilla = (len(fotogramas) + columnas - 1) // columnas

    ancho_total = columnas * an + (columnas + 1) * margen
    alto_total = filas_rejilla * al + (filas_rejilla + 1) * margen
    fondo = bytes((12, 12, 14))
    lienzo = [bytearray(fondo * ancho_total) for _ in range(alto_total)]

    for i, fot in enumerate(fotogramas):
        bloque = rasterizar(fot, escala)
        col, fil = i % columnas, i // columnas
        x0 = margen + col * (an + margen)
        y0 = margen + fil * (al + margen)
        for dy, linea in enumerate(bloque):
            lienzo[y0 + dy][x0 * 3:(x0 * 3) + len(linea)] = linea
    return [bytes(f) for f in lienzo]


# ------------------------------------------------- escritor de PNG (stdlib)
def _trozo(tipo, datos):
    """Un chunk de PNG: longitud, tipo, datos y su CRC."""
    cuerpo = tipo + datos
    return (struct.pack(">I", len(datos)) + cuerpo
            + struct.pack(">I", zlib.crc32(cuerpo) & 0xFFFFFFFF))


def escribir_png(ruta, filas):
    """Escribe un PNG RGB de 8 bits. filas: lista de bytes, una por linea."""
    if not filas:
        raise ValueError("no hay nada que escribir")
    alto = len(filas)
    ancho = len(filas[0]) // 3

    # Cada linea va precedida por su byte de filtro, aqui siempre 0 (ninguno).
    cruda = b"".join(b"\x00" + fila for fila in filas)

    with open(ruta, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_trozo(b"IHDR",
                       struct.pack(">IIBBBBB", ancho, alto, 8, 2, 0, 0, 0)))
        f.write(_trozo(b"IDAT", zlib.compress(cruda, 9)))
        f.write(_trozo(b"IEND", b""))
    return ancho, alto


# -------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(
        description="Convierte el volcado del rasterizador en imagenes PNG.")
    ap.add_argument("--dir", default=".",
                    help="carpeta donde estan los .csv (por defecto, la actual)")
    ap.add_argument("--salida", default="salida",
                    help="carpeta donde escribir los PNG")
    ap.add_argument("--escala", type=int, default=8,
                    help="cuantos pixeles de pantalla por pixel del framebuffer")
    ap.add_argument("--ascii", action="store_true",
                    help="imprimir ademas cada fotograma en la consola")
    ap.add_argument("--solo", default=None,
                    help="procesar solo los fotogramas cuyo nombre contenga esto")
    args = ap.parse_args()

    if args.escala < 1:
        print("la escala tiene que ser 1 o mas", file=sys.stderr)
        return 2

    ruta_img = os.path.join(args.dir, "raster_dump.csv")
    ruta_prb = os.path.join(args.dir, "raster_pruebas.csv")

    if not os.path.exists(ruta_img):
        print("no encuentro %s" % ruta_img, file=sys.stderr)
        print("corre primero la simulacion, o indica la carpeta con --dir",
              file=sys.stderr)
        return 2

    fotogramas = leer_volcado(ruta_img)
    if args.solo:
        fotogramas = [f for f in fotogramas if args.solo.lower() in f.nombre.lower()]
        if not fotogramas:
            print("ningun fotograma coincide con %r" % args.solo, file=sys.stderr)
            return 2

    os.makedirs(args.salida, exist_ok=True)

    print("")
    print(" %-4s %-32s %-11s %-9s %s"
          % ("NUM", "FOTOGRAMA", "TAMANO", "PIXELES", "ARCHIVO"))
    print(" " + "-" * 76)
    for fot in fotogramas:
        nombre_png = "%02d_%s.png" % (fot.indice, fot.nombre)
        ruta_png = os.path.join(args.salida, nombre_png)
        escribir_png(ruta_png, rasterizar(fot, args.escala))
        print(" %-4d %-32s %-11s %-9d %s"
              % (fot.indice, fot.nombre[:32],
                 "%dx%d" % (fot.ancho, fot.alto), fot.escritos(), ruta_png))
        if args.ascii:
            imprimir_ascii(fot)

    if len(fotogramas) > 1:
        ruta_hoja = os.path.join(args.salida, "contactos.png")
        an, al = escribir_png(ruta_hoja,
                              hoja_de_contactos(fotogramas, args.escala))
        print("")
        print(" Hoja de contactos: %s (%dx%d)" % (ruta_hoja, an, al))

    fallas = 0
    if os.path.exists(ruta_prb):
        fallas = resumen_pruebas(leer_pruebas(ruta_prb))
    else:
        print("")
        print(" aviso: no encuentro %s, no hay resumen de pruebas" % ruta_prb)

    print("")
    return 1 if fallas else 0


if __name__ == "__main__":
    sys.exit(main())
