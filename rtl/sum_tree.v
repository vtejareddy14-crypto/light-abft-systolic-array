// -----------------------------------------------------------------------------
// sum_tree.v - combinational adder tree, written as a "knockout tournament".
//
// WHAT: adds NUM signed numbers at once (no clock, no registers).
// WHY : the Light ABFT checker needs three sums: SV_A[t] (N inputs), SV_B[t]
//       (N inputs) and the sum of all N*N accumulators. A tree keeps the
//       logic depth at ceil(log2(NUM)) adders instead of NUM-1 in a chain.
//
// How: put the NUM inputs (sign-extended to W_OUT bits) in a row, then play
// rounds. In each round, neighbours are added in pairs: 0+1, 2+3, 4+5, ...
// so the row halves. With an odd count the last one gets a bye (moves up
// unchanged). After ceil(log2(NUM)) rounds one number is left: the sum.
//
//   example NUM = 4, inputs 1 2 3 4:
//     round 1:  (1+2) (3+4)  ->  3 7
//     round 2:  (3+7)        ->  10
//
// It is written as a procedural loop (always @*) rather than one assign per
// adder because Icarus simulates the assign version about 14x slower
// (measured: 8x8 V1, 105 multiplies, 30.2 s vs 2.2 s).
// Synthesis unrolls the loop into the same tree of adders.
// All additions wrap modulo 2^W_OUT, same as the array's accumulators.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module sum_tree #(
    parameter NUM   = 4,
    parameter W_IN  = 8,
    parameter W_OUT = 10
) (
    input  wire [NUM*W_IN-1:0] in_flat,
    output reg  [W_OUT-1:0]    sum
);

    reg [NUM*W_OUT-1:0] row;    // the current row of numbers, W_OUT bits each
    integer n;                  // how many numbers are still in the row
    integer k;

    always @* begin
        // start: every input, sign-extended from W_IN to W_OUT bits
        for (k = 0; k < NUM; k = k + 1)
            row[k*W_OUT +: W_OUT] = $signed(in_flat[k*W_IN +: W_IN]);

        // rounds: add neighbours in pairs until one number is left
        for (n = NUM; n > 1; n = (n + 1) / 2) begin
            for (k = 0; k < n / 2; k = k + 1)
                row[k*W_OUT +: W_OUT] = row[(2*k)*W_OUT +: W_OUT] + row[(2*k+1)*W_OUT +: W_OUT];
            if (n % 2 == 1)
                row[(n/2)*W_OUT +: W_OUT] = row[(n-1)*W_OUT +: W_OUT];   // bye
        end

        sum = row[0 +: W_OUT];
    end

endmodule
