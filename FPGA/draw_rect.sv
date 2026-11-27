`timescale 1ns / 1ps

//=============================================================================
// draw_rect.sv
// Modulo : Rectangulo, contorno o relleno  (OP_RECT, OP_RECT_FILL, OP_CLEAR)
//
// Dibuja el rectangulo definido por las dos esquinas opuestas (x0, y0) y (x1, y1). 
// La entrada fill elige entre las dos formas:
//
//   fill = 1  Recorrido completo en R_FILL, fila por fila de izquierda a derecha, un pixel por ciclo. 
//             Es tambien el camino de CLEAR:
//             processor_raster reescribe el borrado como un rectangulo relleno del tamano de la pantalla, 
//             de modo que no hace falta un modulo aparte.
//   fill = 0  Cuatro recorridos consecutivos, uno por arista, 
//             en los estados R_TOP, R_BOT, R_LEFT y R_RIGHT.
//
// Las esquinas se ordenan al cargar, asi que da igual en que orden las pase el usuario. 
// Las aristas verticales recorren solo el interior (de ya+1 a yb-1),
// porque las cuatro esquinas ya las pintaron las horizontales; 
// sin eso cada esquina se escribiria dos veces y el contador de pixeles mentiria.
//
// Los casos degenerados se resuelven al cargar: 
// un rectangulo de una sola fila (yb == ya) no tiene arista inferior,
// y uno de una sola columna (xb == xa) no tiene arista derecha.
//
// Recorte (24/11/2026). En R_CLIP la figura se recorta contra la pantalla y
// solo se recorre la parte visible: el relleno barre las filas y columnas
// visibles, y el contorno se salta las aristas que caen fuera y recorre solo
// el tramo visible de las demas. Asi un rectangulo enorme (hasta 65536 x 65536
// con coordenadas de 16 bits) cuesta lo mismo que su parte visible, en vez de
// segundos. Los pixeles escritos son exactamente los mismos; lo unico que
// cambia es que clip_scissor ya no ve (ni cuenta) pixeles fuera de pantalla.
//
// Relleno por tramos. 
// En R_FILL (RECT_FILL y CLEAR) cada ciclo presenta un tramo horizontal de hasta SPAN pixeles del mismo color, 
// cortado en la frontera de rafaga: va de cx hasta el final del grupo alineado de SPAN pixeles que contiene a cx, 
// o hasta xb si llega antes. Como SCREEN_W es multiplo de SPAN, 
// la alineacion en x coincide con la alineacion de la direccion lineal,
// y cada tramo completo es una rafaga entera para el combinador de escritura
// (perspectiva de algoritmos: ocho pixeles por ciclo).
// El contorno sigue saliendo de a un pixel (px_len = 1).
//
// Entradas
//   SCREEN_W, SCREEN_H   Tamano de la pantalla, para el recorte
//   clk, rst_n           Reloj del sistema y reinicio
//   start                Señal que carga los argumentos y arranca la figura
//   stall                Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina
//   fill                 1 = Rectangulo relleno, 0 = Solo el contorno
//   x0, y0               Una esquina del rectangulo
//   x1, y1               La esquina opuesta a la primera esquina
//   color_in             Color en RGB565
//
// Salidas
//   busy                 Señal en alto mientras el rectangulo no ha terminado de dibujarse
//   done                 Señal de un ciclo al terminar
//   px_valid             Solicitud de pixel valida
//   px_x, px_y,          Coordenada del pixel presentado (el primero del tramo)
//   px_len               Pixeles del tramo, de 1 a SPAN, todos en la misma fila
//   px_color             Color de pixel
//=============================================================================
module draw_rect #(
  parameter int SCREEN_W   = 64,
  parameter int SCREEN_H   = 48,
  parameter int PIXEL_BITS = 16,
  parameter int SPAN       = Acelerador_pkg::BURST_LEN,   // Pixeles por tramo de relleno
  parameter int LW         = $clog2(SPAN + 1)
)(
  input  logic                    clk,            // Reloj del sistema
  input  logic                    rst_n,          // Reset del sistema
  input  logic                    start,          // Señal que carga los argumentos y arranca la figura
  input  logic                    stall,          // Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina
  input  logic                    fill,           // 1 = rectangulo relleno, 0 = solo el contorno
  input  logic signed [15:0]      x0, y0, x1, y1, // Coordenadas de esquinas del rectangulo
  input  logic [PIXEL_BITS-1:0]   color_in,       // Color en RGB565
  output logic                    busy,           // Señal en alto mientras el rectangulo no ha terminado de dibujarse
  output logic                    done,           // Señal de un ciclo al terminar
  output logic                    px_valid,       // Solicitud de pixel valida
  output logic signed [15:0]      px_x, px_y,     // Coordenada del pixel presentado
  output logic [LW-1:0]           px_len,         // Pixeles del tramo presentado
  output logic [PIXEL_BITS-1:0]   px_color        // Color de pixel
);

  // Estados
  //   R_CLIP  Calcula la parte visible y decide que aristas existen
  //   R_SEL   Elige la siguiente arista visible del contorno, o termina
  typedef enum logic [3:0] {
    R_IDLE, R_CLIP, R_SEL, R_FILL, R_TOP, R_BOT, R_LEFT, R_RIGHT, R_DONE
  } rst_e;
  rst_e st;

  localparam logic signed [15:0] XMAX = 16'(SCREEN_W - 1);
  localparam logic signed [15:0] YMAX = 16'(SCREEN_H - 1);

  // (xa,ya)-(xb,yb)   Esquinas ordenadas, tal como las pidio el comando
  // (vxa,vya)-(vxb,vyb) Las mismas recortadas a la pantalla
  // lya, lyb          Tramo visible de las aristas verticales (sin las esquinas)
  // pend              Aristas del contorno que faltan: TOP, BOT, LEFT, RIGHT
  logic signed [15:0] xa, xb, ya, yb, cx, cy;
  logic signed [15:0] vxa, vxb, vya, vyb, lya, lyb;
  logic [3:0]         pend;
  logic               fill_q;
  logic [PIXEL_BITS-1:0] col;

  // Valores recortados, calculados sobre las esquinas ya registradas
  logic signed [15:0] c_vxa, c_vxb, c_vya, c_vyb, c_lya, c_lyb;
  logic               x_vis, y_vis, xa_vis, xb_vis, ya_vis, yb_vis, lados;
  assign c_vxa  = (xa > 0)    ? xa : 16'sd0;
  assign c_vxb  = (xb < XMAX) ? xb : XMAX;
  assign c_vya  = (ya > 0)    ? ya : 16'sd0;
  assign c_vyb  = (yb < YMAX) ? yb : YMAX;
  // ya + 1 y yb - 1 en 17 bits: en los extremos de 16 bits darian la vuelta
  logic signed [16:0] ya1, yb1;
  assign ya1    = 17'(ya) + 17'sd1;
  assign yb1    = 17'(yb) - 17'sd1;
  assign c_lya  = (ya1 > 0)        ? ya1[15:0] : 16'sd0;
  assign c_lyb  = (yb1 < 17'(YMAX)) ? yb1[15:0] : YMAX;
  assign x_vis  = (c_vxa <= c_vxb);
  assign y_vis  = (c_vya <= c_vyb);
  assign xa_vis = (xa >= 0) && (xa <= XMAX);
  assign xb_vis = (xb >= 0) && (xb <= XMAX);
  assign ya_vis = (ya >= 0) && (ya <= YMAX);
  assign yb_vis = (yb >= 0) && (yb <= YMAX);
  // Las aristas verticales existen si hay al menos una fila entre las dos
  // horizontales y alguna de esas filas cae en pantalla.
  assign lados  = (17'(yb) > ya1) && (c_lya <= c_lyb);

  logic signed [15:0] fin_grupo, fin_tramo;
  assign fin_grupo = cx | 16'(SPAN - 1);
  assign fin_tramo = (fin_grupo < vxb) ? fin_grupo : vxb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin // Reset
      st <= R_IDLE;
      xa <= '0; xb <= '0; ya <= '0; yb <= '0; cx <= '0; cy <= '0; col <= '0;
      vxa <= '0; vxb <= '0; vya <= '0; vyb <= '0; lya <= '0; lyb <= '0;
      pend <= '0; fill_q <= 1'b0;
    end else if (!stall) begin // Si no esta en Stall
      case (st)
        R_IDLE: if (start) begin
          xa <= (x0 < x1) ? x0 : x1;   xb <= (x0 > x1) ? x0 : x1;
          ya <= (y0 < y1) ? y0 : y1;   yb <= (y0 > y1) ? y0 : y1;
          col    <= color_in;
          fill_q <= fill;
          st     <= R_CLIP;
        end
        // Recorte. Lo que cae fuera de la pantalla ni se recorre: un rectangulo
        // enorme cuesta lo mismo que su parte visible.
        R_CLIP: begin
          vxa <= c_vxa;  vxb <= c_vxb;  vya <= c_vya;  vyb <= c_vyb;
          lya <= c_lya;  lyb <= c_lyb;
          if (fill_q) begin
            cx <= c_vxa;  cy <= c_vya;
            st <= (x_vis && y_vis) ? R_FILL : R_DONE;
          end else begin
            // Mismas aristas que antes del recorte (las verticales sin las
            // esquinas, la inferior solo si hay mas de una fila, la derecha
            // solo si hay mas de una columna), ahora solo si se ven.
            pend[0] <= x_vis && ya_vis;                        // TOP
            pend[1] <= x_vis && yb_vis && (yb != ya);          // BOT
            pend[2] <= lados && xa_vis;                        // LEFT
            pend[3] <= lados && xb_vis && (xb != xa);          // RIGHT
            st      <= R_SEL;
          end
        end
        R_SEL: begin
          if (pend[0]) begin
            pend[0] <= 1'b0;  cx <= vxa;  cy <= ya;   st <= R_TOP;
          end else if (pend[1]) begin
            pend[1] <= 1'b0;  cx <= vxa;  cy <= yb;   st <= R_BOT;
          end else if (pend[2]) begin
            pend[2] <= 1'b0;  cx <= xa;   cy <= lya;  st <= R_LEFT;
          end else if (pend[3]) begin
            pend[3] <= 1'b0;  cx <= xb;   cy <= lya;  st <= R_RIGHT;
          end else begin
            st <= R_DONE;
          end
        end
        R_FILL: begin // Relleno de la parte visible, un tramo por ciclo
          if (fin_tramo == vxb) begin
            cx <= vxa;
            if (cy == vyb) st <= R_DONE;
            else           cy <= cy + 1;
          end else cx <= fin_tramo + 1;
        end
        R_TOP, R_BOT: begin // Aristas horizontales, solo su parte visible
          if (cx == vxb) st <= R_SEL;
          else           cx <= cx + 1;
        end
        R_LEFT, R_RIGHT: begin // Aristas verticales, sin esquinas y solo lo visible
          if (cy == lyb) st <= R_SEL;
          else           cy <= cy + 1;
        end
        R_DONE:  st <= R_IDLE;
        default: st <= R_IDLE;
      endcase
    end
  end

  assign busy     = (st != R_IDLE);
  assign done     = (st == R_DONE);
  assign px_valid = (st == R_FILL) || (st == R_TOP) || (st == R_BOT)
                 || (st == R_LEFT) || (st == R_RIGHT);
  assign px_x     = cx;
  assign px_y     = cy;
  assign px_color = col;
  assign px_len   = (st == R_FILL) ? LW'(fin_tramo - cx + 1) : LW'(1);

`ifndef SYNTHESIS
  initial begin
    if ((SPAN < 1) || ((SPAN & (SPAN - 1)) != 0))
      $error("draw_rect: SPAN (%0d) debe ser potencia de dos", SPAN);
  end
`endif

endmodule
