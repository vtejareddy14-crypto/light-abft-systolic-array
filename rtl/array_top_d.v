// -----------------------------------------------------------------------------
// array_top_d.v - V0-D: like array_top.v (V0), but the results leave the
//                 array ROW BY ROW at the end (drain), not all at once.
//
// WHAT: input gate + skew registers + controller + systolic_array_d.
//       The controller has one extra phase, OUT (N cycles), after the compute
//       has finished. In OUT the array shifts its results down one row per
//       clock, and the bottom row appears on c_row with row_valid = 1:
//         OUT cycle 0: c_row = row N-1 of C,  ...,  OUT cycle N-1: row 0.
//       done pulses for one cycle after the last row.
// WHY : the fair, realistic output-stationary baseline. A real accelerator
//       sends N results per clock to memory; V0's c_flat (all N*N results on
//       wires at once) is only possible in simulation or with virtual pins.
//       The drain checker (V1-D) adds each row as it leaves.
//
// Timing (cycles counted from the first streaming cycle = cycle 0):
//   cycle  -1              : CLEAR
//   cycles 0 .. K-1        : STREAM (in_ready = 1)
//   cycles K .. K+2N-3     : FLUSH  (2N-2 cycles: the last products are added;
//                            this is the phase called DRAIN in array_top.v)
//   cycles K+2N-2 .. K+3N-3: OUT    (row_valid = 1, one row per cycle)
//   cycle  K+3N-2          : DONE   (done = 1)
// So one multiply takes N cycles more than in V0.
//
// array_top.v itself is NOT changed: V0 and V1 still use it.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module array_top_d #(
    parameter N          = 4,
    parameter K          = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        start,     // begin one multiply (IDLE only)

    input  wire [N*DATA_WIDTH-1:0]     a_col,     // unskewed column t of A
    input  wire [N*DATA_WIDTH-1:0]     b_row,     // unskewed row t of B

    output wire                        in_ready,  // a_col/b_row consumed this cycle
    output wire                        clear_o,   // CLEAR cycle (for the checker)
    output wire                        busy,
    output wire                        row_valid, // c_row holds one row of C
    output wire                        done,      // 1-cycle pulse after the last row
    output wire [N*ACC_WIDTH-1:0]      c_row      // the row leaving the array
);

    // ---- sizes ----
    // FLUSH_CYCLES: cycles after the last input until PE(N-1,N-1) is done.
    // CNT_MAX: the counter must count up to K, 2N-2 and N.
    localparam FLUSH_CYCLES = 2*N - 2;
    localparam CNT_MAX      = (K > FLUSH_CYCLES) ? K : FLUSH_CYCLES;
    localparam CW           = $clog2(CNT_MAX);

    // ---- controller ----
    localparam [2:0] S_IDLE   = 3'd0,
                     S_CLEAR  = 3'd1,
                     S_STREAM = 3'd2,
                     S_FLUSH  = 3'd3,
                     S_OUT    = 3'd4,
                     S_DONE   = 3'd5;

    reg [2:0]    state;
    reg [CW-1:0] cnt;

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
                        state <= S_FLUSH;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_FLUSH: begin
                    if (cnt == FLUSH_CYCLES-1) begin
                        cnt   <= {CW{1'b0}};
                        state <= S_OUT;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_OUT: begin
                    if (cnt == N-1) begin
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
    wire shift     = (state == S_OUT);
    assign clear_o   = clear_acc;
    assign in_ready  = (state == S_STREAM);
    assign row_valid = shift;
    assign done      = (state == S_DONE);
    assign busy      = (state != S_IDLE);

    // ---- gate + skew (same as array_top.v) ----
    wire [N*DATA_WIDTH-1:0] a_gated = in_ready ? a_col : {N*DATA_WIDTH{1'b0}};
    wire [N*DATA_WIDTH-1:0] b_gated = in_ready ? b_row : {N*DATA_WIDTH{1'b0}};

    wire [N*DATA_WIDTH-1:0] a_edge;
    wire [N*DATA_WIDTH-1:0] b_edge;

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_skew
            skew_line #(.DEPTH(i), .WIDTH(DATA_WIDTH)) u_skew_a (
                .clk   (clk),
                .rst_n (rst_n),
                .clear (clear_acc),
                .din   (a_gated[i*DATA_WIDTH +: DATA_WIDTH]),
                .dout  (a_edge [i*DATA_WIDTH +: DATA_WIDTH])
            );
            skew_line #(.DEPTH(i), .WIDTH(DATA_WIDTH)) u_skew_b (
                .clk   (clk),
                .rst_n (rst_n),
                .clear (clear_acc),
                .din   (b_gated[i*DATA_WIDTH +: DATA_WIDTH]),
                .dout  (b_edge [i*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

    // ---- the array with the row-by-row output ----
    systolic_array_d #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear_acc (clear_acc),
        .shift     (shift),
        .a_edge    (a_edge),
        .b_edge    (b_edge),
        .c_row     (c_row)
    );

endmodule
