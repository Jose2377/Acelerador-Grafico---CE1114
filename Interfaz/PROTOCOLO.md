# Protocolo de aplicacion sobre TCP (IF-03)

Comunicacion entre la interfaz (`ClienteTransporte`, nivel 1) y el
servicio del HPS (`ServidorComandos`, nivel 2). El documento de diseno fija
un encabezado de 8 bytes con tipo, banderas, longitud y secuencia, y cuatro
tipos de mensaje; este archivo propone el tamano de cada campo y el formato
de cada carga.

Fuente de verdad en codigo: seccion "Protocolo de aplicacion sobre TCP" de
`gfx/constantes.py`. Implementacion de referencia del lado servidor:
`servidor_simulado.py`.

## Encabezado (8 bytes, orden de red / big-endian)

| Bytes | Campo     | Tipo   | Contenido |
|-------|-----------|--------|-----------|
| 0     | tipo      | uint8  | 1 LOTE, 2 SOLICITUD, 3 REPORTE, 4 ERROR |
| 1     | banderas  | uint8  | bit 0 `INICIO_VENTANA` (solo en LOTE); resto en 0 |
| 2-3   | longitud  | uint16 | bytes de carga que siguen al encabezado |
| 4-7   | secuencia | uint32 | numero de mensaje del cliente, empieza en 0 por conexion |

En C:

```c
struct encabezado {        /* leer con ntohs / ntohl */
    uint8_t  tipo;
    uint8_t  banderas;
    uint16_t longitud;
    uint32_t secuencia;
} __attribute__((packed));
```

**Por que orden de red en el encabezado y little-endian en los paquetes:**
el encabezado lo interpreta el servicio (convencion de sockets,
`ntohs`/`ntohl`). La carga de un LOTE, en cambio, el servicio no la toca:
la escribe tal cual en el dispositivo de caracter, y su formato es el que
espera el esclavo Avalon-MM (palabras W0..W5 en little-endian).

## Mensajes

| Tipo | Sentido | Carga | Respuesta |
|---|---|---|---|
| 1 LOTE | cliente -> HPS | N paquetes de 24 bytes, 1 <= N <= 256 (24 a 6144 bytes) | ninguna; solo ERROR si falla |
| 2 SOLICITUD | cliente -> HPS | vacia (longitud 0) | REPORTE con la misma secuencia |
| 3 REPORTE | HPS -> cliente | 16 bytes, ver abajo | - |
| 4 ERROR | HPS -> cliente | 2 bytes + texto, ver abajo | - |

### LOTE

La carga son los paquetes de comando concatenados, en el formato de la
Figura 4. El servicio valida que `longitud` sea multiplo no nulo de 24 y
no mayor que 6144; si no, responde ERROR EC-05 y cierra la conexion.

Si `INICIO_VENTANA` esta activa, el servicio abre una nueva ventana de
medicion (reinicia contadores, `CONTROL.perf_window`) antes de escribir el
lote. El cliente la activa solo en el primer lote de cada escena, asi una
escena de mas de 256 comandos sigue siendo una sola ventana.

No hay confirmacion de lotes: el camino de ida no es bloqueante.

### SOLICITUD / REPORTE

El cliente envia SOLICITUD despues de una escena que contiene `inf`. El
servicio espera a que el hardware publique los resultados (MOE-05), lee
los registros de rendimiento y responde REPORTE con la **misma secuencia**
que la solicitud.

Carga de REPORTE (16 bytes, orden de red):

| Bytes | Campo       | Tipo   | Registro |
|-------|-------------|--------|----------|
| 0-3   | ciclos      | uint32 | PERF_CYCLES (0x14) |
| 4-7   | comandos    | uint32 | PERF_COMMANDS (0x18) |
| 8-11  | pixeles     | uint32 | PERF_PIXELS (0x1C) |
| 12-13 | errores     | uint16 | ERR_INFO.err_count (0x10) |
| 14-15 | descartados | uint16 | PERF_DROPPED (0x20) |

### ERROR

| Bytes | Campo     | Tipo  | Contenido |
|-------|-----------|-------|-----------|
| 0     | codigo    | uint8 | 5 = EC-05, 6 = EC-06, 7 = EC-07, 8 = EC-08 |
| 1     | reservado | uint8 | 0 |
| 2..   | detalle   | UTF-8 | texto opcional para la persona usuaria |

La secuencia es la del mensaje que provoco el error (o 0 si no aplica).

## Tiempos

- El cliente usa `timeout_s` de `config.json` (5 s por defecto) para
  conectar, enviar y esperar el REPORTE. Vencido el plazo: EC-05.
- Tiempo de extremo a extremo: lo mide el cliente desde que encola el
  primer lote de la escena hasta que recibe el REPORTE.

## Ejemplo

Escena `pixel 10 20` + `inf`, primer mensaje de la conexion:

```
01 01 00 30 00 00 00 00      LOTE, INICIO_VENTANA, 48 bytes, secuencia 0
00 00 00 01 ...              paquete pixel (24 bytes, SEQ_ID 0, W0..W5 little-endian)
01 00 00 0B ...              paquete inf   (24 bytes, SEQ_ID 1)
02 00 00 00 00 00 00 01      SOLICITUD, secuencia 1
                       <-    03 00 00 10 00 00 00 01 + 16 bytes de contadores
```
