`timescale 1ns / 1ps

//=============================================================================
// draw_trian.sv
// Modulo : Triangulo, contorno o relleno  (OP_TRIA, OP_TRIA_FILL)
//
// Tres vertices (x0,y0), (x1,y1), (x2,y2). 
// Como en el circulo, las dos formas usan caminos distintos.
//
// Contorno (fill = 0): Tres llamadas consecutivas al mismo draw_line instanciado aqui dentro, 
// una por arista, en los estados T_E0, T_E1 y T_E2.
// Reutilizar el generador de lineas ahorra logica y
// garantiza que las aristas del triangulo salgan identicas a una linea suelta.
//
// Relleno (fill = 1): Funciones de arista. 
// Para cada arista del triangulo se define el producto cruzado que, evaluado en un punto, 
// da el signo del lado en que ese punto cae. 
// Si las tres funciones salen no negativas el punto esta dentro. 
// El recorrido va por el rectangulo que encierra al triangulo (la caja), 
// y en cada paso las tres funciones se actualizan sumando su incremento constante: 
// sx* al avanzar en x, sy* al bajar de fila. 
// Asi el lazo no multiplica nada, solo suma; 
// las unicas multiplicaciones son las del arranque, 
// al evaluar las tres funciones en la esquina de la caja.
//
// Orientacion: El area con signo del triangulo se calcula al cargar y,
// si sale negativa, se intercambian dos vertices. 
// Eso deja siempre el mismo sentido de giro y permite que el criterio de pertenencia sea un simple
// "las tres no negativas" en vez de distinguir casos por orientacion. 
// Un area nula significa que los tres vertices son colineales: 
// no hay area que rellenar y se salta a T_DONE.
//
// La caja se recorta contra la pantalla al calcularla, 
// de modo que un triangulo que se sale no cuesta ciclos recorriendo filas invisibles.
// clip_scissor sigue vigilando pixel a pixel mas adelante.
//
// Los 36 bits de los acumuladores dan margen de sobra para los productos de
// dos diferencias de coordenadas de 16 bits con signo sin que desborden.
//
// Entradas
//   clk, rst_n              Reloj del sistema y reinicio
//   start                   Señal que carga los argumentos y arranca la figura
//   stall                   Señal que el gestor de framebuffer no esta aceptando datos: congela la maquina entera
//   fill                    1 = Triangulo relleno, 0 = Solo los tres lados
//   x0, y0, x1, y1, x2, y2  Coordenadas de los tres vertices
//   color_in                Color en RGB565
//
// Salidas
//   busy                    Señal en alto mientras la figura no ha terminado de dibujarse
//   done                    Señal de un ciclo al terminar
//   px_valid                Solicitud de pixel valida
//   px_x, px_y              Coordenada del pixel presentado
//   px_color                Color de pixel
//=============================================================================
module draw_trian #(
  parameter int SCREEN_W   = 64,
  parameter int SCREEN_H   = 48,
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,                    // Reloj del sistema
  input  logic                    rst_n,                  // Reset del sistema
  input  logic                    start,                  // Señal que carga los argumentos y arranca la figura
  input  logic                    stall,                  // Señal que el gestor de framebuffer no esta aceptando datos
  input  logic                    fill,                   // 1 = Triangulo relleno, 0 = Solo los tres lados
  input  logic signed [15:0]      x0, y0, x1, y1, x2, y2, // Coordenadas de los tres vertices
  input  logic [PIXEL_BITS-1:0]   color_in,               // Color en RGB565
  output logic                    busy,                   // Señal en alto mientras la figura no ha terminado de dibujarse
  output logic                    done,                   // Señal de un ciclo al terminar
  output logic                    px_valid,               // Solicitud de pixel valida
  output logic signed [15:0]      px_x, px_y,             // Coordenada del pixel presentado
  output logic [PIXEL_BITS-1:0]   px_color                // Color de pixel
);

  // Estados de dibujo
  // Espera, Arista 1, Arista 2, Arista 3, Preparacion de relleno, Relleno, Finalizado.
  typedef enum logic [2:0] {
    T_IDLE, T_E0, T_E1, T_E2, T_SETUP, T_FILL, T_DONE
  } tst_e;
  tst_e st;

  // (xa,ya)        Coordenadas primer vertice
  // (xb,yb)        Coordenadas segundo vertice
  // (gx,gy)        Coordenadas tercer vertice
  // (bx0,by0)      Coordenadas de la esquina superior izquierda para relleno
  // (bx1,by1)      Coordenadas de la esquina inferior derecha para relleno
  // (cx,cy)        Coordenadas pixel actual de dibujado
  // e0, e1, e2     Valores actuales de las tres funciones de arista
  // e0r, e1r, e2r  Valores de esas funciones al inicio de cada fila
  // sx0, sx1, sx2  Incrementos horizontales
  // sy0, sy1, sy2  Incrementos verticales
  logic signed [15:0] ax, ay, bx, by, gx, gy;
  logic signed [15:0] bx0, bx1, by0, by1, cx, cy;
  logic signed [35:0] e0, e1, e2, e0r, e1r, e2r;
  logic signed [35:0] sx0, sx1, sx2, sy0, sy1, sy2;
  logic [PIXEL_BITS-1:0] col;

  // lg_start                    Inicia el dibujo de una arista
  // lg_done                     Indica que la arista terminó
  // lg_valid                    Indica que el generador de líneas presenta un píxel válido
  // lg_px, lg_py                Coordenadas del píxel generado
  // lg_x0, lg_y0, lg_x1, lg_y1  Extremos de la arista que debe dibujarse
  logic               lg_start, lg_busy, lg_done, lg_valid;
  logic signed [15:0] lg_x0, lg_y0, lg_x1, lg_y1, lg_px, lg_py;
  logic [PIXEL_BITS-1:0] lg_color;

  draw_line #(.PIXEL_BITS(PIXEL_BITS)) u_gen (
    .clk(clk), .rst_n(rst_n), .start(lg_start), .stall(stall),
    .x0_in(lg_x0), .y0_in(lg_y0), .x1_in(lg_x1), .y1_in(lg_y1),
    .color_in(col),
    .busy(lg_busy), .done(lg_done),
    .px_valid(lg_valid), .px_x(lg_px), .px_y(lg_py), .px_color(lg_color));

  // Extremos que se presentan al generador de lineas segun la arista que toque: A-B, B-C y C-A
  always_comb begin
    case (st)
      T_E0:    begin lg_x0 = ax; lg_y0 = ay; lg_x1 = bx; lg_y1 = by; end
      T_E1:    begin lg_x0 = bx; lg_y0 = by; lg_x1 = gx; lg_y1 = gy; end
      default: begin lg_x0 = gx; lg_y0 = gy; lg_x1 = ax; lg_y1 = ay; end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin : p_tri
    // area                Area orientada calculada a partir de los tres vértices
    // ev0, ev1, ev2       Valores iniciales de las funciones de arista
    // v1x, v1y, v2x, v2y  Coordenadas de los vértices B y C después de ordenar su orientación
    // mnx, mxx, mny, mxy  Límites de la caja antes de guardarlos en registros
    logic signed [35:0] area, ev0, ev1, ev2;
    logic signed [15:0] v1x, v1y, v2x, v2y, mnx, mxx, mny, mxy;

    if (!rst_n) begin // Reset
      st <= T_IDLE;  lg_start <= 1'b0;
      ax <= '0; ay <= '0; bx <= '0; by <= '0; gx <= '0; gy <= '0;
      bx0 <= '0; bx1 <= '0; by0 <= '0; by1 <= '0; cx <= '0; cy <= '0;
      e0 <= '0; e1 <= '0; e2 <= '0; e0r <= '0; e1r <= '0; e2r <= '0;
      sx0 <= '0; sx1 <= '0; sx2 <= '0; sy0 <= '0; sy1 <= '0; sy2 <= '0;
      col <= '0;
    end else if (!stall) begin // Si no esta en Stall
      lg_start <= 1'b0;
      case (st)
		  // Inicializacion de variables
		  // Si area > 0, los vértices tienen una orientación.
        // Si area < 0, tienen la orientación contraria.
        // Si area == 0, los tres puntos son colineales o coinciden y no forman un triángulo de área positiva.
        T_IDLE: if (start) begin
          area = (36'(x1) - 36'(x0)) * (36'(y2) - 36'(y0))
               - (36'(y1) - 36'(y0)) * (36'(x2) - 36'(x0));
          if (area >= 0) begin v1x = x1; v1y = y1; v2x = x2; v2y = y2; end
          else           begin v1x = x2; v1y = y2; v2x = x1; v2y = y1; end

          ax <= x0;  ay <= y0;
          bx <= v1x; by <= v1y;
          gx <= v2x; gy <= v2y;
          col <= color_in;

          if (fill) begin
            // Caja que encierra al triangulo, ya recortada contra la pantalla: 
				// minimos contra 0 y maximos contra el ultimo pixel.
            mnx = (((x0 < v1x) ? ((x0 < v2x) ? x0 : v2x)
                               : ((v1x < v2x) ? v1x : v2x)) > 0)
                  ? ((x0 < v1x) ? ((x0 < v2x) ? x0 : v2x)
                                : ((v1x < v2x) ? v1x : v2x)) : 16'sd0;
            mny = (((y0 < v1y) ? ((y0 < v2y) ? y0 : v2y)
                               : ((v1y < v2y) ? v1y : v2y)) > 0)
                  ? ((y0 < v1y) ? ((y0 < v2y) ? y0 : v2y)
                                : ((v1y < v2y) ? v1y : v2y)) : 16'sd0;
            mxx = (((x0 > v1x) ? ((x0 > v2x) ? x0 : v2x)
                               : ((v1x > v2x) ? v1x : v2x)) < SCREEN_W - 1)
                  ? ((x0 > v1x) ? ((x0 > v2x) ? x0 : v2x)
                                : ((v1x > v2x) ? v1x : v2x)) : 16'(SCREEN_W - 1);
            mxy = (((y0 > v1y) ? ((y0 > v2y) ? y0 : v2y)
                               : ((v1y > v2y) ? v1y : v2y)) < SCREEN_H - 1)
                  ? ((y0 > v1y) ? ((y0 > v2y) ? y0 : v2y)
                                : ((v1y > v2y) ? v1y : v2y)) : 16'(SCREEN_H - 1);
				
				// Asigna variables
            bx0 <= mnx;  bx1 <= mxx;  by0 <= mny;  by1 <= mxy;
            cx  <= mnx;  cy  <= mny;

            // Incrementos constantes de cada funcion de arista: sx por cada paso en x, sy por cada fila. 
				// Sustituyen a la multiplicacion dentro del lazo.
            sx0 <= -(36'(v1y) - 36'(y0));    sy0 <= (36'(v1x) - 36'(x0));
            sx1 <= -(36'(v2y) - 36'(v1y));   sy1 <= (36'(v2x) - 36'(v1x));
            sx2 <= -(36'(y0)  - 36'(v2y));   sy2 <= (36'(x0)  - 36'(v2x));

            // Las tres funciones evaluadas en la esquina superior izquierda de la caja. 
				// Son las unicas multiplicaciones del algoritmo.
            ev0 = (36'(v1x) - 36'(x0))  * (36'(mny) - 36'(y0))
                - (36'(v1y) - 36'(y0))  * (36'(mnx) - 36'(x0));
            ev1 = (36'(v2x) - 36'(v1x)) * (36'(mny) - 36'(v1y))
                - (36'(v2y) - 36'(v1y)) * (36'(mnx) - 36'(v1x));
            ev2 = (36'(x0)  - 36'(v2x)) * (36'(mny) - 36'(v2y))
                - (36'(y0)  - 36'(v2y)) * (36'(mnx) - 36'(v2x));
				
				// Asigna variables
            e0 <= ev0;  e1 <= ev1;  e2 <= ev2;
            e0r <= ev0; e1r <= ev1; e2r <= ev2;

            st <= ((area == 0) || (mnx > mxx) || (mny > mxy)) ? T_DONE : T_SETUP;
          end else begin
            lg_start <= 1'b1;
            st       <= T_E0;
          end
        end

        T_E0: if (lg_done) begin lg_start <= 1'b1; st <= T_E1; end
        T_E1: if (lg_done) begin lg_start <= 1'b1; st <= T_E2; end
        T_E2: if (lg_done) st <= T_DONE;

        T_SETUP: st <= T_FILL;

        // Recorrido de la caja. 
		  // Al final de cada fila los acumuladores vuelven al borde izquierdo con el valor que guardo er,
		  // de modo que no hay que reevaluar las funciones desde cero.
        T_FILL: begin
          if (cx == bx1) begin
            if (cy == by1) st <= T_DONE;
            else begin
              cy  <= cy + 1;      cx  <= bx0;
              e0  <= e0r + sy0;   e0r <= e0r + sy0;
              e1  <= e1r + sy1;   e1r <= e1r + sy1;
              e2  <= e2r + sy2;   e2r <= e2r + sy2;
            end
          end else begin
            cx <= cx + 1;
            e0 <= e0 + sx0;  e1 <= e1 + sx1;  e2 <= e2 + sx2;
          end
        end

        T_DONE:  st <= T_IDLE;
        default: st <= T_IDLE;
      endcase
    end
  end

  assign busy = (st != T_IDLE);
  assign done = (st == T_DONE);

  // Salida. En el contorno se deja pasar lo que produce draw_line; en el
  // relleno, el punto esta dentro cuando las tres funciones de arista son no
  // negativas.
  always_comb begin
    px_valid = 1'b0;  px_x = '0;  px_y = '0;  px_color = col;
    if ((st == T_E0) || (st == T_E1) || (st == T_E2)) begin
      px_valid = lg_valid;  px_x = lg_px;  px_y = lg_py;
      px_color = lg_color;
    end else if (st == T_FILL) begin
      px_valid = (e0 >= 0) && (e1 >= 0) && (e2 >= 0);
      px_x     = cx;        px_y = cy;
    end
  end
endmodule
