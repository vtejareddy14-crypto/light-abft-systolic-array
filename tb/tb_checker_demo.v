// -----------------------------------------------------------------------------
// tb_checker_demo.v - ModelSim demo: does the Light ABFT checker do its job?
//
// WHAT: runs the 4x4 design with Light ABFT (labft_top) on one fixed pair of
//       small matrices, four times, and prints a readable report:
//         1. no fault                     -> correct result, alarm = 0
//         2. a stuck bit in a PE          -> wrong result,   alarm = 1  (DETECTED)
//         3. two errors that cancel       -> wrong result,   alarm = 0  (known limit)
//         4. a stuck bit in the checker   -> correct result, alarm = 1  (FALSE ALARM)
// WHY : a short, honest demo of what the checker catches and what it cannot.
//
// The check (Libano et al. 2023, Theorem VI.1):
//   L (from the inputs)  = sum over t of (sum of column t of A) x (sum of row t of B)
//   sum of all C (from the outputs)
//   alarm = 1 if they differ when the multiply is done.
//
// ModelSim, from the repository root:
//   vlib work
//   vlog tb/tb_checker_demo.v rtl/*.v
//   vsim -c tb_checker_demo -do "run -all; quit -f"      (text report only)
//   vsim tb_checker_demo -do tb/demo_wave.do             (GUI with waveform)
// Icarus:
//   iverilog -g2001 -o demo.vvp tb/tb_checker_demo.v rtl/*.v && vvp demo.vvp
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_checker_demo;

    localparam N = 4, K = 4, DW = 8, AW = 32;

    // ---------------- the design under test ----------------
    reg               clk = 1'b0;
    reg               rst_n, start;
    reg  [N*DW-1:0]   a_col, b_row;
    wire              in_ready, busy, done, alarm;
    wire [N*N*AW-1:0] c_flat;

    always #5 clk = ~clk;            // 100 MHz clock

    labft_top #(.N(N), .K(K)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_col(a_col), .b_row(b_row),
        .in_ready(in_ready), .busy(busy), .done(done), .c_flat(c_flat), .alarm(alarm));

    // ---------------- test matrices (small numbers, easy to check) ----------------
    reg signed [DW-1:0] A [0:N-1][0:K-1];
    reg signed [DW-1:0] B [0:K-1][0:N-1];
    integer             C [0:N-1][0:N-1];     // expected result, computed below

    integer scenario;                         // 1..4, also visible in the waveform
    integer i, j, t, wrong, sum_c;
    integer result_ok [1:4];
    integer alarm_seen [1:4];
    reg     fault_on = 1'b0;

    // ---------------- stuck-at faults (scenarios 2 and 4) ----------------
    // Verilog does not allow `force` on ONE BIT of a register, so the stuck
    // bit is written again 1 ns after every rising clock edge. The register
    // then holds the stuck value for the whole cycle, so the circuit sees
    // exactly what a stuck bit would show it.
    always @(posedge clk) begin
        if (fault_on) begin
            #1;
            if (scenario == 2)   // PE(1,2) accumulator, bit 10 (value 1024) stuck at 1
                dut.u_top.u_array.g_row[1].g_col[2].u_pe.acc_out[10] = 1'b1;
            if (scenario == 4)   // checker's L register, bit 20 stuck at 1
                dut.u_chk.l_acc[20] = 1'b1;
        end
    end

    // ---------------- one multiply, with the chosen fault ----------------
    task run_multiply;
        begin
            // reset (clears the array, L and the sticky alarm)
            rst_n = 1'b0; start = 1'b0; a_col = 0; b_row = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1'b1;

            // persistent faults (scenarios 2 and 4) are switched on before the
            // multiply starts; the always block below keeps the bit stuck
            fault_on = 1'b1;

            // start
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;

            // stream column t of A and row t of B, one t per cycle
            t = 0;
            while (!done) begin
                if (in_ready && t < K) begin
                    for (i = 0; i < N; i = i + 1) begin
                        a_col[i*DW +: DW] = A[i][t];
                        b_row[i*DW +: DW] = B[t][i];
                    end
                    // scenario 3: two errors that cancel (+8 and -8), injected once
                    if (scenario == 3 && t == 0) begin
                        dut.u_top.u_array.g_row[0].g_col[0].u_pe.acc_out =
                            dut.u_top.u_array.g_row[0].g_col[0].u_pe.acc_out + 8;
                        dut.u_top.u_array.g_row[3].g_col[3].u_pe.acc_out =
                            dut.u_top.u_array.g_row[3].g_col[3].u_pe.acc_out - 8;
                    end
                    t = t + 1;
                end else begin
                    a_col = 0;
                    b_row = 0;
                end
                @(negedge clk);
            end

            // done = 1 now: c_flat is final. The alarm is latched one clock later.
            @(negedge clk);
            print_result;

            // switch the fault off again
            fault_on = 1'b0;
        end
    endtask

    // ---------------- print one scenario ----------------
    task print_result;
        begin
            wrong = 0;
            sum_c = 0;
            $display("  C from the hardware            expected C");
            for (i = 0; i < N; i = i + 1) begin
                $write("  ");
                for (j = 0; j < N; j = j + 1)
                    $write("%6d", $signed(c_flat[(i*N+j)*AW +: AW]));
                $write("      ");
                for (j = 0; j < N; j = j + 1) begin
                    $write("%6d", C[i][j]);
                    if ($signed(c_flat[(i*N+j)*AW +: AW]) !== C[i][j]) wrong = wrong + 1;
                    sum_c = sum_c + $signed(c_flat[(i*N+j)*AW +: AW]);
                end
                $display("");
            end
            $display("  L (from the inputs)       = %0d", $signed(dut.u_chk.l_acc));
            $display("  sum of C (from outputs)   = %0d", sum_c);
            $display("  wrong elements = %0d    alarm = %b", wrong, alarm);
            if (wrong == 0 && !alarm) $display("  => CORRECT, NO ALARM");
            if (wrong != 0 &&  alarm) $display("  => ERROR DETECTED (alarm raised)");
            if (wrong != 0 && !alarm) $display("  => SILENT ERROR (wrong result, no alarm)");
            if (wrong == 0 &&  alarm) $display("  => FALSE ALARM (result correct, alarm raised)");
            result_ok[scenario]  = (wrong == 0);
            alarm_seen[scenario] = alarm;
        end
    endtask

    // ---------------- main ----------------
    initial begin
        // A (4x4) and B (4x4): small values, so C is easy to check by hand.
        // Hand check of the checker value:
        //   column sums of A: 6, 4, 4, 6     row sums of B: 4, 4, 4, 4
        //   L = 6*4 + 4*4 + 4*4 + 6*4 = 80  = sum of all elements of C
        A[0][0]=1; A[0][1]=2; A[0][2]=0; A[0][3]=1;
        A[1][0]=3; A[1][1]=1; A[1][2]=2; A[1][3]=0;
        A[2][0]=0; A[2][1]=1; A[2][2]=1; A[2][3]=2;
        A[3][0]=2; A[3][1]=0; A[3][2]=1; A[3][3]=3;
        B[0][0]=2; B[0][1]=1; B[0][2]=0; B[0][3]=1;
        B[1][0]=1; B[1][1]=0; B[1][2]=2; B[1][3]=1;
        B[2][0]=0; B[2][1]=3; B[2][2]=1; B[2][3]=0;
        B[3][0]=1; B[3][1]=1; B[3][2]=0; B[3][3]=2;

        // expected C = A x B
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                C[i][j] = 0;
                for (t = 0; t < K; t = t + 1)
                    C[i][j] = C[i][j] + A[i][t] * B[t][j];
            end

        $display("=================================================================");
        $display(" Light ABFT checker demo (4x4 output-stationary array, labft_top)");
        $display("=================================================================");

        scenario = 1;
        $display("\n--- Scenario 1: no fault ---");
        run_multiply;

        scenario = 2;
        $display("\n--- Scenario 2: PE(1,2) accumulator bit 10 stuck at 1 ---");
        $display("  (expected: C[1][2] too large by 2^10 = 1024, alarm = 1)");
        run_multiply;

        scenario = 3;
        $display("\n--- Scenario 3: +8 in C[0][0] and -8 in C[3][3] (errors cancel) ---");
        $display("  (expected: 2 wrong elements but the totals still match, alarm = 0)");
        run_multiply;

        scenario = 4;
        $display("\n--- Scenario 4: checker's L register bit 20 stuck at 1 ---");
        $display("  (expected: result correct, but L is wrong, so alarm = 1)");
        run_multiply;

        // summary: did each scenario behave as the theory says?
        $display("\n=================================================================");
        $display(" Summary                              result   alarm   as expected?");
        $display(" 1 no fault                           %s  %0d       %s",
                 result_ok[1] ? "correct" : "WRONG  ", alarm_seen[1],
                 ( result_ok[1] && !alarm_seen[1]) ? "yes" : "NO");
        $display(" 2 stuck bit in a PE                  %s  %0d       %s",
                 result_ok[2] ? "correct" : "WRONG  ", alarm_seen[2],
                 (!result_ok[2] &&  alarm_seen[2]) ? "yes (detected)" : "NO");
        $display(" 3 two cancelling errors              %s  %0d       %s",
                 result_ok[3] ? "correct" : "WRONG  ", alarm_seen[3],
                 (!result_ok[3] && !alarm_seen[3]) ? "yes (known limit)" : "NO");
        $display(" 4 stuck bit in the checker           %s  %0d       %s",
                 result_ok[4] ? "correct" : "WRONG  ", alarm_seen[4],
                 ( result_ok[4] &&  alarm_seen[4]) ? "yes (false alarm)" : "NO");
        if (result_ok[1] && !alarm_seen[1] && !result_ok[2] && alarm_seen[2] &&
            !result_ok[3] && !alarm_seen[3] && result_ok[4] && alarm_seen[4])
            $display(" DEMO RESULT: all 4 scenarios behave as Light ABFT theory predicts");
        else
            $display(" DEMO RESULT: MISMATCH - check the scenario marked NO");
        $display("=================================================================");
        $finish;
    end

endmodule
