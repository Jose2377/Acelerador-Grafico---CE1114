transcript on
if {[file exists rtl_work]} {
	vdel -lib rtl_work -all
}
vlib rtl_work
vmap work rtl_work

vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/Acelerador_pkg.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/fifo.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/draw_pixel.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/draw_rect.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/draw_circle.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/draw_trian.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/draw_line.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/clip_scissor.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/addr_calc.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/pixel_gen.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/sync2.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/vga_timing.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/line_buffer.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/async_fifo.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/framebuffer_controller.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/framebuffer_onchip.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/rend_counter.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/led_status.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/Acelerador_Grafico_Top.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/decoder_fsm.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/processor_raster.sv}
vlog -sv -work work +incdir+C:/Users/Jose\ Maria\ Vindas/Documents/GitHub/Acelerador-Grafico---CE1114 {C:/Users/Jose Maria Vindas/Documents/GitHub/Acelerador-Grafico---CE1114/vga_controller.sv}

