`timescale 1ns / 1ps

//=============================================================================
// vga_controller.sv
// Modulo : Controlador de video, prebusqueda de lineas y salida VGA
//
// Vive entero en el dominio de pixel y tiene un plazo que no admite demora:
// cada ciclo de clk_pix el conversor de la placa espera un color, 
// y si no llega la imagen se rompe. 
// La memoria, en cambio, responde en rafagas y con esperas. 
// Conciliar las dos cosas es todo el trabajo de este modulo.
//
// La solucion es prebuscar. 
// Un motor de peticiones va pidiendo lineas completas por delante de donde esta el barrido y las deja en line_buffer,
// que guarda LINES de ellas; el barrido lee siempre de una ranura ya llena, nunca de la memoria. 
// Con LINES = 4 el barrido lleva hasta tres lineas de margen, suficiente para absorber las esperas de la SDRAM.
//
// El motor pide una linea entera y espera a tenerla completa antes de empezar la siguiente (estados F_LIBRE, F_PIDE, F_ESPERA). 
// Las ranuras se indexan por los bits bajos del numero de linea, 
// de modo que el buffer es circular sin ninguna comparacion; 
// por eso LINES debe ser potencia de dos.
// El vector lista marca que ranuras tienen una linea completa: 
// se levanta al recibir la ultima columna y se baja cuando el barrido termina de mostrarla.
//
// El cuadro nuevo arranca en el intervalo vertical. 
// Un llenado a medias no se corta: se anota en reiniciar y se aplica al volver a F_LIBRE, 
// mucho antes de que el intervalo termine.
//
// Salida de video. 
// La lectura del buffer de lineas esta registrada, asi que el pixel llega un ciclo despues de presentar su direccion; 
// las senales de sincronizacion se retrasan ese mismo ciclo para que la imagen no salga corrida un pixel. 
// El color se expande de RGB565 a RGB888 con la funcion del paquete, 
// y fuera de la region visible las tres componentes van a negro, como exige el blanking.
//
// underrun es la bandera de que la prebusqueda se quedo corta: 
// el barrido alcanzo una ranura todavia vacia. 
// Se muestra negro y la bandera queda pegada, 
// de modo que un fallo intermitente no pase desapercibido. 
// No se vigila hasta que el barrido se estabiliza, 
// porque en el arranque en frio ninguna ranura esta llena todavia y seria un falso positivo.
//
// Entradas
//   clk_pix, rst_n          Reloj de pixel y reinicio
//   front_buffer            Buffer delantero ya sincronizado a este dominio
//   frame_buffer_ready      El gestor de framebuffer acepta la peticion
//   frame_buffer_data_in    Pixel devuelto por el gestor
//   frame_buffer_valid_in   Ese pixel es valido en este ciclo
//
// Salidas
//   frame_buffer_req        Pide un pixel a la prebusqueda
//   frame_buffer_addr       Indice del pixel que pide
//   frame_buffer_front      Buffer del que debe leerse
//   vga_r, vga_g, vga_b     Color del pixel en curso, hacia el conversor de video
//   vga_hs, vga_vs          Sincronizacion horizontal y vertical
//   vga_blank_n             Bajo fuera de la region visible
//   vga_sync_n              Sincronizacion compuesta, fija en el conversor
//   vsync_act               VSYNC activo en alto, para cruzar al dominio de rasterizado
//   underrun                El barrido alcanzo una linea que aun no estaba llena
//   frame_count             Cuadros emitidos desde el reinicio
//=============================================================================
module vga_controller #(
  parameter int H_VISIBLE  = 64,
  parameter int H_FRONT    = 2,
  parameter int H_SYNC     = 10,
  parameter int H_BACK     = 4,
  parameter int V_VISIBLE  = 48,
  parameter int V_FRONT    = 1,
  parameter int V_SYNC     = 2,
  parameter int V_BACK     = 2,
  parameter bit H_POL      = 1'b0,
  parameter bit V_POL      = 1'b0,
  parameter int PIXEL_BITS = 16,
  parameter int LINES      = 4        // Potencia de 2
)(
  input  logic clk_pix,
  input  logic rst_n,

  // Seleccion de buffer, ya sincronizada a este dominio
  input  logic front_buffer,          // 0 = buffer A delante, 1 = buffer B

  // Puerto de lectura del framebuffer
  output logic                                     frame_buffer_req,
  output logic [$clog2(H_VISIBLE*V_VISIBLE)-1:0]   frame_buffer_addr,     // Indice de pixel
  output logic                                     frame_buffer_front,    // Buffer a leer
  input  logic                                     frame_buffer_ready,    // Acepta la peticion
  input  logic [PIXEL_BITS-1:0]                    frame_buffer_data_in,
  input  logic                                     frame_buffer_valid_in,

  // Salida hacia el conversor de video
  output logic [7:0] vga_r, vga_g, vga_b,
  output logic       vga_hs,
  output logic       vga_vs,
  output logic       vga_blank_n,
  output logic       vga_sync_n,

  // Estado
  output logic        vsync_act,      // Sincronizacion vertical activo en alto, para el cruce
  output logic        underrun,       // El barrido alcanzo una linea vacia
  output logic [31:0] frame_count
);

  localparam int XW  = $clog2(H_VISIBLE);
  localparam int YW  = $clog2(V_VISIBLE);
  localparam int AW  = $clog2(H_VISIBLE*V_VISIBLE);
  localparam int SW  = $clog2(LINES);
  localparam int VCW = YW + 1;

  // Temporizacion
  logic          hsync_t, vsync_t, data_active_t;
  logic [XW-1:0] pix_x;
  logic [YW-1:0] pix_y;
  logic          linea_fin, cuadro_inicio;

  vga_timing #(
    .H_VISIBLE(H_VISIBLE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
    .V_VISIBLE(V_VISIBLE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
    .H_POL(H_POL), .V_POL(V_POL)
  ) u_timing (
    .clk_pix(clk_pix), .rst_n(rst_n),
    .hsync(hsync_t), .vsync(vsync_t), .data_active(data_active_t),
    .pix_x(pix_x), .pix_y(pix_y),
    .linea_fin(linea_fin), .cuadro_inicio(cuadro_inicio),
    .vsync_act(vsync_act));

  // Pide una linea entera y espera a tenerla completa antes de empezar la siguiente. 
  // El barrido sigue teniendo hasta LINES-1 lineas listas por delante.
  typedef enum logic [1:0] {F_LIBRE, F_PIDE, F_ESPERA} fst_e;
  fst_e fst;

  logic [VCW-1:0]   lin_pide;          // Siguiente linea a pedir
  logic [XW:0]      pedidos, recibidos;
  logic [LINES-1:0] lista;             // Ranuras con una linea completa
  logic             reiniciar;

  logic [SW-1:0] ranura_pide, ranura_lee;

  assign ranura_pide = lin_pide[SW-1:0];     // LINES potencia de 2
  assign ranura_lee  = pix_y[SW-1:0];

  // Una ranura se puede llenar si no guarda ya una linea sin mostrar.
  logic hay_hueco;
  assign hay_hueco = !lista[ranura_pide] && (lin_pide < VCW'(V_VISIBLE));

  assign frame_buffer_req   = (fst == F_PIDE);
  assign frame_buffer_addr  = AW'(lin_pide * H_VISIBLE + pedidos);
  assign frame_buffer_front = front_buffer;

  // Los datos llegan en orden, de modo que el contador de recibidos es la columna donde toca escribirlos.
  logic          lb_wr;
  logic [XW-1:0] lb_wr_x;

  assign lb_wr   = frame_buffer_valid_in && (fst != F_LIBRE);
  assign lb_wr_x = recibidos[XW-1:0];

  always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin
      fst       <= F_LIBRE;
      lin_pide  <= '0;
      pedidos   <= '0;
      recibidos <= '0;
      lista     <= '0;
      reiniciar <= 1'b0;
    end else begin
      // El cuadro nuevo empieza en el intervalo vertical. 
		// No se corta un llenado a medias: se anota y se aplica al volver a F_LIBRE, 
		// mucho antes de que termine el intervalo.
      if (cuadro_inicio) reiniciar <= 1'b1;

      // El barrido termino de mostrar una linea: su ranura queda libre.
      if (linea_fin) lista[ranura_lee] <= 1'b0;

      case (fst)
        F_LIBRE: begin
          if (reiniciar) begin
            reiniciar <= 1'b0;
            lin_pide  <= '0;
            lista     <= '0;
          end else if (hay_hueco) begin
            pedidos   <= '0;
            recibidos <= '0;
            fst       <= F_PIDE;
          end
        end

        F_PIDE: begin
          if (frame_buffer_ready) begin
            if (pedidos == (XW+1)'(H_VISIBLE - 1)) fst <= F_ESPERA;
            pedidos <= pedidos + 1'b1;
          end
        end

        F_ESPERA: begin
          // Espera a recibir la ultima columna de la linea.
        end

        default: fst <= F_LIBRE;
      endcase

      // La recepcion avanza en paralelo al envio de peticiones.
      if (lb_wr) begin
        if (recibidos == (XW+1)'(H_VISIBLE - 1)) begin
          lista[ranura_pide] <= 1'b1;
          lin_pide  <= lin_pide + 1'b1;
          recibidos <= '0;
          fst       <= F_LIBRE;
        end else begin
          recibidos <= recibidos + 1'b1;
        end
      end
    end
  end

  // Buffer de lineas
  logic [PIXEL_BITS-1:0] lb_data_out;

  line_buffer #(.LINES(LINES), .WIDTH(H_VISIBLE), .DATA_W(PIXEL_BITS)) u_lb (
    .clk(clk_pix),
    .wr_ena(lb_wr), .wr_line(ranura_pide), .wr_x(lb_wr_x), .data_in(frame_buffer_data_in),
    .rd_line(ranura_lee), .rd_x(pix_x), .data_out(lb_data_out));

  // Salida de video
  // La lectura del buffer de lineas esta registrada, asi que el pixel llega un ciclo despues de presentar su direccion. 
  // Las sincronizaciones se retrasan lo mismo, para evitar que la imagen salga corrida un pixel.
  logic hsync_q, vsync_q, data_active_q, dato_listo_q;

  always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin
      hsync_q      <= ~H_POL;
      vsync_q      <= ~V_POL;
      data_active_q<= 1'b0;
      dato_listo_q <= 1'b0;
    end else begin
      hsync_q      <= hsync_t;
      vsync_q      <= vsync_t;
      data_active_q<= data_active_t;
      dato_listo_q <= lista[ranura_lee];
    end
  end

  // Si el barrido alcanza una linea que no esta llena se muestra negro y se levanta la bandera,
  // y queda constancia de que el margen de prebusqueda se quedo corto.
  logic [PIXEL_BITS-1:0] pixel;
  logic [23:0]           rgb888;

  assign pixel  = dato_listo_q ? lb_data_out : '0;
  assign rgb888 = Acelerador_pkg::rgb565_to_rgb888(pixel);

  assign vga_r = data_active_q ? rgb888[23:16] : 8'h00;
  assign vga_g = data_active_q ? rgb888[15:8]  : 8'h00;
  assign vga_b = data_active_q ? rgb888[7:0]   : 8'h00;

  assign vga_hs      = hsync_q;
  assign vga_vs      = vsync_q;
  assign vga_blank_n = data_active_q;
  // Sin sincronizacion sobre verde: el conversor la toma de VGA_HS y VGA_VS.
  assign vga_sync_n  = 1'b0;

  // Estado
  // Nota: Presenta arranque en frio
  logic barrido_estable;

  always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin
      underrun        <= 1'b0;
      frame_count     <= '0;
      barrido_estable <= 1'b0;
    end else begin
      if (cuadro_inicio) begin
        frame_count     <= frame_count + 32'd1;
        barrido_estable <= 1'b1;
      end
      if (barrido_estable && data_active_t && !lista[ranura_lee]) underrun <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if ((LINES < 2) || ((LINES & (LINES - 1)) != 0))
      $error("vga_controller: LINES (%0d) debe ser potencia de dos", LINES);
  end
`endif

endmodule
