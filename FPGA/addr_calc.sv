`timescale 1ns / 1ps

//=============================================================================
// addr_calc.sv
// Modulo : Traductor de coordenada de pantalla a direccion lineal
//
// Convierte el par (x, y) en el indice del pixel dentro del framebuffer,
// recorrido por filas: addr = y * SCREEN_W + x. Es la direccion que viaja en
// la solicitud de pixel (IF-07) y la que el gestor de framebuffer suma a la
// base del buffer trasero.
//
// Puramente combinacional, sin reloj ni estado: el sintetizador resuelve la
// multiplicacion por SCREEN_W como un desplazamiento cuando SCREEN_W es
// potencia de dos, de modo que no consume ningun DSP ni ningun ciclo.
//
// Entradas
//   x, y   coordenada del pixel dentro de la region visible
//
// Salidas
//   addr   indice lineal de ese pixel en el framebuffer, y * SCREEN_W + x
//=============================================================================
module addr_calc #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic [$clog2(SCREEN_W)-1:0]            x,
  input  logic [$clog2(SCREEN_H)-1:0]            y,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0]   addr
);

  assign addr = (y * SCREEN_W) + x;

endmodule
