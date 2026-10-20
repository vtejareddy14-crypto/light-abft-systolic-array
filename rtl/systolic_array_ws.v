// -----------------------------------------------------------------------------
// systolic_array_ws.v - KxN grid of weight-stationary PEs (here K = N).
//
//   Weights : PE(t,j) holds B[t][j]. Row t of B is loaded in one cycle,
//             selected by load_row (load_en = 1).
//   A       : a_edge[t] feeds array row t and flows rightward. Lane t
//             carries A[m][t] (already skewed by t cycles, see ws_top.v).
//   Partial sums flow downward; psum into row 0 is zero.
//   C       : the bottom PE of column j outputs C[m][j] on c_bot[j].
//
// Flattened buses keep this plain Verilog-2001.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module systolic_array_ws #(
    parameter N          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter RW         = 2          // width of load_row
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        clear,
    input  wire                        load_en,
    input  wire [RW-1:0]               load_row,   // which array row takes w_row
    input  wire [N*DATA_WIDTH-1:0]     w_row,      // row of B (element j = B[t][j])
    input  wire [N*DATA_WIDTH-1:0]     a_edge,     // one activation per array row
    output wire [N*ACC_WIDTH-1:0]      c_bot       // bottom of column j
);

    genvar t, j;

    // a_wire[t][j]: activation entering PE(t,j); a_wire[t][N] is unused.
    // p_wire[t][j]: partial sum entering PE(t,j); p_wire[N][j] is the output.
    wire signed [DATA_WIDTH-1:0] a_wire [0:N-1][0:N];
    wire signed [ACC_WIDTH-1:0]  p_wire [0:N][0:N-1];

    generate
        for (t = 0; t < N; t = t + 1) begin : g_a_edge
            assign a_wire[t][0] = $signed(a_edge[t*DATA_WIDTH +: DATA_WIDTH]);
        end
        for (j = 0; j < N; j = j + 1) begin : g_p_edge
            assign p_wire[0][j] = {ACC_WIDTH{1'b0}};
            assign c_bot[j*ACC_WIDTH +: ACC_WIDTH] = p_wire[N][j];
        end

        for (t = 0; t < N; t = t + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                pe_ws #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) u_pe (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .clear    (clear),
                    .load_w   (load_en && (load_row == t)),
                    .w_in     (w_row[j*DATA_WIDTH +: DATA_WIDTH]),
                    .a_in     (a_wire[t][j]),
                    .psum_in  (p_wire[t][j]),
                    .w        (),
                    .a_out    (a_wire[t][j+1]),
                    .psum_out (p_wire[t+1][j])
                );
            end
        end
    endgenerate

endmodule
