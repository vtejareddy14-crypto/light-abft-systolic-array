# clock.xdc - one 100 MHz clock (10 ns) for every design.
create_clock -name clk -period 10.000 [get_ports clk]
# Out-of-context run: the clock comes from a global clock buffer.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
