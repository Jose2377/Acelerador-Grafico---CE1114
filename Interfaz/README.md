# Interfaz de comandos graficos (nivel 1)

Interfaz en Python 3 del proyecto *Integracion de unidad de aceleracion
grafica para plataformas a la medida en FPGA (DE1-SoC)*.

Esta entrega contiene **solo la interfaz**: estructura de modulos, CLI,
constantes, tipos y configuracion. El interprete y el codificador de paquetes
estan implementados; el transporte TCP y el rasterizador de
referencia quedan como stubs marcados `PENDIENTE`.

## Estructura

```
Interfaz/
  gfxcli.py            punto de entrada por linea de ordenes
  gfxgui.py            ventana (tkinter): editor de escena + salida
  config.json          host del HPS, puerto, tamano de lote, rutas
  gfx/
    constantes.py      opcodes, rangos, codigos EC, protocolo   [listo]
    comando.py         Comando, EstadoColor                     [listo]
    errores.py         ErrorComando                             [listo]
    config.py          carga del archivo de configuracion       [listo]
    interprete.py      InterpreteComandos                       [listo]
    codificador.py     CodificadorPaquete (24 bytes, W0..W5)    [listo]
    transporte.py      ClienteTransporte (socket TCP, IF-03)    [PENDIENTE]
    reporte.py         ReporteRendimiento (CSV acumulativo)     [parcial]
    raster_cpu.py      RasterizadorCPU (referencia)             [PENDIENTE]
  escenas/ejemplo.gfx  escena de ejemplo
  escenas/con_errores.gfx  escena con errores para probar la validacion
  tests/               pruebas del interprete y del codificador
  reportes/            salida CSV y log de errores de sesion
```

## Uso

### Ventana

```
python3 gfxgui.py                           abre la ventana vacia
python3 gfxgui.py escenas/ejemplo.gfx       abre la ventana con un script
```

La ventana tiene el editor del script arriba (con numeros de linea) y el
panel de salida abajo. Los botones Validar (F5), Enviar (F6), CPU e INF
usan el mismo nucleo que el CLI; las lineas rechazadas se resaltan en el
editor y el error se detalla en la salida. El host y el puerto del HPS se
pueden cambiar en la barra superior sin editar `config.json`.

Requiere tkinter, incluido en la instalacion estandar de Python 3 en
Windows. En Linux puede necesitar el paquete `python3-tk`.

### Linea de ordenes

```
python3 gfxcli.py comandos                  tabla de comandos y rangos
python3 gfxcli.py check escenas/ejemplo.gfx valida sin transmitir
python3 gfxcli.py send  escenas/ejemplo.gfx valida y transmite
python3 gfxcli.py paquetes escenas/ejemplo.gfx  muestra W0..W5 en hex
python3 gfxcli.py cpu   escenas/ejemplo.gfx ejecuta en CPU (referencia)
python3 gfxcli.py inf                       solicita el reporte
```

Codigos de salida: 0 correcto, 1 comandos rechazados, 2 fallo de
ejecucion o funcion pendiente.

## Lenguaje de comandos

Una instruccion por linea, operacion primero y argumentos separados por
espacios. El color se fija con `color` y permanece vigente hasta el
siguiente cambio. `#` inicia un comentario.

| Comando | Args | OpCode |
|---|---|---|
| `color r g b` | 3 | - |
| `pixel x y` | 2 | 0x01 |
| `line x0 y0 x1 y1` | 4 | 0x02 |
| `tria x0 y0 x1 y1 x2 y2` | 6 | 0x03 |
| `tria_fill x0 y0 x1 y1 x2 y2` | 6 | 0x04 |
| `rect x0 y0 x1 y1` | 4 | 0x05 |
| `rect_fill x0 y0 x1 y1` | 4 | 0x06 |
| `circ x y r` | 3 | 0x07 |
| `circ_fill x y r` | 3 | 0x08 |
| `clear` | 0 | 0x09 |
| `swap` | 0 | 0x0A |
| `inf` | 0 | 0x0B |

Rangos: coordenadas -32768..32767, color 0..255 por componente, radio
1..1023. Una figura parcialmente fuera de pantalla es legitima; el
recorte lo hace el hardware.

## Errores detectados por la interfaz

| Codigo | Condicion |
|---|---|
| EC-01 | Operacion inexistente |
| EC-02 | Numero de argumentos incorrecto |
| EC-03 | Argumento no entero o fuera del rango de 16 bits |
| EC-04 | Argumento fuera del rango admitido |

EC-05 lo detecta el servicio del HPS; EC-06 a EC-08 el hardware.

Formato de los mensajes:

```
Error EC-02: 'rect 40 40 280'
  La operacion rect espera 4 argumentos enteros, se recibieron 3

Se rechazaron 2 de 18 comandos. No se transmitio ningun paquete.
```

## Pruebas

```
python -m unittest discover tests
```

## Formato del paquete (Figura 4)

```
        31      24 23      16 15       8 7        0
  W0  | OPCODE    | FLAGS     | SEQ_ID              |
  W1  | X0 (int16 con signo)  | Y0 (int16 con signo)|
  W2  | X1                    | Y1                  |
  W3  | X2                    | Y2                  |
  W4  | RESERVADO | R         | G        | B        |
  W5  | RESERVADO             | PARAM (radio)       |
```

Cada palabra se envia en little-endian, de W0 a W5. Los campos que la
operacion no usa y los reservados van en cero. SEQ_ID empieza en 0,
aumenta en uno por paquete y vuelve a 0 despues de 0xFFFF.

## Siguiente paso

Implementar `ClienteTransporte` en `gfx/transporte.py` (socket TCP,
encabezado de 8 bytes, lotes de hasta 256 paquetes).
