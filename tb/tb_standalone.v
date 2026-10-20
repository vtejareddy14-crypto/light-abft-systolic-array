// -----------------------------------------------------------------------------
// tb_standalone.v - self-contained testbench for labft_top (V1). Verilog-2001.
//
// WHAT: makes NTEST random int8 matrix pairs with $random (fixed SEED),
//       computes the correct C with nested loops, runs each multiply on
//       labft_top, compares c_flat, and prints PASS/FAIL and the alarm.
//       Optionally injects ONE fault. No Python, no input files.
// WHY : lets anyone check the design with a single simulator command
//       (Icarus or ModelSim). Bulk fault campaigns stay in Python
//       (fi/campaign.py).
//
// Parameters (set with -P in Icarus, -g in ModelSim): N, K, NTEST, SEED.
//
// Optional fault (plusargs; without +fault_site there is no fault):
//   +fault_site=acc|aout|bout|lacc   acc_out / a_out / b_out of PE(i,j),
//                                    or the checker's L register
//   +fault_i=<row> +fault_j=<col>    which PE (ignored for lacc), default 0 0
//   +fault_bit=<b>                   which bit, default 0
//   +fault_mode=stuck0|stuck1|flip   default stuck1
//   +fault_cycle=<c>                 flip only: run cycle to flip in (default 2;
//                                    run cycle 0 = the cycle after start)
// stuck0/stuck1 hold the bit for the whole run; flip inverts it once, in
// run cycle c, in every test.
//
// How the fault is applied: at every falling clock edge the chosen bit is
// overwritten (a "deposit"). Registers only change on rising edges, so the
// logic always sees the forced value when it matters. (A `force` statement
// cannot take a bit number chosen at run time in Icarus.)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_standalone;

    parameter N     = 4;
    parameter K     = 4;
    parameter NTEST = 20;
    parameter SEED  = 1;

    localparam DW = 8, AW = 32;

    // ---- DUT ----
    reg                clk = 1'b0;
    reg                rst_n, start;
    reg  [N*DW-1:0]    a_col, b_row;
    wire               in_ready, busy, done, alarm;
    wire [N*N*AW-1:0]  c_flat;

    always #5 clk = ~clk;

    labft_top #(.N(N), .K(K)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_col(a_col), .b_row(b_row),
        .in_ready(in_ready), .busy(busy), .done(done), .c_flat(c_flat), .alarm(alarm));

    // ---- matrices and golden result ----
    reg signed [DW-1:0] A [0:N-1][0:K-1];
    reg signed [DW-1:0] B [0:K-1][0:N-1];
    integer             C [0:N-1][0:N-1];   // 32-bit signed, wraps like the hardware

    integer seed, test, i, j, t, rc, wrong, n_det, n_sil, n_fa, n_ben;

    // ---- fault settings (from plusargs) ----
    reg [8*8-1:0] f_site, f_mode;             // short strings
    reg           f_on;
    integer       f_i, f_j, f_bit, f_cycle;
    event         apply_fault;                // fired at every falling edge

    // new value of the faulty bit, given its current value
    function new_bit;
        input old;
        begin
            if (f_mode == "stuck0")      new_bit = 1'b0;
            else if (f_mode == "flip")   new_bit = (rc == f_cycle) ? ~old : old;
            else                         new_bit = 1'b1;      // stuck1
        end
    endfunction

    // One block per PE, so the hierarchical path has constant indices.
    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_fi_row
            for (gj = 0; gj < N; gj = gj + 1) begin : g_fi_col
                always @(apply_fault) begin
                    if (f_on && f_i == gi && f_j == gj) begin
                        if (f_site == "acc")
                            dut.u_top.u_array.g_row[gi].g_col[gj].u_pe.acc_out[f_bit] =
                                new_bit(dut.u_top.u_array.g_row[gi].g_col[gj].u_pe.acc_out[f_bit]);
                        if (f_site == "aout")
                            dut.u_top.u_array.g_row[gi].g_col[gj].u_pe.a_out[f_bit] =
                                new_bit(dut.u_top.u_array.g_row[gi].g_col[gj].u_pe.a_out[f_bit]);
                        if (f_site == "bout")
                            dut.u_top.u_array.g_row[gi].g_col[gj].u_pe.b_out[f_bit] =
                                new_bit(dut.u_top.u_array.g_row[gi].g_col[gj].u_pe.b_out[f_bit]);
                    end
                end
            end
        end
    endgenerate

    always @(apply_fault)
        if (f_on && f_site == "lacc")
            dut.u_chk.l_acc[f_bit] = new_bit(dut.u_chk.l_acc[f_bit]);

    // ---- one clock step: falling edge, fault, then let signals settle ----
    task step;
        begin
            @(negedge clk);
            -> apply_fault;
            #1;
        end
    endtask

    initial begin
        // read the optional fault
        f_on = $value$plusargs("fault_site=%s", f_site);
        if (!$value$plusargs("fault_mode=%s", f_mode))   f_mode  = "stuck1";
        if (!$value$plusargs("fault_i=%d", f_i))         f_i     = 0;
        if (!$value$plusargs("fault_j=%d", f_j))         f_j     = 0;
        if (!$value$plusargs("fault_bit=%d", f_bit))     f_bit   = 0;
        if (!$value$plusargs("fault_cycle=%d", f_cycle)) f_cycle = 2;
        if (f_on)
            $display("FAULT: site=%0s PE(%0d,%0d) bit=%0d mode=%0s (flip cycle %0d)",
                     f_site, f_i, f_j, f_bit, f_mode, f_cycle);
        else
            $display("no fault");

        seed = SEED;
        n_det = 0; n_sil = 0; n_fa = 0; n_ben = 0;
        rc = -1;

        for (test = 0; test < NTEST; test = test + 1) begin
            // 1. random int8 matrices ($random gives 32 bits; keep the low 8)
            for (i = 0; i < N; i = i + 1)
                for (t = 0; t < K; t = t + 1)
                    A[i][t] = $random(seed);
            for (t = 0; t < K; t = t + 1)
                for (j = 0; j < N; j = j + 1)
                    B[t][j] = $random(seed);

            // 2. golden C with nested loops
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    C[i][j] = 0;
                    for (t = 0; t < K; t = t + 1)
                        C[i][j] = C[i][j] + A[i][t] * B[t][j];
                end

            // 3. reset (clears the sticky alarm), then start
            rst_n = 1'b0; start = 1'b0; a_col = 0; b_row = 0; rc = -1;
            step;
            rst_n = 1'b1; start = 1'b1; rc = 0;
            step;                                   // start seen: now in run cycle 0
            start = 1'b0;

            // 4. stream column t of A / row t of B on each in_ready cycle
            t = 0;
            while (!done && rc < 4*(K + 2*N)) begin
                if (in_ready && t < K) begin
                    for (i = 0; i < N; i = i + 1) begin
                        a_col[i*DW +: DW] = A[i][t];
                        b_row[i*DW +: DW] = B[t][i];
                    end
                    t = t + 1;
                end else begin
                    a_col = 0;
                    b_row = 0;
                end
                rc = rc + 1;                        // count first, so the fault
                step;                               // sees the right cycle number
            end

            // 5. compare every element (a missing done counts as wrong)
            wrong = done ? 0 : N*N;
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    if ($signed(c_flat[(i*N+j)*AW +: AW]) !== C[i][j]) wrong = wrong + 1;

            // 6. the alarm is latched on the edge after done
            step;
            $display("test %0d: %s  wrong elements=%0d  alarm=%b", test,
                     (wrong == 0) ? "PASS" : "FAIL", wrong, alarm);
            if (wrong != 0 &&  alarm) n_det = n_det + 1;
            if (wrong != 0 && !alarm) n_sil = n_sil + 1;
            if (wrong == 0 &&  alarm) n_fa  = n_fa  + 1;
            if (wrong == 0 && !alarm) n_ben = n_ben + 1;
        end

        $display("-------------------------------------------------------------");
        $display("N=%0d K=%0d tests=%0d seed=%0d: correct+no alarm=%0d, wrong+alarm=%0d, wrong+NO alarm=%0d, correct+alarm=%0d",
                 N, K, NTEST, SEED, n_ben, n_det, n_sil, n_fa);
        if (!f_on)
            $display("RESULT: %s", (n_ben == NTEST) ? "PASS" : "FAIL");
        else
            $display("RESULT (fault run): DETECTED=%0d SILENT=%0d FALSE_ALARM=%0d BENIGN=%0d",
                     n_det, n_sil, n_fa, n_ben);
        $display("-------------------------------------------------------------");
        $finish;
    end

endmodule
