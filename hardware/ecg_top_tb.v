`timescale 1ns/1ps
// ecg_top_tb.v
// Tests the WHOLE classifier (ecg_top.v) against the Python answer key: heartbeat samples in, decision out.
//
// For each of the 16 real beats:
//   1. load the beat's 260 samples (answer_key/beats_in.hex) into the input buffer
//      (beats 1, 4, 7, 10, 13 with random idle clocks between the samples),
//   2. wait a random 0..5 clocks, pulse start_beat, wait for beat_done,
//   3. on the beat_done clock: score0, score1 and abnormal must equal answer_key/exp_fc2.hex and
//      exp_decision.hex (beat 9 is an exact tie 628 / 628 -> Normal).
//   After beat_done the scores and abnormal must STAY the same until the next beat is started.
// Beats 3, 7, 11, 15 are run twice in a row, the second run starting on the very clock beat_done is seen
// (fastest possible restart). Beats 5, 6, 9, 10 and 14 are first interrupted by a reset in the middle of
// the beat - beat 5 during conv1, 6 during conv2, 9 exactly at the end of conv1, 10 during fc1, 14 during
// fc2 - and the run after the reset must still be exact. Beats 2, 7 and 12 get stray start_beat pulses
// during the beat (including in the clocks where a layer finishes and where the next one starts); they
// must be ignored and must not change a single result or clock count.
//
// Extra checks (simulation of the RTL only - they look inside the design, so they are skipped in
// the gate-level run, where the same file is used with -DGL):
//   - buffers A, B, C and both score registers are filled with garbage before every run, so a word that is
//     never written cannot pass just because it already held the right number;
//   - EVERY finished value of EVERY layer (4,066 per beat: 2,048 conv1 + 1,984 conv2 + 32 fc1 + 2 fc2)
//     is compared with the key at the output of bias_rescale, before pooling, and every one must appear
//     exactly once;
//   - after the beat all 1,024 words of buffer A, all 992 of buffer B and all 32 of buffer C are
//     compared with the key (exp_conv1_pool.hex, exp_conv2_pool.hex, exp_fc1.hex), and every
//     address of the three buffers must have been written exactly once per beat;
//   - the saturation flag of bias_rescale must be raised exactly as often as the Python model says
//     (answer_key_info.txt: beat 2: 4 values clamped, beat 3: 1, beat 5: 1, all others 0);
//   - the layers run in the order 0, 1, 2, 3, each started by one start_layer pulse, and finish at exactly
//     the predicted clocks: layer_done at 14,339 / 97,670 / 129,481 / 129,552 clocks after the start_beat
//     clock, start_layer at 1 / 14,340 / 97,671 / 129,482;
//   - score0 / score1 change only on the clock after fc2's own neuron 0 / neuron 1 is finished.
// Always checked:
//   - beat_busy is 0 before the start, 1 all the way until beat_done, 0 on the beat_done clock;
//   - beat_done is a single-clock pulse and comes exactly 129,552 clocks after the start_beat clock
//     (14,339 + 83,331 + 31,811 + 70 + 1: each layer takes N x (taps + 2) + 2 clocks, one clock is
//     needed to start the first layer and one between layers);
//   - the number of beat_done pulses is exactly the number of completed runs (an interrupted run
//     must not produce one).
// A watchdog stops the run if it hangs.
//
// Options for the iverilog command line:  -DNBEATS=4 (fewer beats)   -DFIRST=9 (start with beat 9)
//   (used for the slow gate-level run)   -DSTOP_ON_FAIL (stop at the first error)
//
// compile:  iverilog -o ecg_top_sim ecg_top.v layer_seq.v decision.v addr_gen.v layer_ctrl.v mac_unit.v bias_rescale.v max_pool.v pool_pair.v bias_rom.v weight_rom.v data_buffer.v ecg_top_tb.v
// run:      vvp ecg_top_sim        (weights.hex, biases.hex and the answer_key folder must be in the current folder)

`ifndef NBEATS
`define NBEATS 16
`endif
`ifndef FIRST
`define FIRST 0
`endif

module ecg_top_tb;

    localparam NB    = `NBEATS;
    localparam FIRST = `FIRST;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                rst_n      = 1'b0;
    reg                in_we      = 1'b0;
    reg  [8:0]         in_waddr   = 9'd0;
    reg  signed [15:0] in_wdata   = 16'sd0;
    reg                start_beat = 1'b0;
    wire               beat_busy;
    wire               beat_done;
    wire signed [15:0] score0;
    wire signed [15:0] score1;
    wire               abnormal;

    ecg_top dut (.clk(clk), .rst_n(rst_n),
                 .in_we(in_we), .in_waddr(in_waddr), .in_wdata(in_wdata),
                 .start_beat(start_beat), .beat_busy(beat_busy), .beat_done(beat_done),
                 .score0(score0), .score1(score1), .abnormal(abnormal));

    // watchdog: the full test needs about 3,000,000 clocks (30 ms of simulated time)
    initial begin
        #1000000000;
        $display("FAIL: timeout - the testbench did not finish");
        $finish;
    end

    // ------------------------------------------------------------------
    // answer key
    // ------------------------------------------------------------------
    reg [15:0] bin  [0:16*260-1];         // the beats' samples (Q4.12)
    reg [15:0] c1k  [0:16*2048-1];        // conv1 outputs after ReLU, before pooling: filter*256 + position
    reg [15:0] p1k  [0:16*1024-1];        // buffer A: channel*128 + pooled position
    reg [15:0] c2k  [0:16*1984-1];        // conv2 outputs after ReLU, before pooling: filter*124 + position
    reg [15:0] p2k  [0:16*992-1];         // buffer B: channel*62 + pooled position
    reg [15:0] f1k  [0:16*32-1];          // buffer C: fc1 neurons after ReLU
    reg [15:0] f2k  [0:16*2-1];           // scores: [2*beat] = score0, [2*beat+1] = score1
    reg [15:0] deck [0:15];               // decision

    // values clamped per beat in ALL layers together, from answer_key_info.txt (sat(c1,c2,fc1,fc2)): only fc1 clamps
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
    integer errors = 0, n_sc = 0, n_hold = 0, n_vals = 0, n_once = 0, n_bufw = 0, n_wr = 0, n_ovf = 0;
    integer n_proto = 0, n_runs = 0, n_pulses = 0, n_seq = 0, n_chg = 0;
    reg [31:0] rnd = 32'd20261008;
    integer cur_beat = 0;

    task nxt;
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task fail(input [8*44-1:0] what, input integer where, input [15:0] got, input [15:0] exp);
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("FAIL %0s (beat %0d, item %0d): got %h expected %h", what, cur_beat, where, got, exp);
`ifdef STOP_ON_FAIL
            if (errors == 1) begin
                $display("total errors : 1");
                $display("FAIL: stopped at the first error");
                $finish;
            end
`endif
        end
    endtask

    // same, for counts and clock numbers (printed as plain numbers)
    task failn(input [8*44-1:0] what, input integer got, input integer exp);
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("FAIL %0s (beat %0d): got %0d expected %0d", what, cur_beat, got, exp);
`ifdef STOP_ON_FAIL
            if (errors == 1) begin
                $display("total errors : 1");
                $display("FAIL: stopped at the first error");
                $finish;
            end
`endif
        end
    endtask

    // ------------------------------------------------------------------
    // load one beat's 260 samples into the input buffer
    // ------------------------------------------------------------------
    task load_beat(input integer b, input integer gappy);
        integer s;
        begin
            for (s = 0; s < 260; s = s + 1) begin
                @(negedge clk);
                in_we = 1'b1; in_waddr = s[8:0]; in_wdata = bin[b*260 + s];
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
    integer seen [0:4065];                // finished values: 0..2047 conv1, 2048..4031 conv2, 4032..4063 fc1, 4064..4065 fc2
    integer wr_a [0:1023];
    integer wr_b [0:1023];                // (buffer B has 992 words; the extra addresses must stay unwritten)
    integer wr_c [0:31];
    integer pre_cnt, ovf_cnt;
    integer k;
    reg [15:0] tmp16;

    task clear_monitors;
        begin
            for (k = 0; k < 4066; k = k + 1) seen[k] = 0;
            for (k = 0; k < 1024; k = k + 1) begin wr_a[k] = 0; wr_b[k] = 0; end
            for (k = 0; k < 32;   k = k + 1) wr_c[k] = 0;
            pre_cnt = 0;
            ovf_cnt = 0;
        end
    endtask

    // the score registers may change ONLY on the clock after fc2's own neuron is finished
    reg signed [15:0] prev_s0 = 16'bx, prev_s1 = 16'bx;
    reg               ok0 = 1'b0, ok1 = 1'b0;

    task garbage;
        begin
            for (k = 0; k < 1024; k = k + 1) dut.buf_a.mem[k] = 16'hA5A5 ^ k[15:0];
            for (k = 0; k < 992;  k = k + 1) dut.buf_b.mem[k] = 16'h5A5A ^ k[15:0];
            for (k = 0; k < 32;   k = k + 1) dut.buf_c.mem[k] = 16'hC3C3 ^ k[15:0];
            dut.score0_r = 16'h5A5A;  prev_s0 = 16'h5A5A;
            dut.score1_r = 16'hA5A5;  prev_s1 = 16'hA5A5;
        end
    endtask

    always @(negedge clk) begin
        if (dut.score0_r !== prev_s0) begin
            n_chg = n_chg + 1;
            if (!ok0) fail("score0 register changed at a wrong time", 0, dut.score0_r, prev_s0);
        end
        if (dut.score1_r !== prev_s1) begin
            n_chg = n_chg + 1;
            if (!ok1) fail("score1 register changed at a wrong time", 1, dut.score1_r, prev_s1);
        end
        prev_s0 = dut.score0_r;
        prev_s1 = dut.score1_r;
        ok0 = (rst_n === 1'b1) && (dut.done_d === 1'b1) && (dut.layer === 2'd3) && (dut.filter_d === 6'd0);
        ok1 = (rst_n === 1'b1) && (dut.done_d === 1'b1) && (dut.layer === 2'd3) && (dut.filter_d === 6'd1);
    end

    // every clock in which bias_rescale delivers a finished value (done_d = 1): compare it with the key
    integer idx, base, lim;
    reg [15:0] ex;
    always @(negedge clk) if (rst_n && dut.done_d === 1'b1) begin
        pre_cnt = pre_cnt + 1;
        case (dut.layer)
            2'd0:    begin idx = dut.filter_d * 256 + dut.pos_d; base = 0;    lim = 2048; ex = c1k[cur_beat*2048 + idx]; end
            2'd1:    begin idx = dut.filter_d * 124 + dut.pos_d; base = 2048; lim = 1984; ex = c2k[cur_beat*1984 + idx]; end
            2'd2:    begin idx = dut.filter_d;                   base = 4032; lim = 32;   ex = f1k[cur_beat*32 + idx];   end
            default: begin idx = dut.filter_d;                   base = 4064; lim = 2;    ex = f2k[cur_beat*2 + idx];    end
        endcase
        if (idx >= lim) begin
            fail("finished value: filter/position out of range", idx, dut.filter_d, dut.pos_d);
        end else begin
            seen[base + idx] = seen[base + idx] + 1;
            if (dut.act !== ex) fail("finished value wrong at bias_rescale", base + idx, dut.act, ex);
        end
        if (dut.act_ovf === 1'b1) ovf_cnt = ovf_cnt + 1;
    end

    // every clock in which a buffer is really written (the write pins of the memories themselves)
    always @(negedge clk) if (rst_n) begin
        if (dut.buf_a.we === 1'b1) wr_a[dut.buf_a.waddr] = wr_a[dut.buf_a.waddr] + 1;
        if (dut.buf_b.we === 1'b1) wr_b[dut.buf_b.waddr] = wr_b[dut.buf_b.waddr] + 1;
        if (dut.buf_c.we === 1'b1) wr_c[dut.buf_c.waddr] = wr_c[dut.buf_c.waddr] + 1;
    end

    task check_monitors;
        begin
            if (pre_cnt != 4066) begin tmp16 = pre_cnt; fail("finished values seen", pre_cnt, tmp16, 16'd4066); end
            for (k = 0; k < 4066; k = k + 1) begin
                n_once = n_once + 1;
                if (seen[k] != 1) begin tmp16 = seen[k]; fail("value not finished exactly once", k, tmp16, 16'd1); end
            end
            for (k = 0; k < 1024; k = k + 1) begin
                n_wr = n_wr + 1;
                if (wr_a[k] != 1) begin tmp16 = wr_a[k]; fail("buffer A address not written once", k, tmp16, 16'd1); end
            end
            for (k = 0; k < 1024; k = k + 1) begin
                n_wr = n_wr + 1;
                if (wr_b[k] != ((k < 992) ? 1 : 0)) begin tmp16 = wr_b[k]; fail("buffer B address not written once", k, tmp16, (k < 992) ? 16'd1 : 16'd0); end
            end
            for (k = 0; k < 32; k = k + 1) begin
                n_wr = n_wr + 1;
                if (wr_c[k] != 1) begin tmp16 = wr_c[k]; fail("buffer C address not written once", k, tmp16, 16'd1); end
            end
            n_ovf = n_ovf + ovf_cnt;
            if (ovf_cnt != exp_ovf(cur_beat)) begin tmp16 = ovf_cnt; fail("clamped values (saturation flag)", cur_beat, tmp16, exp_ovf(cur_beat)); end
        end
    endtask

    // the finished buffers against the key
    task check_buffers;
        integer i;
        begin
            for (i = 0; i < 1024; i = i + 1) begin
                n_bufw = n_bufw + 1;
                if (dut.buf_a.mem[i] !== p1k[cur_beat*1024 + i]) fail("buffer A word wrong", i, dut.buf_a.mem[i], p1k[cur_beat*1024 + i]);
            end
            for (i = 0; i < 992; i = i + 1) begin
                n_bufw = n_bufw + 1;
                if (dut.buf_b.mem[i] !== p2k[cur_beat*992 + i]) fail("buffer B word wrong", i, dut.buf_b.mem[i], p2k[cur_beat*992 + i]);
            end
            for (i = 0; i < 32; i = i + 1) begin
                n_bufw = n_bufw + 1;
                if (dut.buf_c.mem[i] !== f1k[cur_beat*32 + i]) fail("buffer C word wrong", i, dut.buf_c.mem[i], f1k[cur_beat*32 + i]);
            end
        end
    endtask
`endif

    // ------------------------------------------------------------------
    // results on the beat_done clock, and holding them afterwards
    // ------------------------------------------------------------------
    reg signed [15:0] e0, e1;             // expected scores of the beat under test
    reg               e_ab;               // expected decision
    reg               hold_en = 1'b0;
    reg signed [15:0] h0, h1;
    reg               h_ab;

    always @(negedge clk) if (hold_en) begin
        n_hold = n_hold + 1;
        if (score0   !== h0)   fail("score0 changed after beat_done",   0, score0, h0);
        if (score1   !== h1)   fail("score1 changed after beat_done",   1, score1, h1);
        if (abnormal !== h_ab) fail("abnormal changed after beat_done", 2, {15'd0, abnormal}, {15'd0, h_ab});
    end

    task check_results;
        begin
            n_sc = n_sc + 1;
            if (score0   !== e0)   fail("score0 wrong",   0, score0, e0);
            if (score1   !== e1)   fail("score1 wrong",   1, score1, e1);
            if (abnormal !== e_ab) fail("abnormal wrong", 2, {15'd0, abnormal}, {15'd0, e_ab});
            h0 = e0; h1 = e1; h_ab = e_ab;
            hold_en = 1'b1;
        end
    endtask

    // ------------------------------------------------------------------
    // wait for beat_done after a start pulse. Called at the negedge where start_beat was set.
    // Stray start_beat pulses (stray_en) at awkward moments must change nothing.
    // ------------------------------------------------------------------
    reg stray_en = 1'b0;

    function is_stray(input integer n);
        begin
            is_stray = (n == 1) || (n == 2) || (n == 3000) || (n == 14339) || (n == 14340) || (n == 97670) ||
                       (n == 97671) || (n == 129481) || (n == 129482) || (n == 129551);
        end
    endfunction

    integer ld_n [0:3];
    integer sl_n [0:3];
    integer sl_l [0:3];
    integer p;

    task wait_done;
        integer n, nl, ns;
        begin
            n = 0; nl = 0; ns = 0;
            @(negedge clk);
            n = 1;
            while (beat_done !== 1'b1 && n < 200000) begin
                n_proto = n_proto + 1;
                if (beat_busy !== 1'b1) fail("beat_busy not 1 while running", n, {15'd0, beat_busy}, 16'd1);
`ifndef GL
                if (dut.layer_done === 1'b1) begin
                    if (nl < 4) ld_n[nl] = n;
                    nl = nl + 1;
                end
                if (dut.start_layer === 1'b1) begin
                    if (ns < 4) begin sl_n[ns] = n; sl_l[ns] = dut.layer; end
                    ns = ns + 1;
                end
`endif
                start_beat = stray_en && is_stray(n);
                @(negedge clk);
                n = n + 1;
            end
            start_beat = 1'b0;
            n_proto = n_proto + 3;
            if (beat_done !== 1'b1)     fail("beat_done never came", n, 16'd0, 16'd1);
            else begin
                if (n != 129552)        failn("clocks from start_beat to beat_done", n, 129552);
                if (beat_busy !== 1'b0) fail("beat_busy not 0 on beat_done", 0, {15'd0, beat_busy}, 16'd0);
`ifndef GL
                // the layers: order, start clocks and finish clocks
                n_seq = n_seq + 1;
                if (dut.layer_done !== 1'b1) fail("layer_done not high on beat_done", 0, 16'd0, 16'd1);
                if (ns != 4) failn("number of start_layer pulses", ns, 4);
                else begin
                    if (sl_n[0] != 1)      failn("conv1 start clock", sl_n[0], 1);
                    if (sl_n[1] != 14340)  failn("conv2 start clock", sl_n[1], 14340);
                    if (sl_n[2] != 97671)  failn("fc1 start clock",   sl_n[2], 97671);
                    if (sl_n[3] != 129482) failn("fc2 start clock",   sl_n[3], 129482);
                    for (p = 0; p < 4; p = p + 1)
                        if (sl_l[p] != p)  failn("layer number at start_layer", sl_l[p], p);
                end
                if (nl != 3) failn("layer_done pulses before the last", nl, 3);
                else begin
                    if (ld_n[0] != 14339)  failn("conv1 finish clock", ld_n[0], 14339);
                    if (ld_n[1] != 97670)  failn("conv2 finish clock", ld_n[1], 97670);
                    if (ld_n[2] != 129481) failn("fc1 finish clock",   ld_n[2], 129481);
                end
`endif
            end
            n_runs = n_runs + 1;
        end
    endtask

    // beat_done must be a one-clock pulse; count the pulses
    reg prev_done = 1'b0;
    always @(negedge clk) begin
        if (beat_done === 1'b1) begin
            n_pulses = n_pulses + 1;
            if (prev_done) fail("beat_done lasted more than 1 clock", 0, 16'd1, 16'd0);
        end
        prev_done = (beat_done === 1'b1);
    end

    // ------------------------------------------------------------------
    // one run of the whole network. immediate = 0: random idle clocks, then start.
    // immediate = 1: start on the clock beat_done was just seen (fastest restart).
    // ------------------------------------------------------------------
    task launch(input integer immediate);
        begin
            if (immediate == 0) begin
                nxt; repeat (rnd[31:29] % 6) @(negedge clk);          // 0..5 idle clocks before the start
                @(negedge clk);
                n_proto = n_proto + 1;
                if (beat_busy !== 1'b0) fail("beat_busy not 0 before start", 0, {15'd0, beat_busy}, 16'd0);
            end
            hold_en = 1'b0;
`ifndef GL
            clear_monitors;
            garbage;
`endif
            start_beat = 1'b1;
            wait_done;
            check_results;
`ifndef GL
            check_monitors;
            check_buffers;
`endif
        end
    endtask

    // start the beat, let it run nclk clocks, then reset in the middle of it
    task abort_run(input integer nclk);
        begin
            hold_en = 1'b0;
`ifndef GL
            clear_monitors;
            garbage;
`endif
            @(negedge clk); start_beat = 1'b1;
            @(negedge clk); start_beat = 1'b0;
            repeat (nclk) @(negedge clk);
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (3) @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer b, kk;
    initial begin
        $readmemh("answer_key/beats_in.hex",        bin);
        $readmemh("answer_key/exp_conv1_relu.hex",  c1k);
        $readmemh("answer_key/exp_conv1_pool.hex",  p1k);
        $readmemh("answer_key/exp_conv2_relu.hex",  c2k);
        $readmemh("answer_key/exp_conv2_pool.hex",  p2k);
        $readmemh("answer_key/exp_fc1.hex",         f1k);
        $readmemh("answer_key/exp_fc2.hex",         f2k);
        $readmemh("answer_key/exp_decision.hex",    deck);
        for (kk = 0; kk < 16*260;  kk = kk + 1) if (^bin[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file beats_in.hex missing or short");       kk = 16*260;  end
        for (kk = 0; kk < 16*2048; kk = kk + 1) if (^c1k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv1_relu.hex missing or short"); kk = 16*2048; end
        for (kk = 0; kk < 16*1024; kk = kk + 1) if (^p1k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv1_pool.hex missing or short"); kk = 16*1024; end
        for (kk = 0; kk < 16*1984; kk = kk + 1) if (^c2k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv2_relu.hex missing or short"); kk = 16*1984; end
        for (kk = 0; kk < 16*992;  kk = kk + 1) if (^p2k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv2_pool.hex missing or short"); kk = 16*992;  end
        for (kk = 0; kk < 16*32;   kk = kk + 1) if (^f1k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_fc1.hex missing or short");        kk = 16*32;   end
        for (kk = 0; kk < 16*2;    kk = kk + 1) if (^f2k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_fc2.hex missing or short");        kk = 16*2;    end
        for (kk = 0; kk < 16;      kk = kk + 1) if (^deck[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_decision.hex missing or short");   kk = 16;      end

        // reset
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        for (b = FIRST; b < FIRST + NB; b = b + 1) begin
            cur_beat = b;
            e0 = f2k[2*b]; e1 = f2k[2*b + 1]; e_ab = deck[b][0];
            load_beat(b, (b % 3) == 1);

            // reset in the middle of a beat, in a different layer each time
            if (b == 5)  abort_run(5000);        // inside conv1
            if (b == 6)  abort_run(50000);       // inside conv2
            if (b == 9)  abort_run(14339);       // at the end of conv1, when conv2 is about to start
            if (b == 10) abort_run(110000);      // inside fc1
            if (b == 14) abort_run(129500);      // inside fc2

            stray_en = ((b % 5) == 2);
            launch(0);
            if ((b % 4) == 3) launch(1);         // beats 3, 7, 11, 15: run again at once
            stray_en = 1'b0;
        end

        repeat (5) @(negedge clk);

        // totals
        if (n_pulses !== n_runs) begin errors = errors + 1; $display("FAIL beat_done pulses: %0d, runs: %0d", n_pulses, n_runs); end

        $display("runs of the network / done pulses            : %0d / %0d", n_runs, n_pulses);
        $display("results compared on beat_done (scores+decision): %0d runs", n_sc);
        $display("clocks checked for 'results hold'            : %0d", n_hold);
`ifndef GL
        $display("finished values checked at bias_rescale      : %0d (%0d runs x 4,066)", n_once, n_runs);
        $display("buffer words compared with the key           : %0d (%0d runs x 2,048)", n_bufw, n_runs);
        $display("buffer address written-once checks           : %0d", n_wr);
        $display("layer order / start / finish clock checks    : %0d runs", n_seq);
        $display("clamped values seen (flag)                   : %0d (on every run it must equal the key's count for that beat)", n_ovf);
        $display("score register changes seen                  : %0d (any change at another clock is an error)", n_chg);
`endif
        $display("protocol checks                              : %0d", n_proto);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
