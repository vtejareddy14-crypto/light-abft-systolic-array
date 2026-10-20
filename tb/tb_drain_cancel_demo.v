// -----------------------------------------------------------------------------
// tb_drain_cancel_demo.v - 2x2 demo: the SAME broken bit is caught by V1 but
//                          missed by V1-D (the drain version).
//
// WHAT: A = [[1,2],[3,4]], B = [[5,6],[7,8]], C = [[19,22],[43,50]], L = 134.
//       Fault: bit 3 (value 8) of PE(1,0)'s result register reads INVERTED
//       ("held-inverted", the same fault model as tb/tb_fi.v).
//         V1  : only C[1][0] is in that register: 43 -> 35 (-8).
//               The total drops to 126, L = 134, so alarm = 1.
//         V1-D: C[1][0] is hit (43 -> 35, -8) AND C[0][0] passes through the
//               same register on its way out (19 has bit 3 = 0: 19 -> 27, +8).
//               The total stays 134, so alarm = 0: two wrong numbers, no alarm.
// WHY : shows in two numbers why the cheap drain checker misses some faults
//       that the parallel checker catches (errors of opposite sign cancel).
//
// Run (from the repository root):
//   V1  : iverilog -g2005 -o v1.vvp tb/tb_drain_cancel_demo.v rtl/labft_top.v rtl/labft_checker.v rtl/sum_tree.v rtl/array_top.v rtl/systolic_array.v rtl/pe.v rtl/skew_line.v && vvp v1.vvp
//   V1-D: iverilog -g2005 -DDRAIN -o v1d.vvp tb/tb_drain_cancel_demo.v rtl/labft_top_d.v rtl/labft_checker_d.v rtl/sum_tree.v rtl/array_top_d.v rtl/systolic_array_d.v rtl/pe_d.v rtl/skew_line.v && vvp v1d.vvp
//   ModelSim: vlog the same files (add +define+DRAIN for V1-D), then vsim -c tb_drain_cancel_demo -do "run -all"
//   V1-DW (doubling total): +define+DW with rtl/labft_top_dw.v rtl/labft_checker_dw.v instead of the V1-D checker files
// -----------------------------------------------------------------------------
`ifdef DW
  `define DRAIN
  `define DRAIN_TOP labft_top_dw   // V1-DW: row by row + doubling total
`else
  `define DRAIN_TOP labft_top_d
`endif

module tb_drain_cancel_demo;
  reg clk=0; always #5 clk=~clk;
  reg rst_n, start; reg [15:0] a_col, b_row; reg inv_on;
  wire in_ready, busy, done, alarm;
`ifdef DRAIN
  wire row_valid; wire [63:0] c_row;
  `DRAIN_TOP #(.N(2),.K(2)) dut(.clk(clk),.rst_n(rst_n),.start(start),.a_col(a_col),.b_row(b_row),
    .in_ready(in_ready),.busy(busy),.row_valid(row_valid),.done(done),.c_row(c_row),.alarm(alarm));
`else
  wire [127:0] c_flat;
  labft_top #(.N(2),.K(2)) dut(.clk(clk),.rst_n(rst_n),.start(start),.a_col(a_col),.b_row(b_row),
    .in_ready(in_ready),.busy(busy),.done(done),.c_flat(c_flat),.alarm(alarm));
`endif
  always @(posedge clk) if (inv_on) begin #1; dut.u_top.u_array.g_row[1].g_col[0].u_pe.acc_out[3] = ~dut.u_top.u_array.g_row[1].g_col[0].u_pe.acc_out[3]; end
  reg [15:0] AC [0:1]; reg [15:0] BR [0:1]; integer t, s;
  initial begin
    AC[0] = {8'd3, 8'd1}; AC[1] = {8'd4, 8'd2}; BR[0] = {8'd6, 8'd5}; BR[1] = {8'd8, 8'd7};
    rst_n=0; start=0; a_col=0; b_row=0; inv_on=0; @(negedge clk); rst_n=1;
    dut.u_top.u_array.g_row[1].g_col[0].u_pe.acc_out[3] = ~dut.u_top.u_array.g_row[1].g_col[0].u_pe.acc_out[3]; inv_on=1;
    start=1; @(negedge clk); start=0; t=0; s=0;
    while (!done) begin
      if (in_ready && t<2) begin a_col=AC[t]; b_row=BR[t]; t=t+1; end else begin a_col=0; b_row=0; end
`ifdef DRAIN
      #1 if (row_valid) begin $display("row out: (%0d, %0d)   golden row %0d = %s", $signed(c_row[31:0]), $signed(c_row[63:32]), 1-s, s==0 ? "(43, 50)" : "(19, 22)"); s=s+1; end
`endif
      @(negedge clk);
    end
`ifndef DRAIN
    $display("C = [[%0d, %0d], [%0d, %0d]]   golden [[19, 22], [43, 50]]", $signed(c_flat[31:0]), $signed(c_flat[63:32]), $signed(c_flat[95:64]), $signed(c_flat[127:96]));
`endif
    $display("L = %0d, output sum seen by the checker = %0d", $signed(dut.u_chk.l_acc),
`ifdef DRAIN
      dut.u_chk.out_acc);
`else
      dut.u_chk.out_sum);
`endif
    @(negedge clk); $display("alarm = %b", alarm); $finish;
  end
endmodule
