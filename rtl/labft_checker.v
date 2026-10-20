// -----------------------------------------------------------------------------
// labft_checker.v - Light ABFT checker (V1), after Libano et al. 2023, Thm VI.1.
//
// WHAT: computes the sum of all C elements in two independent ways (from the
//       inputs as they stream in, and from the outputs at the end), compares
//       them, and raises a sticky alarm if they differ.
// WHY : it detects any error that changes the total of C, at the cost of one
//       extra multiply-accumulate plus adders, instead of the i+k+1 extra PEs
//       of traditional ABFT (paper p.2399, Table III p.2400).
//
//   sum of all C[i][j]  ==  sum over t of  SV_A[t] * SV_B[t]
//   SV_A[t] = sum_i A[i][t]   (sum of the column of A streamed at step t)
//   SV_B[t] = sum_j B[t][j]   (sum of the row    of B streamed at step t)
//
// Why it works: sum_ij C[i][j] = sum_ij sum_t A[i][t] B[t][j]
//                              = sum_t (sum_i A[i][t]) (sum_j B[t][j]).
//
// Hardware:
//   * two input adder trees on the UNSKEWED a_col / b_row (width grows by
//     log2(N) bits, so the sums never overflow),
//   * one extra multiply-accumulate register L (the "extra PE"), 32-bit wrap,
//   * one output adder tree over all N*N accumulators (32-bit wrap),
//   * one comparator, sampled when the array says done,
//   * a sticky alarm latch, cleared only by reset (like the LABFT repo).
// Both sides wrap modulo 2^32 the same way, so an overflow on one side is
// matched by the same overflow on the other: no false alarm from overflow.
//
// Flops in the checker (fault-site class "checker"): l_acc (32), alarm (1).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_checker #(
    parameter N          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear,      // start of a multiply: L <= 0
    input  wire                     acc_en,     // a_col/b_row valid this cycle
    input  wire                     check,      // c_flat is final: compare now
    input  wire [N*DATA_WIDTH-1:0]  a_col,      // unskewed column t of A
    input  wire [N*DATA_WIDTH-1:0]  b_row,      // unskewed row t of B
    input  wire [N*N*ACC_WIDTH-1:0] c_flat,     // all accumulators of the array
    output reg                      alarm       // sticky until reset
);

    // A sum of N signed DATA_WIDTH-bit values needs log2(N) extra bits.
    // $clog2 is a built-in function. Example: N = 4 -> $clog2(4) = 2,
    // so SUM_W = 8 + 2 = 10 bits (four values of -128 add up to -512,
    // which needs 10 bits).
    localparam SUM_W = DATA_WIDTH + $clog2(N);

    // ---- input side: SV_A[t], SV_B[t] ----
    wire [SUM_W-1:0] sva;
    wire [SUM_W-1:0] svb;

    sum_tree #(.NUM(N), .W_IN(DATA_WIDTH), .W_OUT(SUM_W)) u_sva (
        .in_flat (a_col),
        .sum     (sva)
    );
    sum_tree #(.NUM(N), .W_IN(DATA_WIDTH), .W_OUT(SUM_W)) u_svb (
        .in_flat (b_row),
        .sum     (svb)
    );

    // the one extra multiply (the paper's "extra PE")
    wire signed [2*SUM_W-1:0] sv_prod = $signed(sva) * $signed(svb);

    reg signed [ACC_WIDTH-1:0] l_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_acc <= {ACC_WIDTH{1'b0}};
        end else if (clear) begin
            l_acc <= {ACC_WIDTH{1'b0}};
        end else if (acc_en) begin
            // sv_prod is sign-extended to ACC_WIDTH, then the sum wraps
            l_acc <= l_acc + sv_prod;
        end
    end

    // ---- output side: sum of all N*N accumulators, modulo 2^32 ----
    wire [ACC_WIDTH-1:0] out_sum;

    sum_tree #(.NUM(N*N), .W_IN(ACC_WIDTH), .W_OUT(ACC_WIDTH)) u_osum (
        .in_flat (c_flat),
        .sum     (out_sum)
    );

    // ---- comparator + sticky alarm ----
    wire mismatch = (l_acc != out_sum);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            alarm <= 1'b0;
        else if (check && mismatch)
            alarm <= 1'b1;
    end

endmodule
