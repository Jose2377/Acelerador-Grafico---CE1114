`timescale 1ns / 1ps

//=============================================================================
// draw_pixel.sv
// Modulo : Dibujo de un pixel suelto  (OP_PIXEL)
//
// El mas simple de los cinco modulos de dibujo y el que fija el contrato que
// todos comparten:
//
//   start   Señal que carga los argumentos y arranca la figura
//   busy    Señal en alto mientras la figura no ha terminado
//   done    Señal de un ciclo al terminar; lo espera el decodificador
//   stall   Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina entera
//
// Carga los argumentos, Presenta el pixel un ciclo y avisa.
// El estado P_DONE existe por separado para que done sea un pulso limpio de un ciclo y no coincida con el ultimo pixel.
//
// Entradas
//   clk, rst_n   Reloj del sistema y reinicio
//   start        Señal que carga los argumentos y arranca la figura
//   stall        Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina entera
//   x0, y0       Coordenada del pixel
//   color_in     Color del pixel en RGB565
//
// Salidas
//   busy         Señal en alto mientras la figura no ha terminado de dibujarse
//   done         Señal de un ciclo al terminar
//   px_valid     Solicitud de pixel valida
//   px_x, px_y   Coordenada del pixel presentado
//   px_color     Color de pixel
//=============================================================================
module draw_pixel #(
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,        // Reloj del sistema
  input  logic                    rst_n,      // Reset del sistema
  input  logic                    start,      // Señal que carga los argumentos y arranca la figura
  input  logic                    stall,      // Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina entera
  input  logic signed [15:0]      x0, y0,     // Coordenada del pixel
  input  logic [PIXEL_BITS-1:0]   color_in,   // Color del pixel en RGB565
  output logic                    busy,       // Señal en alto mientras la figura no ha terminado
  output logic                    done,       // Señal de un ciclo al terminar
  output logic                    px_valid,   // Solicitud de pixel valida
  output logic signed [15:0]      px_x, px_y, // Coordenada del pixel presentado
  output logic [PIXEL_BITS-1:0]   px_color    // Color de pixel
);

  typedef enum logic [1:0] {P_IDLE, P_OUT, P_DONE} pst_e;
  pst_e st;

  logic signed [15:0]    x, y;
  logic [PIXEL_BITS-1:0] col;

  // Con stall en alto la maquina se congela por completo. 
  // El pixel presente se mantiene en la salida hasta que lo acepten. 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= P_IDLE;
      x <= '0;  y <= '0;  col <= '0;
    end else if (!stall) begin
      case (st)
        P_IDLE: if (start) begin
          x <= x0;  y <= y0;  col <= color_in;
          st <= P_OUT;
        end

        P_OUT:   st <= P_DONE;
        P_DONE:  st <= P_IDLE;
        default: st <= P_IDLE;
      endcase
    end
  end

  assign busy     = (st != P_IDLE);
  assign done     = (st == P_DONE);
  assign px_valid = (st == P_OUT);
  assign px_x     = x;
  assign px_y     = y;
  assign px_color = col;

endmodule
