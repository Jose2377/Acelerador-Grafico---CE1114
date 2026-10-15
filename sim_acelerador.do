#==============================================================================
# sim_acelerador.do
# Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
#
# Simulacion del acelerador a resolucion reducida (64 x 48), independiente de
# Quartus y de NativeLink.
#
# POR QUE EXISTE ESTE SCRIPT
#
# Desde que el nivel superior del proyecto es DE1_SoC_top_level, NativeLink le
# entrega a ModelSim todos los archivos del proyecto, incluidos los del HPS que
# genero Platform Designer. Uno de ellos,
#
#   Platform_Designer/synthesis/submodules/soc_system_hps_0_hps_io_border.sv
#
# usa la senal "intermediate" en la linea 57 y la declara hasta la linea 64.
# Verilog-2001 lo acepta como red implicita; SystemVerilog no, y vlog -sv falla
# con "Undefined variable: 'intermediate'" seguido de "already declared in this
# scope". Quartus compila ese archivo sin problema, de modo que el error es
# exclusivamente del flujo de simulacion.
#
# Parchear el archivo no sirve: Platform Designer lo regenera en cada
# "Generate HDL". La salida correcta es no compilarlo, y no hace ninguna falta:
# los dos bancos de pruebas instancian Acelerador_Grafico_Top directamente y no
# tocan el HPS, ni el banco de registros, ni el wrapper. Aqui se compila
# unicamente lo que el banco de pruebas necesita.
#
# USO
#
#   En la consola de ModelSim, situarse en la carpeta del proyecto y ejecutar:
#
#     cd {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114}
#     do sim_acelerador.do
#
#   Para la escena del faro, cambiar TB mas abajo por tb_escena_faro.
#
# NOTA SOBRE LA RESOLUCION
#
# Los bancos de pruebas fijan W = 64 y H = 48, que son los valores del paquete.
# Los parametros de temporizacion de video de Acelerador_Grafico_Top toman sus
# valores por defecto, tambien del paquete, de modo que esta simulacion es
# identica a la de siempre. La tabla VESA de 640 x 480 solo la aplica el
# wrapper de placa, que aqui no participa.
#==============================================================================

set TB tb_Acelerador_Grafico_Top
# set TB tb_escena_faro

#------------------------------------------------------------------ biblioteca
if {[file isdirectory work]} {
  vdel -lib work -all
}
vlib work
vmap work work

#--------------------------------------------------------------- el paquete va
# primero, porque todo lo demas lo importa.
vlog -sv Acelerador_pkg.sv

#------------------------------------------------------------------------- RTL
# El orden entre estos no importa: vlog resuelve las instancias al elaborar.
set RTL {
  fifo.sv
  decoder_fsm.sv
  processor_raster.sv
  draw_pixel.sv
  draw_rect.sv
  draw_circle.sv
  draw_trian.sv
  draw_line.sv
  clip_scissor.sv
  addr_calc.sv
  pixel_gen.sv
  sync2.sv
  vga_timing.sv
  line_buffer.sv
  vga_controller.sv
  async_fifo.sv
  framebuffer_controller.sv
  framebuffer_onchip.sv
  rend_counter.sv
  led_status.sv
  Acelerador_Grafico_Top.sv
}

foreach archivo $RTL {
  vlog -sv $archivo
}

#--------------------------------------------------------------- banco de pruebas
vlog -sv $TB.sv

#------------------------------------------------------------------- simulacion
# +acc mantiene visibles las senales internas para poder sondear la jerarquia.
vsim -voptargs=+acc work.$TB

add wave -position insertpoint sim:/$TB/*

run -all
