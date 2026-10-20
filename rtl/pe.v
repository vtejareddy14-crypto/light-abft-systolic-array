
// -----------------------------------------------------------------------------
// pe.v - Single Processing Element, Output-Stationary (OS) dataflow.
//
// Phase 0 baseline. No gating / remainder logic here - that is Phase 3.
//
// Each cycle this PE:
//   1. multiplies the operands presented on a_in and b_in,
//   2. adds that product into its own local accumulator (the "output" that
//      stays put - this is what makes the dataflow output-stationary),
//   3. forwards a_in to the right (a_out) and b_in downward (b_out) so the
//      neighbouring PEs see the same values exactly one cycle later.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module pe #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,      // active-low, power-up only
    input  wire                          enable,     // STUB - unused in Phase 0
    input  wire                          clear_acc,  // zero the accumulator between GEMMs

    input  wire signed [DATA_WIDTH-1:0]  a_in,       // from left neighbour
    input  wire signed [DATA_WIDTH-1:0]  b_in,       // from PE above

    output reg  signed [DATA_WIDTH-1:0]  a_out,      // to right neighbour
    output reg  signed [DATA_WIDTH-1:0]  b_out,      // to PE below
    output reg  signed [ACC_WIDTH-1:0]   acc_out     // local partial sum
);

    // Combinational intermediate: a continuous assignment, NOT clocked.
  
    wire signed [2*DATA_WIDTH-1:0] product = a_in * b_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out   <= {DATA_WIDTH{1'b0}};
            b_out   <= {DATA_WIDTH{1'b0}};
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (clear_acc) begin
            // Flush the pipeline registers too, not just the accumulator, so a
            // stale operand cannot leak into the next GEMM through a_out/b_out.
            a_out   <= {DATA_WIDTH{1'b0}};
            b_out   <= {DATA_WIDTH{1'b0}};
            acc_out <= {ACC_WIDTH{1'b0}};
        end else begin
            a_out   <= a_in;
            b_out   <= b_in;
            acc_out <= acc_out + product;
        end
    end

endmodule
