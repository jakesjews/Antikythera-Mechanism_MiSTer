# The wrapper supplies a 50 MHz PLL clock with a 25 MHz pixel enable.
# Root clocks and framework clock-domain exceptions are in sys/sys_top.sdc.
derive_pll_clocks
derive_clock_uncertainty

# Every register of the renderer is enabled by the pixel clock enable, so the
# logic between them has two 50 MHz cycles. The enable itself stays single-cycle.
set_multicycle_path -setup -end 2 -from [get_registers {*|am_video:*|*}] -to [get_registers {*|am_video:*|*}]
set_multicycle_path -hold -end 1 -from [get_registers {*|am_video:*|*}] -to [get_registers {*|am_video:*|*}]
set_multicycle_path -setup -end 1 -from [get_registers {*|am_video:*|divider}]
set_multicycle_path -hold -end 0 -from [get_registers {*|am_video:*|divider}]
