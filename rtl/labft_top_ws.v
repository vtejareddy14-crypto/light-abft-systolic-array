// -----------------------------------------------------------------------------
// labft_top_ws.v - W1: W0 (ws_top) + the Light ABFT checker for WS.
//
// WHAT: wiring only - connects labft_checker_ws to W0's inputs, controls and
//       outputs. W0 stays byte-for-byte the same inside W1, so W1 - W0 is the
//       checker's cost (same method as V1 - V0).
// The checker taps the same raw input wires (w_row, a_row) and the same
// controller signals as the array (common mode, like V1).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module labft_top_ws #(
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
    output wire                        alarm      // sticky until reset
);

    wire          clear, dot_en;
    wire [RW-1:0] load_row, dot_sel;

    ws_top #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .RW(RW)
    ) u_top (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .w_row     (w_row),
        .a_row     (a_row),
        .w_ready   (w_ready),
        .in_ready  (in_ready),
        .clear_o   (clear),
        .load_row  (load_row),
        .dot_en    (dot_en),
        .dot_sel   (dot_sel),
        .busy      (busy),
        .done      (done),
        .col_valid (col_valid),
        .c_bot     (c_bot)
    );

    labft_checker_ws #(
        .N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .RW(RW)
    ) u_chk (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear),
        .load_en   (w_ready),
        .load_row  (load_row),
        .acc_en    (in_ready),
        .dot_en    (dot_en),
        .dot_sel   (dot_sel),
        .check     (done),
        .w_row     (w_row),
        .a_row     (a_row),
        .col_valid (col_valid),
        .c_bot     (c_bot),
        .alarm     (alarm)
    );

endmodule
