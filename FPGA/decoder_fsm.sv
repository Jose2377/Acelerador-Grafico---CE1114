`timescale 1ns / 1ps

//=============================================================================
// decoder_fsm.sv
// Modulo : Decodificador de comandos y maquina de estados del sistema
//
// Es el cerebro del acelerador: saca comandos de la cola de uno en uno,
// los valida, los traduce y gobierna los seis modos de operacion (MOE) que el registro STATUS publica al HPS.
//
// Ciclo de trabajo de un comando de dibujo:
//   MOE_IDLE  Hay algo en la cola y enable esta alto: se pide un comando
//   MOE_PROC  Llega el dato (un ciclo despues de pedirlo), se valida y se presentan los argumentos al rasterizador
//   MOE_WAIT  Espera el done del rasterizador
//   MOE_IDLE  Se contabiliza el comando y se vuelve a empezar
//
// Los tres codigos que no dibujan se resuelven sin tocar el rasterizador:
//   NOP   Se descarta y se cuenta
//   SWAP  Pasa por MOE_SWAP, que espera el flanco de VSYNC antes de cambiar buffer_sel. 
//         Intercambiar fuera del intervalo vertical partiria la imagen por la mitad (tearing), 
//         asi que la peticion se retiene hasta que el barrido este entre cuadros.
//   INF   Pasa por MOE_INFO, que congela la ventana de medicion con perf_latch y la reabre con perf_clear
//
// Errores que el hardware puede detectar por si mismo:
//   EC-06  codigo de operacion desconocido
//   EC-07  parametro geometrico invalido (radio nulo en los circulos)
//   EC-08  desbordamiento de la cola
// Los tres llevan a MOE_ERROR, que dura un solo ciclo y solo sirve para que el modo sea observable. 
// EC-01 a EC-04 los emite la capa de software y nunca llegan hasta aqui.
//
// El desbordamiento es asincrono respecto al flujo de comandos: 
// Lo senala la cola en cualquier momento, incluso con una figura en curso. 
// Por eso se anota en err_pend y el paso por MOE_ERROR se hace al volver a MOE_IDLE, 
// en lugar de interrumpir lo que se este dibujando.
//
// modo publica MOE_PROC tambien durante MOE_WAIT: 
// La espera al rasterizador es un detalle interno y el HPS solo debe ver seis modos.
//
// Entradas:
//   clk, rst_n            Reloj de rasterizado y reinicio
//   enable, soft_reset    Bits del registro CONTROL
//
//   Estados y datos de la cola de comandos:
//   fifo_empty, fifo_data_out, fifo_data_out_valid, fifo_drop
//   Si esta vacia, el data, si el data es valido, y desborde
//
//   ras_busy, ras_done    Señal si el rasterizador esta ocupado o acaba de terminar
//   vsync                 Sincronismo vertical del controlador VGA
//
// Salidas
//   fifo_rd               Extrae el paquete siguiente de la cola
//   ras_start             Arranca el rasterizador con los argumentos de abajo
//   ras_op                Codigo de operacion del comando
//   ras_x0 .. ras_y2      Vertices y coordenadas del comando
//   ras_radius            Radio, para el circulo
//   ras_r, ras_g, ras_b   Color del comando en RGB888
//   buffer_sel            Buffer delantero, 0 = A y 1 = B; se cambia en VSYNC
//   perf_latch            Congela la ventana de medicion al decodificar INF
//   perf_clear            Abre una ventana de medicion nueva
//   modo                  Modo del sistema, MOE-01 a MOE-06, para STATUS y los LED
//   busy                  Si hay un comando ejecutandose
//   err_last, err_count   Ultimo codigo de error y cantidad de errores.
//   comand_count          Comandos aceptados y completados
//   comand_tick           Aviso de un comando completado
//   seq_last              SEQ_ID del ultimo comando aceptado
//=============================================================================
module decoder_fsm #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic        clk,             // Reloj del sistema
  input  logic        rst_n,           // Reset del sistema
  input  logic        enable,          // Bit enable del registro CONTROL
  input  logic        soft_reset,      // Bit reset_soft del registro CONTROL

  // FIFO
  input  logic        fifo_empty,          // Si el fifo esta vacia
  input  logic [Acelerador_pkg::COMAND_BITS-1:0] fifo_data_out, // Data de salida
  input  logic        fifo_data_out_valid, // Si el data de salida es valido
  input  logic        fifo_drop,           // Desborde del fifo
  output logic        fifo_rd,             // Lectura del fifo

  // Rasterizador
  output logic        ras_start,
  output logic [3:0]  ras_op,
  output logic signed [15:0] ras_x0, ras_y0, ras_x1, ras_y1, ras_x2, ras_y2, // Vertices y coordenadas del comando
  output logic [9:0]  ras_radius,          // Radio, para el circulo
  output logic [7:0]  ras_r, ras_g, ras_b, // Color del comando en RGB888
  input  logic        ras_busy,            // Señal si hay un comando ejecutandose
  input  logic        ras_done,            // Señal si el rasterizador termino

  // Medicion
  input  logic        vsync,           // Controlador VGA
  output logic        buffer_sel,      // 0 = buffer A delante, 1 = buffer B
  output logic        perf_latch,      // Congelar la ventana de medicion
  output logic        perf_clear,      // Reiniciar la ventana de medicion

  // Estado
  output logic [2:0]  modo,            // MOE-01 a MOE-06, para STATUS y LED
  output logic        busy,            // Si el rasterizador esta ocupado
  output logic [3:0]  err_last,        // Ultimo codigo de error
  output logic [15:0] err_count,       // Cantidad de errores
  output logic [31:0] comand_count,    // Comandos aceptados y completados
  output logic        comand_tick,     // Un comando completado
  output logic [15:0] seq_last         // SEQ_ID del ultimo comando aceptado
);

  localparam int INIT_CICLOS = 4;      // Ciclos de inicio MOE-01

  Acelerador_pkg::sys_state_e st;      // Estado para maquina de estado

  logic [2:0] init_cnt;                // Cuenta ciclos de inicio
  logic       err_pend;                // Error detectado
  logic       vsync_q;                 // Para detectar el flanco

  Acelerador_pkg::comand_t comand_in;
  assign comand_in = fifo_data_out;    // Comando de entrada

  // Validar valores, principalmente del circulo
  function automatic logic parametros_validos(input Acelerador_pkg::comand_t c);
    case (c.opcode)
      Acelerador_pkg::OPC_CIRC,
      Acelerador_pkg::OPC_CIRC_FILL: parametros_validos = (c.param != 16'd0);
      default:                       parametros_validos = 1'b1;
    endcase
  endfunction

  // Deteccion de errores
  logic       comand_ready;
  logic       err_opcode, err_param, err_comand;
  logic [1:0] err_inc;
  logic [3:0] err_cod;

  // Asigna valores segun estados y variables.
  assign comand_ready  = (st == Acelerador_pkg::MOE_PROC) && fifo_data_out_valid;
  assign err_opcode = comand_ready && !Acelerador_pkg::opcode_valido(comand_in.opcode);
  assign err_param  = comand_ready && !err_opcode && !parametros_validos(comand_in);
  assign err_comand = err_opcode || err_param;
  assign err_inc    = {1'b0, err_comand} + {1'b0, fifo_drop};

  // err_last manda el error del comando, porque es el que lleva al sistema a MOE-06 en este instante. 
  always_comb begin
    if      (err_opcode) err_cod = Acelerador_pkg::EC_06_OPCODE;
    else if (err_param)  err_cod = Acelerador_pkg::EC_07_PARAM;
    else                 err_cod = Acelerador_pkg::EC_08_OVERFLOW;
  end

  always_comb begin
    if (st == Acelerador_pkg::MOE_WAIT) modo = Acelerador_pkg::MOE_PROC;
    else                                modo = st;
  end

  assign busy = (st != Acelerador_pkg::MOE_IDLE); // Si esta ocupado

  // Registro de errores y contador
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin //Reset
      err_last  <= Acelerador_pkg::EC_NONE;
      err_count <= '0;
    end else if (st == Acelerador_pkg::MOE_INIT) begin // Inicio
      err_last  <= Acelerador_pkg::EC_NONE;
      err_count <= '0;
    end else if (err_inc != 2'd0) begin // Cuenta errores
      err_last  <= err_cod;
      // Satura en lugar de dar la vuelta
      if (err_count < (16'hFFFF - 16'(err_inc))) err_count <= err_count + 16'(err_inc);
      else                                        err_count <= 16'hFFFF;
    end
  end

  // Maquina de estados
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin // Reset
      st         <= Acelerador_pkg::MOE_INIT;
      init_cnt   <= '0;
      fifo_rd    <= 1'b0;
      ras_start  <= 1'b0;
      ras_op     <= '0;
      ras_x0 <= '0; ras_y0 <= '0; ras_x1 <= '0; ras_y1 <= '0;
      ras_x2 <= '0; ras_y2 <= '0;
      ras_radius <= '0;
      ras_r <= '0;  ras_g <= '0;  ras_b <= '0;
      buffer_sel <= 1'b0;
      perf_latch <= 1'b0;
      perf_clear <= 1'b0;
      comand_count  <= '0;
      comand_tick   <= 1'b0;
      seq_last   <= '0;
      err_pend   <= 1'b0;
      vsync_q    <= 1'b0;
    end else begin
      // Pulsos de un solo ciclo
      fifo_rd    <= 1'b0;
      ras_start  <= 1'b0;
      perf_latch <= 1'b0;
      perf_clear <= 1'b0;
      comand_tick   <= 1'b0;
      vsync_q    <= vsync;

      // Un desbordamiento deja pendiente el paso por MOE-06
      if (fifo_drop) err_pend <= 1'b1;

      if (soft_reset) begin // Reset
        st       <= Acelerador_pkg::MOE_INIT;
        init_cnt <= '0;
      end else begin
        case (st)

          // MOE-01 Inicio
          Acelerador_pkg::MOE_INIT: begin // Asigna variables iniciales
            comand_count  <= '0;
            buffer_sel <= 1'b0;
            seq_last   <= '0;
            err_pend   <= 1'b0;
            if (init_cnt == INIT_CICLOS[2:0]) begin // Si ya inicio
              init_cnt <= '0;
              st       <= Acelerador_pkg::MOE_IDLE; 
            end else begin // Cuenta ciclos de inicio
              init_cnt <= init_cnt + 3'd1;
            end
          end

          // MOE-02 Espera
          Acelerador_pkg::MOE_IDLE: begin
            if (err_pend) begin // Si hay un desbordamiento sin senalizar y nada en curso: es el momento de pasar por MOE-06.
              st <= Acelerador_pkg::MOE_ERROR;
            end else if (enable && !fifo_empty) begin // Si hay un comando en espera y nada en curso: es el momento de pasar a MOE-03
              fifo_rd <= 1'b1;
              st      <= Acelerador_pkg::MOE_PROC;
            end
          end

          // MOE-03 Procesamiento
          Acelerador_pkg::MOE_PROC: begin
            // El dato llega un ciclo despues de pedirlo, por eso verifica si es valido.
            if (fifo_data_out_valid) begin
              if (err_comand) begin // Si presenta un error de comando, pasar a error.
                st <= Acelerador_pkg::MOE_ERROR;
              end else begin // Caso estandar, se empieza a procesar el comando.
                seq_last <= comand_in.seq_id;

                case (comand_in.opcode) // Comandos especiales: NOP Vacia y nada, SWAP cambio de buffer,  INF informe.
                  Acelerador_pkg::OPC_NOP: begin // NOP: No hace nada.
                    comand_count <= comand_count + 32'd1;
                    comand_tick  <= 1'b1;
                    st        <= Acelerador_pkg::MOE_IDLE;
                  end

                  Acelerador_pkg::OPC_SWAP: begin // Swap
                    st <= Acelerador_pkg::MOE_SWAP;
                  end

                  Acelerador_pkg::OPC_INF: begin // Informe
                    perf_latch <= 1'b1;
                    st         <= Acelerador_pkg::MOE_INFO;
                  end

                  default: begin // Comando de dibujo: se presentan argumentos y se llama al rasterizador en el mismo ciclo.
                    ras_op     <= Acelerador_pkg::opcode_a_op(comand_in.opcode);
                    ras_x0     <= comand_in.x0;  ras_y0 <= comand_in.y0;
                    ras_x1     <= comand_in.x1;  ras_y1 <= comand_in.y1;
                    ras_x2     <= comand_in.x2;  ras_y2 <= comand_in.y2;
                    ras_radius <= comand_in.param[9:0];
                    ras_r      <= comand_in.r;
                    ras_g      <= comand_in.g;
                    ras_b      <= comand_in.b;
                    ras_start  <= 1'b1;
                    st         <= Acelerador_pkg::MOE_WAIT;
                  end
                endcase
              end
            end
          end

          // Espera al rasterizador
          Acelerador_pkg::MOE_WAIT: begin
            if (ras_done) begin // Si ya termino, cuenta el trabajo.
              comand_count <= comand_count + 32'd1;
              comand_tick  <= 1'b1;
              st        <= Acelerador_pkg::MOE_IDLE;
            end
          end

          // MOE-04 Swap Buffer
          // El intercambio se solicita aqui pero solo se hace efectivo en el flanco de sincronizacion vertical
          Acelerador_pkg::MOE_SWAP: begin
            if (vsync && !vsync_q) begin
              buffer_sel <= ~buffer_sel;
              comand_count  <= comand_count + 32'd1;
              comand_tick   <= 1'b1;
              st         <= Acelerador_pkg::MOE_IDLE;
            end
          end

          // MOE-05 Informe
          Acelerador_pkg::MOE_INFO: begin
            // Los contadores quedaron congelados por perf_latch al decodificar
            // INF; aqui se reinicia la ventana de medicion y se continua.
            perf_clear <= 1'b1;
            comand_count  <= comand_count + 32'd1;
            comand_tick   <= 1'b1;
            st         <= Acelerador_pkg::MOE_IDLE;
          end

          // MOE-06 Error
          // Un solo ciclo. El error ya quedo contabilizado en el bloque de registro,
			 // Solo consume la senalizacion pendiente. 
          // Si en este mismo ciclo llega otro desbordamiento,
          // La pendiente se mantiene y se vuelve a pasar por el modo.
          Acelerador_pkg::MOE_ERROR: begin
            if (!fifo_drop) err_pend <= 1'b0;
            st <= Acelerador_pkg::MOE_IDLE;
          end

          default: st <= Acelerador_pkg::MOE_INIT;
        endcase
      end
    end
  end

endmodule
