// -----------------------------------------------------------------------------
// tb_ws_standalone.v - self-checking testbench for labft_top_ws (W1).
//
// WHAT: like tb_standalone.v (run A) but for the weight-stationary design.
//       Makes NTEST random int8 matrix pairs with $random (fixed SEED),
//       computes the correct C, loads B as the weights, streams A, collects
//       the results as they leave the bottom of the array, compares every
//       element, and prints PASS/FAIL and the alarm. Optionally ONE fault.
//
// Parameters (-g in ModelSim, -P in Icarus): N, NTEST, SEED.  (K = N.)
//
// Optional fault (without +fault_site there is no fault):
//   +fault_site=psum|w|aout|lacc   psum_out / weight / a_out of PE(t,j),
//                                  or the checker's L register
//   +fault_t=<row> +fault_j=<col>  which PE, default 0 0
//   +fault_bit=<b>                 which bit, default 0
//   +fault_mode=stuck0|stuck1      default stuck1 (held for the whole run)
// The chosen bit is overwritten at every falling clock edge, so the logic
// always sees the stuck value.
//
// ModelSim:
//   vlog rtl/pe_ws.v rtl/systolic_array_ws.v rtl/skew_line.v rtl/sum_tree.v \
//        rtl/ws_top.v rtl/labft_checker_ws.v rtl/labft_top_ws.v tb/tb_ws_standalone.v
//   vsim -c tb_ws_standalone -do "run -all"
//   vsim -c tb_ws_standalone +fault_site=psum +fault_t=1 +fault_j=2 +fault_bit=5 -do "run -all"
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

`ifdef W3
  `define WS_TOP labft_top_ws3
`else
  `define WS_TOP labft_top_ws
`endif

module tb_ws_standalone;

    parameter N     = 4;
    parameter NTEST = 20;
    parameter SEED  = 1;

    localparam K = N, DW = 8, AW = 32;

    // ---- DUT ----
    reg                clk = 1'b0;
    reg                rst_n, start;
    reg  [N*DW-1:0]    w_row, a_row;
    wire               w_ready, in_ready, busy, done, alarm;
    wire [N-1:0]       col_valid;
    wire [N*AW-1:0]    c_bot;

    always #5 clk = ~clk;

    `WS_TOP #(.N(N), .K(K)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .w_row(w_row), .a_row(a_row),
        .w_ready(w_ready), .in_ready(in_ready), .busy(busy), .done(done),
        .col_valid(col_valid), .c_bot(c_bot), .alarm(alarm));

    // ---- matrices, golden result, collected result ----
    reg signed [DW-1:0] A [0:N-1][0:K-1];
    reg signed [DW-1:0] B [0:K-1][0:N-1];
    integer             C  [0:N-1][0:N-1];   // golden (32-bit wrap)
    integer             CH [0:N-1][0:N-1];   // what came out of the array
    integer             got [0:N-1];         // results seen per column

    integer seed, test, i, j, t, m, rc, wrong, n_det, n_sil, n_fa, n_ben;

    // ---- fault settings ----
    reg [8*8-1:0] f_site, f_mode;
    reg           f_on;
    integer       f_t, f_j, f_bit;
    event         apply_fault;

    function new_bit;
        input old;
        begin
            new_bit = (f_mode == "stuck0") ? 1'b0 : 1'b1;
        end
    endfunction

    genvar gt, gj;
    generate
        for (gt = 0; gt < N; gt = gt + 1) begin : g_fi_row
            for (gj = 0; gj < N; gj = gj + 1) begin : g_fi_col
                always @(apply_fault) begin
                    if (f_on && f_t == gt && f_j == gj) begin
                        if (f_site == "psum")
                            dut.u_top.u_array.g_row[gt].g_col[gj].u_pe.psum_out[f_bit] =
                                new_bit(dut.u_top.u_array.g_row[gt].g_col[gj].u_pe.psum_out[f_bit]);
                        if (f_site == "w")
                            dut.u_top.u_array.g_row[gt].g_col[gj].u_pe.w[f_bit] =
                                new_bit(dut.u_top.u_array.g_row[gt].g_col[gj].u_pe.w[f_bit]);
                        if (f_site == "aout")
                            dut.u_top.u_array.g_row[gt].g_col[gj].u_pe.a_out[f_bit] =
                                new_bit(dut.u_top.u_array.g_row[gt].g_col[gj].u_pe.a_out[f_bit]);
                    end
                end
            end
        end
    endgenerate

    always @(apply_fault)
        if (f_on && f_site == "lacc")
            dut.u_chk.l_acc[f_bit] = new_bit(dut.u_chk.l_acc[f_bit]);

    task step;
        begin
            @(negedge clk);
            -> apply_fault;
            #1;
        end
    endtask

    // collect the results leaving the bottom of the array in this cycle
    task collect;
        begin
            for (j = 0; j < N; j = j + 1)
                if (col_valid[j]) begin
                    if (got[j] < N) CH[got[j]][j] = $signed(c_bot[j*AW +: AW]);
                    got[j] = got[j] + 1;
                end
        end
    endtask

    initial begin
        f_on = $value$plusargs("fault_site=%s", f_site);
        if (!$value$plusargs("fault_mode=%s", f_mode)) f_mode = "stuck1";
        if (!$value$plusargs("fault_t=%d", f_t))       f_t    = 0;
        if (!$value$plusargs("fault_j=%d", f_j))       f_j    = 0;
        if (!$value$plusargs("fault_bit=%d", f_bit))   f_bit  = 0;
        if (f_on)
            $display("FAULT: site=%0s PE(%0d,%0d) bit=%0d mode=%0s",
                     f_site, f_t, f_j, f_bit, f_mode);
        else
            $display("no fault");

        seed = SEED;
        n_det = 0; n_sil = 0; n_fa = 0; n_ben = 0;

        for (test = 0; test < NTEST; test = test + 1) begin
            // 1. random int8 matrices and the golden C
            for (i = 0; i < N; i = i + 1)
                for (t = 0; t < K; t = t + 1)
                    A[i][t] = $random(seed);
            for (t = 0; t < K; t = t + 1)
                for (j = 0; j < N; j = j + 1)
                    B[t][j] = $random(seed);
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    C[i][j] = 0;
                    CH[i][j] = 0;
                    for (t = 0; t < K; t = t + 1)
                        C[i][j] = C[i][j] + A[i][t] * B[t][j];
                end
            for (j = 0; j < N; j = j + 1) got[j] = 0;

            // 2. reset (clears the sticky alarm), then start
            rst_n = 1'b0; start = 1'b0; w_row = 0; a_row = 0; rc = 0;
            step;
            rst_n = 1'b1; start = 1'b1;
            step;
            start = 1'b0;

            // 3. load row t of B while w_ready, then row m of A while in_ready
            t = 0; m = 0;
            while (!done && rc < 8*(K + 2*N)) begin
                collect;
                w_row = 0; a_row = 0;
                if (w_ready && t < K) begin
                    for (j = 0; j < N; j = j + 1) w_row[j*DW +: DW] = B[t][j];
                    t = t + 1;
                end
                if (in_ready && m < N) begin
                    for (i = 0; i < K; i = i + 1) a_row[i*DW +: DW] = A[m][i];
                    m = m + 1;
                end
                rc = rc + 1;
                step;
            end

            // 4. compare (a missing done or a missing result counts as wrong)
            wrong = done ? 0 : N*N;
            for (j = 0; j < N; j = j + 1)
                if (got[j] != N) wrong = wrong + 1;
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    if (CH[i][j] !== C[i][j]) wrong = wrong + 1;

            // 5. the alarm is latched on the edge after done
            step;
            $display("test %0d: %s  wrong elements=%0d  alarm=%b", test,
                     (wrong == 0) ? "PASS" : "FAIL", wrong, alarm);
            if (wrong != 0 &&  alarm) n_det = n_det + 1;
            if (wrong != 0 && !alarm) n_sil = n_sil + 1;
            if (wrong == 0 &&  alarm) n_fa  = n_fa  + 1;
            if (wrong == 0 && !alarm) n_ben = n_ben + 1;
        end

        $display("-------------------------------------------------------------");
        $display("WS N=%0d tests=%0d seed=%0d: correct+no alarm=%0d, wrong+alarm=%0d, wrong+NO alarm=%0d, correct+alarm=%0d",
                 N, NTEST, SEED, n_ben, n_det, n_sil, n_fa);
        if (!f_on)
            $display("RESULT: %s", (n_ben == NTEST) ? "PASS" : "FAIL");
        else
            $display("RESULT (fault run): DETECTED=%0d SILENT=%0d FALSE_ALARM=%0d BENIGN=%0d",
                     n_det, n_sil, n_fa, n_ben);
        $display("-------------------------------------------------------------");
        $finish;
    end

endmodule
