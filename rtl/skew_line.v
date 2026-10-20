// -----------------------------------------------------------------------------
// skew_line.v - delay one operand lane by DEPTH clock cycles.
//
// WHAT: a DEPTH-stage shift register, WIDTH bits per stage.
// WHY : the array needs its edge inputs "skewed" (staggered in time) so that
//       A[i][t] and B[t][j] meet in PE(i,j) in the same cycle. The Phase 0
//       array has no skew logic inside, so array_top adds it with these lines:
//       row i of A is delayed i cycles, column j of B is delayed j cycles.
//       DEPTH = 0 is a plain wire (no flops).
//
// The shift register is one flat vector (not a reg array) so that every bit
// has a simple hierarchical name for fault injection: sr[bit].
//   sr[WIDTH-1:0]              = stage 0, newest (1 cycle old)
//   sr[DEPTH*WIDTH-1 -: WIDTH] = stage DEPTH-1, oldest (DEPTH cycles old) = dout
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module skew_line #(
    parameter DEPTH = 1,
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             clear,   // same clear_acc as the PEs: flush stale data
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);

    genvar s;

    generate
        if (DEPTH == 0) begin : g_wire
            assign dout = din;
        end else begin : g_reg
            reg  [DEPTH*WIDTH-1:0] sr;
            wire [DEPTH*WIDTH-1:0] sr_next;   // sr moved up by one stage

            // stage 0 takes the new input ...
            assign sr_next[0 +: WIDTH] = din;
            // ... and every later stage takes the stage before it
            for (s = 1; s < DEPTH; s = s + 1) begin : g_stage
                assign sr_next[s*WIDTH +: WIDTH] = sr[(s-1)*WIDTH +: WIDTH];
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    sr <= {DEPTH*WIDTH{1'b0}};
                else if (clear)
                    sr <= {DEPTH*WIDTH{1'b0}};
                else
                    sr <= sr_next;
            end

            assign dout = sr[DEPTH*WIDTH-1 -: WIDTH];
        end
    endgenerate

endmodule
