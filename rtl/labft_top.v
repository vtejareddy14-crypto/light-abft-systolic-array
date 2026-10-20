// -----------------------------------------------------------------------------
// labft_top.v - V1: V0 (array_top) + one Light ABFT checker.
//
// WHAT: wiring only - connects the checker to V0's inputs, control and outputs.
// WHY : keeps V0 byte-for-byte the same inside V1, so the V1-V0 cost
//       difference is exactly the checker.
//
// The checker taps the SAME raw input wires the array gets (a_col, b_row)
// before any skew register, plus the controller's clear / in_ready / done.
// Those taps are shared with the array (common mode): a fault on a raw input
// wire or in the controller is seen identically by array and checker.
// Ports are identical to array_top plus `alarm`.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_top #(
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
    output wire                        alarm      // sticky until reset
);

    wire clear;

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
    ) u_chk (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (clear),
        .acc_en  (in_ready),
        .check   (done),
        .a_col   (a_col),
        .b_row   (b_row),
        .c_flat  (c_flat),
        .alarm   (alarm)
    );

endmodule
