// -----------------------------------------------------------------------------
// ws_top.v - W0: weight-stationary baseline = controller + skew + WS array.
//
// WHAT: the unprotected WS accelerator. The user (testbench) gives
//   * the K rows of B, one per cycle, while w_ready = 1 (row t on cycle t),
//   * then the N rows of A, one per cycle, while in_ready = 1:
//       a_row = row m of A (element t = A[m][t] at a_row[t*DW +: DW]).
//   Results leave the bottom of the array as they are finished:
//       column j outputs C[m][j] on c_bot[j] while col_valid[j] = 1,
//       m = 0, 1, ..., N-1 on consecutive cycles.
// WHY : this is the paper's dataflow; results stream out on their own, so no
//       separate readout is needed (unlike the OS array).
//
// Timing (cycles counted from the first STREAM cycle, s = 0):
//   CLEAR (1) -> LOAD (K) -> STREAM (N, s = 0..N-1) -> WAIT (K+N-1) -> DONE
//   lane t of A is delayed t cycles (skew), so PE(t,j) sees A[m][t] in cycle
//   m + t + j; the bottom of column j holds C[m][j] in cycle K + j + m.
//   col_valid[j] is in_ready delayed by K + j cycles: it marks exactly those
//   cycles. The last result (C[N-1][N-1]) is out in cycle K + 2N - 2; DONE
//   follows the WAIT so the checker has added it.
//
// The Light ABFT checker (W1) taps w_row, a_row, the load/stream controls,
// col_valid, c_bot, and dot_en/dot_sel (cycles WAIT 0..K-1).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module ws_top #(
    parameter N          = 4,
    parameter K          = 4,          // inner dimension (array rows); use K = N
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 32,
    parameter RW         = (K > 1) ? $clog2(K) : 1   // width of row selects
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        start,      // begin one multiply (IDLE only)
    input  wire [N*DATA_WIDTH-1:0]     w_row,      // row t of B, while w_ready
    input  wire [N*DATA_WIDTH-1:0]     a_row,      // row m of A, while in_ready
    output wire                        w_ready,    // w_row taken this cycle
    output wire                        in_ready,   // a_row taken this cycle
    output wire                        clear_o,    // CLEAR cycle (for the checker)
    output wire [RW-1:0]               load_row,   // array row being loaded
    output wire                        dot_en,     // checker: L step this cycle
    output wire [RW-1:0]               dot_sel,    // checker: which lane
    output wire                        busy,
    output wire                        done,       // 1-cycle pulse: all results out
    output wire [N-1:0]                col_valid,  // c_bot[j] holds a result
    output wire [N*ACC_WIDTH-1:0]      c_bot       // bottom of each column
);

    localparam WAIT_CY = K + N - 1;
    localparam CNT_MAX = (WAIT_CY > K) ? WAIT_CY : K;
    localparam CW      = $clog2(CNT_MAX + 1);
    localparam VW      = K + N - 1;                // valid delay line length

    localparam [2:0] S_IDLE   = 3'd0,
                     S_CLEAR  = 3'd1,
                     S_LOAD   = 3'd2,
                     S_STREAM = 3'd3,
                     S_WAIT   = 3'd4,
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
                    state <= S_LOAD;
                end
                S_LOAD: begin
                    if (cnt == K-1) begin
                        cnt   <= {CW{1'b0}};
                        state <= S_STREAM;
                    end else
                        cnt <= cnt + 1'b1;
                end
                S_STREAM: begin
                    if (cnt == N-1) begin
                        cnt   <= {CW{1'b0}};
                        state <= S_WAIT;
                    end else
                        cnt <= cnt + 1'b1;
                end
                S_WAIT: begin
                    if (cnt == WAIT_CY-1) begin
                        cnt   <= {CW{1'b0}};
                        state <= S_DONE;
                    end else
                        cnt <= cnt + 1'b1;
                end
                S_DONE: begin
                    cnt   <= {CW{1'b0}};
                    state <= S_IDLE;
                end
                default: begin                      // illegal state: recover
                    cnt   <= {CW{1'b0}};
                    state <= S_IDLE;
                end
            endcase
        end
    end

    wire clear   = (state == S_CLEAR);
    assign clear_o  = clear;
    assign w_ready  = (state == S_LOAD);
    assign in_ready = (state == S_STREAM);
    assign done     = (state == S_DONE);
    assign busy     = (state != S_IDLE);
    assign load_row = cnt[RW-1:0];
    assign dot_en   = (state == S_WAIT) && (cnt < K);
    assign dot_sel  = cnt[RW-1:0];

    // ---- valid flag travels with the data: in_ready delayed K + j cycles ----
    reg [VW-1:0] vld_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vld_sr <= {VW{1'b0}};
        else if (clear)
            vld_sr <= {VW{1'b0}};
        else
            vld_sr <= {vld_sr[VW-2:0], in_ready};
    end

    genvar j, t;
    generate
        for (j = 0; j < N; j = j + 1) begin : g_valid
            assign col_valid[j] = vld_sr[K + j - 1];
        end
    endgenerate

    // ---- gate + skew: lane t of A is delayed t cycles ----
    wire [N*DATA_WIDTH-1:0] a_gated = in_ready ? a_row : {N*DATA_WIDTH{1'b0}};
    wire [N*DATA_WIDTH-1:0] a_edge;

    generate
        for (t = 0; t < N; t = t + 1) begin : g_skew
            skew_line #(.DEPTH(t), .WIDTH(DATA_WIDTH)) u_skew_a (
                .clk   (clk),
                .rst_n (rst_n),
                .clear (clear),
                .din   (a_gated[t*DATA_WIDTH +: DATA_WIDTH]),
                .dout  (a_edge [t*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

    systolic_array_ws #(
        .N          (N),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .RW         (RW)
    ) u_array (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (clear),
        .load_en  (w_ready),
        .load_row (load_row),
        .w_row    (w_row),
        .a_edge   (a_edge),
        .c_bot    (c_bot)
    );

endmodule
