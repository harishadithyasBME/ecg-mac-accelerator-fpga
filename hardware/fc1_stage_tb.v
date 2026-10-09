`timescale 1ns/1ps
// fc1_stage_tb.v
// Tests the whole third layer (fc1_stage.v) against the Python answer key.
//
// The layer's input is taken from the key as well: answer_key/exp_conv2_pool.hex is exactly what
// conv2 leaves in buffer B (the flattened 992 values), so fc1 is tested on its own, with the right numbers.
//
// For each of the 16 real beats:
//   1. load the 992 values of buffer B into the layer's input buffer (beats 1, 4, 7, 10, 13 with
//      random idle clocks between values),
//   2. wait a random 0..5 clocks, pulse start_layer, wait for layer_done,
//   3. read buffer C back (32 words) and compare EVERY word with answer_key/exp_fc1.hex.
// Beats 3, 7, 11, 15 are run twice in a row, the second run starting on the very clock layer_done
// is seen (fastest possible restart); buffer C is refilled with garbage between the two runs.
// Beat 5 is first interrupted by a reset in the middle of the layer; the run after the reset must
// still be exact.
//
// Extra checks (simulation of the RTL only - they look inside the design, so they are skipped in
// the gate-level run, where the same file is used with -DGL):
//   - buffer C is filled with garbage before every run, so a word that is never written cannot pass
//     just because it already held the right number;
//   - every neuron must be finished exactly once, and every one of the 32 buffer-C addresses must
//     be written exactly once per run;
//   - the saturation flag of bias_rescale must be raised exactly as often as the Python model says:
//     answer_key_info.txt lists how many fc1 values are clamped in each beat (beat 2: 4, beat 3: 1,
//     beat 5: 1, all others 0). That table comes from the Python side, so it is an independent check
//     of the clamping.
// Always checked:
//   - layer_busy is 0 before the start, 1 all the way until layer_done, 0 on the layer_done clock;
//   - layer_done is a single-clock pulse and comes exactly 31,810 = 994 x 32 + 2 clocks after start_layer
//     (the first neuron starts 2 clocks after the pulse, each neuron takes 994 clocks - 992 work, 1 done,
//     1 idle - and layer_done comes 2 clocks after the last neuron's done clock);
//   - the number of layer_done pulses is exactly the number of runs.
// A watchdog stops the run if it hangs.
//
// Fewer beats (used for the slow gate-level run): add  -DNBEATS=4  to the iverilog command line.
//
// compile:  iverilog -o fc1_stage_sim fc1_stage.v addr_gen.v layer_ctrl.v mac_unit.v bias_rescale.v bias_rom.v weight_rom.v data_buffer.v fc1_stage_tb.v
// run:      vvp fc1_stage_sim        (weights.hex, biases.hex and the answer_key folder must be in the current folder)

`ifndef NBEATS
`define NBEATS 16
`endif

module fc1_stage_tb;

    localparam NB = `NBEATS;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                rst_n       = 1'b0;
    reg                in_we       = 1'b0;
    reg  [9:0]         in_waddr    = 10'd0;
    reg  signed [15:0] in_wdata    = 16'sd0;
    reg                start_layer = 1'b0;
    wire               layer_busy;
    wire               layer_done;
    reg  [4:0]         c_raddr     = 5'd0;
    wire signed [15:0] c_rdata;

    fc1_stage dut (.clk(clk), .rst_n(rst_n),
                   .in_we(in_we), .in_waddr(in_waddr), .in_wdata(in_wdata),
                   .start_layer(start_layer), .layer_busy(layer_busy), .layer_done(layer_done),
                   .c_raddr(c_raddr), .c_rdata(c_rdata));

    // watchdog: the full test needs about 700,000 clocks (7 ms of simulated time)
    initial begin
        #100000000;
        $display("FAIL: timeout - the testbench did not finish");
        $finish;
    end

    // ------------------------------------------------------------------
    // answer key
    // ------------------------------------------------------------------
    reg [15:0] pool2 [0:16*992-1];        // layer input = buffer B as conv2 leaves it (flatten order)
    reg [15:0] fc1k  [0:16*32-1];         // expected buffer C (neuron 0..31, Q7.9, after ReLU)

    // fc1 values clamped per beat, from answer_key_info.txt (column sat(c1,c2,fc1,fc2), third number)
    function integer exp_ovf(input integer beat);
        begin
            case (beat)
                2:       exp_ovf = 4;
                3:       exp_ovf = 1;
                5:       exp_ovf = 1;
                default: exp_ovf = 0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    integer errors = 0, n_c = 0, n_neur = 0, n_wr = 0, n_ovf = 0, n_proto = 0, n_runs = 0, n_pulses = 0;
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
    // load one beat's layer input (992 values) into the input buffer
    // ------------------------------------------------------------------
    task load_beat(input integer b, input integer gappy);
        integer s;
        begin
            for (s = 0; s < 992; s = s + 1) begin
                @(negedge clk);
                in_we = 1'b1; in_waddr = s[9:0]; in_wdata = pool2[b*992 + s];
                if (gappy != 0) begin
                    nxt;
                    repeat (rnd[31:30]) begin                 // 0..3 idle clocks with garbage on the lines
                        @(negedge clk);
                        nxt;
                        in_we = 1'b0; in_waddr = rnd[31:22]; in_wdata = rnd[22:7];
                    end
                end
            end
            @(negedge clk);
            in_we = 1'b0; nxt; in_waddr = rnd[31:22]; in_wdata = rnd[22:7];
        end
    endtask

    // ------------------------------------------------------------------
    // monitors that look inside the design (RTL only)
    // ------------------------------------------------------------------
`ifndef GL
    integer wr_count [0:31];
    integer seen     [0:31];
    integer pre_cnt, ovf_cnt;
    integer k;
    reg [15:0] tmp16;

    task clear_monitors;
        begin
            for (k = 0; k < 32; k = k + 1) begin wr_count[k] = 0; seen[k] = 0; end
            pre_cnt = 0;
            ovf_cnt = 0;
        end
    endtask

    task garbage_in_buffer_c;
        begin
            for (k = 0; k < 32; k = k + 1) dut.buf_c.mem[k] = 16'hA5A5 ^ k[15:0];
        end
    endtask

    // every clock in which bias_rescale delivers a finished neuron value (done_d = 1)
    always @(negedge clk) if (rst_n && dut.done_d === 1'b1) begin
        pre_cnt = pre_cnt + 1;
        seen[dut.filter_d] = seen[dut.filter_d] + 1;
        if (dut.act !== fc1k[cur_beat*32 + dut.filter_d])
            fail("neuron value wrong at bias_rescale", dut.filter_d, dut.act, fc1k[cur_beat*32 + dut.filter_d]);
        if (dut.act_ovf === 1'b1) ovf_cnt = ovf_cnt + 1;
    end

    // every clock in which buffer C is really written (the write pins of the memory itself)
    always @(negedge clk) if (rst_n && dut.buf_c.we === 1'b1) begin
        wr_count[dut.buf_c.waddr] = wr_count[dut.buf_c.waddr] + 1;
    end

    task check_monitors;
        integer bad;
        begin
            bad = 0;
            n_neur = n_neur + 32;
            if (pre_cnt != 32) fail("neuron values seen", pre_cnt, pre_cnt[15:0], 16'd32);
            for (k = 0; k < 32; k = k + 1) begin
                n_wr = n_wr + 1;
                if (seen[k] != 1) begin
                    tmp16 = seen[k];
                    fail("neuron not finished exactly once", k, tmp16, 16'd1);
                end
                if (wr_count[k] != 1) begin
                    tmp16 = wr_count[k];
                    fail("buffer C address not written once", k, tmp16, 16'd1);
                end
            end
            n_ovf = n_ovf + ovf_cnt;
            tmp16 = ovf_cnt;
            if (ovf_cnt != exp_ovf(cur_beat)) fail("clamped values (saturation flag)", cur_beat, tmp16, exp_ovf(cur_beat));
        end
    endtask
`endif

    // ------------------------------------------------------------------
    // wait for layer_done after a start pulse. Called at the negedge where start_layer was set.
    // ------------------------------------------------------------------
    task wait_done;
        integer n;
        begin
            @(negedge clk);
            start_layer = 1'b0;
            n = 1;
            while (layer_done !== 1'b1 && n < 100000) begin
                n_proto = n_proto + 1;
                if (layer_busy !== 1'b1) fail("layer_busy not 1 while running", n, {15'd0, layer_busy}, 16'd1);
                @(negedge clk);
                n = n + 1;
            end
            n_proto = n_proto + 3;
            if (layer_done !== 1'b1)     fail("layer_done never came", n, 16'd0, 16'd1);
            else begin
                if (n != 31810)          fail("clocks from start to layer_done", n, n[15:0], 16'd0);
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
    // read buffer C back and compare every word with the answer key
    // ------------------------------------------------------------------
    task read_back(input integer b);
        integer a;
        begin
            for (a = 0; a <= 32; a = a + 1) begin
                @(negedge clk);
                if (a < 32) c_raddr = a[4:0];
                if (a > 0) begin
                    n_c = n_c + 1;
                    if (c_rdata !== fc1k[b*32 + a - 1])
                        fail("buffer C word wrong", a - 1, c_rdata, fc1k[b*32 + a - 1]);
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer b, kk;
    initial begin
        $readmemh("answer_key/exp_conv2_pool.hex", pool2);
        $readmemh("answer_key/exp_fc1.hex",        fc1k);
        for (kk = 0; kk < 16*992; kk = kk + 1) if (^pool2[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv2_pool.hex missing or short"); kk = 16*992; end
        for (kk = 0; kk < 16*32;  kk = kk + 1) if (^fc1k[kk]  === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_fc1.hex missing or short");        kk = 16*32;  end

        // reset
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        for (b = 0; b < NB; b = b + 1) begin
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
            garbage_in_buffer_c;
`endif
            start_layer = 1'b1;
            wait_done;
`ifndef GL
            check_monitors;
`endif

            // ---- beats 3, 7, 11, 15: run again, starting on the clock layer_done is seen ----
            if ((b % 4) == 3) begin
                start_layer = 1'b1;
`ifndef GL
                clear_monitors;
                garbage_in_buffer_c;
`endif
                wait_done;
`ifndef GL
                check_monitors;
`endif
            end

            read_back(b);
        end

        repeat (5) @(negedge clk);

        // totals
        if (n_pulses !== n_runs) begin errors = errors + 1; $display("FAIL layer_done pulses: %0d, runs: %0d", n_pulses, n_runs); end

        $display("buffer C words compared with the key : %0d (%0d beats x 32)", n_c, NB);
        $display("runs of the layer / done pulses      : %0d / %0d", n_runs, n_pulses);
`ifndef GL
        $display("neuron values checked at bias_rescale: %0d (%0d runs x 32)", n_neur, n_runs);
        $display("neuron / buffer-C-address-once checks: %0d", n_wr);
        $display("clamped values seen (flag)           : %0d (on every run it must equal the key's count for that beat)", n_ovf);
`endif
        $display("protocol checks                      : %0d", n_proto);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
