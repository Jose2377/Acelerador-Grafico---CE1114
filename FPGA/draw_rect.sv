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
// Los casos degenerados se resuelven en las propias transiciones: 
// un rectangulo de una sola fila (yb == ya) o de una sola columna (xb == xa)
// salta directo a R_DONE en lugar de recorrer aristas que no existen.
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
  parameter int PIXEL_BITS = 16,
  parameter int SPAN       = Acelerador_pkg::BURST_LEN,   // Pixeles por tramo de relleno
  parameter int LW         = $clog2(SPAN + 1)
)(
  input  logic                    clk,            // Reloj del sistema
  input  logic                    rst_n,          // Reset del sistema
  input  logic                    start,          // Señal que carga los argumentos y arranca la figura
  input  logic                    stall,          // Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina
  input  logic                    fill,           // 1 = rectangulo relleno, 0 = solo el contorno
  input  logic signed [15:0]      x0, y0, x1, y1, // Coordenadas de esquinas del triangulo
  input  logic [PIXEL_BITS-1:0]   color_in,       // Color en RGB565
  output logic                    busy,           // Señal en alto mientras el rectangulo no ha terminado de dibujarse
  output logic                    done,           // Señal de un ciclo al terminar
  output logic                    px_valid,       // Solicitud de pixel valida
  output logic signed [15:0]      px_x, px_y,     // Coordenada del pixel presentado
  output logic [LW-1:0]           px_len,         // Pixeles del tramo presentado
  output logic [PIXEL_BITS-1:0]   px_color        // Color de pixel
);

  // Estados de dibujo
  // Espera, Relleno, Linea Superior, Linea Inferior, Linea Izquierda, Linea Derecha, Finalizado.
  typedef enum logic [2:0] {
    R_IDLE, R_FILL, R_TOP, R_BOT, R_LEFT, R_RIGHT, R_DONE
  } rst_e;
  rst_e st;
	
  // Coordenadas del rectangulo
  // (xa,ya) coordenadas de la esquina superior izquierda
  // (xb,yb) coordenadas de la esquina inferior derecha
  // (cx,cy) coordenadas actuales de dibujado
  logic signed [15:0] xa, xb, ya, yb, cx, cy;
  logic [PIXEL_BITS-1:0] col;

  // Tramo de relleno: de cx al final de su grupo alineado, sin pasar de xb
  logic signed [15:0] fin_grupo, fin_tramo;
  assign fin_grupo = cx | 16'(SPAN - 1);
  assign fin_tramo = (fin_grupo < xb) ? fin_grupo : xb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin // Reset
      st <= R_IDLE;
      xa <= '0; xb <= '0; ya <= '0; yb <= '0; cx <= '0; cy <= '0; col <= '0;
    end else if (!stall) begin // Si no esta en Stall
      case (st)
        R_IDLE: if (start) begin 
		    // Ordena las coordenadas
			 // Distingue cual es la esquina superior izquierda y cual la esquina inferior derecha
			 // No importa el orden de escritura de las coordenadas
          xa <= (x0 < x1) ? x0 : x1;   xb <= (x0 > x1) ? x0 : x1;
          ya <= (y0 < y1) ? y0 : y1;   yb <= (y0 > y1) ? y0 : y1;
          cx <= (x0 < x1) ? x0 : x1;   cy <= (y0 < y1) ? y0 : y1;
          col <= color_in;
          st <= fill ? R_FILL : R_TOP;
        end

        R_FILL: begin // Relleno, un tramo por ciclo
          if (fin_tramo == xb) begin
            cx <= xa;
            if (cy == yb) st <= R_DONE;
            else          cy <= cy + 1;
          end else cx <= fin_tramo + 1;
        end

        R_TOP: begin // Arista superior
          if (cx == xb) begin
            cx <= xa;  cy <= yb;
            st <= (yb == ya) ? R_DONE : R_BOT;
          end else cx <= cx + 1;
        end

        R_BOT: begin // Arista inferior
          if (cx == xb) begin
            cx <= xa;  cy <= ya + 1;
            st <= (yb <= ya + 1) ? R_DONE : R_LEFT;
          end else cx <= cx + 1;
        end

        R_LEFT: begin // Arista izquierda
          if (cy == yb - 1) begin
            cy <= ya + 1;  cx <= xb;
            st <= (xb == xa) ? R_DONE : R_RIGHT;
          end else cy <= cy + 1;
        end

        R_RIGHT: begin // Arista derecha
          if (cy == yb - 1) st <= R_DONE;
          else              cy <= cy + 1;
        end

        R_DONE:  st <= R_IDLE;
        default: st <= R_IDLE;
      endcase
    end
  end

  // Señales de salida
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
