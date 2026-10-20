// -----------------------------------------------------------------------------
// labft_checker_d.v - Light ABFT checker for the drain variants (V1-D, V2-D).
//
// WHAT: the same check as labft_checker.v (V1):
//          L (from the inputs)  must equal  the sum of all N*N results.
//       The input side (SV_A, SV_B, the one extra multiply, L) is identical.
//       The output side is different: the results arrive one row per clock
//       on c_row (while row_valid = 1), so the checker adds the N numbers of
//       that row and keeps a running total, out_acc:
//          out_acc <= out_acc + (C[r][0] + ... + C[r][N-1])
//       After the last row, done = 1, and the checker compares L with out_acc.
// WHY : adding N numbers per clock needs N-1 adders plus one accumulator,
//       instead of the N*N-1 adders that V1 needs to add all results at once.
//       This is how a weight-stationary checker works too (paper p.2399),
//       so it makes the OS / WS comparison fair.
//
// Worked example (2x2, C = [[1,2],[3,4]], L = 10):
//   OUT cycle 0: c_row = row 1 = (3,4) -> out_acc = 0 + 7 = 7
//   OUT cycle 1: c_row = row 0 = (1,2) -> out_acc = 7 + 3 = 10
//   DONE       : L = 10, out_acc = 10 -> equal -> no alarm
//
// Flops in this checker: l_acc (32), out_acc (32), alarm (1).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_checker_d #(
    parameter N          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear,      // start of a multiply: L, out_acc <= 0
    input  wire                     acc_en,     // a_col/b_row valid this cycle
    input  wire                     row_en,     // c_row holds one row of C
    input  wire                     check,      // all rows have passed: compare now
    input  wire [N*DATA_WIDTH-1:0]  a_col,      // unskewed column t of A
    input  wire [N*DATA_WIDTH-1:0]  b_row,      // unskewed row t of B
    input  wire [N*ACC_WIDTH-1:0]   c_row,      // the row of C leaving the array
    output reg                      alarm       // sticky until reset
);

    localparam SUM_W = DATA_WIDTH + $clog2(N);

    // ---- input side: identical to labft_checker.v ----
    (* keep *) wire [SUM_W-1:0] sva;
    (* keep *) wire [SUM_W-1:0] svb;

    sum_tree #(.NUM(N), .W_IN(DATA_WIDTH), .W_OUT(SUM_W)) u_sva (
        .in_flat (a_col),
        .sum     (sva)
    );
    sum_tree #(.NUM(N), .W_IN(DATA_WIDTH), .W_OUT(SUM_W)) u_svb (
        .in_flat (b_row),
        .sum     (svb)
    );

    wire signed [2*SUM_W-1:0] sv_prod = $signed(sva) * $signed(svb);

    (* preserve *) reg signed [ACC_WIDTH-1:0] l_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            l_acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            l_acc <= {ACC_WIDTH{1'b0}};
        else if (acc_en)
            l_acc <= l_acc + sv_prod;
    end

    // ---- output side: add one row per clock into out_acc ----
    (* keep *) wire [ACC_WIDTH-1:0] row_sum;

    sum_tree #(.NUM(N), .W_IN(ACC_WIDTH), .W_OUT(ACC_WIDTH)) u_rsum (
        .in_flat (c_row),
        .sum     (row_sum)
    );

    (* preserve *) reg [ACC_WIDTH-1:0] out_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            out_acc <= {ACC_WIDTH{1'b0}};
        else if (row_en)
            out_acc <= out_acc + row_sum;
    end

    // ---- comparator + sticky alarm ----
    (* keep *) wire mismatch = (l_acc != out_acc);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            alarm <= 1'b0;
        else if (check && mismatch)
            alarm <= 1'b1;
    end

endmodule
