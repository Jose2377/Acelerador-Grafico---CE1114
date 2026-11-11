# Linux embebido para la DE1-SoC (unidad de aceleración gráfica 2D, CE-1114)

Esta carpeta (`Linux/` del repositorio) arma la imagen completa de la microSD de la DE1-SoC: preloader (SPL), U-Boot, kernel, device tree, rootfs, el driver `/dev/gpu2d` y el servicio TCP. Al arrancar, U-Boot programa la FPGA con `soc_system.rbf`, habilita los puentes HPS↔FPGA y arranca Linux.

---

## 0. Cómo se reparte el trabajo entre Windows y Linux

Windows y Ubuntu están en particiones distintas del mismo disco. **Ninguna ruta de Windows existe en Linux** (`C:\Users\...` no se ve desde Ubuntu). Por eso el repositorio en GitHub es el único puente entre los dos sistemas:

| | Windows | Ubuntu (otra partición) |
|---|---|---|
| Qué se hace | Quartus: compilar el `.sof` y convertirlo a `.rbf` | Buildroot: compilar la imagen de la SD |
| Carpeta | `C:\Users\Jose Maria Vindas\Documents\GitHub\Acelerador-Grafico---CE1114` | `~/Acelerador-Grafico---CE1114` (clon propio, **sin espacios** en la ruta) |
| Cómo se sincroniza | `git commit` + `git push` | `git pull` |
| Qué viaja | `Linux/br2-external/board/de1soc/fpga/soc_system.rbf` y el código | — |

- **El `.sof` no viaja:** `.gitignore` excluye `*.sof`. Lo que se versiona es el `.rbf`, que es lo único que Linux necesita.
- **Linux no necesita Quartus.**
- **No compiles en la partición de Windows montada desde Ubuntu** (`/media/...`): NTFS rompe permisos y Buildroot falla. Todo se hace en el disco de Linux.

En este documento, `<repositorio>` es la raíz del clon en cada sistema. **Todos los comandos de Linux se ejecutan desde `<repositorio>/Linux`** con `bash scripts/NN-....sh`. Con `bash` delante no hace falta `chmod`; además, los scripts corrigen solos los permisos y los finales de línea de `post-image.sh` y demás.

---

## 1. Valores estándar

| Valor | Estándar |
|---|---|
| Quartus | Prime 18.1 Lite, en Windows (`C:\intelFPGA_lite\18.1\quartus\bin64`) |
| Dispositivo | 5CSEMA5F31C6 (en la cadena JTAG: `SOCVHPS` + `5CSEMA5`) |
| Carpeta de compilación (Linux) | `~/de1soc` (Buildroot, descargas y resultado; ~15 GB). Se cambia con `BASE=/ruta` |
| SW10 (MSEL[4:0]) | `01010` (FPPx32, el HPS configura la FPGA desde la SD; acepta `.rbf` comprimido). Confírmalo con la tabla del manual |
| Consola serie | mini-USB "UART" junto al Ethernet, 115200 8N1 |
| Usuario / contraseña | `root` / `de1soc` |
| IP de la placa / de la PC | `192.168.10.2/24` / `192.168.10.1/24`, cable directo |
| Puerto del servicio | TCP 5000 |
| Base del acelerador | `0xFF200000`; el registro ID debe leer `0xACE11140` |

---

## 2. Contenido de esta carpeta

```
Linux/
  LEEME.md                         este documento
  windows/generar-rbf.bat          (Windows) .sof -> soc_system.rbf, doble clic
  scripts/                         (Linux) pasos numerados, siempre con "bash"
    config.sh                      rutas; se calculan solas desde el repositorio
    00-instalar-dependencias.sh    una vez
    01-preparar-buildroot.sh       una vez
    02-descargar-fuentes.sh        opcional
    03-compilar.sh                 compilación completa
    04-compilar-modulo.sh          solo driver y servicio
    05-actualizar-rbf.sh           solo cambiar el bitstream
    06-grabar-sd.sh                grabar la microSD
    qts-handoff.sh                 solo si cambia el HPS en Platform Designer
  br2-external/                    árbol externo de Buildroot
    configs/de1soc_defconfig
    board/de1soc/
      socfpga_cyclone5_de1_soc.dts   DTS del kernel (nodo gpu2d@ff200000)
      boot.cmd                       fpga load + bridge enable + bootz
      post-image.sh                  arma sdcard.img (p1 FAT | p2 ext4 | p3 tipo A2)
      fpga/soc_system.rbf            bitstream (llega por git)
      qts/                           handoff del preloader
      rootfs-overlay/                IP fija, arranque del servicio (S90gpu2d)
    package/gpu2d-driver, gpu2d-servicio
  ejemplos/driver/                 driver /dev/gpu2d (gpu2d.c) e interfaz común (gpu2d_ioctl.h)
  ejemplos/servicio/               servicio TCP con PROTOCOLO.md (ver sección 7)
```

| Componente | Versión |
|---|---|
| Buildroot | 2026.02.3 LTS |
| Toolchain | Bootlin armv7-eabihf glibc *stable* (precompilada) |
| U-Boot + SPL | 2026.01, `socfpga_de1_soc_defconfig` + handoff de `qts/` |
| Kernel | Linux 6.12.91 LTS, `socfpga_defconfig` + `linux.fragment` |

---

## 3. Fase A (Windows): probar la FPGA sola por JTAG

Hazla antes que todo lo demás. Si la FPGA no funciona sola, Linux no lo va a arreglar.

1. Compila `FPGA\Acelerador_Grafico.qpf` en Quartus (*Processing → Start Compilation*).
2. Conecta la alimentación, el monitor VGA y el USB al puerto **USB-Blaster** (junto al conector de alimentación).
3. *Tools → Programmer → Hardware Setup* → **DE-SoC [USB-1]**.
4. **Auto Detect** → elige **5CSEMA5**. Si pregunta si actualiza la lista de dispositivos, responde **Yes**.
5. La cadena debe tener **exactamente dos** dispositivos: `SOCVHPS` y `5CSEMA5`.
6. Selecciona la fila `5CSEMA5` → **Change File** (no *Add File*) → `output_files\Acelerador_Grafico.sof`.
7. Marca **Program/Configure** solo en esa fila → **Start** → `100% (Successful)`.

| LED | Esperado | Indica |
|---|---|---|
| LEDR[3] | Cambia cada 0,5 s | PLL y `clk_sys` vivos |
| LEDR[0] | Parpadea a 1 Hz | Barrido VGA a ~60 cuadros/s |
| LEDR[9:7] | `001` (Espera) | FSM del decodificador viva |
| LEDR[6:4] | `000` | Cola vacía |

El monitor debe detectar 640×480 a 60 Hz. La imagen puede salir negra o con basura. Si sale corrida un píxel, prueba `assign VGA_CLK = ~clk_pix;` en `DE1_SoC_top_level.sv`.

---

## 4. Fase B (Windows): generar el `.rbf` y subirlo

Repite esta fase cada vez que recompiles el hardware.

1. Doble clic en `Linux\windows\generar-rbf.bat`. Calcula las rutas solo y deja `Linux\br2-external\board\de1soc\fpga\soc_system.rbf`. Si Quartus no está en `C:\intelFPGA_lite\18.1\quartus\bin64`, edita `QBIN` al inicio del archivo.
2. Súbelo:
   ```
   git add Linux/br2-external/board/de1soc/fpga/soc_system.rbf
   git commit -m "Bitstream actualizado"
   git push
   ```

---

## 5. Fase C (Ubuntu): compilar la imagen de la SD

Requisitos: Ubuntu 22.04/24.04, unos 40 GB libres en la partición de Linux, conexión a internet. La primera compilación tarda 30-60 min.

```bash
# Una vez: clonar el repositorio en el disco de Linux (ruta sin espacios)
cd ~
git clone https://github.com/Jose2377/Acelerador-Grafico---CE1114.git
cd Acelerador-Grafico---CE1114
git checkout <rama>              # la rama que tenga Linux/ y el .rbf (ej. development)

# Cada vez: traer lo último de Windows
git pull

cd Linux
bash scripts/00-instalar-dependencias.sh   # una vez (pide la contraseña de sudo)
bash scripts/01-preparar-buildroot.sh      # una vez
bash scripts/02-descargar-fuentes.sh       # opcional
bash scripts/03-compilar.sh                # compilación completa
```

`03-compilar.sh` revisa primero que exista `soc_system.rbf`. Si falta, avisa y pregunta si continúas sin él; sin bitstream, la placa arranca Linux pero no programa la FPGA. Lo correcto es hacer la fase B y `git pull` antes.

Resultado en `~/de1soc/output/images/`: `sdcard.img` (más `u-boot-with-spl.sfp`, `zImage`, `socfpga_cyclone5_de1_soc.dtb`, `boot.scr` y `rootfs.ext4`).

Revisión rápida: `sfdisk -l ~/de1soc/output/images/sdcard.img` debe mostrar p1 FAT, p2 Linux y p3 tipo `a2`.

### Ciclos siguientes (minutos, no horas)

| Cambió | En Windows | En Ubuntu (`<repositorio>/Linux`) |
|---|---|---|
| Hardware (SystemVerilog) | Fase B (`.bat` + push) | `git pull && bash scripts/05-actualizar-rbf.sh` |
| Driver o servicio (`ejemplos/`) | push si lo editaste ahí | `git pull && bash scripts/04-compilar-modulo.sh` |
| HPS en Platform Designer | Recompilar + push de `FPGA/hps_isw_handoff` | `bash scripts/qts-handoff.sh && make -C ~/de1soc/output uboot-dirclean all` |
| DTS, kernel o config | — | `make -C ~/de1soc/output linux-rebuild all` |

Si el `.rbf` llega por otra vía (por ejemplo, una memoria USB): `bash scripts/05-actualizar-rbf.sh /media/$USER/USB/soc_system.rbf`.

El handoff de `qts/` coincide con `FPGA/hps_isw_handoff` al 10/11/2026: git solo muestra cambios de finales de línea. No hace falta regenerarlo.

---

## 6. Fase D: grabar la SD y arrancar la placa

1. **Graba la SD** desde Ubuntu: `lsblk` para ver el nombre del lector y luego `bash scripts/06-grabar-sd.sh /dev/sdX`.
2. **SW10 (MSEL[4:0]) = `01010`**, con la placa apagada. En SW10, ON = 0; revisa la serigrafía.
3. **Consola serie:**
   - Ubuntu: `sudo picocom -b 115200 /dev/ttyUSB0`.
   - Windows: PuTTY → *Serial*, el COM del Administrador de dispositivos, 115200.
4. Inserta la SD, enciende y verifica esta secuencia:

| Mensaje | Si se detiene aquí |
|---|---|
| `U-Boot SPL 2026.01` | Revisa `qts/` y que la SD tenga la partición A2 |
| `Programando FPGA con soc_system.rbf` | Revisa MSEL y que el `.rbf` sea comprimido |
| `AVISO: no hay soc_system.rbf` | Falta la fase B y `05-actualizar-rbf.sh` |
| `de1soc login:` | Entra con `root` / `de1soc` |

5. Verifica el acelerador:
   ```bash
   dmesg | grep gpu2d          # "acelerador 2D listo (ID 0xace11140 ...)"
   ls -l /dev/gpu2d
   devmem 0xFF200000 32        # 0xACE11140
   devmem 0xFF200008 32        # STATUS
   ps | grep gpu2d-servicio
   ```
6. **Red:** PC en `192.168.10.1/24` con cable directo, luego `ssh root@192.168.10.2`.

Con Linux corriendo, **no reprogrames la FPGA por JTAG** sin antes ejecutar `/etc/init.d/S90gpu2d stop; rmmod gpu2d`. Lo normal es actualizar el `.rbf` y reiniciar.

---

## 7. Fase E: interfaz Python por red

1. `Interfaz/config.json` ya apunta a `192.168.10.2:5000`. Para probar sin la placa con `servidor_simulado.py`, cambia el host a `127.0.0.1` en la barra superior de la GUI.
2. Pon la PC en `192.168.10.1/24`, conecta el cable directo y comprueba con `ping 192.168.10.2`.
3. `python gfxgui.py escenas/ejemplo.gfx` → *Enviar*, o `python gfxcli.py send escenas/ejemplo.gfx`. Con `inf` al final, la escena devuelve el reporte de rendimiento y lo anexa a `reportes/rendimiento.csv`.
4. Para ver en vivo lo que recibe la placa: `ssh root@192.168.10.2`, luego `/etc/init.d/S90gpu2d stop` y `gpu2d-servicio 5000 -v`.

### Cómo se reparte el trabajo

| Pieza | Archivo | Qué hace |
|---|---|---|
| Servicio (nivel 2) | `ejemplos/servicio/gpu2d-servicio.c` | Implementa `Interfaz/PROTOCOLO.md`: valida el encabezado (EC-05 y cierra si es inválido), escribe los LOTE, abre la ventana solo con `INICIO_VENTANA` y responde la SOLICITUD con el REPORTE de la misma secuencia |
| Acceso al hardware | `hw_dev.c` (placa) / `hw_sim.c` (PC) | Mismas 6 funciones; `make sim` arma el servicio con un acelerador simulado en memoria |
| Driver | `ejemplos/driver/gpu2d.c` | `write()` espera espacio en la cola antes de cada paquete (no se pierde ninguno); ioctl `VENTANA`, `ACK` y `ESPERAR` |
| Interfaz común | `ejemplos/driver/gpu2d_ioctl.h` | Lo incluyen el driver y el servicio; si cambias uno, recompila los dos (`bash scripts/04-compilar-modulo.sh`) |

**Qué errores se envían como ERROR:**
- **EC-05:** mensaje mal formado, fallo de `/dev/gpu2d`, o el hardware no terminó en 4 s.
- **EC-08:** la cola del hardware descartó paquetes.
- **EC-06 y EC-07** (comando inválido en hardware) **no** se envían como ERROR. El hardware los ignora (RF-20) y se cuentan en el campo `errores` del REPORTE, que es por ventana. Así un error de hardware no aborta la espera del reporte en el cliente.

### Probar el servicio en la PC (Ubuntu), sin la placa

```bash
cd Linux/ejemplos/servicio && make sim
./gpu2d-servicio-sim 5000 x -v          # otra terminal:
cd ../../../Interfaz && python3 gfxcli.py send escenas/ejemplo.gfx   # con host 127.0.0.1
```

---

## 8. Pendientes conocidos

- **Los tiempos no cierran:** `clk_sys` (100 MHz) tiene slack −7,1 ns y TNS −9105 ns. Si los dibujos salen corruptos, revisa *Report Top Failing Paths*. Para descartarlo, prueba con 50 MHz en el PLL. La solución que prevé el `.sdc` es un `sdram_controller.sv` propio.
- **RF-23:** verifica en la placa que el framebuffer arranca en negro.
- **Interrupción FPGA→HPS:** no está conectada, así que el driver consulta `STATUS` periódicamente.
- **Validación:** falta ejecutar en la placa la tabla de pruebas RF-01..RF-23 y la comparación CPU vs FPGA (CU-04).

---

## 9. Problemas comunes

| Síntoma | Causa / acción |
|---|---|
| `Permission denied` al ejecutar un script | Ejecútalo con `bash scripts/...`. Los scripts arreglan solos los permisos de `post-image.sh` |
| `/bin/bash^M: bad interpreter` | Finales de línea CRLF de Windows. Ejecuta con `bash scripts/...` (se corrigen solos). `.gitattributes` evita que vuelva a pasar |
| `no existe .../output/.config` | Falta `bash scripts/01-preparar-buildroot.sh` |
| `la ruta contiene espacios` | Clona el repositorio en una ruta sin espacios (`~/Acelerador-Grafico---CE1114`) |
| Programmer marca *Failed* | Hay 3 dispositivos en la cadena: borra la fila extra y usa *Change File* sobre `5CSEMA5` |
| "auto-detected device chain does not match" | Normal; responde **Yes** |
| `dmesg`: `ID inesperado` | La FPGA no tiene este diseño o no hubo `.rbf` en la SD |
| LEDR[9:7] = `111` | Error del hardware: `devmem 0xFF200010 32`, bits [3:0] |

## 10. Comandos útiles de Buildroot (`make -C ~/de1soc/output ...`)

| Qué | Objetivo |
|---|---|
| Configurar el kernel | `linux-menuconfig` |
| Recompilar el kernel / U-Boot | `linux-rebuild all` / `uboot-rebuild all` |
| Agregar paquetes (python3, etc.) | `menuconfig`, luego `savedefconfig` |
| Empezar de cero (ccache conserva lo compilado) | `clean all` |
