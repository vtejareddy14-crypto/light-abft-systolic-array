// -----------------------------------------------------------------------------
// labft_top_ws2.v - W2: W0 (ws_top) + TWO independent Light ABFT checkers for
//                   the weight-stationary array (the paper's suggested
//                   duplicated checker, Libano et al. 2023, p. 2402).
//
// WHAT: two complete copies of labft_checker_ws.v watch the same array.
//       Combiner (same rule as V2, labft_top_2.v):
//         alarm     = both checkers alarm  -> "array error"  (the real alarm)
//         chk_fault = exactly one alarms   -> "checker fault" (one checker is
//                                             broken; the result may be fine)
// WHY : every false alarm in W1 comes from a fault inside the checker. One
//       internal fault can upset only one of two checkers, so it is reported
//       as chk_fault instead of a false "array error".
// Shared by both checkers (common mode): the array, skew registers,
// controller, and the raw input / output wires.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_top_ws2 #(
    parameter N          = 4,
    parameter K          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter RW         = (K > 1) ? $clog2(K) : 1
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        start,
    input  wire [N*DATA_WIDTH-1:0]     w_row,
    input  wire [N*DATA_WIDTH-1:0]     a_row,
    output wire                        w_ready,
    output wire                        in_ready,
    output wire                        busy,
    output wire                        done,
    output wire [N-1:0]                col_valid,
    output wire [N*ACC_WIDTH-1:0]      c_bot,
    output wire                        alarm,      // array error: both checkers agree
    output wire                        chk_fault   // the two checkers disagree
);

    wire          clear, dot_en;
    wire [RW-1:0] load_row, dot_sel;
    wire          alarm1, alarm2;

    ws_top #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .RW(RW)
    ) u_top (
        .clk(clk), .rst_n(rst_n), .start(start), .w_row(w_row), .a_row(a_row),
        .w_ready(w_ready), .in_ready(in_ready), .clear_o(clear), .load_row(load_row),
        .dot_en(dot_en), .dot_sel(dot_sel), .busy(busy), .done(done),
        .col_valid(col_valid), .c_bot(c_bot)
    );

    labft_checker_ws #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .RW(RW)
    ) u_chk1 (
        .clk(clk), .rst_n(rst_n), .clear(clear), .load_en(w_ready), .load_row(load_row),
        .acc_en(in_ready), .dot_en(dot_en), .dot_sel(dot_sel), .check(done),
        .w_row(w_row), .a_row(a_row), .col_valid(col_valid), .c_bot(c_bot),
        .alarm(alarm1)
    );

    labft_checker_ws #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .RW(RW)
    ) u_chk2 (
        .clk(clk), .rst_n(rst_n), .clear(clear), .load_en(w_ready), .load_row(load_row),
        .acc_en(in_ready), .dot_en(dot_en), .dot_sel(dot_sel), .check(done),
        .w_row(w_row), .a_row(a_row), .col_valid(col_valid), .c_bot(c_bot),
        .alarm(alarm2)
    );

    // ---- combiner (report disagreement) ----
    assign alarm     = alarm1 & alarm2;
    assign chk_fault = alarm1 ^ alarm2;

endmodule
