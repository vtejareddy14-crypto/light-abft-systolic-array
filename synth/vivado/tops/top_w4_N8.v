// top_w4_N8.v - Vivado top for W4: WS + two doubling checkers, N = K = 8.
// Only fixes the size and passes every port through. No logic.
`timescale 1ns / 1ps
module top_w4_N8 (
    input  wire clk,
    input  wire rst_n,
    input   wire start,
    input   wire [63:0] w_row,
    input   wire [63:0] a_row,
    output  wire w_ready,
    output  wire in_ready,
    output  wire busy,
    output  wire done,
    output  wire [7:0] col_valid,
    output  wire [255:0] c_bot,
    output  wire alarm,
    output  wire chk_fault
);
    labft_top_ws4 #(.N(8), .K(8)) u (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .w_row(w_row),
        .a_row(a_row),
        .w_ready(w_ready),
        .in_ready(in_ready),
        .busy(busy),
        .done(done),
        .col_valid(col_valid),
        .c_bot(c_bot),
        .alarm(alarm),
        .chk_fault(chk_fault)
    );
endmodule
