`timescale 1ns / 1ps

//=============================================================================
// framebuffer_onchip.sv
// Modulo : Framebuffer en memoria interna de la FPGA, esclavo Avalon-MM
//
// Ocupa el lugar del controlador de SDRAM mientras ese no exista. Habla el
// mismo Avalon-MM de rafaga que implementara el modulo real, de modo que el
// gestor de framebuffer no distingue uno de otro: cambiar de medio es mover
// el parametro FB_ONCHIP del nivel superior y nada mas.
//
// Guarda los dos buffers en bloques M10K de la FPGA, uno tras otro en una
// memoria plana. La traduccion de direccion compara contra las dos bases en
// lugar de mirar un bit, para que siga siendo correcta si las bases del
// paquete dejan de ser potencias de dos.
//
// No pretende ser rapido sino realista, y para eso imita los dos
// comportamientos de la SDRAM que mas afectan al diseno:
//
//   RD_LATENCY    ciclos entre aceptar la peticion y entregar el primer
//                 dato, modelados con una tuberia de registros
//   STALL_PERIOD  esperas periodicas via waitrequest, como las de un
//                 refresco o una activacion de fila. Son las que obligan al
//                 arbitro a decidir y al rasterizador a detenerse; sin ellas
//                 el diseno pareceria correcto y fallaria en la placa.
//
// Protocolo de rafaga: el maestro mantiene sd_address fijo durante toda la
// transaccion, asi que el puntero que recorre las palabras lo lleva el
// esclavo. La lectura se acepta en un solo latido y a partir de ahi entrega
// burstcount palabras seguidas sin volver a mirar waitrequest.
//
// La diferencia util frente a un modelo de banco de pruebas esta al final
// del archivo: este modulo no acepta en silencio cualquier cosa, sino que
// comprueba el protocolo y avisa en el instante en que se rompe. Si el
// gestor emite un burstcount invalido, solapa lecturas o se sale de region,
// el error aparece donde se produce y no tres mil ciclos despues disfrazado
// de imagen torcida. Un acceso fuera de region no se escribe, para no
// corromper un pixel valido mientras se cuenta el suceso.
//=============================================================================
module framebuffer_onchip #(
  parameter int SCREEN_W     = 64,
  parameter int SCREEN_H     = 48,
  parameter int PIXEL_BITS   = 16,
  parameter int BURST_LEN    = 8,
  parameter int SD_ADDR_BITS = 25,
  parameter int FB_BASE_A    = 0,
  parameter int FB_BASE_B    = 'h100000,

  // Ciclos entre la aceptacion de la peticion y el primer dato valido.
  // Debe ser al menos uno: la lectura de la memoria ya consume un ciclo.
  parameter int RD_LATENCY   = 4,

  // Esperas periodicas. waitrequest sube durante STALL_BUSY ciclos de cada
  // STALL_PERIOD. Con STALL_PERIOD = 0 no hay esperas.
  parameter int STALL_PERIOD = 30,
  parameter int STALL_BUSY   = 3
)(
  input  logic clk,
  input  logic rst_n,

  // Esclavo Avalon-MM de rafaga
  input  logic                            sd_read,
  input  logic                            sd_write,
  input  logic [SD_ADDR_BITS-1:0]         sd_address,
  input  logic [$clog2(BURST_LEN+1)-1:0]  sd_burstcount,
  input  logic [PIXEL_BITS-1:0]           sd_writedata,
  output logic                            sd_waitrequest,
  output logic [PIXEL_BITS-1:0]           sd_readdata,
  output logic                            sd_readdatavalid,

  // Estado
  output logic [31:0] words_written,   // Palabras escritas en total
  output logic [31:0] words_read,      // Palabras devueltas en total
  output logic [31:0] range_errors     // Accesos fuera de las dos regiones
);

  localparam int FB_PIXELS = SCREEN_W * SCREEN_H;
  localparam int MEM_WORDS = 2 * FB_PIXELS;
  localparam int MEMW      = $clog2(MEM_WORDS);
  localparam int BCW       = $clog2(BURST_LEN + 1);

  // Ancho del contador de esperas. 
  // El guardado evita $clog2(0) cuando las esperas estan desactivadas.
  localparam int SP  = (STALL_PERIOD < 2) ? 2 : STALL_PERIOD;
  localparam int SPW = $clog2(SP);

  logic [PIXEL_BITS-1:0] mem [0:MEM_WORDS-1];

  // Inicializacion de Memoria
  initial begin
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;
  end

  // Traduccion de direccion
  // La base se decide comparando, no mirando un bit, para que el modulo siga
  // siendo correcto si las bases del paquete dejan de ser potencias de dos.
  function automatic logic en_region(input logic [SD_ADDR_BITS-1:0] a);
    en_region = ((a >= SD_ADDR_BITS'(FB_BASE_A)) &&
                 (a <  SD_ADDR_BITS'(FB_BASE_A + FB_PIXELS)))
             || ((a >= SD_ADDR_BITS'(FB_BASE_B)) &&
                 (a <  SD_ADDR_BITS'(FB_BASE_B + FB_PIXELS)));
  endfunction

  function automatic logic [MEMW-1:0] traducir(input logic [SD_ADDR_BITS-1:0] a);
    if (a >= SD_ADDR_BITS'(FB_BASE_B))
      traducir = MEMW'(FB_PIXELS) + MEMW'(a - SD_ADDR_BITS'(FB_BASE_B));
    else
      traducir = MEMW'(a - SD_ADDR_BITS'(FB_BASE_A));
  endfunction

  // Esperas
  logic [SPW-1:0] espera_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) espera_cnt <= '0;
    else        espera_cnt <= (espera_cnt == SPW'(STALL_PERIOD - 1)) ? '0
                                                        : espera_cnt + 1'b1;
  end

  assign sd_waitrequest = (STALL_PERIOD != 0)
                       && (espera_cnt < SPW'(STALL_BUSY));

  // Escritura de rafaga
  // La direccion llega con el primer latido y avanza sola mientras write siga
  // alto y waitrequest en bajo. El maestro mantiene sd_address fijo durante
  // toda la rafaga, asi que el puntero lo lleva el esclavo.
  logic            wr_latido;
  logic [MEMW-1:0] wr_ptr, wr_idx;
  logic [BCW-1:0]  wr_quedan;
  logic            wr_primero, wr_valido;

  assign wr_latido  = sd_write && !sd_waitrequest;
  assign wr_primero = (wr_quedan == '0);
  assign wr_idx     = wr_primero ? traducir(sd_address) : wr_ptr;

  // Un acceso fuera de region no se escribe: el gestor de framebuffer ya
  // garantiza la restriccion, de modo que si llega uno es un fallo y lo que
  // interesa es no corromper un pixel valido mientras se cuenta el suceso.
  assign wr_valido = wr_latido && (wr_idx < MEMW'(MEM_WORDS))
                  && (!wr_primero || en_region(sd_address));

  // Lectura de rafaga
  // La peticion se acepta en un solo latido y a partir de ahi el esclavo
  // produce burstcount palabras seguidas, una por ciclo, sin volver a mirar
  // waitrequest: es el comportamiento del modelo del banco y el que espera la
  // maquina R_DATOS del gestor.
  logic            rd_arranca, rd_sigue, rd_busca;
  logic [MEMW-1:0] rd_ptr, rd_idx;
  logic [BCW-1:0]  rd_quedan;

  assign rd_arranca = sd_read && !sd_waitrequest && (rd_quedan == '0);
  assign rd_sigue   = (rd_quedan != '0);
  assign rd_busca   = rd_arranca || rd_sigue;
  assign rd_idx     = rd_arranca ? traducir(sd_address) : rd_ptr;

  // Si el indice se sale, se lee la posicion cero. El latido se produce
  // igual: el maestro cuenta palabras y quedarse corto lo colgaria esperando
  // una que no llega. La asercion de mas abajo deja constancia.
  logic [MEMW-1:0] rd_idx_seguro;
  assign rd_idx_seguro = (rd_idx < MEMW'(MEM_WORDS)) ? rd_idx : '0;

  // Memoria
  // Plantilla de doble puerto simple: una escritura y una lectura registrada
  // en el mismo bloque. Es lo que infiere M10K. El arbitro del gestor
  // garantiza que lectura y escritura nunca coinciden, asi que no hay que
  // resolver colisiones.
  logic [PIXEL_BITS-1:0] ram_data [0:RD_LATENCY-1];
  logic                  ram_valid  [0:RD_LATENCY-1];

  always_ff @(posedge clk) begin
    if (wr_valido) mem[wr_idx] <= sd_writedata;
    ram_data[0] <= mem[rd_idx_seguro];
    for (int i = 1; i < RD_LATENCY; i++) ram_data[i] <= ram_data[i-1];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < RD_LATENCY; i++) ram_valid[i] <= 1'b0;
    end else begin
      ram_valid[0] <= rd_busca;
      for (int i = 1; i < RD_LATENCY; i++) ram_valid[i] <= ram_valid[i-1];
    end
  end

  assign sd_readdata      = ram_data[RD_LATENCY-1];
  assign sd_readdatavalid = ram_valid[RD_LATENCY-1];

  // Punteros, contadores y estado
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr        <= '0;
      wr_quedan     <= '0;
      rd_ptr        <= '0;
      rd_quedan     <= '0;
      words_written <= '0;
      words_read    <= '0;
      range_errors  <= '0;
    end else begin
      // Escritura
      if (wr_latido) begin
        wr_ptr <= wr_idx + MEMW'(1);
        if (wr_primero) wr_quedan <= sd_burstcount - BCW'(1);
        else            wr_quedan <= wr_quedan - BCW'(1);
        words_written <= words_written + 32'd1;
        if (wr_primero && !en_region(sd_address))
          range_errors <= range_errors + 32'd1;
      end

      // Lectura
      if (rd_busca) begin
        rd_ptr <= rd_idx + MEMW'(1);
        if (rd_arranca) rd_quedan <= sd_burstcount - BCW'(1);
        else            rd_quedan <= rd_quedan - BCW'(1);
        words_read <= words_read + 32'd1;
        if (rd_arranca && !en_region(sd_address))
          range_errors <= range_errors + 32'd1;
      end
    end
  end


  // Vista por buffer, para las comprobaciones del banco de pruebas
  // Equivalente a la funcion sdram_px del banco. Se invoca por nombre
  // jerarquico, por ejemplo u_fbmem.leer_pixel(~buffer_sel, y*W + x).
  function automatic logic [PIXEL_BITS-1:0] leer_pixel(input logic buf_b,
                                                       input int   idx);
    leer_pixel = mem[(buf_b ? FB_PIXELS : 0) + idx];
  endfunction

`ifndef SYNTHESIS

  // Comprobaciones de protocolo
  // El modelo del banco acepta en silencio cualquier cosa. Este modulo avisa:
  // si el gestor de framebuffer rompe el protocolo, el fallo se ve donde se
  // produce y no tres mil ciclos despues como una imagen torcida.
  initial begin
    if (RD_LATENCY < 1)
      $error("framebuffer_onchip: RD_LATENCY (%0d) debe ser al menos 1",
             RD_LATENCY);
    if ((STALL_PERIOD != 0) && (STALL_BUSY >= STALL_PERIOD))
      $error("framebuffer_onchip: STALL_BUSY (%0d) debe ser menor que STALL_PERIOD (%0d)",
             STALL_BUSY, STALL_PERIOD);
    if (SD_ADDR_BITS < $clog2(FB_BASE_B + FB_PIXELS))
      $error("framebuffer_onchip: SD_ADDR_BITS (%0d) no alcanza para FB_BASE_B",
             SD_ADDR_BITS);
  end

  always @(posedge clk) if (rst_n) begin
    if (sd_read && sd_write)
      $error("framebuffer_onchip: read y write simultaneos en t=%0t", $time);

    if (sd_read && !sd_waitrequest && (rd_quedan == '0) &&
        ((sd_burstcount == '0) || (sd_burstcount > BCW'(BURST_LEN))))
      $error("framebuffer_onchip: burstcount de lectura invalido (%0d) en t=%0t",
             sd_burstcount, $time);

    if (sd_write && !sd_waitrequest && (wr_quedan == '0) &&
        ((sd_burstcount == '0) || (sd_burstcount > BCW'(BURST_LEN))))
      $error("framebuffer_onchip: burstcount de escritura invalido (%0d) en t=%0t",
             sd_burstcount, $time);

    // Peticion de lectura nueva con una rafaga todavia en curso.
    if (sd_read && !sd_waitrequest && (rd_quedan != '0))
      $error("framebuffer_onchip: lectura solapada, quedan %0d palabras en t=%0t",
             rd_quedan, $time);

    if (wr_latido && wr_primero && !en_region(sd_address))
      $error("framebuffer_onchip: escritura fuera de region, addr=%0h en t=%0t",
             sd_address, $time);

    if (rd_busca && rd_arranca && !en_region(sd_address))
      $error("framebuffer_onchip: lectura fuera de region, addr=%0h en t=%0t",
             sd_address, $time);

    if (wr_latido && (wr_idx >= MEMW'(MEM_WORDS)))
      $error("framebuffer_onchip: la rafaga de escritura se salio de la memoria en t=%0t",
             $time);

    if (rd_busca && (rd_idx >= MEMW'(MEM_WORDS)))
      $error("framebuffer_onchip: la rafaga de lectura se salio de la memoria en t=%0t",
             $time);
  end
`endif

endmodule
