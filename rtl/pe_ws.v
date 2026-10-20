// -----------------------------------------------------------------------------
// pe_ws.v - Single Processing Element, Weight-Stationary (WS) dataflow.
//
// The base paper's dataflow (Libano et al. 2023; their public LABFT RTL,
// int8_pe.sv + int8_quad_mac.sv). Simplified on purpose: one int8 MAC per
// PE, where the paper packs four int8 MACs into one DSP block.
//
// Each cycle this PE:
//   1. keeps its own weight w (loaded once, before the inputs stream in -
//      this is what makes the dataflow weight-stationary),
//   2. multiplies the activation on a_in by w and adds the partial sum coming
//      from the PE above: psum_out <= psum_in + a_in * w,
//   3. forwards a_in to the right (a_out), so the next PE sees it one cycle
//      later.
// Partial sums flow DOWN the column; the bottom PE of column j outputs the
// finished results C[m][j], one per cycle. Every result of column j passes
// through the psum_out register of every PE in that column.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module pe_ws #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,      // active-low
    input  wire                          clear,      // start of a multiply
    input  wire                          load_w,     // capture w_in as the weight
    input  wire signed [DATA_WIDTH-1:0]  w_in,       // weight (row of B)
    input  wire signed [DATA_WIDTH-1:0]  a_in,       // activation, from the left
    input  wire signed [ACC_WIDTH-1:0]   psum_in,    // partial sum, from above
    output reg  signed [DATA_WIDTH-1:0]  w,          // the stationary weight
    output reg  signed [DATA_WIDTH-1:0]  a_out,      // to the right neighbour
    output reg  signed [ACC_WIDTH-1:0]   psum_out    // to the PE below
);

    wire signed [2*DATA_WIDTH-1:0] product = a_in * w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w        <= {DATA_WIDTH{1'b0}};
            a_out    <= {DATA_WIDTH{1'b0}};
            psum_out <= {ACC_WIDTH{1'b0}};
        end else begin
            if (load_w)
                w <= w_in;
            if (clear) begin
                a_out    <= {DATA_WIDTH{1'b0}};
                psum_out <= {ACC_WIDTH{1'b0}};
            end else begin
                a_out    <= a_in;
                psum_out <= psum_in + product;
            end
        end
    end

endmodule
