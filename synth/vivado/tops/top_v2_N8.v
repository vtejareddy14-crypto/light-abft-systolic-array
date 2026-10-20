// top_v2_N8.v - Vivado top for V2: V0 + TWO Light ABFT checkers (alarm = both agree, chk_fault = they disagree), N = K = 8.
// Only fixes the size and passes every port through. No logic.

`timescale 1ns / 1ps

module top_v2_N8 (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [63:0] a_col,
    input  wire [63:0] b_row,
    output wire in_ready,
    output wire busy,
    output wire done,
    output wire [2047:0] c_flat,
    output wire alarm,
    output wire chk_fault
);

    labft_top_2 #(.N(8), .K(8)) u (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .a_col    (a_col),
        .b_row    (b_row),
        .in_ready (in_ready),
        .busy     (busy),
        .done     (done),
        .c_flat   (c_flat),
        .alarm    (alarm),
        .chk_fault(chk_fault)
    );

endmodule
