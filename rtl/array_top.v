// -----------------------------------------------------------------------------
// array_top.v - V0 baseline: skew registers + controller + NxN OS array.
//
// WHAT: the unprotected accelerator (variant V0) = input gate + skew
//       registers + a small controller + the unchanged Phase 0 array.
// WHY : the Phase 0 array needs pre-skewed inputs and external clear/done
//       control. Light ABFT must tap the UNSKEWED inputs, so the skew has to
//       live in RTL we synthesize (and inject faults into), not in a testbench.
//
// The user (testbench) streams the operands UNSKEWED, one step t per cycle:
//   a_col = column t of A  (element i = A[i][t] at a_col[i*DW +: DW])
//   b_row = row    t of B  (element j = B[t][j] at b_row[j*DW +: DW])
// for t = 0 .. K-1, on the K cycles where in_ready = 1.
//
// This wrapper then
//   * delays row i of A by i cycles and column j of B by j cycles (skew),
//     so PE(i,j) sees A[i][t] and B[t][j] in the same cycle (t + i + j);
//   * forces the edge inputs to zero outside the K streaming cycles, because
//     the PEs accumulate EVERY cycle (enable is an unused stub);
//   * pulses clear_acc once before streaming, and pulses done when the last
//     PE (N-1,N-1) has added its last product.
//
// Timing (measured in simulation):
//   cycle  -1        : CLEAR   (clear_acc = 1; a start seen in IDLE got us here)
//   cycles 0..K-1    : STREAM  (in_ready = 1, operands accepted)
//   cycles K..K+2N-3 : DRAIN   (2N-2 cycles, edge inputs forced to 0)
//   cycle  K+2N-2    : DONE    (done = 1, c_flat valid)
// PE(N-1,N-1) adds its last product (t = K-1) at the end of cycle
// K-1 + 2(N-1) = K+2N-3, so c_flat is final at the start of cycle K+2N-2.
// c_flat stays valid after done until the next start (inputs stay zero).
//
// The Light ABFT checker (V1) taps a_col / b_row and in_ready from here.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module array_top #(
    parameter N          = 4,
    parameter K          = 4,     // streaming length (inner dimension)
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        start,     // begin one multiply (IDLE only)

    input  wire [N*DATA_WIDTH-1:0]     a_col,     // unskewed column t of A
    input  wire [N*DATA_WIDTH-1:0]     b_row,     // unskewed row t of B

    output wire                        in_ready,  // a_col/b_row consumed this cycle
    output wire                        clear_o,   // CLEAR cycle (for the V1 checker)
    output wire                        busy,
    output wire                        done,      // 1-cycle pulse: c_flat valid
    output wire [N*N*ACC_WIDTH-1:0]    c_flat     // C[i][j] at index i*N+j
);

    // ---- sizes (fixed when the design is built) ----
    // DRAIN_CYCLES: cycles after the last input until PE(N-1,N-1) is done.
    // CNT_MAX: the counter must count up to K (STREAM) and 2N-2 (DRAIN).
    // CW: bits the counter needs. $clog2(x) is a built-in function: the
    //     number of bits needed to count 0 .. x-1.
    //     Example: CNT_MAX = 6 -> $clog2(6) = 3, because 3 bits count 0..7.
    // (N must be at least 2, so CNT_MAX >= 2 and CW >= 1.)
    localparam DRAIN_CYCLES = 2*N - 2;
    localparam CNT_MAX      = (K > DRAIN_CYCLES) ? K : DRAIN_CYCLES;
    localparam CW           = $clog2(CNT_MAX);

    // ---- controller ----
    localparam [2:0] S_IDLE   = 3'd0,
                     S_CLEAR  = 3'd1,
                     S_STREAM = 3'd2,
                     S_DRAIN  = 3'd3,
                     S_DONE   = 3'd4;

    reg [2:0]    state;
    reg [CW-1:0] cnt;      // counts cycles inside STREAM and DRAIN

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cnt   <= {CW{1'b0}};
        end else begin
            case (state)
                S_IDLE: begin
                    cnt <= {CW{1'b0}};
                    if (start) state <= S_CLEAR;
                end
                S_CLEAR: begin
                    cnt   <= {CW{1'b0}};
                    state <= S_STREAM;
                end
                S_STREAM: begin
                    if (cnt == K-1) begin
                        cnt   <= {CW{1'b0}};
                        // N = 1 has no drain: go straight to DONE
                        state <= (DRAIN_CYCLES == 0) ? S_DONE : S_DRAIN;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_DRAIN: begin
                    if (cnt == DRAIN_CYCLES-1) begin
                        cnt   <= {CW{1'b0}};
                        state <= S_DONE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_DONE: begin
                    cnt   <= {CW{1'b0}};
                    state <= S_IDLE;
                end
                default: begin               // illegal state: recover to IDLE
                    cnt   <= {CW{1'b0}};
                    state <= S_IDLE;
                end
            endcase
        end
    end

    wire clear_acc = (state == S_CLEAR);
    assign clear_o  = clear_acc;
    assign in_ready = (state == S_STREAM);
    assign done     = (state == S_DONE);
    assign busy     = (state != S_IDLE);

    // ---- gate + skew ----
    // Outside STREAM the edges must see zeros, otherwise stale inputs would be
    // multiplied and accumulated during drain.
    wire [N*DATA_WIDTH-1:0] a_gated = in_ready ? a_col : {N*DATA_WIDTH{1'b0}};
    wire [N*DATA_WIDTH-1:0] b_gated = in_ready ? b_row : {N*DATA_WIDTH{1'b0}};

    wire [N*DATA_WIDTH-1:0] a_edge;
    wire [N*DATA_WIDTH-1:0] b_edge;

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_skew
            // row i of A: delay i cycles
            skew_line #(.DEPTH(i), .WIDTH(DATA_WIDTH)) u_skew_a (
                .clk   (clk),
                .rst_n (rst_n),
                .clear (clear_acc),
                .din   (a_gated[i*DATA_WIDTH +: DATA_WIDTH]),
                .dout  (a_edge [i*DATA_WIDTH +: DATA_WIDTH])
            );
            // column i of B: delay i cycles
            skew_line #(.DEPTH(i), .WIDTH(DATA_WIDTH)) u_skew_b (
                .clk   (clk),
                .rst_n (rst_n),
                .clear (clear_acc),
                .din   (b_gated[i*DATA_WIDTH +: DATA_WIDTH]),
                .dout  (b_edge [i*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

    // ---- the array (unchanged Phase 0 file) ----
    systolic_array #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .enable    (1'b1),        // stub in pe.v; tied off
        .clear_acc (clear_acc),
        .a_edge    (a_edge),
        .b_edge    (b_edge),
        .c_flat    (c_flat)
    );

endmodule
