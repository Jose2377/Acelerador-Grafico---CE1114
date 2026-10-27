`timescale 1ns / 1ps

//=============================================================================
// draw_circle.sv
// Modulo : Circulo, contorno o relleno  (OP_CIRC, OP_CIRC_FILL)
//
// Centro en (cx_in, cy_in) y radio r_in. 
// Dos algoritmos distintos segun la entrada fill, 
// porque el que sirve para el contorno no sirve para el area.
//
// Contorno (fill = 0): punto medio de Bresenham para circunferencias.
// Recorre solo un octante y aprovecha la simetria de ocho para obtener el resto: 
// cada pareja (x, y) calculada produce ocho pixeles intercambiando y negando las dos coordenadas. 
// El multiplexor combinacional de oct hace esa reflexion, un octante por ciclo en K_OUT; 
// K_UPD avanza al punto siguiente y termina cuando x cruza por debajo de y, que es el final del octante.
// El termino de error se corrige con err += 2*y + 1 y err -= 2*x + 1: 
// solo sumas y desplazamientos, sin raices ni trigonometria.
//
// Relleno (fill = 1): recorrido del cuadrado circunscrito, de -r a +r en los dos ejes, 
// dejando pasar el pixel cuando dx^2 + dy^2 <= r^2. 
// Los cuadrados no se multiplican en cada paso sino que se llevan de forma incremental (dx2 += 2*dx + 1), 
// de modo que el lazo tampoco necesita multiplicador. 
// Cuesta mas ciclos que el area real del circulo, pero garantiza un relleno sin huecos, 
// que es lo que el reflejo del contorno no puede asegurar.
//
// La validacion del radio distinto de cero la hace decoder_fsm antes de arrancar, 
// y emite EC-07 si no se cumple.
//
// Entradas
//   clk, rst_n           Reloj del sistema y reinicio
//   start                Señal que carga los argumentos y arranca la figura
//   stall                Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina entera
//   fill                 1 = Circulo relleno, 0 = Solo la circunferencia
//   cx_in, cy_in         Centro del circulo
//   r_in                 Radio en pixeles
//   color_in             Color en RGB565
//
// Salidas
//   busy                 Señal en alto mientras la figura no ha terminado de dibujarse
//   done                 Señal de un ciclo al terminar
//   px_valid             Solicitud de pixel valida
//   px_x, px_y           Coordenada del pixel presentado
//   px_color             Color de pixel
//=============================================================================
module draw_circle #(
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,          // Reloj del sistema
  input  logic                    rst_n,        // Reset del sistema
  input  logic                    start,        // Señal que carga los argumentos y arranca la figura
  input  logic                    stall,        // Señal que el gestor de framebuffer no esta aceptando datos
  input  logic                    fill,         // 1 = circulo relleno, 0 = solo la circunferencia
  input  logic signed [15:0]      cx_in, cy_in, // Centro del circulo
  input  logic        [9:0]       r_in,         // Radio en pixeles
  input  logic [PIXEL_BITS-1:0]   color_in,     // Color en RGB565
  output logic                    busy,         // Señal en alto mientras la figura no ha terminado de dibujarse
  output logic                    done,         // Señal de un ciclo al terminar
  output logic                    px_valid,     // Solicitud de pixel valida
  output logic signed [15:0]      px_x, px_y,   // Coordenada del pixel presentado
  output logic [PIXEL_BITS-1:0]   px_color      // Color de pixel
);

  // Estados de dibujo
  // Espera, Preparacion de registros, Dibujado 8 puntos simetricos, Actualizacion de coordenadas, Relleno, Finalizado.
  typedef enum logic [2:0] {K_IDLE, K_SETUP, K_OUT, K_UPD, K_FILL, K_DONE} kst_e;
  kst_e st;

  // Registros
  // (cx, cy) Coordenadas del centro del circulo
  // rr       Radio almacenado del circulo
  // (x,y)    Coordenadas actuales del algoritmo
  // dx, dy   Desplazamientos respecto al centro para el relleno
  // err      Error acumulado del algoritmo
  // r2       Radio al cuadrado
  // dx2, dy2 Desplazamientos al cuadrado respecto al centro para el relleno+
  // oct      Uno de los ocho puntos simetricos
  logic signed [15:0] cx, cy, rr, x, y, dx, dy;
  logic signed [21:0] err, r2, dx2, dy2;
  logic        [2:0]  oct;
  logic signed [15:0] ox, oy;
  logic [PIXEL_BITS-1:0] col;

  // Simetria de ocho. 
  // El punto (x, y) calculado en el primer octante se refleja en los otros siete intercambiando las coordenadas
  // y cambiando los signos; son cables y sumas, ningun calculo nuevo.
  always_comb begin
    case (oct)
      3'd0:    begin ox = cx + x; oy = cy + y; end
      3'd1:    begin ox = cx + y; oy = cy + x; end
      3'd2:    begin ox = cx - y; oy = cy + x; end
      3'd3:    begin ox = cx - x; oy = cy + y; end
      3'd4:    begin ox = cx - x; oy = cy - y; end
      3'd5:    begin ox = cx - y; oy = cy - x; end
      3'd6:    begin ox = cx + y; oy = cy - x; end
      default: begin ox = cx + x; oy = cy - y; end
    endcase
  end

  // Paso del punto medio de Bresenham, en paralelo
  // Con err > 0 solo se retrocede en x:
  //   x' = x - 1,  err' = err - 2x + 1
  // Con err <= 0 se avanza en y, y se retrocede en x si el error queda positivo:
  //   e1 = err + 2y + 3                      (y' = y + 1)
  //   e1 >  0: x' = x - 1, err' = err + 2y - 2x + 4
  //   e1 <= 0: x' = x,     err' = e1
  // El fin del octante (x' < y') se resuelve igual, comparando "x", "e" y "ya"
  // registrados contra la constante que corresponde a cada caso.
  logic signed [21:0] upd_e1, upd_e2, upd_e3, upd_err;
  logic signed [15:0] upd_x, upd_y;
  logic               upd_fin, upd_sube;

  assign upd_sube = (err <= 0);
  assign upd_e1   = err + 22'(y) + 22'(y) + 22'sd3;
  assign upd_e2   = err - 22'(x) - 22'(x) + 22'sd1;
  assign upd_e3   = err + 22'(y) + 22'(y) - 22'(x) - 22'(x) + 22'sd4;

  always_comb begin
    if (!upd_sube) begin                 // err > 0
      upd_x = x - 16'sd1;  upd_y = y;           upd_err = upd_e2;
      upd_fin = (x <= y);                       // x - 1 < y
    end else if (upd_e1 > 0) begin       // sube y baja
      upd_x = x - 16'sd1;  upd_y = y + 16'sd1;  upd_err = upd_e3;
      upd_fin = (x <= y + 16'sd1);              // x - 1 < y + 1
    end else begin                       // solo sube
      upd_x = x;           upd_y = y + 16'sd1;  upd_err = upd_e1;
      upd_fin = (x <= y);                       // x < y + 1
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin : p_circ

    if (!rst_n) begin // Reset
      st <= K_IDLE;
      cx <= '0; cy <= '0; rr <= '0; x <= '0; y <= '0; oct <= '0;
      dx <= '0; dy <= '0; err <= '0; r2 <= '0; dx2 <= '0; dy2 <= '0;
      col <= '0;
    end else if (!stall) begin // Si no esta en Stall
      case (st)
        K_IDLE: if (start) begin // Inicializa variables
          cx <= cx_in;  cy <= cy_in;  rr <= 16'(r_in);
          col <= color_in;
          st <= K_SETUP;
        end

        // Preparacion comun de variables dependiendo del algoritmo,
		  // ya sea para relleno o solo circunferencia.
        K_SETUP: begin
          if (fill) begin // Relleno
            r2  <= 22'(rr) * 22'(rr);
            dx2 <= 22'(rr) * 22'(rr);
            dy2 <= 22'(rr) * 22'(rr);
            dx  <= -rr;  dy <= -rr;
            st  <= K_FILL;
          end else begin // Circunferencia
            x <= rr;  y <= '0;  err <= '0;  oct <= '0;
            st <= K_OUT;
          end
        end

        K_OUT: begin // Ocho octantes, Uno por ciclo
          if (oct == 3'd7) begin oct <= '0; st <= K_UPD; end
          else                   oct <= oct + 1'b1;
        end

        // Actualiza el punto del octante.
        // Los tres resultados posibles se calculan en paralelo desde registros y solo se elige uno.
        K_UPD: begin
          err <= upd_err;  x <= upd_x;  y <= upd_y;
          st  <= upd_fin ? K_DONE : K_OUT;
        end

        // Recorrido del cuadrado circunscrito. 
		  // El criterio de pertenencia lo evalua el bloque combinacional de salida, no este.
        K_FILL: begin
          if (dx == rr) begin // Recorre desde -rr a rr, fuera de aqui no existe pixel que pertenezca
            dx <= -rr;  dx2 <= r2;
            if (dy == rr) st <= K_DONE;
            else begin
              dy2 <= dy2 + 22'(dy) + 22'(dy) + 1;       // dy2 += 2*dy + 1
              dy  <= dy + 1;
            end
          end else begin
            dx2 <= dx2 + 22'(dx) + 22'(dx) + 1;         // dx2 += 2*dx + 1
            dx  <= dx + 1;
          end
        end

        K_DONE:  st <= K_IDLE;
        default: st <= K_IDLE;
      endcase
    end
  end

  assign busy = (st != K_IDLE);
  assign done = (st == K_DONE);

  // Salida. 
  // En el contorno todos los pixeles son validos; 
  // en el relleno solo los que caen dentro de la circunferencia, 
  // de modo que px_valid baja en las esquinas del cuadrado recorrido.
  always_comb begin
    px_valid = 1'b0;  px_x = '0;  px_y = '0;  px_color = col;
    if (st == K_OUT) begin
      px_valid = 1'b1;       px_x = ox;       px_y = oy;
    end else if (st == K_FILL) begin
      px_valid = ((dx2 + dy2) <= r2);
      px_x     = cx + dx;    px_y = cy + dy;
    end
  end
endmodule
