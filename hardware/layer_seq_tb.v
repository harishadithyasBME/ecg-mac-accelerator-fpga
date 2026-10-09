`timescale 1ns/1ps
// layer_seq_tb.v
// Tests layer_seq.v (the layer sequencer) on its own.
//
// The testbench plays the part of the datapath: whenever the sequencer pulses start_layer, a "fake
// datapath" answers with a layer_done pulse after a random number of clocks (1 .. 12, sometimes up to 40).
// Then, for 400,000 clocks, the testbench throws everything at the sequencer:
//   - start_beat pulses at random times: when idle, in the middle of a beat (must be ignored), and in the
//     very clock in which a beat finishes (must start the next beat at once),
//   - stray layer_done pulses while the sequencer is idle or in its GO state (must be ignored),
//   - resets in the middle of a beat (everything must go back to idle, layer 0).
//
// EVERY clock, all four outputs (layer, start_layer, beat_busy, beat_done) are compared with what the rules
// say they must be. The rules are written down here a second time, as a small step-by-step model:
//   idle --accepted start_beat--> go (start_layer = 1 for one clock, layer = 0)
//   go --next clock--> run
//   run --layer_done--> go with layer + 1  (or, after layer 3: idle, with beat_done = 1 in that clock)
//   a start_beat is accepted only when idle, or in the beat_done clock.
// On top of that, a second, separate check counts events: every beat must show exactly four start_layer
// pulses, with layer numbers 0, 1, 2, 3 in that order, each pulse one clock wide.
//
// compile:  iverilog -o layer_seq_sim layer_seq.v layer_seq_tb.v
// run:      vvp layer_seq_sim

module layer_seq_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  rst_n      = 1'b0;
    reg  start_beat = 1'b0;
    reg  spur_next  = 1'b0;                 // a stray layer_done in the next clock
    integer dly_next = 1;                   // how long the fake datapath takes for the layer that starts now

    wire       start_layer, beat_busy, beat_done;
    wire [1:0] layer;
    wire       layer_done;

    layer_seq dut (.clk(clk), .rst_n(rst_n), .start_beat(start_beat), .layer_done(layer_done),
                   .layer(layer), .start_layer(start_layer), .beat_busy(beat_busy), .beat_done(beat_done));

    // ------------------------------------------------------------------
    // the fake datapath: registered outputs, like the real layer_done
    // ------------------------------------------------------------------
    reg     fake_done = 1'b0;
    reg     spur_r    = 1'b0;
    integer cnt       = 0;
    assign  layer_done = fake_done | spur_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fake_done <= 1'b0;
            spur_r    <= 1'b0;
            cnt       <= 0;
        end else begin
            fake_done <= 1'b0;
            spur_r    <= spur_next;
            if (cnt > 0) begin
                cnt <= cnt - 1;
                if (cnt == 1) fake_done <= 1'b1;
            end
            if (start_layer) begin
                if (dly_next == 1) fake_done <= 1'b1;
                else               cnt <= dly_next - 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // bookkeeping
    // ------------------------------------------------------------------
    integer errors = 0, n_clocks = 0, n_sl = 0, n_bd = 0, n_cmp = 0;
    integer n_acc_idle = 0, n_acc_restart = 0, n_ign_busy = 0, n_spur_idle = 0, n_spur_go = 0;
    integer n_resets = 0, n_resets_mid = 0, n_beats_ok = 0;
    reg [31:0] rnd = 32'd20261008;

    task nxt;
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task fail(input [8*40-1:0] what, input integer a, input integer b);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("FAIL %0s (clock %0d): got %0d expected %0d", what, n_clocks, a, b);
        end
    endtask

    // the step-by-step model
    integer m_mode  = 0;                    // 0 idle, 1 go, 2 run
    integer m_layer = 0;
    // the separate event counting
    integer sl_in_beat = 0;
    reg     prev_sl = 1'b0, prev_bd = 1'b0;

    integer exp_sl, exp_ly, exp_bd, exp_bb, accepted, next_mode, maxd;
    integer r_a, r_b, r_c, r_d, rst_hold = 0;

    always @(negedge clk) begin
        n_clocks = n_clocks + 1;

        // ---------- 1. what the outputs must be in this clock ----------
        exp_sl = (m_mode == 1);
        exp_ly = m_layer;
        exp_bd = (m_mode == 2) && (layer_done === 1'b1) && (m_layer == 3);
        exp_bb = (m_mode != 0) && !exp_bd;

        n_cmp = n_cmp + 4;
        if (start_layer !== exp_sl[0]) fail("start_layer", start_layer, exp_sl);
        if (layer       !== exp_ly[1:0]) fail("layer",       layer,       exp_ly);
        if (beat_done   !== exp_bd[0]) fail("beat_done",   beat_done,   exp_bd);
        if (beat_busy   !== exp_bb[0]) fail("beat_busy",   beat_busy,   exp_bb);

        if (spur_r && m_mode == 0) n_spur_idle = n_spur_idle + 1;
        if (spur_r && m_mode == 1) n_spur_go   = n_spur_go + 1;

        // ---------- 2. the separate event check ----------
        if (start_layer === 1'b1) begin
            n_sl = n_sl + 1;
            if (prev_sl) fail("start_layer wider than 1 clock", 1, 0);
            if (layer !== sl_in_beat[1:0]) fail("layer number at start_layer", layer, sl_in_beat);
            sl_in_beat = sl_in_beat + 1;
        end
        if (beat_done === 1'b1) begin
            n_bd = n_bd + 1;
            if (prev_bd) fail("beat_done wider than 1 clock", 1, 0);
            if (sl_in_beat != 4) fail("start_layer pulses in this beat", sl_in_beat, 4);
            else n_beats_ok = n_beats_ok + 1;
        end
        prev_sl = (start_layer === 1'b1);
        prev_bd = (beat_done === 1'b1);

        // ---------- 3. choose the inputs for the edge that ends this clock ----------
        nxt; r_a = rnd[31:28];
        nxt; r_b = rnd[31:28];
        nxt; r_c = rnd[31:26];
        nxt; r_d = rnd[31:21];

        // reset: sometimes, in the middle of things
        if (rst_hold > 0) begin
            rst_hold = rst_hold - 1;
            if (rst_hold == 0) rst_n = 1'b1;
        end else if (n_clocks > 5 && r_d == 11'd7) begin                // about 1 in 2000 clocks
            rst_n = 1'b0;
            rst_hold = 1 + (r_a % 3);
            n_resets = n_resets + 1;
            if (m_mode != 0) n_resets_mid = n_resets_mid + 1;
        end else if (n_clocks == 4) begin
            rst_n = 1'b1;                                               // first release
        end

        // start_beat: more often when idle or when a beat is just finishing
        if (m_mode == 0 || exp_bd) start_beat = (r_a < 8);              // 50 %
        else                       start_beat = (r_a < 3);              // ~19 % while a beat is running (must be ignored)
        if (n_clocks < 8) start_beat = 1'b0;

        accepted = start_beat && (m_mode == 0 || exp_bd) && rst_n;
        if (accepted && m_mode == 0)      n_acc_idle    = n_acc_idle + 1;
        if (accepted && m_mode != 0)      n_acc_restart = n_acc_restart + 1;
        if (start_beat && !accepted && m_mode != 0 && rst_n) n_ign_busy = n_ign_busy + 1;

        // the fake datapath's answer time for a layer that starts in this clock (sampled at the edge that ends it)
        maxd = (r_b < 2) ? 40 : 12;
        dly_next = 1 + (r_c % maxd);

        // ---------- 4. the model's next state ----------
        if (!rst_n) begin
            m_mode = 0; m_layer = 0; sl_in_beat = 0;
        end else if (accepted) begin
            m_mode = 1; m_layer = 0; sl_in_beat = 0;
        end else begin
            case (m_mode)
                1: m_mode = 2;
                2: if (layer_done === 1'b1) begin
                       if (m_layer == 3) m_mode = 0;
                       else begin m_layer = m_layer + 1; m_mode = 1; end
                   end
                default: ;
            endcase
        end

        // stray layer_done in the next clock: only where the sequencer will not be running
        spur_next = (m_mode != 2) && (r_b == 4'd5 || r_b == 4'd9) && rst_n;
    end

    initial begin
        rst_n = 1'b0;
        wait (n_clocks == 400000);
        @(posedge clk);

        // the test must really have visited every kind of situation
        if (n_bd < 1000)        begin errors = errors + 1; $display("FAIL too few finished beats: %0d", n_bd); end
        if (n_acc_restart < 50) begin errors = errors + 1; $display("FAIL too few restarts in the beat_done clock: %0d", n_acc_restart); end
        if (n_ign_busy < 500)   begin errors = errors + 1; $display("FAIL too few ignored start_beat pulses: %0d", n_ign_busy); end
        if (n_spur_idle < 100)  begin errors = errors + 1; $display("FAIL too few stray layer_done while idle: %0d", n_spur_idle); end
        if (n_spur_go < 100)    begin errors = errors + 1; $display("FAIL too few stray layer_done in GO: %0d", n_spur_go); end
        if (n_resets_mid < 20)  begin errors = errors + 1; $display("FAIL too few resets in the middle of a beat: %0d", n_resets_mid); end

        $display("clocks run                              : %0d", n_clocks);
        $display("output comparisons                      : %0d (4 outputs x every clock)", n_cmp);
        $display("beats finished (beat_done pulses)       : %0d, of which with exactly 4 correct start_layer pulses: %0d", n_bd, n_beats_ok);
        $display("start_layer pulses                      : %0d", n_sl);
        $display("beats started from idle / at beat_done  : %0d / %0d", n_acc_idle, n_acc_restart);
        $display("start_beat ignored while busy           : %0d", n_ign_busy);
        $display("stray layer_done while idle / in GO     : %0d / %0d", n_spur_idle, n_spur_go);
        $display("resets / of those in the middle of a beat: %0d / %0d", n_resets, n_resets_mid);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
