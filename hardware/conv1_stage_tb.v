`timescale 1ns/1ps
// conv1_stage_tb.v
// Tests the whole first layer (conv1_stage.v) against the Python answer key.
//
// For each of the 16 real beats in answer_key/beats_in.hex:
//   1. load the 260 samples into the input buffer (beats 1, 4, 7, 10, 13 with random idle clocks
//      between samples),
//   2. wait a random 0..5 clocks, pulse start_layer, wait for layer_done,
//   3. read buffer A back (1,024 words) and compare EVERY word with answer_key/exp_conv1_pool.hex.
// Beats 3, 7, 11, 15 are run twice in a row, the second run starting on the very clock layer_done
// is seen (fastest possible restart); buffer A is refilled with garbage between the two runs.
// Beat 5 is first interrupted by a reset in the middle of the layer; the run after the reset must
// still be exact.
//
// Extra checks (simulation of the RTL only - they look inside the design, so they are skipped in
// the gate-level run, where the same file is used with -DGL):
//   - buffer A is filled with garbage before every run, so a word that is never written cannot pass
//     just because it already held the right number;
//   - every one of the 2,048 finished outputs (before pooling) is compared with
//     answer_key/exp_conv1_relu.hex at the clock where bias_rescale delivers it, and every
//     (filter, position) must appear exactly once;
//   - every one of the 1,024 buffer-A addresses must be written exactly once per run.
// Always checked:
//   - layer_busy is 0 before the start, 1 all the way until layer_done, 0 on the layer_done clock;
//   - layer_done is a single-clock pulse and comes exactly 14,338 = 7 x 2,048 + 2 clocks after start_layer
//     (the first answer starts 2 clocks after the pulse, each answer takes 7 clocks - 5 work, 1 done,
//     1 idle - and layer_done comes 2 clocks after the last answer's done clock);
//   - the number of layer_done pulses is exactly the number of runs.
// A watchdog stops the run if it hangs.
//
// compile:  iverilog -o conv1_stage_sim conv1_stage.v addr_gen.v layer_ctrl.v mac_unit.v bias_rescale.v bias_rom.v weight_rom.v data_buffer.v max_pool.v pool_pair.v conv1_stage_tb.v
// run:      vvp conv1_stage_sim        (weights.hex, biases.hex and the answer_key folder must be in the current folder)

module conv1_stage_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                rst_n       = 1'b0;
    reg                in_we       = 1'b0;
    reg  [8:0]         in_waddr    = 9'd0;
    reg  signed [15:0] in_wdata    = 16'sd0;
    reg                start_layer = 1'b0;
    wire               layer_busy;
    wire               layer_done;
    reg  [9:0]         a_raddr     = 10'd0;
    wire signed [15:0] a_rdata;

    conv1_stage dut (.clk(clk), .rst_n(rst_n),
                     .in_we(in_we), .in_waddr(in_waddr), .in_wdata(in_wdata),
                     .start_layer(start_layer), .layer_busy(layer_busy), .layer_done(layer_done),
                     .a_raddr(a_raddr), .a_rdata(a_rdata));

    // watchdog: the whole test needs about 330,000 clocks (3.3 ms of simulated time)
    initial begin
        #20000000;
        $display("FAIL: timeout - the testbench did not finish");
        $finish;
    end

    // ------------------------------------------------------------------
    // answer key
    // ------------------------------------------------------------------
    reg [15:0] beats [0:16*260-1];        // input samples, Q4.12
    reg [15:0] pool1 [0:16*1024-1];       // expected buffer A  (filter*128 + p)
    reg [15:0] relu1 [0:16*2048-1];       // expected conv1 outputs before pooling (filter*256 + position)

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    integer errors = 0, n_pool = 0, n_pre = 0, n_wr = 0, n_proto = 0, n_runs = 0, n_pulses = 0;
    reg [31:0] rnd = 32'd20261008;
    integer cur_beat = 0;
    reg     aborting = 1'b0;              // 1 while the run that gets interrupted by a reset is going

    task nxt;
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task fail(input [8*44-1:0] what, input integer where, input [15:0] got, input [15:0] exp);
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("FAIL %0s (beat %0d, item %0d): got %h expected %h", what, cur_beat, where, got, exp);
        end
    endtask

    // ------------------------------------------------------------------
    // load one beat into the input buffer
    // ------------------------------------------------------------------
    task load_beat(input integer b, input integer gappy);
        integer s;
        begin
            for (s = 0; s < 260; s = s + 1) begin
                @(negedge clk);
                in_we = 1'b1; in_waddr = s[8:0]; in_wdata = beats[b*260 + s];
                if (gappy != 0) begin
                    nxt;
                    repeat (rnd[31:30]) begin                 // 0..3 idle clocks with garbage on the lines
                        @(negedge clk);
                        nxt;
                        in_we = 1'b0; in_waddr = rnd[31:23]; in_wdata = rnd[22:7];
                    end
                end
            end
            @(negedge clk);
            in_we = 1'b0; nxt; in_waddr = rnd[31:23]; in_wdata = rnd[22:7];
        end
    endtask

    // ------------------------------------------------------------------
    // monitors that look inside the design (RTL only)
    // ------------------------------------------------------------------
`ifndef GL
    integer wr_count [0:1023];
    integer seen     [0:2047];
    integer pre_cnt;
    integer k;
    reg [15:0] tmp16;

    task clear_monitors;
        begin
            for (k = 0; k < 1024; k = k + 1) wr_count[k] = 0;
            for (k = 0; k < 2048; k = k + 1) seen[k] = 0;
            pre_cnt = 0;
        end
    endtask

    task garbage_in_buffer_a;
        begin
            for (k = 0; k < 1024; k = k + 1) dut.buf_a.mem[k] = 16'hA5A5 ^ k[15:0];
        end
    endtask

    // every clock in which bias_rescale delivers a finished output (done_d = 1)
    always @(negedge clk) if (rst_n && dut.done_d === 1'b1) begin
        pre_cnt = pre_cnt + 1;
        if (!aborting) n_pre = n_pre + 1;
        if (dut.act !== relu1[cur_beat*2048 + dut.filter_d*256 + dut.pos_d])
            fail("output before pooling wrong", dut.filter_d*256 + dut.pos_d, dut.act,
                 relu1[cur_beat*2048 + dut.filter_d*256 + dut.pos_d]);
        seen[dut.filter_d*256 + dut.pos_d] = seen[dut.filter_d*256 + dut.pos_d] + 1;
    end

    // every clock in which buffer A is really written (the write pins of the memory itself)
    always @(negedge clk) if (rst_n && dut.buf_a.we === 1'b1) begin
        wr_count[dut.buf_a.waddr] = wr_count[dut.buf_a.waddr] + 1;
    end

    task check_monitors;
        integer bad;
        begin
            bad = 0;
            if (pre_cnt != 2048) fail("outputs seen before pooling", pre_cnt, pre_cnt[15:0], 16'd2048);
            for (k = 0; k < 2048; k = k + 1) begin
                if (seen[k] != 1) begin
                    bad = bad + 1;
                    tmp16 = seen[k];
                    if (bad <= 3) fail("output not seen exactly once", k, tmp16, 16'd1);
                end
            end
            for (k = 0; k < 1024; k = k + 1) begin
                n_wr = n_wr + 1;
                if (wr_count[k] != 1) begin
                    tmp16 = wr_count[k];
                    fail("buffer A address not written once", k, tmp16, 16'd1);
                end
            end
        end
    endtask
`endif

    // ------------------------------------------------------------------
    // wait for layer_done after a start pulse. Called at the negedge where start_layer was set.
    // ------------------------------------------------------------------
    task wait_done(input [8*20-1:0] tag);
        integer n;
        begin
            @(negedge clk);
            start_layer = 1'b0;
            n = 1;
            while (layer_done !== 1'b1 && n < 20000) begin
                n_proto = n_proto + 1;
                if (layer_busy !== 1'b1) fail("layer_busy not 1 while running", n, {15'd0, layer_busy}, 16'd1);
                @(negedge clk);
                n = n + 1;
            end
            n_proto = n_proto + 3;
            if (layer_done !== 1'b1)     fail("layer_done never came", n, 16'd0, 16'd1);
            else begin
                if (n != 14338)          fail("clocks from start to layer_done", n, n[15:0], 16'd14338);
                if (layer_busy !== 1'b0) fail("layer_busy not 0 on layer_done", 0, {15'd0, layer_busy}, 16'd0);
            end
            n_runs = n_runs + 1;
        end
    endtask

    // layer_done must be a one-clock pulse; count the pulses
    reg prev_done = 1'b0;
    always @(negedge clk) begin
        if (layer_done === 1'b1) begin
            n_pulses = n_pulses + 1;
            if (prev_done) fail("layer_done lasted more than 1 clock", 0, 16'd1, 16'd0);
        end
        prev_done = (layer_done === 1'b1);
    end

    // ------------------------------------------------------------------
    // read buffer A back and compare every word with the answer key
    // ------------------------------------------------------------------
    task read_back(input integer b);
        integer a;
        begin
            for (a = 0; a <= 1024; a = a + 1) begin
                @(negedge clk);
                if (a < 1024) a_raddr = a[9:0];
                if (a > 0) begin
                    n_pool = n_pool + 1;
                    if (a_rdata !== pool1[b*1024 + a - 1])
                        fail("buffer A word wrong", a - 1, a_rdata, pool1[b*1024 + a - 1]);
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer b, kk;
    initial begin
        $readmemh("answer_key/beats_in.hex",       beats);
        $readmemh("answer_key/exp_conv1_pool.hex", pool1);
        $readmemh("answer_key/exp_conv1_relu.hex", relu1);
        for (kk = 0; kk < 16*260;  kk = kk + 1) if (^beats[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file beats_in.hex missing or short");       kk = 16*260;  end
        for (kk = 0; kk < 16*1024; kk = kk + 1) if (^pool1[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv1_pool.hex missing or short"); kk = 16*1024; end
        for (kk = 0; kk < 16*2048; kk = kk + 1) if (^relu1[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv1_relu.hex missing or short"); kk = 16*2048; end

        // reset
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        for (b = 0; b < 16; b = b + 1) begin
            cur_beat = b;
            load_beat(b, (b % 3) == 1);

            if (b == 5) begin
                // start the layer, let it run for a while, then reset in the middle of it
                aborting = 1'b1;
`ifndef GL
                clear_monitors;
`endif
                @(negedge clk); start_layer = 1'b1;
                @(negedge clk); start_layer = 1'b0;
                repeat (1000) @(negedge clk);
                rst_n = 1'b0;
                repeat (3) @(negedge clk);
                rst_n = 1'b1;
                repeat (3) @(negedge clk);
                aborting = 1'b0;
            end

            nxt; repeat (rnd[31:29] % 6) @(negedge clk);        // 0..5 idle clocks before the start

            // ---- the run ----
            @(negedge clk);
            n_proto = n_proto + 1;
            if (layer_busy !== 1'b0) fail("layer_busy not 0 before start", 0, {15'd0, layer_busy}, 16'd0);
`ifndef GL
            clear_monitors;
            garbage_in_buffer_a;
`endif
            start_layer = 1'b1;
            wait_done("first run");
`ifndef GL
            check_monitors;
`endif

            // ---- beats 3, 7, 11, 15: run again, starting on the clock layer_done is seen ----
            if ((b % 4) == 3) begin
                start_layer = 1'b1;
`ifndef GL
                clear_monitors;
                garbage_in_buffer_a;
`endif
                wait_done("restart");
`ifndef GL
                check_monitors;
`endif
            end

            read_back(b);
        end

        repeat (5) @(negedge clk);

        // totals
        if (n_pulses !== n_runs) begin errors = errors + 1; $display("FAIL layer_done pulses: %0d, runs: %0d", n_pulses, n_runs); end

        $display("buffer A words compared with the key : %0d (16 beats x 1024)", n_pool);
        $display("runs of the layer / done pulses      : %0d / %0d", n_runs, n_pulses);
`ifndef GL
        $display("outputs before pooling compared      : %0d (%0d runs x 2048)", n_pre, n_runs);
        $display("buffer A address-written-once checks : %0d (%0d runs x 1024)", n_wr, n_runs);
`endif
        $display("protocol checks                      : %0d", n_proto);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
