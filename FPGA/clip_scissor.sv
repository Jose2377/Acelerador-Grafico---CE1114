`timescale 1ns / 1ps

//=============================================================================
// clip_scissor.sv
// Modulo : Recorte de pixeles contra la region visible
//
// Los modulos de dibujo trabajan con coordenadas de 16 bits con signo, 
// de modo que una figura puede salirse de la pantalla por cualquier lado. 
// Este modulo deja pasar unicamente los pixeles que caen dentro del rectangulo visible y descarta el resto, 
// en lugar de dejar que una coordenada negativa o demasiado grande se recorte sola al truncar los bits 
// y reaparezca en el lado opuesto corrompiendo un pixel ajeno.
//
// La decision es combinacional, de un solo ciclo y sin estado, 
// asi que el recorte no cuesta ningun ciclo al rasterizador.
//
// El truncado de x_out e y_out solo tiene sentido cuando valid_out vale 1;
// se hace sin condicion porque no cuesta nada y el consumidor ya mira valid.
//
// Tramos. La solicitud puede traer len_in pixeles consecutivos en la misma fila
// (el relleno de rectangulo los emite de a una rafaga).
// Se recorta el tramo entero: sale la parte visible, empezando en x_out y con len_out pixeles,
// y n_fuera cuenta los descartados.
// Un pixel suelto es un tramo de longitud 1 y se comporta exactamente como antes.
//
// Entradas
//   valid_in      Si hay un pixel presentado en x_in, y_in
//   len_in        Pixeles del tramo, de 1 a BURST_LEN
//   x_in, y_in    Coordenada con signo que produce el modulo de dibujo
//
// Salidas
//   valid_out     Si el pixel cae dentro de la pantalla: sigue hacia el framebuffer
//   x_out, y_out  La misma coordenada ya truncada al ancho de la pantalla
//   len_out       Pixeles visibles del tramo (0 si no queda ninguno)
//   fuera         Al menos un pixel cae fuera y se descarta
//   n_fuera       Cuantos pixeles se descartan: alimenta el contador de recortes
//=============================================================================
module clip_scissor #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48,
  parameter int LW       = $clog2(Acelerador_pkg::BURST_LEN + 1)
)(
  input  logic               valid_in,       // Si hay un pixel presentado en x_in, y_in
  input  logic signed [15:0] x_in, y_in,     // Coordenada con signo que produce el modulo de dibujo
  input  logic [LW-1:0]      len_in,         // Pixeles del tramo
  output logic [LW-1:0]      len_out,        // Pixeles visibles del tramo
  output logic [LW-1:0]      n_fuera,        // Pixeles descartados
  output logic               valid_out,      // Si el pixel cae dentro de la pantalla: sigue hacia el framebuffer
  output logic [$clog2(SCREEN_W)-1:0] x_out, // La misma coordenada ya truncada al ancho de la pantalla
  output logic [$clog2(SCREEN_H)-1:0] y_out, // El pixel cae fuera y se descarta: alimenta el contador de recortes
  output logic               fuera          
);

  // Extremos del tramo en 17 bits, para que x_in + len no desborde
  logic signed [16:0] xa, xb, xa_vis, xb_vis;
  logic               fila_ok, hay_visible;

  assign xa = 17'(x_in);
  assign xb = 17'(x_in) + 17'(len_in) - 17'sd1;

  assign fila_ok     = (y_in >= 0) && (y_in < SCREEN_H);
  assign xa_vis      = (xa > 0) ? xa : 17'sd0;
  assign xb_vis      = (xb < 17'(SCREEN_W - 1)) ? xb : 17'(SCREEN_W - 1);
  assign hay_visible = valid_in && fila_ok && (xa_vis <= xb_vis);

  assign valid_out = hay_visible;
  assign len_out   = hay_visible ? LW'(xb_vis - xa_vis + 17'sd1) : '0;
  assign n_fuera   = valid_in ? (len_in - len_out) : '0;
  assign fuera     = (n_fuera != '0);

  // Truncado al ancho de la pantalla; solo tiene sentido con valid_out en 1
  assign x_out = xa_vis[$clog2(SCREEN_W)-1:0];
  assign y_out = y_in[$clog2(SCREEN_H)-1:0];

endmodule
