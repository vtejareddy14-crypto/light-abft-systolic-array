// -----------------------------------------------------------------------------
// tb_fi_d.v - fault-injection campaign testbench for the DRAIN variants:
//             V0-D (array_top_d), V1-D (-DV1D, labft_top_d), V1-DW (-DV1DW,
//             labft_top_dw: doubling total),
//             V2-D (-DV2D, labft_top_d2).
//
// The same as tb/tb_fi.v (same plusargs, same fault modes, same result line),
// except that the results come out one row per clock on c_row while
// row_valid = 1 (bottom row first). This testbench collects the rows into
// c_got and compares c_got with the golden C when done is seen.
// A row that never came out stays at an impossible marker, so it counts as wrong.
//
// Result line: fid site mode cycle mat correct n_wrong alarm hang done_rc mask chk_fault
//   (one more column than tb_fi.v: chk_fault, V2-D only, else 0)
// Run cycle numbering: rc = 0 is the CLEAR cycle, stream = 1..K,
// rows out = K+2N-1 .. K+3N-2, done = K+3N-1 in a fault-free run.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

`ifdef V2D
  `define ATOP dut.u_top
  `define CHK1 dut.u_chk1
  `define CHK2 dut.u_chk2
  `define TOP  dut
`elsif V1D
  `define ATOP dut.u_top
  `define CHK  dut.u_chk
`elsif V1DW
  `define ATOP dut.u_top
  `define CHK  dut.u_chk
`else
  `define ATOP dut
`endif

module tb_fi_d;

    parameter N          = 4;
    parameter K          = 4;
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH  = 32;
    parameter MAXT       = 16;

    localparam TIMEOUT = 2*(K + 3*N) + 8;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                          rst_n;
    reg                          start;
    reg  [N*DATA_WIDTH-1:0]      a_col;
    reg  [N*DATA_WIDTH-1:0]      b_row;
    wire                         in_ready;
    wire                         busy;
    wire                         row_valid;
    wire                         done;
    wire [N*ACC_WIDTH-1:0]       c_row;
    wire                         alarm;
    wire                         chk_fault;

`ifdef V2D
    labft_top_d2 #(.N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_col(a_col), .b_row(b_row),
        .in_ready(in_ready), .busy(busy), .row_valid(row_valid), .done(done),
        .c_row(c_row), .alarm(alarm), .chk_fault(chk_fault));
`elsif V1D
    labft_top_d #(.N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_col(a_col), .b_row(b_row),
        .in_ready(in_ready), .busy(busy), .row_valid(row_valid), .done(done),
        .c_row(c_row), .alarm(alarm));
    assign chk_fault = 1'b0;
`elsif V1DW
    labft_top_dw #(.N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_col(a_col), .b_row(b_row),
        .in_ready(in_ready), .busy(busy), .row_valid(row_valid), .done(done),
        .c_row(c_row), .alarm(alarm));
    assign chk_fault = 1'b0;
`else
    array_top_d #(.N(N), .K(K), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .a_col(a_col), .b_row(b_row),
        .in_ready(in_ready), .clear_o(), .busy(busy), .row_valid(row_valid), .done(done),
        .c_row(c_row));
    assign alarm     = 1'b0;
    assign chk_fault = 1'b0;
`endif

    `include `FI_SITES

    reg [N*DATA_WIDTH-1:0] amem [0:MAXT*K-1];
    reg [N*DATA_WIDTH-1:0] bmem [0:MAXT*K-1];
    reg [ACC_WIDTH-1:0]    cmem [0:MAXT*N*N-1];

    reg [8*512-1:0] vecdir, faultfile, outfile, vcdfile;
    integer fin, fout, nread, nrun;
    integer fid, site, mode, fcyc, mat;
    integer rc, t, ii, jj, nwrong, done_rc, got_done, hang, alarm_s, chkf_s, nrows;
    reg     inv_on;
    reg [N*N-1:0]           mask;
    reg [N*N*ACC_WIDTH-1:0] c_got;      // rows collected from c_row
    reg [N*N-1:0]           got;        // which elements were delivered

    // held-inverted register fault (same as tb_fi.v)
    always @(posedge clk) begin
        if (inv_on) begin
            #1;
            fi_flip(site);
        end
    end

    task drive_inputs;
        begin
            if (in_ready && t < K) begin
                a_col = amem[mat*K + t];
                b_row = bmem[mat*K + t];
                t = t + 1;
            end else begin
                a_col = {N*DATA_WIDTH{1'b0}};
                b_row = {N*DATA_WIDTH{1'b0}};
            end
        end
    endtask

    // store the row now on c_row: the d-th row out is row N-1-d
    task collect_row;
        begin
            if (nrows < N) begin
                for (jj = 0; jj < N; jj = jj + 1) begin
                    c_got[((N-1-nrows)*N + jj)*ACC_WIDTH +: ACC_WIDTH] = c_row[jj*ACC_WIDTH +: ACC_WIDTH];
                    got[(N-1-nrows)*N + jj] = 1'b1;
                end
            end
            nrows = nrows + 1;
        end
    endtask

    task compare_c;
        begin
            nwrong = 0;
            mask = {N*N{1'b0}};
            for (ii = 0; ii < N*N; ii = ii + 1) begin
                if (!got[ii] || c_got[ii*ACC_WIDTH +: ACC_WIDTH] !== cmem[mat*N*N + ii]) begin
                    nwrong = nwrong + 1;
                    mask[ii] = 1'b1;
                end
            end
            // more rows than N (a control fault) also means a wrong delivery
            if (nrows > N && nwrong == 0) nwrong = -2;
        end
    endtask

    task run_one;
        begin
            inv_on = 1'b0;
            rst_n  = 1'b0;
            start  = 1'b0;
            t      = 0;
            nrows  = 0;
            got    = {N*N{1'b0}};
            c_got  = {N*N*ACC_WIDTH{1'b0}};
            a_col  = {N*DATA_WIDTH{1'b0}};
            b_row  = {N*DATA_WIDTH{1'b0}};
            @(negedge clk);
            rst_n = 1'b1;

            if (mode == 1) fi_force(site, 1'b0);
            if (mode == 2) fi_force(site, 1'b1);
            if (mode == 3) begin
                fi_flip(site);
                inv_on = 1'b1;
            end

            start = 1'b1;
            @(negedge clk);          // rc = 0
            start = 1'b0;
            rc = 0;
            got_done = 0;
            hang = 0;
            done_rc = -1;
            while (!got_done && !hang) begin
                if (mode == 4 && rc == fcyc) fi_flip(site);
                if (mode == 4 && rc == fcyc + 1 && fi_is_net(site)) fi_release(site);
                drive_inputs;
                if (row_valid) collect_row;
                if (done) begin
                    got_done = 1;
                    done_rc = rc;
                    compare_c;
                end else if (rc >= TIMEOUT) begin
                    hang = 1;
                    compare_c;
                    if (nwrong == 0) nwrong = -1;
                end
                if (!got_done && !hang) begin
                    @(negedge clk);
                    rc = rc + 1;
                end
            end
            // the alarm latches on the edge that ends the done cycle
            @(negedge clk);
            alarm_s = alarm;
            chkf_s  = chk_fault;
            inv_on = 1'b0;
            if (mode == 1 || mode == 2 || (mode == 4 && fi_is_net(site))) fi_release(site);
            $fdisplay(fout, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %h %0d",
                      fid, site, mode, fcyc, mat, (nwrong == 0 && !hang), nwrong,
                      alarm_s, hang, done_rc, mask, chkf_s);
        end
    endtask

    initial begin
        if (!$value$plusargs("vec=%s", vecdir) || !$value$plusargs("faults=%s", faultfile) ||
            !$value$plusargs("out=%s", outfile)) begin
            $display("FATAL: need +vec= +faults= +out=");
            $finish;
        end
        if ($value$plusargs("vcd=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_fi_d);
        end
        $readmemh({vecdir, "/a.hex"}, amem);
        $readmemh({vecdir, "/b.hex"}, bmem);
        $readmemh({vecdir, "/c.hex"}, cmem);
        fin  = $fopen(faultfile, "r");
        fout = $fopen(outfile, "w");
        inv_on = 1'b0;
        site = -1;
        nrun = 0;
        nread = $fscanf(fin, "%d %d %d %d %d\n", fid, site, mode, fcyc, mat);
        while (nread == 5) begin
            run_one;
            nrun = nrun + 1;
            nread = $fscanf(fin, "%d %d %d %d %d\n", fid, site, mode, fcyc, mat);
        end
        $fclose(fout);
        $display("FI_DONE runs=%0d", nrun);
        $finish;
    end

endmodule
