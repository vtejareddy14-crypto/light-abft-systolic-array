// -----------------------------------------------------------------------------
// tb_ws_cancel_demo.v - 2x2 demo on the weight-stationary design (W1):
//                       does the run C / run D fault cancel here too?
//
// WHAT: A = [[1,2],[3,4]], B = [[5,6],[7,8]], C = [[19,22],[43,50]], L = 134.
//       Same fault as runs C and D: bit 3 (value 8) of a partial-sum register
//       reads INVERTED, for the whole run. Default: PE(1,0), the bottom PE of
//       column 0 (+fault_t / +fault_j choose another PE).
//       In WS, the results of column 0 (19, then 43) both pass through that
//       register on their way out:
//         19 = 010011 (bit 3 = 0) -> 27  (+8)
//         43 = 101011 (bit 3 = 1) -> 35  (-8)
//       Total 27 + 35 + 22 + 50 = 134 = L -> no alarm: two wrong results.
// WHY : shows whether the paper's own dataflow has the same blind spot as
//       our row-by-row readout (V1-D, run D).
//
// The fault model is the one used in runs C/D and in the campaigns
// (tb/tb_fi.v): the bit is re-inverted right after every rising edge.
//
// ModelSim:
//   vlog rtl/pe_ws.v rtl/systolic_array_ws.v rtl/skew_line.v rtl/sum_tree.v \
//        rtl/ws_top.v rtl/labft_checker_ws.v rtl/labft_top_ws.v tb/tb_ws_cancel_demo.v
//   vsim -c tb_ws_cancel_demo -do "run -all"
//   (no fault, for comparison: add +nofault)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

`ifdef W3
  `define WS_TOP labft_top_ws3
`else
  `define WS_TOP labft_top_ws
`endif

module tb_ws_cancel_demo;

    reg clk = 0; always #5 clk = ~clk;
    reg rst_n, start; reg [15:0] w_row, a_row; reg inv_on;
    wire w_ready, in_ready, busy, done, alarm;
    wire [1:0]  col_valid;
    wire [63:0] c_bot;

    `WS_TOP #(.N(2), .K(2)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .w_row(w_row), .a_row(a_row),
        .w_ready(w_ready), .in_ready(in_ready), .busy(busy), .done(done),
        .col_valid(col_valid), .c_bot(c_bot), .alarm(alarm));

    integer f_t, f_j;

    // invert bit 3 of the chosen psum register right after every rising edge
    task flip;
        begin
            case ({f_t[0], f_j[0]})
                2'b00: dut.u_top.u_array.g_row[0].g_col[0].u_pe.psum_out[3] = ~dut.u_top.u_array.g_row[0].g_col[0].u_pe.psum_out[3];
                2'b01: dut.u_top.u_array.g_row[0].g_col[1].u_pe.psum_out[3] = ~dut.u_top.u_array.g_row[0].g_col[1].u_pe.psum_out[3];
                2'b10: dut.u_top.u_array.g_row[1].g_col[0].u_pe.psum_out[3] = ~dut.u_top.u_array.g_row[1].g_col[0].u_pe.psum_out[3];
                2'b11: dut.u_top.u_array.g_row[1].g_col[1].u_pe.psum_out[3] = ~dut.u_top.u_array.g_row[1].g_col[1].u_pe.psum_out[3];
            endcase
        end
    endtask
    always @(posedge clk) if (inv_on) begin #1; flip; end

    reg [15:0] BR [0:1];   // rows of B (weights)
    reg [15:0] AR [0:1];   // rows of A (activations)
    integer t, m;

    initial begin
        if (!$value$plusargs("fault_t=%d", f_t)) f_t = 1;
        if (!$value$plusargs("fault_j=%d", f_j)) f_j = 0;
        BR[0] = {8'd6, 8'd5}; BR[1] = {8'd8, 8'd7};    // B = [5 6; 7 8]
        AR[0] = {8'd2, 8'd1}; AR[1] = {8'd4, 8'd3};    // A = [1 2; 3 4]
        if ($test$plusargs("nofault"))
            $display("no fault");
        else
            $display("fault: bit 3 of PE(%0d,%0d)'s psum register reads inverted", f_t, f_j);

        rst_n = 0; start = 0; w_row = 0; a_row = 0; inv_on = 0;
        @(negedge clk); rst_n = 1;
        if (!$test$plusargs("nofault")) begin flip; inv_on = 1; end
        start = 1; @(negedge clk); start = 0; t = 0; m = 0;
        while (!done) begin
            #1;
            if (col_valid[0]) $display("column 0 out: %0d", $signed(c_bot[31:0]));
            if (col_valid[1]) $display("column 1 out: %0d", $signed(c_bot[63:32]));
            w_row = 0; a_row = 0;
            if (w_ready && t < 2) begin w_row = BR[t]; t = t + 1; end
            if (in_ready && m < 2) begin a_row = AR[m]; m = m + 1; end
            @(negedge clk);
        end
        $display("golden: column 0 = 19, 43   column 1 = 22, 50");
        $display("L = %0d, output sum seen by the checker = %0d",
                 $signed(dut.u_chk.l_acc), $signed(dut.u_chk.s_acc));
        @(negedge clk);
        $display("alarm = %b", alarm);
        $finish;
    end

endmodule
