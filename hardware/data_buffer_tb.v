`timescale 1ns/1ps
// data_buffer_tb.v
// Tests the data_buffer memory at all four sizes it will be used at, using the
// REAL numbers from the answer key (the 16 real heartbeats):
//
//     input buffer   260   <- answer_key/beats_in.hex        (the heartbeat, Q4.12)
//     buffer A      1024   <- answer_key/exp_conv1_pool.hex  (conv1 output, 8 x 128)
//     buffer B       992   <- answer_key/exp_conv2_pool.hex  (conv2 output, 16 x 62, flattened)
//     buffer C        32   <- answer_key/exp_fc1.hex         (fc1 output)
//
// The four buffers are tested at the same time, each by one copy of buffer_check.
// Every copy does, in this order:
//   1. a read before any write shows "unknown" (x)                    (simulation only)
//   2. for each of the 16 beats:
//        - write the beat (even beats in address order, odd beats scrambled), which
//          also overwrites the previous beat completely
//        - read every address back three ways: up, down, scrambled; every read
//          must (a) still show the OLD value right after the address changes and
//          (b) show the right value ONE clock edge later
//        - read it the way the real layer will: the real layer_ctrl + addr_gen
//          drive the read address through a whole layer's worth of reads, and every
//          value is compared with the answer key
//   3. corner cases: extreme values, walking 1s / 0s, neighbours not disturbed,
//      we = 0 ignored, read during write returns the OLD value, repeated writes,
//      the output holds while nothing changes
//   4. 20,000 random operations, each compared with a shadow copy kept in this file
// Anything wrong prints a FAIL line. A watchdog stops the run if it hangs.
//
// Gate-level mode: compile with -DGL to use the synthesized netlists
// (data_buffer_260 / _1024 / _992 / _32) instead of data_buffer.v.

module buffer_check #(
    parameter DEPTH   = 1024,
    parameter AW      = $clog2(DEPTH),
    parameter NBEATS  = 16,
    parameter KEYFILE = "answer_key/exp_conv1_pool.hex",
    parameter NAME    = "A",
    // how the layer that READS this buffer walks through it
    parameter P_NF    = 1,        // number of filters / neurons walked
    parameter P_NP    = 124,      // positions
    parameter P_NC    = 8,        // channels
    parameter P_K     = 5,        // kernel (steps per channel)
    parameter P_ROW   = 128,      // row length
    parameter NRAND   = 20000,
    parameter [31:0] SEED = 32'd1
)(
    input  wire        clk,
    output reg         done   = 1'b0,
    output reg  [31:0] errors = 32'd0,
    output reg  [31:0] checks = 32'd0
);

    // ------------------------------------------------------------------
    // the buffer under test
    // ------------------------------------------------------------------
    reg                 we      = 1'b0;
    reg  [AW-1:0]       waddr   = {AW{1'b0}};
    reg  signed [15:0]  wdata   = 16'sd0;
    reg  [AW-1:0]       raddr_d = {AW{1'b0}};   // read address chosen by this file
    reg                 pat     = 1'b0;         // 1 = read address comes from addr_gen
    wire [10:0]         data_addr;
    wire [AW-1:0]       raddr   = pat ? data_addr[AW-1:0] : raddr_d;
    wire signed [15:0]  rdata;

`ifdef GL
    generate
        if (DEPTH == 260)
            data_buffer_260  dut (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .raddr(raddr), .rdata(rdata));
        else if (DEPTH == 1024)
            data_buffer_1024 dut (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .raddr(raddr), .rdata(rdata));
        else if (DEPTH == 992)
            data_buffer_992  dut (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .raddr(raddr), .rdata(rdata));
        else
            data_buffer_32   dut (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .raddr(raddr), .rdata(rdata));
    endgenerate
`else
    data_buffer #(.DEPTH(DEPTH)) dut (.clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                                      .raddr(raddr), .rdata(rdata));
`endif

    // ------------------------------------------------------------------
    // the real address generator + layer controller, used for the "read it the
    // way the real layer does" test
    // ------------------------------------------------------------------
    localparam [5:0]  C_NF  = P_NF;
    localparam [8:0]  C_NP  = P_NP;
    localparam [3:0]  C_NC  = P_NC;
    localparam [9:0]  C_K   = P_K;
    localparam [10:0] C_ROW = P_ROW;
    localparam [10:0] C_NT  = P_NC * P_K;

    reg  rst_n = 1'b0, start = 1'b0, init = 1'b0;
    wire clear_acc, enable, busy, ctrl_done;
    wire [10:0] term_idx;
    wire [15:0] weight_addr;
    wire [5:0]  filter_idx;
    wire [8:0]  position_idx;
    wire        last_output;

    layer_ctrl lc (.clk(clk), .rst_n(rst_n), .start(start), .num_terms(C_NT),
                   .clear_acc(clear_acc), .enable(enable), .busy(busy),
                   .done(ctrl_done), .term_idx(term_idx));

    addr_gen ag (.clk(clk), .rst_n(rst_n), .init(init), .step(enable), .next_output(ctrl_done),
                 .num_filters(C_NF), .num_positions(C_NP), .num_channels(C_NC),
                 .kernel(C_K), .row_len(C_ROW),
                 .data_addr(data_addr), .weight_addr(weight_addr),
                 .filter_idx(filter_idx), .position_idx(position_idx),
                 .last_output(last_output));

    // ------------------------------------------------------------------
    // answer key and shadow copy
    // ------------------------------------------------------------------
    reg [15:0] key [0:NBEATS*DEPTH-1];
    reg [15:0] sh  [0:DEPTH-1];            // shadow copy for the random test
    initial $readmemh(KEYFILE, key);

    // ------------------------------------------------------------------
    // checking helpers
    // ------------------------------------------------------------------
    task ck(input [15:0] got, input [15:0] exp, input [8*34-1:0] what, input integer where);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL [%0s] %0s, address/index %0d: got %h expected %h",
                             NAME, what, where, got, exp);
            end
        end
    endtask

    task bad(input [8*34-1:0] what, input integer where);
        begin
            checks = checks + 1;
            errors = errors + 1;
            if (errors <= 10)
                $display("FAIL [%0s] %0s, address/index %0d", NAME, what, where);
        end
    endtask

    // All stimulus is applied just after a falling clock edge and looked at just
    // before the next falling edge, so nothing races the rising (active) edge.

    task wr(input [AW-1:0] a, input [15:0] d);      // one write, then we back to 0
        begin
            @(negedge clk); we = 1'b1; waddr = a; wdata = d;
            @(negedge clk); we = 1'b0;
        end
    endtask

    task rd(input [AW-1:0] a, output [15:0] v);     // set the address, value is there one edge later
        begin
            @(negedge clk); raddr_d = a;
            @(negedge clk); v = rdata;
        end
    endtask

    task rd_ck(input [AW-1:0] a, input [15:0] exp, input [8*34-1:0] what);
        reg [15:0] v;
        begin
            rd(a, v);
            ck(v, exp, what, a);
        end
    endtask

    // ---- write one whole beat; order 0 = ascending, 1 = scrambled (stride 37) ----
    task write_beat(input integer b, input integer order);
        integer i, a;
        begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                a = (order == 0) ? i : ((i * 37) % DEPTH);
                @(negedge clk);
                we = 1'b1; waddr = a; wdata = key[b*DEPTH + a];
            end
            @(negedge clk); we = 1'b0;
        end
    endtask

    // ---- read every address; mode 0 = up, 1 = down, 2 = scrambled ----
    task read_all(input integer b, input integer mode);
        integer i, a, prev_a;
        begin
            prev_a = 0;
            for (i = 0; i <= DEPTH; i = i + 1) begin
                @(negedge clk);
                if (i > 0)                                          // value for the address given one edge ago
                    ck(rdata, key[b*DEPTH + prev_a], "read-back (one edge later)", prev_a);
                if (i < DEPTH) begin
                    a = (mode == 0) ? i : (mode == 1) ? (DEPTH - 1 - i) : ((i * 37) % DEPTH);
                    raddr_d = a;
                    #1;                                             // output must not move before the edge
                    if (i > 0 && rdata !== key[b*DEPTH + prev_a])
                        bad("output changed before the edge", a);
                    prev_a = a;
                end
            end
        end
    endtask

    // ---- the real reading pattern: layer_ctrl + addr_gen walk through the buffer ----
    reg           en_prev   = 1'b0;
    reg  [AW-1:0] addr_prev = {AW{1'b0}};
    integer       beat_cur  = 0;
    reg           pat_chk   = 1'b0;

    always @(posedge clk) begin
        en_prev   <= enable;
        addr_prev <= raddr;
    end

    always @(negedge clk) begin
        if (pat_chk && en_prev)
            ck(rdata, key[beat_cur*DEPTH + addr_prev], "real read pattern", addr_prev);
    end

    task run_pattern(input integer b);
        integer n_out;
        reg [31:0] c0;
        begin
            beat_cur = b;
            c0 = checks;
            @(negedge clk); init = 1'b1; pat = 1'b1;
            @(negedge clk); init = 1'b0; pat_chk = 1'b1;
            for (n_out = 0; n_out < P_NF*P_NP; n_out = n_out + 1) begin
                @(negedge clk); start = 1'b1;
                @(negedge clk); start = 1'b0;
                while (!ctrl_done) @(negedge clk);
            end
            @(negedge clk); pat_chk = 1'b0; pat = 1'b0;
            if (checks - c0 != P_NF*P_NP*C_NT) begin
                $display("FAIL [%0s] real read pattern: %0d reads checked, expected %0d",
                         NAME, checks - c0, P_NF*P_NP*C_NT);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // corner cases
    // ------------------------------------------------------------------
    reg [15:0]   extreme [0:6];
    reg [AW-1:0] e_addr  [0:4];
    reg [15:0]   v1;
    integer      ea, ev, ei;

    task corner_cases;
        begin
            extreme[0] = 16'h8000; extreme[1] = 16'h7FFF; extreme[2] = 16'hFFFF;
            extreme[3] = 16'h0000; extreme[4] = 16'h0001; extreme[5] = 16'hAAAA; extreme[6] = 16'h5555;
            e_addr[0] = 0; e_addr[1] = 1; e_addr[2] = DEPTH/2; e_addr[3] = DEPTH-2; e_addr[4] = DEPTH-1;

            // extreme values at the ends and in the middle: all 16 bits must be kept
            for (ea = 0; ea < 5; ea = ea + 1)
                for (ev = 0; ev < 7; ev = ev + 1) begin
                    wr(e_addr[ea], extreme[ev]);
                    rd_ck(e_addr[ea], extreme[ev], "extreme value");
                end

            // walking 1 and walking 0 (a stuck or lost bit shows up here)
            for (ei = 0; ei < 16; ei = ei + 1) begin
                wr(DEPTH/3, (16'h0001 << ei));
                rd_ck(DEPTH/3, (16'h0001 << ei), "walking 1");
                wr(DEPTH/3, ~(16'h0001 << ei));
                rd_ck(DEPTH/3, ~(16'h0001 << ei), "walking 0");
            end

            // a write must not disturb its neighbours
            for (ea = 0; ea < 3; ea = ea + 1) begin
                ei = (ea == 0) ? 1 : (ea == 1) ? DEPTH/2 : DEPTH-2;
                wr(ei-1, 16'h1111); wr(ei+1, 16'h2222); wr(ei, 16'h3333);
                rd_ck(ei-1, 16'h1111, "neighbour below (before)");
                rd_ck(ei+1, 16'h2222, "neighbour above (before)");
                rd_ck(ei,   16'h3333, "written address");
                wr(ei, 16'hCCCC);
                rd_ck(ei-1, 16'h1111, "neighbour below (after)");
                rd_ck(ei+1, 16'h2222, "neighbour above (after)");
                rd_ck(ei,   16'hCCCC, "overwritten address");
            end

            // we = 0: nothing may be written, whatever waddr / wdata show
            wr(5, 16'h1234); wr(6, 16'h5678); wr(0, 16'h9ABC); wr(DEPTH-1, 16'hDEF0);
            @(negedge clk); we = 1'b0; waddr = 5;       wdata = 16'h4321;
            @(negedge clk); waddr = 6;                  wdata = 16'h4322;
            @(negedge clk); waddr = 0;                  wdata = 16'h4323;
            @(negedge clk); waddr = DEPTH-1;            wdata = 16'h4324;
            @(negedge clk); waddr = 5;                  wdata = 16'h4325;
            rd_ck(5,       16'h1234, "we=0 must not write (a)");
            rd_ck(6,       16'h5678, "we=0 must not write (b)");
            rd_ck(0,       16'h9ABC, "we=0 must not write (c)");
            rd_ck(DEPTH-1, 16'hDEF0, "we=0 must not write (d)");

            // read during write of the SAME address: old value comes out, new one next time
            wr(7, 16'h0A0A);
            @(negedge clk); raddr_d = 7; waddr = 7; wdata = 16'h0B0B; we = 1'b1;
            @(negedge clk); we = 1'b0;
            ck(rdata, 16'h0A0A, "read during write gives OLD value", 7);
            @(negedge clk);
            ck(rdata, 16'h0B0B, "next read gives NEW value", 7);
            // same again with a third value, to be sure it is not a one-off
            @(negedge clk); waddr = 7; wdata = 16'h0C0C; we = 1'b1;
            @(negedge clk); we = 1'b0;
            ck(rdata, 16'h0B0B, "read during write gives OLD value (2)", 7);
            @(negedge clk);
            ck(rdata, 16'h0C0C, "next read gives NEW value (2)", 7);

            // writing a different address while reading: the read must not change
            wr(8, 16'h7777);
            @(negedge clk); raddr_d = 8;
            @(negedge clk); we = 1'b1; waddr = 9;  wdata = 16'h1010;
            @(negedge clk); waddr = 10; wdata = 16'h2020;
            @(negedge clk); waddr = 11; wdata = 16'h3030;
            @(negedge clk); we = 1'b0;
            ck(rdata, 16'h7777, "read unaffected by writes elsewhere", 8);
            rd_ck(9,  16'h1010, "written during that time (a)");
            rd_ck(10, 16'h2020, "written during that time (b)");
            rd_ck(11, 16'h3030, "written during that time (c)");

            // the same address written in three consecutive cycles: the last one wins
            @(negedge clk); we = 1'b1; waddr = 12; wdata = 16'h00A1;
            @(negedge clk);             wdata = 16'h00A2;
            @(negedge clk);             wdata = 16'h00A3;
            @(negedge clk); we = 1'b0;
            rd_ck(12, 16'h00A3, "last of 3 writes wins");

            // the output holds its value while the address stays the same
            rd_ck(12, 16'h00A3, "hold (start)");
            repeat (5) @(negedge clk);
            ck(rdata, 16'h00A3, "hold (after 5 idle clocks)", 12);
        end
    endtask

    // ------------------------------------------------------------------
    // 20,000 random operations compared with a shadow copy
    // ------------------------------------------------------------------
    reg [31:0] rnd;
    reg [15:0] exp_prev;
    reg        have_exp;
    integer    n, ncoll, nwr;

    task nxt;                       // small deterministic random number generator
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task random_phase;
        reg [AW-1:0] ra, wa;
        begin
            rnd = SEED;
            // 1. fill the whole buffer with random values, and remember them
            for (n = 0; n < DEPTH; n = n + 1) begin
                nxt;
                @(negedge clk); we = 1'b1; waddr = n; wdata = rnd[31:16];
                sh[n] = rnd[31:16];
            end
            @(negedge clk); we = 1'b0;
            // 2. random operations
            have_exp = 1'b0; ncoll = 0; nwr = 0;
            for (n = 0; n < NRAND; n = n + 1) begin
                @(negedge clk);
                if (have_exp) ck(rdata, exp_prev, "random operation", n);
                // (only the upper bits of the generator are used: its low bits repeat quickly)
                nxt; we = (rnd[31:29] != 3'd0);                    // 7 of 8 cycles write
                nxt; wa = rnd[31] ? ((rnd[30:20] % 8) % DEPTH)     // half: a small window (many collisions)
                                  : ((rnd[30:16] % DEPTH));        // half: anywhere
                nxt; ra = (rnd[31:30] == 2'd0) ? wa :              // 1 of 4: same address as the write
                          rnd[29] ? ((rnd[28:20] % 8) % DEPTH) : ((rnd[28:13] % DEPTH));
                nxt; wdata = rnd[31:16];
                waddr = wa; raddr_d = ra;
                exp_prev = sh[ra];                                  // the OLD value (before this cycle's write)
                have_exp = 1'b1;
                if (we) begin sh[wa] = rnd[31:16]; nwr = nwr + 1; end
                if (we && wa == ra) ncoll = ncoll + 1;
            end
            @(negedge clk); we = 1'b0;
            ck(rdata, exp_prev, "random operation (last)", NRAND);
            // 3. the whole memory must now equal the shadow copy
            for (n = 0; n < DEPTH; n = n + 1)
                rd_ck(n, sh[n], "final memory vs shadow copy");
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer b, k;
    reg [15:0] vx;
    initial begin
        // the key file must have been read completely
        for (k = 0; k < NBEATS*DEPTH; k = k + 1)
            if (^key[k] === 1'bx) begin
                $display("FAIL [%0s] key file %0s is missing or too short (entry %0d)", NAME, KEYFILE, k);
                errors = errors + 1;
                k = NBEATS*DEPTH;
            end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // 1. nothing written yet -> unknown (simulation only)
`ifndef GL
        rd(0, vx);       ck({15'd0, (^vx === 1'bx)}, 16'd1, "unwritten address 0 reads x", 0);
        rd(DEPTH-1, vx); ck({15'd0, (^vx === 1'bx)}, 16'd1, "unwritten last address reads x", DEPTH-1);
`endif

        // 2. the 16 real beats
        for (b = 0; b < NBEATS; b = b + 1) begin
            write_beat(b, b % 2);
            read_all(b, 0);
            read_all(b, 1);
            read_all(b, 2);
            run_pattern(b);
        end

        // 3. corner cases
        corner_cases;

        // 4. random operations
        random_phase;

        $display("[%0s] depth %0d: %0d checks, %0d errors, %0d random writes (%0d same-address read+write)  -> %0s",
                 NAME, DEPTH, checks, errors, nwr, ncoll, (errors == 0) ? "PASS" : "FAIL");
        done = 1'b1;
    end

endmodule


// ----------------------------------------------------------------------
// top level: the four buffers side by side
// ----------------------------------------------------------------------
module data_buffer_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;                                   // 100 MHz in simulation (speed is irrelevant here)

    wire        d_in, d_a, d_b, d_c;
    wire [31:0] e_in, e_a, e_b, e_c;
    wire [31:0] c_in, c_a, c_b, c_c;

    //                 depth  key file                          reading pattern of the layer that uses it
    buffer_check #(.DEPTH(260),  .NAME("input 260"), .KEYFILE("answer_key/beats_in.hex"),
                   .P_NF(8), .P_NP(256), .P_NC(1), .P_K(5),   .P_ROW(0),   .SEED(32'd11))
        u_in (.clk(clk), .done(d_in), .errors(e_in), .checks(c_in));      // conv1 reads it
    buffer_check #(.DEPTH(1024), .NAME("A     1024"), .KEYFILE("answer_key/exp_conv1_pool.hex"),
                   .P_NF(1), .P_NP(124), .P_NC(8), .P_K(5),   .P_ROW(128), .SEED(32'd22))
        u_a  (.clk(clk), .done(d_a),  .errors(e_a),  .checks(c_a));       // conv2 reads it (one filter's pass)
    buffer_check #(.DEPTH(992),  .NAME("B      992"), .KEYFILE("answer_key/exp_conv2_pool.hex"),
                   .P_NF(2), .P_NP(1),   .P_NC(1), .P_K(992), .P_ROW(0),   .SEED(32'd33))
        u_b  (.clk(clk), .done(d_b),  .errors(e_b),  .checks(c_b));       // fc1 reads it (two neurons)
    buffer_check #(.DEPTH(32),   .NAME("C       32"), .KEYFILE("answer_key/exp_fc1.hex"),
                   .P_NF(2), .P_NP(1),   .P_NC(1), .P_K(32),  .P_ROW(0),   .SEED(32'd44))
        u_c  (.clk(clk), .done(d_c),  .errors(e_c),  .checks(c_c));       // fc2 reads it (both neurons)

    // watchdog (the whole run takes well under 100 ms of simulated time)
    initial begin
        #400000000;
        $display("FAIL: timeout - the testbench did not finish");
        $finish;
    end

    initial begin
        wait (d_in && d_a && d_b && d_c);
        #20;
        $display("---------------------------------------------");
        $display("total checks : %0d", c_in + c_a + c_b + c_c);
        $display("total errors : %0d", e_in + e_a + e_b + e_c);
        if (e_in + e_a + e_b + e_c == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAIL: some tests failed");
        $finish;
    end

endmodule
