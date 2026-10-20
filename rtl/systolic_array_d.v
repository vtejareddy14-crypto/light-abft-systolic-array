// -----------------------------------------------------------------------------
// systolic_array_d.v - NxN output-stationary array with a row-by-row output
//                      (used by the drain variants V0-D, V1-D, V2-D).
//
// WHAT: the same grid as systolic_array.v, built from pe_d.v. The results
//       are NOT all exposed at once. Instead, each PE's acc_in is wired to the
//       PE above it, and only the BOTTOM row is an output (c_row).
//       While shift = 1, every column moves down one PE per clock:
//         cycle 0 of the output phase: c_row = row N-1 of C
//         cycle 1                    : c_row = row N-2 of C
//         ...
//         cycle N-1                  : c_row = row 0   of C
//       Row 0 takes zeros from the top, so after N shifts the array is empty.
// WHY : this is the realistic way an output-stationary array hands its
//       results to memory: N numbers per clock instead of N*N wires.
//
// systolic_array.v itself is NOT changed: V0 and V1 still use it.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module systolic_array_d #(
    parameter N          = 8,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        clear_acc,
    input  wire                        shift,      // output phase

    input  wire [N*DATA_WIDTH-1:0]     a_edge,     // one operand per row
    input  wire [N*DATA_WIDTH-1:0]     b_edge,     // one operand per column

    output wire [N*ACC_WIDTH-1:0]      c_row       // bottom row: C[N-1-d][j] at index j
);

    genvar i, j;

    wire signed [DATA_WIDTH-1:0] a_wire [0:N-1][0:N];
    wire signed [DATA_WIDTH-1:0] b_wire [0:N][0:N-1];
    // acc_wire[i][j] = result going INTO PE(i,j) from above during shift.
    // Row 0 gets zero; acc_wire[i+1][j] is the result of PE(i,j).
    wire signed [ACC_WIDTH-1:0]  acc_wire [0:N][0:N-1];

    generate
        for (i = 0; i < N; i = i + 1) begin : g_a_edge
            assign a_wire[i][0] = $signed(a_edge[i*DATA_WIDTH +: DATA_WIDTH]);
        end
        for (j = 0; j < N; j = j + 1) begin : g_b_edge
            assign b_wire[0][j]   = $signed(b_edge[j*DATA_WIDTH +: DATA_WIDTH]);
            assign acc_wire[0][j] = {ACC_WIDTH{1'b0}};
        end

        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                pe_d #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .clear_acc (clear_acc),
                    .shift     (shift),
                    .a_in      (a_wire[i][j]),
                    .b_in      (b_wire[i][j]),
                    .acc_in    (acc_wire[i][j]),
                    .a_out     (a_wire[i][j+1]),
                    .b_out     (b_wire[i+1][j]),
                    .acc_out   (acc_wire[i+1][j])
                );
            end
        end

        // the bottom row leaves the array
        for (j = 0; j < N; j = j + 1) begin : g_out
            assign c_row[j*ACC_WIDTH +: ACC_WIDTH] = acc_wire[N][j];
        end
    endgenerate

endmodule
