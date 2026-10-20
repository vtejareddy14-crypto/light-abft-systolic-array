// -----------------------------------------------------------------------------
// systolic_array.v - NxN grid of output-stationary PEs.
//
// Phase 0 baseline. Pure datapath: no skew logic, no tiling, no gating.
// Operands must arrive at the edges ALREADY SKEWED (see tb_systolic_array.v).
//
//   A enters from the left  : a_edge[i] feeds row i,    flows rightward
//   B enters from the top   : b_edge[j] feeds column j, flows downward
//   C stays put             : PE(i,j) accumulates C[i][j] in place
//
// Ports are flattened buses so this stays plain Verilog-2001 compatible
// (2-D ports would require SystemVerilog).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module systolic_array #(
    parameter N          = 8,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,     // STUB - Phase 3
    input  wire                        clear_acc,

    input  wire [N*DATA_WIDTH-1:0]     a_edge,     // one operand per row
    input  wire [N*DATA_WIDTH-1:0]     b_edge,     // one operand per column

    output wire [N*N*ACC_WIDTH-1:0]    c_flat      // C[i][j] at index i*N+j
);

    genvar i, j;

    // Interconnect. Column 0 / row 0 of these arrays are the edge inputs;
    // index [i][j+1] is what PE(i,j) drives to its right neighbour, and
    // [i+1][j] is what it drives downward.
    wire signed [DATA_WIDTH-1:0] a_wire [0:N-1][0:N];
    wire signed [DATA_WIDTH-1:0] b_wire [0:N][0:N-1];

    generate
        // Edge injection
        for (i = 0; i < N; i = i + 1) begin : g_a_edge
            assign a_wire[i][0] = $signed(a_edge[i*DATA_WIDTH +: DATA_WIDTH]);
        end
        for (j = 0; j < N; j = j + 1) begin : g_b_edge
            assign b_wire[0][j] = $signed(b_edge[j*DATA_WIDTH +: DATA_WIDTH]);
        end

        // The grid
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col

                wire signed [ACC_WIDTH-1:0] acc_ij;

                pe #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .enable    (enable),
                    .clear_acc (clear_acc),

                    .a_in      (a_wire[i][j]),
                    .b_in      (b_wire[i][j]),

                    // exactly the connection worked out by hand:
                    //   pe(i,j).a_out -> pe(i,j+1).a_in
                    //   pe(i,j).b_out -> pe(i+1,j).b_in
                    .a_out     (a_wire[i][j+1]),
                    .b_out     (b_wire[i+1][j]),

                    .acc_out   (acc_ij)
                );

                assign c_flat[(i*N + j)*ACC_WIDTH +: ACC_WIDTH] = acc_ij;
            end
        end
    endgenerate

endmodule
