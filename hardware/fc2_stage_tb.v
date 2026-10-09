`timescale 1ns/1ps
// fc2_stage_tb.v
// Tests the whole last layer (fc2_stage.v: fc2 + the two score registers + decision) against the
// Python answer key, and against a second, independent calculation inside this testbench.
//
// PART 1 - the 16 real beats
//   The layer's input comes from the key too: answer_key/exp_fc1.hex is exactly what fc1 leaves in
//   buffer C (32 values), so fc2 is tested on its own with the right numbers.
//   For each beat:
//     1. load the 32 values into the layer's input buffer (beats 1, 4, 7, 10, 13 with random idle clocks
//        between the values),
//     2. wait a random 0..5 clocks, pulse start_layer, wait for layer_done,
//     3. on the layer_done clock: score0 and score1 must equal answer_key/exp_fc2.hex, and abnormal must
//        equal answer_key/exp_decision.hex (beat 9 is an exact tie 628 / 628 -> Normal; beat 10 is
//        603 / 602 -> one step apart, Normal).
//   After layer_done the two scores and abnormal must STAY the same (checked on every clock until the
//   next run is started, which includes the time the next beat's input is being loaded).
//   Beats 3, 7, 11, 15 are run twice in a row, the second run starting on the very clock layer_done is
//   seen (fastest possible restart). Beats 5 and 13 are first interrupted by a reset in the middle of the
//   layer (beat 5 during neuron 0, beat 13 during neuron 1); the run after the reset must still be exact.
//
// PART 2 - random input vectors (NRAND, default 2000)
//   The key's beats never push a score into the clamp (saturation), and they are all realistic numbers.
//   So random vectors are added: small, medium and full-range numbers, all +32767, all -32768, all
//   zero (only the bias counts), sparse vectors, and non-negative (ReLU-like) vectors. The expected scores
//   are worked out inside this testbench from weights.hex and biases.hex with 64-bit integers:
//       acc = sum(input * weight)    + (bias << 9)    then  >> 14    then clamp to -32768 .. 32767
//   Another way of calculating than the RTL (no shared code). The same calculation is first run on the
//   16 key beats and must reproduce the key exactly - that ties the testbench's own calculation to the
//   Python answer key. For these vectors the expected 'abnormal' is score1 > score0 as 32-bit integers.
//   Every 5th random vector is also run twice in a row (fastest restart).
//
// Extra checks (simulation of the RTL only - they look inside the design, so they are skipped in
// the gate-level run, where the same file is used with -DGL):
//   - both score registers are filled with garbage before every run, so a score that is never written
//     cannot pass just because it already held the right number;
//   - each of the two neuron values must be finished exactly once per run, in the right order, with
//     the right value at the output of bias_rescale (done_d clock);
//   - score0 may change only on the clock after neuron 0 is finished and score1 only on the clock after
//     neuron 1 is finished - at no other clock (each score register is written only by its own neuron);
//   - the saturation flag of bias_rescale must be raised exactly as often as the clamps that the
//     testbench's own calculation finds (0 on every key beat - answer_key_info.txt, last number of sat(...)).
// Always checked:
//   - layer_busy is 0 before the start, 1 all the way until layer_done, 0 on the layer_done clock;
//   - layer_done is a single-clock pulse and comes exactly 70 = 2 x 34 + 2 clocks after start_layer
//     (the first neuron starts 2 clocks after the pulse, each neuron takes 34 clocks - 32 work, 1 done,
//     1 idle - and layer_done comes 2 clocks after the last neuron's done clock);
//   - the number of layer_done pulses is exactly the number of completed runs (an interrupted run
//     must not produce one).
// A watchdog stops the run if it hangs.
//
// Fewer beats / vectors (gate-level run): add  -DNBEATS=16 -DNRAND=300  to the iverilog command line.
//
// compile:  iverilog -o fc2_stage_sim fc2_stage.v decision.v addr_gen.v layer_ctrl.v mac_unit.v bias_rescale.v bias_rom.v weight_rom.v data_buffer.v fc2_stage_tb.v
// run:      vvp fc2_stage_sim        (weights.hex, biases.hex and the answer_key folder must be in the current folder)

`ifndef NBEATS
`define NBEATS 16
`endif
`ifndef NRAND
`define NRAND 2000
`endif

module fc2_stage_tb;

    localparam NB = `NBEATS;
    localparam NR = `NRAND;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                rst_n       = 1'b0;
    reg                in_we       = 1'b0;
    reg  [4:0]         in_waddr    = 5'd0;
    reg  signed [15:0] in_wdata    = 16'sd0;
    reg                start_layer = 1'b0;
    wire               layer_busy;
    wire               layer_done;
    wire signed [15:0] score0;
    wire signed [15:0] score1;
    wire               abnormal;

    fc2_stage dut (.clk(clk), .rst_n(rst_n),
                   .in_we(in_we), .in_waddr(in_waddr), .in_wdata(in_wdata),
                   .start_layer(start_layer), .layer_busy(layer_busy), .layer_done(layer_done),
                   .score0(score0), .score1(score1), .abnormal(abnormal));

    // watchdog: the full test needs about 250,000 clocks (2.5 ms of simulated time)
    initial begin
        #100000000;
        $display("FAIL: timeout - the testbench did not finish");
        $finish;
    end

    // ------------------------------------------------------------------
    // answer key and the weights for the testbench's own calculation
    // ------------------------------------------------------------------
    reg [15:0] fc1k [0:16*32-1];          // layer input = buffer C as fc1 leaves it (Q7.9)
    reg [15:0] fc2k [0:16*2-1];           // expected scores: [2*beat] = score0, [2*beat+1] = score1 (Q6.10)
    reg [15:0] deck [0:15];               // expected decision per beat (1 hex digit)
    reg [15:0] wmem [0:32487];            // all weights (fc2 = 32,424 .. 32,487)
    reg [15:0] bmem [0:57];               // all biases  (fc2 = 56, 57)

    // ------------------------------------------------------------------
    // the vector under test and what is expected for it
    // ------------------------------------------------------------------
    reg signed [15:0] rin [0:31];         // the 32 input values
    reg signed [15:0] e0, e1;             // expected score0 / score1
    reg               e_ab;               // expected abnormal
    integer           e_ovf;              // expected number of clamped scores in this run

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    integer errors = 0, n_sc = 0, n_dec = 0, n_hold = 0, n_model = 0, n_neur = 0, n_ovf = 0;
    integer n_proto = 0, n_runs = 0, n_pulses = 0, n_key = 0, n_rnd = 0;
    integer n_hi = 0, n_lo = 0;
    reg [31:0] rnd = 32'd20261008;
    integer cur_beat = 0;

    task nxt;
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task fail(input [8*44-1:0] what, input integer where, input [15:0] got, input [15:0] exp);
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("FAIL %0s (vector %0d, item %0d): got %h expected %h", what, cur_beat, where, got, exp);
        end
    endtask

    // ------------------------------------------------------------------
    // the testbench's own calculation of fc2 for the vector in rin[]
    // result in m0, m1 (score0, score1), m_ovf = number of clamped scores
    // ------------------------------------------------------------------
    reg signed [15:0] m0, m1;
    integer           m_ovf;

    task model;
        integer n, t, p;
        reg signed [63:0] acc, bs, v;
        begin
            m_ovf = 0;
            for (n = 0; n < 2; n = n + 1) begin
                acc = 64'sd0;
                for (t = 0; t < 32; t = t + 1) begin
                    p   = $signed(rin[t]) * $signed(wmem[32424 + n*32 + t]);
                    acc = acc + p;
                end
                bs  = $signed(bmem[56 + n]);
                acc = acc + (bs <<< 9);
                v   = acc >>> 14;
                if (v > 64'sd32767) begin
                    v = 64'sd32767;  m_ovf = m_ovf + 1; n_hi = n_hi + 1;
                end else if (v < -64'sd32768) begin
                    v = -64'sd32768; m_ovf = m_ovf + 1; n_lo = n_lo + 1;
                end
                if (n == 0) m0 = v[15:0]; else m1 = v[15:0];
            end
        end
    endtask

    // ------------------------------------------------------------------
    // load the 32 input values of rin[] into the layer's input buffer
    // ------------------------------------------------------------------
    task load_vec(input integer gappy);
        integer s;
        begin
            for (s = 0; s < 32; s = s + 1) begin
                @(negedge clk);
                in_we = 1'b1; in_waddr = s[4:0]; in_wdata = rin[s];
                if (gappy != 0) begin
                    nxt;
                    repeat (rnd[31:30]) begin                 // 0..3 idle clocks with garbage on the lines
                        @(negedge clk);
                        nxt;
                        in_we = 1'b0; in_waddr = rnd[31:27]; in_wdata = rnd[22:7];
                    end
                end
            end
            @(negedge clk);
            in_we = 1'b0; nxt; in_waddr = rnd[31:27]; in_wdata = rnd[22:7];
        end
    endtask

    // ------------------------------------------------------------------
    // monitors that look inside the design (RTL only)
    // ------------------------------------------------------------------
`ifndef GL
    integer seen [0:63];
    integer pre_cnt, ovf_cnt;
    integer k;
    reg [15:0] tmp16;

    task clear_monitors;
        begin
            for (k = 0; k < 64; k = k + 1) seen[k] = 0;
            pre_cnt = 0;
            ovf_cnt = 0;
        end
    endtask

    // the score registers may change ONLY on the clock after their own neuron's done_d clock
    // (score0 after neuron 0 is finished, score1 after neuron 1) - never at any other time.
    reg signed [15:0] prev_s0 = 16'bx, prev_s1 = 16'bx;     // value seen at the previous look
    reg               ok0 = 1'b0, ok1 = 1'b0;               // 1 = a change is allowed at the next look
    integer           n_chg = 0;

    task garbage_scores;
        begin
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
        ok0 = (rst_n === 1'b1) && (dut.done_d === 1'b1) && (dut.filter_d === 6'd0);
        ok1 = (rst_n === 1'b1) && (dut.done_d === 1'b1) && (dut.filter_d === 6'd1);
    end

    // every clock in which bias_rescale delivers a finished neuron value (done_d = 1)
    always @(negedge clk) if (rst_n && dut.done_d === 1'b1) begin
        pre_cnt = pre_cnt + 1;
        seen[dut.filter_d] = seen[dut.filter_d] + 1;          // filter_d has 6 bits: 0..63 always fits
        if (dut.filter_d === 6'd0) begin
            if (dut.act !== e0) fail("neuron 0 value wrong at bias_rescale", 0, dut.act, e0);
        end else if (dut.filter_d === 6'd1) begin
            if (dut.act !== e1) fail("neuron 1 value wrong at bias_rescale", 1, dut.act, e1);
        end else begin
            fail("neuron number out of range", dut.filter_d, {10'd0, dut.filter_d}, 16'd1);
        end
        if (dut.act_ovf === 1'b1) ovf_cnt = ovf_cnt + 1;
    end

    task check_monitors;
        begin
            n_neur = n_neur + 2;
            if (pre_cnt != 2) begin tmp16 = pre_cnt; fail("neuron values seen", pre_cnt, tmp16, 16'd2); end
            if (seen[0] != 1) begin tmp16 = seen[0]; fail("neuron 0 not finished exactly once", 0, tmp16, 16'd1); end
            if (seen[1] != 1) begin tmp16 = seen[1]; fail("neuron 1 not finished exactly once", 1, tmp16, 16'd1); end
            n_ovf = n_ovf + ovf_cnt;
            if (ovf_cnt != e_ovf) begin tmp16 = ovf_cnt; fail("clamped values (saturation flag)", e_ovf, tmp16, e_ovf[15:0]); end
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
            while (layer_done !== 1'b1 && n < 1000) begin
                n_proto = n_proto + 1;
                if (layer_busy !== 1'b1) fail("layer_busy not 1 while running", n, {15'd0, layer_busy}, 16'd1);
                @(negedge clk);
                n = n + 1;
            end
            n_proto = n_proto + 3;
            if (layer_done !== 1'b1)     fail("layer_done never came", n, 16'd0, 16'd1);
            else begin
                if (n != 70)             fail("clocks from start to layer_done", n, n[15:0], 16'd70);
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
    // after layer_done the results must hold until the next run is started
    // ------------------------------------------------------------------
    reg hold_en = 1'b0;
    reg signed [15:0] h0, h1;                 // copies of the results taken on the layer_done clock
    reg               h_ab;
    always @(negedge clk) if (hold_en) begin
        n_hold = n_hold + 1;
        if (score0   !== h0)   fail("score0 changed after layer_done",   0, score0, h0);
        if (score1   !== h1)   fail("score1 changed after layer_done",   1, score1, h1);
        if (abnormal !== h_ab) fail("abnormal changed after layer_done", 2, {15'd0, abnormal}, {15'd0, h_ab});
    end

    // ------------------------------------------------------------------
    // compare the results on the layer_done clock
    // ------------------------------------------------------------------
    task check_results;
        begin
            n_sc  = n_sc + 2;
            n_dec = n_dec + 1;
            if (score0   !== e0)   fail("score0 wrong",   0, score0, e0);
            if (score1   !== e1)   fail("score1 wrong",   1, score1, e1);
            if (abnormal !== e_ab) fail("abnormal wrong", 2, {15'd0, abnormal}, {15'd0, e_ab});
            h0 = e0; h1 = e1; h_ab = e_ab;
            hold_en = 1'b1;
        end
    endtask

    // ------------------------------------------------------------------
    // one run of the layer. immediate = 0: random idle clocks, then start.
    // immediate = 1: start on the clock layer_done was just seen (fastest restart).
    // ------------------------------------------------------------------
    task launch(input integer immediate);
        begin
            if (immediate == 0) begin
                nxt; repeat (rnd[31:29] % 6) @(negedge clk);          // 0..5 idle clocks before the start
                @(negedge clk);
                n_proto = n_proto + 1;
                if (layer_busy !== 1'b0) fail("layer_busy not 0 before start", 0, {15'd0, layer_busy}, 16'd0);
            end
            hold_en = 1'b0;
`ifndef GL
            clear_monitors;
            garbage_scores;
`endif
            start_layer = 1'b1;
            wait_done;
            check_results;
`ifndef GL
            check_monitors;
`endif
        end
    endtask

    // start the layer, let it run nclk clocks, then reset in the middle of it
    task abort_run(input integer nclk);
        begin
            hold_en = 1'b0;
`ifndef GL
            clear_monitors;
            garbage_scores;
`endif
            @(negedge clk); start_layer = 1'b1;
            @(negedge clk); start_layer = 1'b0;
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
    integer b, r, j, kk, cls, a0, a1;
    reg signed [15:0] sv;
    initial begin
        $readmemh("answer_key/exp_fc1.hex",      fc1k);
        $readmemh("answer_key/exp_fc2.hex",      fc2k);
        $readmemh("answer_key/exp_decision.hex", deck);
        $readmemh("weights.hex",                 wmem);
        $readmemh("biases.hex",                  bmem);
        for (kk = 0; kk < 16*32; kk = kk + 1) if (^fc1k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_fc1.hex missing or short"); kk = 16*32; end
        for (kk = 0; kk < 16*2;  kk = kk + 1) if (^fc2k[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_fc2.hex missing or short"); kk = 16*2;  end
        for (kk = 0; kk < 16;    kk = kk + 1) if (^deck[kk] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_decision.hex missing or short"); kk = 16; end
        for (kk = 32424; kk < 32488; kk = kk + 1) if (^wmem[kk] === 1'bx) begin errors = errors + 1; $display("FAIL weights.hex missing or short"); kk = 32488; end
        for (kk = 56;    kk < 58;    kk = kk + 1) if (^bmem[kk] === 1'bx) begin errors = errors + 1; $display("FAIL biases.hex missing or short");  kk = 58;    end

        // reset
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        // ============ PART 1: the 16 real beats ============
        for (b = 0; b < NB; b = b + 1) begin
            cur_beat = b;
            for (j = 0; j < 32; j = j + 1) rin[j] = fc1k[b*32 + j];
            e0 = fc2k[2*b]; e1 = fc2k[2*b + 1]; e_ab = deck[b][0]; e_ovf = 0;

            // the testbench's own calculation must reproduce the key
            model;
            n_model = n_model + 1;
            if (m0 !== e0) fail("TB calculation disagrees with key (s0)", 0, m0, e0);
            if (m1 !== e1) fail("TB calculation disagrees with key (s1)", 1, m1, e1);
            if (m_ovf != 0) fail("TB calculation clamps a key beat", 2, m_ovf[15:0], 16'd0);

            load_vec((b % 3) == 1);
            if ((b % 8) == 5) abort_run(30 + 15 * (b / 8));       // beat 5: in neuron 0, beat 13: in neuron 1
            launch(0);
            if ((b % 4) == 3) launch(1);                          // beats 3, 7, 11, 15: run again at once
            n_key = n_key + 1;
        end

        // ============ PART 2: random vectors ============
        for (r = 0; r < NR; r = r + 1) begin
            cur_beat = 1000 + r;
            nxt; cls = rnd[31:29];
            for (j = 0; j < 32; j = j + 1) begin
                nxt; sv = rnd[31:16];
                case (cls)
                    0:       rin[j] = sv >>> 8;                       // small
                    1:       rin[j] = sv >>> 4;                       // medium
                    2:       rin[j] = sv;                             // full range
                    3:       begin nxt; rin[j] = (rnd[31:29] == 3'd0) ? sv : 16'sd0; end   // sparse
                    4:       rin[j] = 16'sd32767;                     // all the largest value
                    5:       rin[j] = -16'sd32768;                    // all the smallest value
                    6:       rin[j] = 16'sd0;                         // all zero: only the bias counts
                    default: rin[j] = {1'b0, rnd[30:16]};             // non-negative, like real ReLU outputs
                endcase
            end
            model;
            e0 = m0; e1 = m1; e_ovf = m_ovf;
            a0 = m0; a1 = m1;
            e_ab = (a1 > a0);

            load_vec((r % 3) == 1);
            launch(0);
            if ((r % 5) == 4) launch(1);
            n_rnd = n_rnd + 1;
        end

        repeat (5) @(negedge clk);

        // totals
        if (n_pulses !== n_runs) begin errors = errors + 1; $display("FAIL layer_done pulses: %0d, runs: %0d", n_pulses, n_runs); end

        $display("key beats / random vectors            : %0d / %0d", n_key, n_rnd);
        $display("scores compared on layer_done         : %0d (%0d runs x 2)", n_sc, n_dec);
        $display("clocks checked for 'results hold'     : %0d", n_hold);
        $display("TB calculation vs key                 : %0d beats", n_model);
        $display("runs of the layer / done pulses       : %0d / %0d", n_runs, n_pulses);
        $display("clamps found by the TB calculation    : %0d high, %0d low", n_hi, n_lo);
`ifndef GL
        $display("neuron values checked at bias_rescale : %0d (%0d runs x 2)", n_neur, n_runs);
        $display("clamped values seen (flag)            : %0d (on every run it must equal the TB calculation's count)", n_ovf);
        $display("score register changes seen          : %0d (about 2 per run; any change at another clock is an error)", n_chg);
`endif
        $display("protocol checks                       : %0d", n_proto);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
