// -----------------------------------------------------------------------------
// labft_top_d.v - V1-D: V0-D (array_top_d) + one drain Light ABFT checker.
//
// WHAT: wiring only - connects labft_checker_d to V0-D's inputs, control and
//       row output.
// WHY : keeps V0-D the same inside V1-D, so the V1-D minus V0-D cost
//       difference is exactly the checker.
//
// The checker taps the raw input wires (a_col, b_row), the controller's
// clear / in_ready / row_valid / done, and the row leaving the array (c_row).
// Ports are identical to array_top_d plus `alarm`.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_top_d #(
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
    output wire                        alarm      // sticky until reset
);

    wire clear;

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
    ) u_chk (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (clear),
        .acc_en  (in_ready),
        .row_en  (row_valid),
        .check   (done),
        .a_col   (a_col),
        .b_row   (b_row),
        .c_row   (c_row),
        .alarm   (alarm)
    );

endmodule
