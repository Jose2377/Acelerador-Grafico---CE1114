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
// El punto esta dentro si las tres funciones son positivas,
// o si alguna vale cero y esa arista gana el pixel segun la regla de relleno. 
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
// Regla de relleno top-left.
// Un pixel que cae exactamente sobre una arista (E = 0) pertenece al triangulo solo si esa arista es superior o izquierda. 
// Dos triangulos que comparten una arista la recorren en sentidos opuestos,
// de modo que para uno es superior/izquierda y para el otro no:
// cada pixel de la frontera lo pinta exactamente uno de los dos.
// Con la orientacion normalizada (E > 0 dentro, eje y hacia abajo), una arista de direccion (dx, dy) es
//   izquierda  si dy < 0
//   superior   si dy = 0 y dx > 0
// Las coordenadas son enteras y se muestrea en el pixel, 
// de modo que E es entero y "E >= 0 o E > 0 segun la arista" basta,
// sin sesgos fraccionarios.
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
  //
  // La preparacion se reparte en cinco estados para que ningun ciclo encadene mas de una multiplicacion:
  //   T_AREA    Productos del area orientada
  //   T_ORIENT  Signo del area e intercambio de vertices
  //   T_BOX     Caja envolvente recortada e incrementos
  //   T_EVAL    Productos de las tres funciones en la esquina de la caja
  //   T_SUM     Restas finales y carga de los acumuladores
  typedef enum logic [3:0] {
    T_IDLE, T_AREA, T_ORIENT, T_BOX, T_EVAL, T_SUM,
    T_E0, T_E1, T_E2, T_FILL, T_DONE
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

  // Registros intermedios de la preparacion
  // fill_q         Copia de fill tomada al arrancar
  // pa, pb         Los dos productos del area orientada (17 x 17 bits)
  // area_nula      Los tres vertices son colineales
  // p00 .. p21     Los dos productos de cada funcion de arista en la esquina
  logic                  fill_q, area_nula;
  logic                  tl0, tl1, tl2;    // La arista es superior o izquierda
  logic signed [33:0]    pa, pb;
  logic signed [33:0]    p00, p01, p10, p11, p20, p21;

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

  // Distribucion de trabajo
  // Aqui cada estado hace como mucho una resta, una multiplicacion de 17 x 17 bits (un bloque DSP) o una resta de 35 bits.
  // Asegura que se complete el proceso en flancos de reloj y no los alargue
  //
  // Las diferencias de coordenadas de 16 bits con signo caben en 17 bits,
  // de modo que se declaran asi explicitamente para que el sintetizador infiera multiplicadores de 18 x 18 y no de 36 x 36.

  // Diferencias que alimentan los multiplicadores. Todas salen de registros.
  logic signed [16:0] d_bxax, d_gyay, d_byay, d_gxax;            // area
  logic signed [16:0] d_e0x, d_e0y, d_e1x, d_e1y, d_e2x, d_e2y;  // aristas
  logic signed [16:0] d_my0, d_mx0, d_my1, d_mx1, d_my2, d_mx2;  // esquina

  assign d_bxax = 17'(bx) - 17'(ax);
  assign d_gyay = 17'(gy) - 17'(ay);
  assign d_byay = 17'(by) - 17'(ay);
  assign d_gxax = 17'(gx) - 17'(ax);

  // Arista 0: A -> B, arista 1: B -> C, arista 2: C -> A
  assign d_e0x = 17'(bx) - 17'(ax);   assign d_e0y = 17'(by) - 17'(ay);
  assign d_e1x = 17'(gx) - 17'(bx);   assign d_e1y = 17'(gy) - 17'(by);
  assign d_e2x = 17'(ax) - 17'(gx);   assign d_e2y = 17'(ay) - 17'(gy);

  // Esquina superior izquierda de la caja respecto al origen de cada arista
  assign d_my0 = 17'(by0) - 17'(ay);  assign d_mx0 = 17'(bx0) - 17'(ax);
  assign d_my1 = 17'(by0) - 17'(by);  assign d_mx1 = 17'(bx0) - 17'(bx);
  assign d_my2 = 17'(by0) - 17'(gy);  assign d_mx2 = 17'(bx0) - 17'(gx);

  // Caja envolvente recortada a la pantalla, sobre los vertices ya registrados
  function automatic logic signed [15:0] min3(input logic signed [15:0] a, b, c);
    logic signed [15:0] m;
    m = (a < b) ? a : b;
    min3 = (m < c) ? m : c;
  endfunction

  function automatic logic signed [15:0] max3(input logic signed [15:0] a, b, c);
    logic signed [15:0] m;
    m = (a > b) ? a : b;
    max3 = (m > c) ? m : c;
  endfunction

  // Limites con signo: comparar contra una constante sin signo convertiria
  // la comparacion en sin signo y una coordenada negativa pareceria enorme.
  localparam logic signed [15:0] XMAX = 16'(SCREEN_W - 1);
  localparam logic signed [15:0] YMAX = 16'(SCREEN_H - 1);

  logic signed [15:0] mnx, mny, mxx, mxy, mnx_r, mny_r, mxx_r, mxy_r;
  assign mnx_r = min3(ax, bx, gx);
  assign mny_r = min3(ay, by, gy);
  assign mxx_r = max3(ax, bx, gx);
  assign mxy_r = max3(ay, by, gy);
  assign mnx = (mnx_r > 0)                  ? mnx_r : 16'sd0;
  assign mny = (mny_r > 0)                  ? mny_r : 16'sd0;
  assign mxx = (mxx_r < XMAX) ? mxx_r : XMAX;
  assign mxy = (mxy_r < YMAX) ? mxy_r : YMAX;

  always_ff @(posedge clk or negedge rst_n) begin : p_tri
    if (!rst_n) begin // Reset
      st <= T_IDLE;  lg_start <= 1'b0;
      ax <= '0; ay <= '0; bx <= '0; by <= '0; gx <= '0; gy <= '0;
      bx0 <= '0; bx1 <= '0; by0 <= '0; by1 <= '0; cx <= '0; cy <= '0;
      e0 <= '0; e1 <= '0; e2 <= '0; e0r <= '0; e1r <= '0; e2r <= '0;
      sx0 <= '0; sx1 <= '0; sx2 <= '0; sy0 <= '0; sy1 <= '0; sy2 <= '0;
      col <= '0;
      fill_q <= 1'b0;  area_nula <= 1'b0;
      tl0 <= 1'b0;  tl1 <= 1'b0;  tl2 <= 1'b0;
      pa <= '0; pb <= '0;
      p00 <= '0; p01 <= '0; p10 <= '0; p11 <= '0; p20 <= '0; p21 <= '0;
    end else if (!stall) begin // Si no esta en Stall
      lg_start <= 1'b0;
      case (st)
        // Captura de los argumentos. Nada se calcula sobre las entradas,
		  // que llegan directamente de los registros de decoder_fsm.
        T_IDLE: if (start) begin
          ax <= x0;  ay <= y0;
          bx <= x1;  by <= y1;
          gx <= x2;  gy <= y2;
          col    <= color_in;
          fill_q <= fill;
          st     <= T_AREA;
        end

        // Area orientada, primera mitad: los dos productos.
        T_AREA: begin
          pa <= d_bxax * d_gyay;
          pb <= d_byay * d_gxax;
          st <= T_ORIENT;
        end

        // Area orientada, segunda mitad: el signo decide el sentido de giro.
        // Si area > 0, los vertices tienen una orientacion.
        // Si area < 0, tienen la orientacion contraria y se intercambian B y C.
        // Si area == 0, los tres puntos son colineales y no hay area que rellenar.
        // El contorno tambien usa los vertices ordenados, igual que antes, para
        // que las aristas salgan pixel a pixel identicas a la version anterior.
        T_ORIENT: begin
          if (pa < pb) begin
            bx <= gx;  by <= gy;
            gx <= bx;  gy <= by;
          end
          area_nula <= (pa == pb);
          if (fill_q) begin
            st <= T_BOX;
          end else begin
            lg_start <= 1'b1;
            st       <= T_E0;
          end
        end

        // Caja envolvente recortada e incrementos constantes de cada funcion.
			T_BOX: begin
				 bx0 <= mnx;
				 bx1 <= mxx;
				 by0 <= mny;
				 by1 <= mxy;

				 cx <= mnx;
				 cy <= mny;

				 // Incrementos horizontales: -dy
				 sx0 <= -$signed({{19{d_e0y[16]}}, d_e0y});
				 sx1 <= -$signed({{19{d_e1y[16]}}, d_e1y});
				 sx2 <= -$signed({{19{d_e2y[16]}}, d_e2y});

				 // Incrementos verticales: dx
				 sy0 <= $signed({{19{d_e0x[16]}}, d_e0x});
				 sy1 <= $signed({{19{d_e1x[16]}}, d_e1x});
				 sy2 <= $signed({{19{d_e2x[16]}}, d_e2x});

				 // Regla de relleno: aristas superiores e izquierdas
				 tl0 <= (d_e0y < 0) || ((d_e0y == 0) && (d_e0x > 0));
				 tl1 <= (d_e1y < 0) || ((d_e1y == 0) && (d_e1x > 0));
				 tl2 <= (d_e2y < 0) || ((d_e2y == 0) && (d_e2x > 0));

				 st <= T_EVAL;
			end
        // Funciones de arista en la esquina de la caja, primera mitad:
        // E(x, y) = (xb - xa)(y - ya) - (yb - ya)(x - xa)
        T_EVAL: begin
          p00 <= d_e0x * d_my0;   p01 <= d_e0y * d_mx0;
          p10 <= d_e1x * d_my1;   p11 <= d_e1y * d_mx1;
          p20 <= d_e2x * d_my2;   p21 <= d_e2y * d_mx2;

          if (area_nula || (bx0 > bx1) || (by0 > by1)) st <= T_DONE;
          else                                         st <= T_SUM;
        end

        // Segunda mitad: restas y carga de los acumuladores de fila.
        T_SUM: begin
          e0  <= 36'(p00) - 36'(p01);  e0r <= 36'(p00) - 36'(p01);
          e1  <= 36'(p10) - 36'(p11);  e1r <= 36'(p10) - 36'(p11);
          e2  <= 36'(p20) - 36'(p21);  e2r <= 36'(p20) - 36'(p21);
          st  <= T_FILL;
        end

        T_E0: if (lg_done) begin lg_start <= 1'b1; st <= T_E1; end
        T_E1: if (lg_done) begin lg_start <= 1'b1; st <= T_E2; end
        T_E2: if (lg_done) st <= T_DONE;

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
  // relleno, el punto esta dentro cuando cada funcion de arista es positiva,
  // o nula sobre una arista superior o izquierda (regla top-left).
  logic dentro0, dentro1, dentro2;
  assign dentro0 = tl0 ? (e0 >= 0) : (e0 > 0);
  assign dentro1 = tl1 ? (e1 >= 0) : (e1 > 0);
  assign dentro2 = tl2 ? (e2 >= 0) : (e2 > 0);

  always_comb begin
    px_valid = 1'b0;  px_x = '0;  px_y = '0;  px_color = col;
    if ((st == T_E0) || (st == T_E1) || (st == T_E2)) begin
      px_valid = lg_valid;  px_x = lg_px;  px_y = lg_py;
      px_color = lg_color;
    end else if (st == T_FILL) begin
      px_valid = dentro0 && dentro1 && dentro2;
      px_x     = cx;        px_y = cy;
    end
  end
endmodule
