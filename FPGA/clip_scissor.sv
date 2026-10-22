`timescale 1ns / 1ps

//=============================================================================
// clip_scissor.sv
// Modulo : Recorte de pixeles contra la region visible
//
// Los modulos de dibujo trabajan con coordenadas de 16 bits con signo, de
// modo que una figura puede salirse de la pantalla por cualquier lado. Este
// modulo deja pasar unicamente los pixeles que caen dentro del rectangulo
// visible y descarta el resto, en lugar de dejar que una coordenada negativa
// o demasiado grande se recorte sola al truncar los bits y reaparezca en el
// lado opuesto corrompiendo un pixel ajeno.
//
// La decision es combinacional, de un solo ciclo y sin estado, asi que el
// recorte no cuesta ningun ciclo al rasterizador.
//
//   valid_out  pixel dentro: sigue hacia el framebuffer
//   fuera      pixel descartado: alimenta el contador de recortes
//
// El truncado de x_out e y_out solo tiene sentido cuando valid_out vale 1;
// se hace sin condicion porque no cuesta nada y el consumidor ya mira valid.
//
// Entradas
//   valid_in      hay un pixel presentado en x_in, y_in
//   x_in, y_in    coordenada con signo que produce el modulo de dibujo
//
// Salidas
//   valid_out     el pixel cae dentro de la pantalla: sigue hacia el framebuffer
//   x_out, y_out  la misma coordenada ya truncada al ancho de la pantalla
//   fuera         el pixel cae fuera y se descarta: alimenta el contador de recortes
//=============================================================================
module clip_scissor #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic               valid_in,
  input  logic signed [15:0] x_in, y_in,
  output logic               valid_out,
  output logic [$clog2(SCREEN_W)-1:0] x_out,
  output logic [$clog2(SCREEN_H)-1:0] y_out,
  output logic               fuera
);

  logic dentro;

  assign dentro  = (x_in >= 0) && (x_in < SCREEN_W)
                && (y_in >= 0) && (y_in < SCREEN_H);

  assign valid_out = valid_in &&  dentro;
  assign fuera   = valid_in && !dentro;

  assign x_out = x_in[$clog2(SCREEN_W)-1:0];
  assign y_out = y_in[$clog2(SCREEN_H)-1:0];

endmodule
