// -----------------------------------------------------------------------------
// pe_d.v - output-stationary PE that can also SHIFT its result down
//          (used by the drain variants V0-D, V1-D, V2-D).
//
// WHAT: identical to pe.v, plus one extra mode:
//         shift = 1 : acc_out <= acc_in   (take the result of the PE above)
//       So during the "output" phase the results of a column move down one
//       PE per clock, like a conveyor belt, and leave at the bottom row.
// WHY : a real accelerator must move its N*N results out to memory. It
//       cannot put all of them on wires at once (V0 does that with c_flat,
//       which is fine for simulation but not realistic). Shifting down the
//       column is the usual way, and it lets the checker add the results
//       one row at a time (N adders) instead of all at once (N*N-1 adders).
//
// pe.v itself is NOT changed: V0 and V1 still use it.
// Priority of the modes: reset, clear_acc, shift, normal multiply-accumulate.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module pe_d #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,      // active-low, power-up only
    input  wire                          clear_acc,  // zero the accumulator between GEMMs
    input  wire                          shift,      // output phase: take acc_in

    input  wire signed [DATA_WIDTH-1:0]  a_in,       // from left neighbour
    input  wire signed [DATA_WIDTH-1:0]  b_in,       // from PE above
    input  wire signed [ACC_WIDTH-1:0]   acc_in,     // result of the PE above

    output reg  signed [DATA_WIDTH-1:0]  a_out,      // to right neighbour
    output reg  signed [DATA_WIDTH-1:0]  b_out,      // to PE below
    output reg  signed [ACC_WIDTH-1:0]   acc_out     // local result
);

    wire signed [2*DATA_WIDTH-1:0] product = a_in * b_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out   <= {DATA_WIDTH{1'b0}};
            b_out   <= {DATA_WIDTH{1'b0}};
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (clear_acc) begin
            a_out   <= {DATA_WIDTH{1'b0}};
            b_out   <= {DATA_WIDTH{1'b0}};
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (shift) begin
            // output phase: the inputs are zero here, keep the operand
            // registers moving as usual and pass the result down
            a_out   <= a_in;
            b_out   <= b_in;
            acc_out <= acc_in;
        end else begin
            a_out   <= a_in;
            b_out   <= b_in;
            acc_out <= acc_out + product;
        end
    end

endmodule
