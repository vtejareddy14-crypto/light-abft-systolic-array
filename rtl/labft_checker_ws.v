// -----------------------------------------------------------------------------
// labft_checker_ws.v - Light ABFT checker for the weight-stationary array (W1).
//
// WHAT: the same check as V1 / V1-D,
//          L (from the inputs)  must equal  S (the sum of all results),
//       built the way the paper's own RTL builds it for WS (LABFT repo:
//       e_n_acc_n, abcd_n_acc_n, dot_nxn/mac_n, wxyz_acc_nxn):
//   * SV_B[t] = sum of row t of B, taken once while the weights load
//               (one N-input adder tree, stored per row: svb_reg),
//   * SV_A[t] = sum of the activations that enter lane t, accumulated while
//               A streams in (one accumulator per lane: sva_acc),
//   * L       = sum over t of SV_A[t] * SV_B[t], with ONE multiplier that
//               steps through the lanes after streaming (dot_en / dot_sel),
//   * S       = running total of the results as they leave the bottom of the
//               array (an N-input adder tree over the valid columns + 1 adder).
//   At done: L != S -> sticky alarm.
// WHY : results stream out of a WS array on their own, so the output side
//       needs only N adders and one accumulator, as in the paper.
//
// Worked example (2x2, A = [1 2; 3 4], B = [5 6; 7 8]):
//   SV_B = (5+6, 7+8) = (11, 15);  SV_A = (1+3, 2+4) = (4, 6)
//   L = 4*11 + 6*15 = 134;  S = 19 + 22 + 43 + 50 = 134  -> no alarm.
//
// Flops: svb_reg (K x SUM_W), sva_acc (K x SUM_W), l_acc (32), s_acc (32),
//        alarm (1).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_checker_ws #(
    parameter N          = 4,
    parameter K          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter RW         = 2
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear,      // start of a multiply
    input  wire                     load_en,    // w_row valid this cycle
    input  wire [RW-1:0]            load_row,   // ... and it is row load_row of B
    input  wire                     acc_en,     // a_row valid this cycle
    input  wire                     dot_en,     // one L step this cycle
    input  wire [RW-1:0]            dot_sel,    // ... for lane dot_sel
    input  wire                     check,      // all results are out: compare
    input  wire [N*DATA_WIDTH-1:0]  w_row,      // row of B being loaded
    input  wire [N*DATA_WIDTH-1:0]  a_row,      // row of A streaming in (unskewed)
    input  wire [N-1:0]             col_valid,  // which columns output a result
    input  wire [N*ACC_WIDTH-1:0]   c_bot,      // results leaving the array
    output reg                      alarm       // sticky until reset
);

    // N values of DATA_WIDTH bits add up to DATA_WIDTH + log2(N) bits
    localparam SUM_W = DATA_WIDTH + $clog2(N);

    integer k;

    // ---- SV_B: sum of each row of B, stored while the weights load ----
    wire [SUM_W-1:0] row_b_sum;
    sum_tree #(.NUM(N), .W_IN(DATA_WIDTH), .W_OUT(SUM_W)) u_svb (
        .in_flat (w_row),
        .sum     (row_b_sum)
    );

    reg [K*SUM_W-1:0] svb_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            svb_reg <= {K*SUM_W{1'b0}};
        else if (clear)
            svb_reg <= {K*SUM_W{1'b0}};
        else if (load_en)
            for (k = 0; k < K; k = k + 1)
                if (load_row == k)
                    svb_reg[k*SUM_W +: SUM_W] <= row_b_sum;
    end

    // ---- SV_A: one accumulator per lane, while A streams in ----
    reg [K*SUM_W-1:0] sva_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sva_acc <= {K*SUM_W{1'b0}};
        else if (clear)
            sva_acc <= {K*SUM_W{1'b0}};
        else if (acc_en)
            for (k = 0; k < K; k = k + 1)
                sva_acc[k*SUM_W +: SUM_W] <= sva_acc[k*SUM_W +: SUM_W]
                                           + {{(SUM_W-DATA_WIDTH){a_row[k*DATA_WIDTH+DATA_WIDTH-1]}},
                                              a_row[k*DATA_WIDTH +: DATA_WIDTH]};
    end

    // ---- L: one multiplier, one lane per cycle (the paper's dot_nxn) ----
    wire signed [SUM_W-1:0]   sva_sel = sva_acc[dot_sel*SUM_W +: SUM_W];
    wire signed [SUM_W-1:0]   svb_sel = svb_reg[dot_sel*SUM_W +: SUM_W];
    wire signed [2*SUM_W-1:0] dot_prod = sva_sel * svb_sel;

    reg signed [ACC_WIDTH-1:0] l_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            l_acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            l_acc <= {ACC_WIDTH{1'b0}};
        else if (dot_en)
            l_acc <= l_acc + dot_prod;
    end

    // ---- S: add the results as they leave the array ----
    wire [N*ACC_WIDTH-1:0] c_masked;
    genvar j;
    generate
        for (j = 0; j < N; j = j + 1) begin : g_mask
            assign c_masked[j*ACC_WIDTH +: ACC_WIDTH] =
                col_valid[j] ? c_bot[j*ACC_WIDTH +: ACC_WIDTH] : {ACC_WIDTH{1'b0}};
        end
    endgenerate

    wire [ACC_WIDTH-1:0] out_sum;
    sum_tree #(.NUM(N), .W_IN(ACC_WIDTH), .W_OUT(ACC_WIDTH)) u_osum (
        .in_flat (c_masked),
        .sum     (out_sum)
    );

    reg [ACC_WIDTH-1:0] s_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            s_acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            s_acc <= {ACC_WIDTH{1'b0}};
        else
            s_acc <= s_acc + out_sum;
    end

    // ---- comparator + sticky alarm ----
    wire mismatch = (l_acc != s_acc);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            alarm <= 1'b0;
        else if (check && mismatch)
            alarm <= 1'b1;
    end

endmodule
