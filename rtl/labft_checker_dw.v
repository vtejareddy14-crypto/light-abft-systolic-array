// -----------------------------------------------------------------------------
// labft_checker_dw.v - V1-DW: row-by-row (drain) Light ABFT checker with a
//                      DOUBLING (weighted) total. Same ports as labft_checker_d.
//
// WHAT: rows leave the array bottom first (row N-1, ..., row 0). The output
//       total doubles before each row is added:
//          out_acc <- 2*out_acc + (sum of the row leaving now)
//       so row i of C gets the weight 2^i. The input side gives row i of A the
//       same weight: SV_A[t] = sum over i of 2^i * A[i][t] (shifts), and
//          L <- L + SV_A[t] * SV_B[t]   (as before).
//       No fault: L = out_acc, exactly as in V1-D.
// WHY : in V1-D the register in row r carries the results of rows 0..r on
//       their way out; one broken bit can push two of them by +x and -x, which
//       cancel in a plain total. With weights 2^i, equal-size errors in
//       different rows cannot cancel.
// Example (run D, 2x2): rows leave (35,50) then (27,22):
//   plain:    85 + 49 = 134 = L  (missed)
//   doubling: out_acc = 85, then 2*85 + 49 = 219; L = 2*(43+50) + (19+22) = 227
//             -> 219 != 227 -> alarm.
// Totals are N bits wider so the weighted values never wrap around.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_checker_dw #(
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

    localparam SUM_W = DATA_WIDTH + $clog2(N);   // plain row sum of B
    localparam WA_W  = DATA_WIDTH + N;           // weighted column sum of A
    localparam WW    = ACC_WIDTH + N;            // wide totals: no wrap-around

    // ---- input side: SV_A weighted (row i of A shifted left by i), SV_B plain ----
    wire [N*WA_W-1:0] a_shifted;
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_ash
            wire signed [WA_W-1:0] a_ext = $signed(a_col[i*DATA_WIDTH +: DATA_WIDTH]);
            assign a_shifted[i*WA_W +: WA_W] = a_ext <<< i;
        end
    endgenerate

    (* keep *) wire [WA_W-1:0]  sva;
    (* keep *) wire [SUM_W-1:0] svb;

    sum_tree #(.NUM(N), .W_IN(WA_W), .W_OUT(WA_W)) u_sva (
        .in_flat (a_shifted),
        .sum     (sva)
    );
    sum_tree #(.NUM(N), .W_IN(DATA_WIDTH), .W_OUT(SUM_W)) u_svb (
        .in_flat (b_row),
        .sum     (svb)
    );

    wire signed [WA_W+SUM_W-1:0] sv_prod = $signed(sva) * $signed(svb);

    (* preserve *) reg signed [WW-1:0] l_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            l_acc <= {WW{1'b0}};
        else if (clear)
            l_acc <= {WW{1'b0}};
        else if (acc_en)
            l_acc <= l_acc + sv_prod;
    end

    // ---- output side: doubling total, one row per clock ----
    (* keep *) wire [WW-1:0] row_sum;

    sum_tree #(.NUM(N), .W_IN(ACC_WIDTH), .W_OUT(WW)) u_rsum (
        .in_flat (c_row),
        .sum     (row_sum)
    );

    (* preserve *) reg [WW-1:0] out_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_acc <= {WW{1'b0}};
        else if (clear)
            out_acc <= {WW{1'b0}};
        else if (row_en)
            out_acc <= (out_acc << 1) + row_sum;
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
