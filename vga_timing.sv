module vga_timing #(
  parameter int H_VISIBLE = 640,
  parameter int H_FRONT   = 16,
  parameter int H_SYNC    = 96,
  parameter int H_BACK    = 48,
  parameter int V_VISIBLE = 480,
  parameter int V_FRONT   = 10,
  parameter int V_SYNC    = 2,
  parameter int V_BACK    = 33,
  parameter bit H_POL     = 1'b0,      // Nivel activo de la sincronizacion
  parameter bit V_POL     = 1'b0
)(
  input  logic clk_pix,
  input  logic rst_n,

  output logic hsync,
  output logic vsync,
  output logic data_active,                     // Dato activo: dentro de la region visible
  output logic [$clog2(H_VISIBLE)-1:0] pix_x,
  output logic [$clog2(V_VISIBLE)-1:0] pix_y,

  output logic linea_fin,              // Ultimo pixel visible de una linea
  output logic cuadro_inicio,          // Primer ciclo del intervalo vertical
  output logic vsync_act               // Sincronismo vertical, activo en alto
);

  localparam int H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
  localparam int V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;
  localparam int HCW     = $clog2(H_TOTAL);
  localparam int VCW     = $clog2(V_TOTAL);

  localparam int H_SYNC_INI = H_VISIBLE + H_FRONT;
  localparam int H_SYNC_FIN = H_VISIBLE + H_FRONT + H_SYNC;   // exclusivo
  localparam int V_SYNC_INI = V_VISIBLE + V_FRONT;
  localparam int V_SYNC_FIN = V_VISIBLE + V_FRONT + V_SYNC;   // exclusivo

  logic [HCW-1:0] hcnt;
  logic [VCW-1:0] vcnt;

  // Contadores
  always_ff @(posedge clk_pix or negedge rst_n) begin
    if (!rst_n) begin
      hcnt <= '0;
      vcnt <= '0;
    end else if (hcnt == HCW'(H_TOTAL - 1)) begin
      hcnt <= '0;
      vcnt <= (vcnt == VCW'(V_TOTAL - 1)) ? '0 : vcnt + 1'b1;
    end else begin
      hcnt <= hcnt + 1'b1;
    end
  end

  // Salidas
  logic h_visible, v_visible, h_en_sync, v_en_sync;

  assign h_visible = (hcnt < HCW'(H_VISIBLE));
  assign v_visible = (vcnt < VCW'(V_VISIBLE));
  assign h_en_sync = (hcnt >= HCW'(H_SYNC_INI)) && (hcnt < HCW'(H_SYNC_FIN));
  assign v_en_sync = (vcnt >= VCW'(V_SYNC_INI)) && (vcnt < VCW'(V_SYNC_FIN));

  assign hsync = h_en_sync ? H_POL : ~H_POL;
  assign vsync = v_en_sync ? V_POL : ~V_POL;
  assign data_active    = h_visible && v_visible;

  // Solo se usan cuando data_active vale 1.
  assign pix_x = hcnt[$clog2(H_VISIBLE)-1:0];
  assign pix_y = vcnt[$clog2(V_VISIBLE)-1:0];

  // Version activa en alto del sincronismo vertical.
  assign vsync_act = v_en_sync;

  assign linea_fin = v_visible && (hcnt == HCW'(H_VISIBLE - 1));

  // Primer ciclo del intervalo vertical. 
  assign cuadro_inicio = (vcnt == VCW'(V_VISIBLE)) && (hcnt == '0);

endmodule
