# synth.tcl - synthesize, place and route one design on the Xilinx XC7Z020-3
# (the base paper's chip), out of context, and print LUT / FF / DSP / WNS / Fmax.
#
# Vivado Tcl console, from the repository root (forward slashes on Windows):
#   set design w3;  source synth/vivado/synth.tcl
# Designs: v0 v1 v0d v1d v2 v2d v1dw w0 w1 w2 w3 w4   (all 8 x 8)

set os  {rtl/pe.v rtl/systolic_array.v rtl/skew_line.v rtl/array_top.v rtl/sum_tree.v}
set osd {rtl/pe_d.v rtl/systolic_array_d.v rtl/skew_line.v rtl/array_top_d.v rtl/sum_tree.v}
set ws  {rtl/pe_ws.v rtl/systolic_array_ws.v rtl/skew_line.v rtl/ws_top.v rtl/sum_tree.v}
array set rtl [list \
    v0   $os \
    v1   [concat $os  rtl/labft_checker.v rtl/labft_top.v] \
    v2   [concat $os  rtl/labft_checker.v rtl/labft_top_2.v] \
    v0d  $osd \
    v1d  [concat $osd rtl/labft_checker_d.v rtl/labft_top_d.v] \
    v2d  [concat $osd rtl/labft_checker_d.v rtl/labft_top_d2.v] \
    v1dw [concat $osd rtl/labft_checker_dw.v rtl/labft_top_dw.v] \
    w0   $ws \
    w1   [concat $ws  rtl/labft_checker_ws.v rtl/labft_top_ws.v] \
    w2   [concat $ws  rtl/labft_checker_ws.v rtl/labft_top_ws2.v] \
    w3   [concat $ws  rtl/labft_checker_ws_w.v rtl/labft_top_ws3.v] \
    w4   [concat $ws  rtl/labft_checker_ws_w.v rtl/labft_top_ws4.v]]

set part   xc7z020clg484-3
set period 10.0
set top    top_${design}_N8
file mkdir reports

create_project -in_memory -part $part
read_verilog [concat $rtl($design) synth/vivado/tops/${top}.v]
read_xdc synth/vivado/clock.xdc
# out_of_context: more data ports than the chip has pins
# keep_equivalent_registers: keeps both copies of a duplicated checker
synth_design -top $top -part $part -mode out_of_context -keep_equivalent_registers
opt_design
place_design
route_design
report_utilization -file reports/${design}_util.rpt
report_utilization -hierarchical -file reports/${design}_util_hier.rpt
report_timing_summary -max_paths 5 -file reports/${design}_timing.rpt

proc used {txt name} {
    if {[regexp "\\|\\s*${name}\\*?\\s*\\|\\s*(\[0-9.\]+)" $txt -> n]} { return $n }
    return "?"
}
set util [report_utilization -return_string]
set wns  [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set fmax [format "%.1f" [expr {1000.0 / ($period - $wns)}]]
puts "RESULT $design: LUT=[used $util {Slice LUTs}] FF=[used $util {Slice Registers}] DSP=[used $util DSPs] WNS=$wns ns Fmax=$fmax MHz"
close_project
