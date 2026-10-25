#!/usr/bin/env python3
"""Ventana de la interfaz de comandos graficos.

Editor de escenas con validacion, envio y reporte de rendimiento.
Usa el mismo nucleo que gfxcli.py; estilo deliberadamente basico.

Uso:
  python3 gfxgui.py [escenas/ejemplo.gfx]

Compilado: 
  python -m PyInstaller --onefile gfxgui.py
"""

import os
import sys
import tkinter as tk
from tkinter import filedialog, messagebox

from gfx import config as cfgmod
from gfx import constantes as K
from gfx.interprete import InterpreteComandos
from gfx.codificador import CodificadorPaquete
from gfx.transporte import ClienteTransporte
from gfx.reporte import ReporteRendimiento
from gfx.raster_cpu import RasterizadorCPU


class VentanaInterfaz(tk.Tk):

    def __init__(self, ruta_inicial=None):
        super().__init__()
        self.title("Acelerador grafico DE1-SoC - Interfaz de comandos")
        self.geometry("900x640")

        self.cfg = cfgmod.cargar("config.json")
        self.ruta_actual = None
        self.modificado = False

        self._construir_menu()
        self._construir_barra()
        self._construir_cuerpo()
        self._construir_estado()

        self.protocol("WM_DELETE_WINDOW", self.al_cerrar)
        self.bind("<Control-a>", lambda e: self.abrir())
        self.bind("<Control-s>", lambda e: self.guardar())
        self.bind("<Control-d>", lambda e: self.validar())
        self.bind("<Control-f>", lambda e: self.enviar())

        if ruta_inicial and os.path.exists(ruta_inicial):
            self.cargar_archivo(ruta_inicial)
        else:
            self.nuevo()

    # Armado

    def _construir_menu(self):
        barra = tk.Menu(self)

        m = tk.Menu(barra, tearoff=0)
        m.add_command(label="Nuevo", command=self.nuevo)
        m.add_command(label="Abrir...", accelerator="Ctrl+O",
                      command=self.abrir)
        m.add_command(label="Guardar", accelerator="Ctrl+S",
                      command=self.guardar)
        m.add_command(label="Guardar como...", command=self.guardar_como)
        m.add_separator()
        m.add_command(label="Salir", command=self.al_cerrar)
        barra.add_cascade(label="Archivo", menu=m)

        m = tk.Menu(barra, tearoff=0)
        m.add_command(label="Validar", accelerator="Ctrl+D",
                      command=self.validar)
        m.add_command(label="Enviar", accelerator="Ctrl+F", command=self.enviar)
        m.add_command(label="Ejecutar en CPU (referencia)",
                      command=self.ejecutar_cpu)
        m.add_separator()
        m.add_command(label="Solicitar reporte (INF)",
                      command=self.solicitar_inf)
        barra.add_cascade(label="Ejecucion", menu=m)

        m = tk.Menu(barra, tearoff=0)
        m.add_command(label="Tabla de comandos", command=self.ver_comandos)
        m.add_command(label="Codigos de error", command=self.ver_errores)
        barra.add_cascade(label="Ayuda", menu=m)

        self.config(menu=barra)

    def _construir_barra(self):
        f = tk.Frame(self, bd=1, relief=tk.RAISED)
        f.pack(side=tk.TOP, fill=tk.X)

        for texto, accion in (("Abrir", self.abrir),
                              ("Guardar", self.guardar),
                              ("Validar", self.validar),
                              ("Enviar", self.enviar),
                              ("CPU", self.ejecutar_cpu),
                              ("INF", self.solicitar_inf)):
            tk.Button(f, text=texto, width=12,
                      command=accion).pack(side=tk.LEFT, padx=2, pady=2)

        tk.Label(f, text="  HPS:").pack(side=tk.LEFT)
        self.var_host = tk.StringVar(value=self.cfg["host"])
        tk.Entry(f, textvariable=self.var_host,
                 width=16).pack(side=tk.LEFT, padx=2)
        tk.Label(f, text="Puerto:").pack(side=tk.LEFT)
        self.var_puerto = tk.StringVar(value=str(self.cfg["puerto"]))
        tk.Entry(f, textvariable=self.var_puerto,
                 width=7).pack(side=tk.LEFT, padx=2)

    def _construir_cuerpo(self):
        panel = tk.PanedWindow(self, orient=tk.VERTICAL,
                               sashrelief=tk.RAISED)
        panel.pack(fill=tk.BOTH, expand=True)

        # --- editor de escena ---
        sup = tk.Frame(panel)
        tk.Label(sup, text="Script de escena",
                 anchor="w").pack(fill=tk.X)
        cont = tk.Frame(sup)
        cont.pack(fill=tk.BOTH, expand=True)

        self.numeros = tk.Text(cont, width=5, padx=4, takefocus=0,
                               bd=0, state=tk.DISABLED,
                               font=("Courier New", 10), bg="#eeeeee")
        self.numeros.pack(side=tk.LEFT, fill=tk.Y)

        barra_v = tk.Scrollbar(cont)
        barra_v.pack(side=tk.RIGHT, fill=tk.Y)

        self.editor = tk.Text(cont, wrap=tk.NONE, undo=True,
                              font=("Courier New", 10),
                              yscrollcommand=self._scroll_editor)
        self.editor.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        barra_v.config(command=self._scroll_ambos)
        self.barra_v = barra_v

        self.editor.tag_configure("linea_error", background="#ffd6d6")
        self.editor.bind("<<Modified>>", self._al_modificar)
        self.editor.bind("<KeyRelease>", lambda e: self._pintar_numeros())
        panel.add(sup, minsize=200)

        # --- salida ---
        inf = tk.Frame(panel)
        tk.Label(inf, text="Salida", anchor="w").pack(fill=tk.X)
        self.salida = tk.Text(inf, height=12, wrap=tk.WORD,
                              font=("Courier New", 10),
                              state=tk.DISABLED, bg="#f6f6f6")
        bs = tk.Scrollbar(inf, command=self.salida.yview)
        bs.pack(side=tk.RIGHT, fill=tk.Y)
        self.salida.config(yscrollcommand=bs.set)
        self.salida.pack(fill=tk.BOTH, expand=True)
        self.salida.tag_configure("err", foreground="#aa0000")
        self.salida.tag_configure("ok", foreground="#006600")
        self.salida.tag_configure("pend", foreground="#aa6600")
        panel.add(inf, minsize=120)

    def _construir_estado(self):
        self.var_estado = tk.StringVar(value="Listo.")
        tk.Label(self, textvariable=self.var_estado, anchor="w",
                 bd=1, relief=tk.SUNKEN).pack(side=tk.BOTTOM, fill=tk.X)

    # Editor: auxiliares

    def _scroll_editor(self, *a):
        self.barra_v.set(*a)
        self.numeros.yview_moveto(a[0])

    def _scroll_ambos(self, *a):
        self.editor.yview(*a)
        self.numeros.yview(*a)

    def _al_modificar(self, _evt):
        if self.editor.edit_modified():
            self.modificado = True
            self._pintar_titulo()
            self._pintar_numeros()
            self.editor.edit_modified(False)

    def _pintar_numeros(self):
        total = int(self.editor.index("end-1c").split(".")[0])
        self.numeros.config(state=tk.NORMAL)
        self.numeros.delete("1.0", tk.END)
        self.numeros.insert("1.0",
                            "\n".join(str(i) for i in range(1, total + 1)))
        self.numeros.config(state=tk.DISABLED)
        self.numeros.yview_moveto(self.editor.yview()[0])

    def _pintar_titulo(self):
        nombre = self.ruta_actual or "(sin titulo)"
        marca = "*" if self.modificado else ""
        self.title("Acelerador grafico DE1-SoC - {}{}".format(nombre, marca))

    # Salida

    def log(self, texto, tag=None):
        self.salida.config(state=tk.NORMAL)
        self.salida.insert(tk.END, texto + "\n", tag)
        self.salida.see(tk.END)
        self.salida.config(state=tk.DISABLED)

    def limpiar_salida(self):
        self.salida.config(state=tk.NORMAL)
        self.salida.delete("1.0", tk.END)
        self.salida.config(state=tk.DISABLED)
        self.editor.tag_remove("linea_error", "1.0", tk.END)

    # Archivo

    def nuevo(self):
        if not self._confirmar_descarte():
            return
        self.editor.delete("1.0", tk.END)
        self.ruta_actual = None
        self.modificado = False
        self._pintar_titulo()
        self._pintar_numeros()
        self.limpiar_salida()

    def abrir(self):
        if not self._confirmar_descarte():
            return
        ruta = filedialog.askopenfilename(
            title="Abrir script de escena",
            initialdir="escenas",
            filetypes=[("Scripts de escena", "*.gfx *.txt"),
                       ("Todos", "*.*")])
        if ruta:
            self.cargar_archivo(ruta)

    def cargar_archivo(self, ruta):
        with open(ruta, "r", encoding="utf-8") as f:
            contenido = f.read()
        self.editor.delete("1.0", tk.END)
        self.editor.insert("1.0", contenido)
        self.ruta_actual = ruta
        self.modificado = False
        self.editor.edit_modified(False)
        self._pintar_titulo()
        self._pintar_numeros()
        self.limpiar_salida()
        self.var_estado.set("Abierto: {}".format(ruta))

    def guardar(self):
        if self.ruta_actual is None:
            return self.guardar_como()
        with open(self.ruta_actual, "w", encoding="utf-8") as f:
            f.write(self.editor.get("1.0", "end-1c"))
        self.modificado = False
        self._pintar_titulo()
        self.var_estado.set("Guardado: {}".format(self.ruta_actual))
        return True

    def guardar_como(self):
        ruta = filedialog.asksaveasfilename(
            title="Guardar script", initialdir="escenas",
            defaultextension=".gfx",
            filetypes=[("Scripts de escena", "*.gfx"), ("Todos", "*.*")])
        if not ruta:
            return False
        self.ruta_actual = ruta
        return self.guardar()

    def _confirmar_descarte(self):
        if not self.modificado:
            return True
        r = messagebox.askyesnocancel(
            "Cambios sin guardar", "Guardar los cambios actuales?")
        if r is None:
            return False
        if r:
            return bool(self.guardar())
        return True

    def al_cerrar(self):
        if self._confirmar_descarte():
            self.destroy()

    # Ejecucion

    def _config_viva(self):
        cfg = dict(self.cfg)
        cfg["host"] = self.var_host.get().strip() or cfg["host"]
        try:
            cfg["puerto"] = int(self.var_puerto.get())
        except ValueError:
            pass
        return cfg

    def _analizar(self):
        """Devuelve el ResultadoAnalisis o None si la logica esta pendiente."""
        self.limpiar_salida()
        texto = self.editor.get("1.0", "end-1c")
        try:
            res = InterpreteComandos().analizar_texto(texto)
        except NotImplementedError as e:
            self.log("[pendiente] {}".format(e), "pend")
            self.var_estado.set("Logica del interprete pendiente.")
            return None

        for err in res.errores:
            self.log(str(err), "err")
            self.log("")
            self._marcar_linea(err.linea_num)

        if res.rechazados:
            self.log(res.resumen(), "err")
            self.var_estado.set("{} comando(s) rechazado(s).".format(
                res.rechazados))
        else:
            self.log(res.resumen(), "ok")
            self.var_estado.set("{} comando(s) aceptado(s).".format(
                res.aceptados))
        return res

    def _marcar_linea(self, num):
        if num:
            self.editor.tag_add("linea_error",
                                "{}.0".format(num),
                                "{}.end".format(num))

    def validar(self):
        self._analizar()

    def enviar(self):
        res = self._analizar()
        if res is None or res.rechazados:
            return
        cfg = self._config_viva()
        cod = CodificadorPaquete()
        cli = ClienteTransporte(cfg["host"], cfg["puerto"], cfg["tam_lote"])
        try:
            cli.conectar()
            for i in range(0, len(res.comandos), cli.tam_lote):
                lote = res.comandos[i:i + cli.tam_lote]
                cli.enviar_lote(cod.codificar_lote(lote))
            self.log("Transmitidos {} paquetes a {}:{}".format(
                res.aceptados, cfg["host"], cfg["puerto"]), "ok")
            self.var_estado.set("Lote transmitido.")
        except NotImplementedError as e:
            self.log("[pendiente] {}".format(e), "pend")
            self.var_estado.set("Transporte pendiente.")
        except OSError as e:
            self.log("Error {}: {}".format(K.EC_05, e), "err")
            self.var_estado.set("Fallo de conexion.")
        finally:
            cli.cerrar()

    def ejecutar_cpu(self):
        res = self._analizar()
        if res is None or res.rechazados:
            return
        try:
            RasterizadorCPU().ejecutar(res.comandos)
            self.log("Ejecucion en CPU completada.", "ok")
        except NotImplementedError as e:
            self.log("[pendiente] {}".format(e), "pend")

    def solicitar_inf(self):
        cfg = self._config_viva()
        cli = ClienteTransporte(cfg["host"], cfg["puerto"], cfg["tam_lote"])
        rep = ReporteRendimiento(cfg["ruta_reportes"])
        try:
            cli.conectar()
            fila = rep.parsear_respuesta(cli.solicitar_reporte())
            self.log("--- Reporte de rendimiento ---")
            for k, v in fila.items():
                self.log("  {:<14} {}".format(k, v))
            rep.anexar(fila)
            self.var_estado.set("Reporte anexado a {}".format(
                cfg["ruta_reportes"]))
        except NotImplementedError as e:
            self.log("[pendiente] {}".format(e), "pend")
        except OSError as e:
            self.log("Error {}: {}".format(K.EC_05, e), "err")
        finally:
            cli.cerrar()

    # Ayuda

    def ver_comandos(self):
        lineas = ["{:<24}{:<6}{}".format("Comando", "Args", "OpCode"),
                  "-" * 46]
        for nombre, (op, n) in K.TABLA_COMANDOS.items():
            lineas.append("{:<24}{:<6}{}".format(
                nombre, n, "-" if op is None else "0x{:02X}".format(op)))
        lineas += ["",
                   "Coordenadas: {} a {}".format(K.COORD_MIN, K.COORD_MAX),
                   "Color: {} a {} por componente".format(
                       K.COLOR_MIN, K.COLOR_MAX),
                   "Radio: {} a {}".format(K.RADIO_MIN, K.RADIO_MAX),
                   "Pantalla visible: {} x {}".format(
                       K.ANCHO_PANTALLA, K.ALTO_PANTALLA)]
        self._ventana_texto("Tabla de comandos", "\n".join(lineas))

    def ver_errores(self):
        lineas = ["{:<8}{}".format("Codigo", "Condicion"), "-" * 60]
        for cod, desc in K.DESCRIPCION_EC.items():
            lineas.append("{:<8}{}".format(cod, desc))
        self._ventana_texto("Codigos de error", "\n".join(lineas))

    def _ventana_texto(self, titulo, contenido):
        v = tk.Toplevel(self)
        v.title(titulo)
        v.geometry("560x420")
        t = tk.Text(v, wrap=tk.NONE, font=("Courier New", 10))
        t.pack(fill=tk.BOTH, expand=True)
        t.insert("1.0", contenido)
        t.config(state=tk.DISABLED)


def main():
    ruta = sys.argv[1] if len(sys.argv) > 1 else None
    VentanaInterfaz(ruta).mainloop()


if __name__ == "__main__":
    main()
