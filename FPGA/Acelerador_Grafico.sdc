#==============================================================================
# Acelerador_Grafico.sdc
# Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
# Archivo  : Restricciones de temporizacion del nivel de placa (DE1_SoC_top_level)
#
# Sin este archivo el analizador de tiempos solo conoce los relojes del HPS
# (los SDC de Platform Designer) y deja CLOCK_50 sin restringir, de modo que
# los relojes del PLL (100 MHz de rasterizado/SDRAM y el de pixel) y toda la
# logica del acelerador quedan fuera del analisis.
#
# Relojes, todos del PLL pll_0 dentro de soc_system:
#   general[0]  outclk0  100 MHz,           clk_sys: rasterizado, SDRAM, puente
#   general[1]  outclk1  100 MHz desfasado, solo hacia el pin DRAM_CLK
#   general[2]  outclk2  reloj de pixel,    clk_pix: barrido VGA
#
# Dominios asincronos: clk_sys y clk_pix no guardan relacion de fase util.
# Todo lo que cruza entre ellos pasa por sync2 (un bit) o por las async_fifo
# del gestor de framebuffer (punteros en Gray), asi que se declaran como
# grupos asincronos y el analizador no intenta cerrar esos caminos.
#==============================================================================

#------------------------------------------------------------ Reloj de entrada
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

#----------------------------------------------------- Relojes derivados del PLL
derive_pll_clocks
derive_clock_uncertainty

# Nombres que crea derive_pll_clocks, resueltos por patron para no depender de
# la ruta jerarquica completa que genera Platform Designer.
set clk_sys   [get_clocks {*pll_0*general[0]*divclk}]
set clk_sdram [get_clocks {*pll_0*general[1]*divclk}]
set clk_pix   [get_clocks {*pll_0*general[2]*divclk}]

#------------------------------------------------- Relojes que salen por pines
# DRAM_CLK: copia de outclk1 en el pin, referencia de las restricciones de E/S
# de la SDRAM.
create_generated_clock -name sdram_clk_pin \
  -source [get_pins -compatibility_mode {*pll_0*general[1]*divclk}] \
  [get_ports {DRAM_CLK}]

# VGA_CLK: copia de clk_pix en el pin, referencia del conversor ADV7123.
create_generated_clock -name vga_clk_pin \
  -source [get_pins -compatibility_mode {*pll_0*general[2]*divclk}] \
  [get_ports {VGA_CLK}]

#------------------------------------------------------- Grupos de reloj
# clk_sys, el reloj desfasado de la SDRAM y su copia en el pin son sincronos
# entre si (mismo PLL, misma frecuencia). El dominio de pixel es asincrono.
set_clock_groups -asynchronous \
  -group [list $clk_sys $clk_sdram [get_clocks {sdram_clk_pin}]] \
  -group [list $clk_pix [get_clocks {vga_clk_pin}]]

#------------------------------------------------- SDRAM IS42S16320D (lado FPGA)
# Valores de la hoja de datos (grado -7, CL = 3) mas ~0,5 ns de pista:
#   tAC  (acceso)       5,4 ns   ->  input  max  5,9
#   tOH  (retencion)    2,7 ns   ->  input  min  3,0
#   tIS  (preparacion)  1,5 ns   ->  output max  1,6 (con pista)
#   tIH  (retencion)    0,8 ns   ->  output min -0,9 (con pista)
set sdram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N \
                          DRAM_LDQM DRAM_UDQM DRAM_RAS_N DRAM_WE_N DRAM_DQ[*]}]

set_input_delay  -clock sdram_clk_pin -max  5.9 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock sdram_clk_pin -min  3.0 [get_ports {DRAM_DQ[*]}]
set_output_delay -clock sdram_clk_pin -max  1.6 $sdram_out
set_output_delay -clock sdram_clk_pin -min -0.9 $sdram_out

#------------------------------------------------- Conversor de video ADV7123
# tS = 0,2 ns, tH = 1,5 ns respecto al flanco de subida de VGA_CLK.
set vga_out [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS VGA_BLANK_N VGA_SYNC_N}]

set_output_delay -clock vga_clk_pin -max  0.2 $vga_out
set_output_delay -clock vga_clk_pin -min -1.5 $vga_out

#------------------------------------------------- Entradas y salidas lentas
# KEY_N es un pulsador asincrono; el reinicio se suelta de forma sincrona en
# cada dominio dentro de DE1_SoC_top_level. LEDR solo lo mira una persona.
set_false_path -from [get_ports {KEY_N[*]}]
set_false_path -to   [get_ports {LEDR[*]}]
