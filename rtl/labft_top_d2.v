// -----------------------------------------------------------------------------
// labft_top_d2.v - V2-D: V0-D (array_top_d) + TWO independent drain checkers
//                  (DMR Light ABFT on the realistic row-by-row output).
//
// WHAT: two complete copies of labft_checker_d.v watch the same array.
//       The combiner is the same as in labft_top_2.v (V2):
//         alarm     = both checkers alarm  -> "array error"
//         chk_fault = exactly one alarms   -> "checker fault"
// WHY : a drain checker is small, so a second one is cheap, while a second
//       parallel checker costs much more.
//
// Shared by both checkers (common mode): the array, the skew registers, the
// controller, and the raw input / row-output wires.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_top_d2 #(
    parameter N          = 4,
    parameter K          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        start,
    input  wire [N*DATA_WIDTH-1:0]     a_col,
    input  wire [N*DATA_WIDTH-1:0]     b_row,
    output wire                        in_ready,
    output wire                        busy,
    output wire                        row_valid,
    output wire                        done,
    output wire [N*ACC_WIDTH-1:0]      c_row,
    output wire                        alarm,      // array error: both checkers agree
    output wire                        chk_fault   // the two checkers disagree
);

    wire clear;
    wire alarm1, alarm2;

    array_top_d #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_top (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .a_col     (a_col),
        .b_row     (b_row),
        .in_ready  (in_ready),
        .clear_o   (clear),
        .busy      (busy),
        .row_valid (row_valid),
        .done      (done),
        .c_row     (c_row)
    );

    labft_checker_d #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_chk1 (
        .clk (clk), .rst_n (rst_n), .clear (clear), .acc_en (in_ready),
        .row_en (row_valid), .check (done), .a_col (a_col), .b_row (b_row),
        .c_row (c_row), .alarm (alarm1)
    );

    labft_checker_d #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_chk2 (
        .clk (clk), .rst_n (rst_n), .clear (clear), .acc_en (in_ready),
        .row_en (row_valid), .check (done), .a_col (a_col), .b_row (b_row),
        .c_row (c_row), .alarm (alarm2)
    );

    // ---- combiner (Rule 2: report disagreement) ----
    assign alarm     = alarm1 & alarm2;
    assign chk_fault = alarm1 ^ alarm2;

endmodule
