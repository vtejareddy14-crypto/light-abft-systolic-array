// top_v2d_N8.v - Vivado top for V2-D: V0-D + TWO drain checkers (alarm, chk_fault), N = K = 8.
// Only fixes the size and passes every port through. No logic.

`timescale 1ns / 1ps

module top_v2d_N8 (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [63:0] a_col,
    input  wire [63:0] b_row,
    output wire in_ready,
    output wire busy,
    output wire row_valid,
    output wire done,
    output wire [255:0] c_row,
    output wire alarm,
    output wire chk_fault
);

    labft_top_d2 #(.N(8), .K(8)) u (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .a_col    (a_col),
        .b_row    (b_row),
        .in_ready (in_ready),
        .busy     (busy),
        .row_valid(row_valid),
        .done     (done),
        .c_row    (c_row),
        .alarm    (alarm),
        .chk_fault(chk_fault)
    );

endmodule
