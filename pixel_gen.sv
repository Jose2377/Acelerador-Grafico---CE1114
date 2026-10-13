//=============================================================================
// pixel_gen.sv
// Modulo : Salida comun del rasterizador  (interfaz IF-07)
//
// Ultima etapa del camino de pixeles. Recibe el flujo que sale del
// multiplexor de los cinco modulos de dibujo y lo convierte en la solicitud
// de pixel que consume el gestor de framebuffer. Son tres cosas encadenadas:
//
//   1. clip_scissor descarta lo que cae fuera de la region visible
//   2. addr_calc traduce la coordenada superviviente a direccion lineal
//   3. los dos contadores de instrumentacion
//
// Tenerlo en un solo sitio es lo que permite que los modulos de dibujo
// trabajen con coordenadas con signo sin preocuparse por los bordes ni por
// la direccion: ninguno de ellos conoce el tamano de la pantalla.
//
// Los contadores incrementan solo cuando px_ready esta alto, no cuando el
// pixel se presenta. Con contrapresion el mismo pixel se queda presentado
// varios ciclos seguidos, y contar ciclos en vez de pixeles aceptados
// inflaria la medida.
//=============================================================================
module pixel_gen #(
  parameter int SCREEN_W   = 64,
  parameter int SCREEN_H   = 48,
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    clr_cnt,

  input  logic                    px_ready,

  // Flujo
  input  logic                    valid_in,
  input  logic signed [15:0]      x_in, y_in,
  input  logic [PIXEL_BITS-1:0]   color_in,

  // Solicitud
  output logic                    px_valid,
  output logic [$clog2(SCREEN_W)-1:0] px_x,
  output logic [$clog2(SCREEN_H)-1:0] px_y,
  output logic [PIXEL_BITS-1:0]   px_color,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0] px_addr,

  // Instrumentacion
  output logic [31:0]             pix_count,
  output logic [31:0]             clip_count
);

  logic fuera;

  clip_scissor #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_clip (
    .valid_in(valid_in), .x_in(x_in), .y_in(y_in),
    .valid_out(px_valid), .x_out(px_x), .y_out(px_y), .fuera(fuera));

  addr_calc #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_addr (
    .x(px_x), .y(px_y), .addr(px_addr));

  assign px_color = color_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pix_count  <= '0;
      clip_count <= '0;
    end else if (clr_cnt) begin
      pix_count  <= '0;
      clip_count <= '0;
    end else begin
      if (px_valid && px_ready) pix_count  <= pix_count  + 32'd1;
      if (fuera    && px_ready) clip_count <= clip_count + 32'd1;
    end
  end

endmodule
