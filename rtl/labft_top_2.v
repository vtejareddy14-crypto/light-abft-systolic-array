// -----------------------------------------------------------------------------
// labft_top_2.v - V2: V0 (array_top) + TWO independent Light ABFT checkers
//                 (DMR Light ABFT, parallel output side like V1).
//
// WHAT: two complete copies of labft_checker.v (each with its own input sums,
//       own L, own output adder tree, own comparator and alarm latch) watch
//       the same array. A small combiner turns their two alarms into:
//         alarm     = both checkers alarm  -> "array error"  (the real alarm)
//         chk_fault = exactly one alarms   -> "checker fault" (one checker is
//                                             broken; the result itself may be fine)
// WHY : every false alarm measured in V1 came from a fault INSIDE the checker.
//       With two checkers, one internal fault can upset only one of them, so
//       it shows up as chk_fault instead of a false "array error".
//
// Shared by both checkers (common mode, a stated limitation): the array, the
// skew registers, the controller, and the raw input / output wires.
//
// Synthesis: the two checkers are identical, so the tool may try to merge them
// into one; Vivado is run with -keep_equivalent_registers to prevent that.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_top_2 #(
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
    output wire                        done,
    output wire [N*N*ACC_WIDTH-1:0]    c_flat,
    output wire                        alarm,      // array error: both checkers agree
    output wire                        chk_fault   // the two checkers disagree
);

    wire clear;
    wire alarm1, alarm2;

    array_top #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_top (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .a_col    (a_col),
        .b_row    (b_row),
        .in_ready (in_ready),
        .clear_o  (clear),
        .busy     (busy),
        .done     (done),
        .c_flat   (c_flat)
    );

    labft_checker #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_chk1 (
        .clk (clk), .rst_n (rst_n), .clear (clear), .acc_en (in_ready),
        .check (done), .a_col (a_col), .b_row (b_row), .c_flat (c_flat),
        .alarm (alarm1)
    );

    labft_checker #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_chk2 (
        .clk (clk), .rst_n (rst_n), .clear (clear), .acc_en (in_ready),
        .check (done), .a_col (a_col), .b_row (b_row), .c_flat (c_flat),
        .alarm (alarm2)
    );

    // ---- combiner (Rule 2: report disagreement) ----
    assign alarm     = alarm1 & alarm2;
    assign chk_fault = alarm1 ^ alarm2;

endmodule
