// -----------------------------------------------------------------------------
// labft_checker_ws_w.v - W3: Light ABFT checker for the weight-stationary
//                        array with a DOUBLING (time-weighted) total.
//
// WHAT: the same check as labft_checker_ws.v (W1), but every running total is
//       doubled before the next value is added:
//         output side:  S <- 2*S + (results leaving the array this clock)
//         input side:   SV_A[t] <- 2*SV_A[t] + A[m][t]    (rows of A in order)
//                       SV_B[t]  = sum over j of 2^(N-1-j) * B[t][j]  (shifts)
//         L = sum over t of SV_A[t] * SV_B[t]  (one multiplier, as before)
//       Result C[m][j] leaves column j in clock K + j + m, so in S it gets the
//       weight 2^(2N-2-m-j); the input side gives every product
//       A[m][t]*B[t][j] the same weight 2^(N-1-m) * 2^(N-1-j). So L = S when
//       there is no fault, exactly as in plain Light ABFT.
// WHY : in W1 one broken register shared by several results can make equal
//       and opposite errors (+8 and -8) that cancel in the plain total. Here
//       results that pass the register in different clocks get different
//       weights (powers of 2), so equal-size errors can no longer cancel.
//
// Example (2x2, rows leave in order, column skew ignored):
//   no fault:   S = 41, then 2*41 + 93 = 175;  with the run D fault:
//               S = 49, then 2*49 + 85 = 183  ->  183 != 175  ->  alarm.
//
// Costs compared with W1: the doubling is wiring (a shift); the totals are
// 2N bits wider so the larger weighted values never wrap around.
// Assumes the true results fit in ACC_WIDTH bits (true for int8 inputs).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_checker_ws_w #(
    parameter N          = 4,
    parameter K          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter RW         = 2
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear,
    input  wire                     load_en,
    input  wire [RW-1:0]            load_row,
    input  wire                     acc_en,
    input  wire                     dot_en,
    input  wire [RW-1:0]            dot_sel,
    input  wire                     check,
    input  wire [N*DATA_WIDTH-1:0]  w_row,
    input  wire [N*DATA_WIDTH-1:0]  a_row,
    input  wire [N-1:0]             col_valid,
    input  wire [N*ACC_WIDTH-1:0]   c_bot,
    output reg                      alarm
);

    localparam SW = DATA_WIDTH + N;          // weighted sums of N int8 values
    localparam WW = ACC_WIDTH + 2*N;         // wide totals: no wrap-around

    integer k;

    // ---- SV_B: weighted row sum of B, B[t][j] shifted left by N-1-j ----
    wire [N*SW-1:0] w_shifted;
    genvar j;
    generate
        for (j = 0; j < N; j = j + 1) begin : g_wsh
            wire signed [SW-1:0] b_ext = $signed(w_row[j*DATA_WIDTH +: DATA_WIDTH]);
            assign w_shifted[j*SW +: SW] = b_ext <<< (N - 1 - j);
        end
    endgenerate

    wire [SW-1:0] row_b_sum;
    sum_tree #(.NUM(N), .W_IN(SW), .W_OUT(SW)) u_svb (
        .in_flat (w_shifted),
        .sum     (row_b_sum)
    );

    reg [K*SW-1:0] svb_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            svb_reg <= {K*SW{1'b0}};
        else if (clear)
            svb_reg <= {K*SW{1'b0}};
        else if (load_en)
            for (k = 0; k < K; k = k + 1)
                if (load_row == k)
                    svb_reg[k*SW +: SW] <= row_b_sum;
    end

    // ---- SV_A: doubling accumulator per lane, while A streams in ----
    reg [K*SW-1:0] sva_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sva_acc <= {K*SW{1'b0}};
        else if (clear)
            sva_acc <= {K*SW{1'b0}};
        else if (acc_en)
            for (k = 0; k < K; k = k + 1)
                sva_acc[k*SW +: SW] <= (sva_acc[k*SW +: SW] << 1)
                                     + {{(SW-DATA_WIDTH){a_row[k*DATA_WIDTH+DATA_WIDTH-1]}},
                                        a_row[k*DATA_WIDTH +: DATA_WIDTH]};
    end

    // ---- L: one multiplier, one lane per cycle ----
    wire signed [SW-1:0]   sva_sel  = sva_acc[dot_sel*SW +: SW];
    wire signed [SW-1:0]   svb_sel  = svb_reg[dot_sel*SW +: SW];
    wire signed [2*SW-1:0] dot_prod = sva_sel * svb_sel;

    reg signed [WW-1:0] l_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            l_acc <= {WW{1'b0}};
        else if (clear)
            l_acc <= {WW{1'b0}};
        else if (dot_en)
            l_acc <= l_acc + dot_prod;
    end

    // ---- S: doubling running total of the results leaving the array ----
    wire [N*ACC_WIDTH-1:0] c_masked;
    generate
        for (j = 0; j < N; j = j + 1) begin : g_mask
            assign c_masked[j*ACC_WIDTH +: ACC_WIDTH] =
                col_valid[j] ? c_bot[j*ACC_WIDTH +: ACC_WIDTH] : {ACC_WIDTH{1'b0}};
        end
    endgenerate

    wire [WW-1:0] out_sum;
    sum_tree #(.NUM(N), .W_IN(ACC_WIDTH), .W_OUT(WW)) u_osum (
        .in_flat (c_masked),
        .sum     (out_sum)
    );

    reg [WW-1:0] s_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            s_acc <= {WW{1'b0}};
        else if (clear)
            s_acc <= {WW{1'b0}};
        else
            s_acc <= (s_acc << 1) + out_sum;
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
