`timescale 1ns/1ps
// decision_tb.v
// Tests decision.v (abnormal = 1 only when score1 is strictly higher than score0, signed compare).
//
// Part 1 - the real key: the 16 beats of answer_key/exp_fc2.hex (score0, score1 per beat) must give
//          exactly answer_key/exp_decision.hex. This includes beat 9, where both scores are equal
//          (a tie must give Normal).
// Part 2 - every possible 16-bit value for score0 (65,536 values) against 12 partners each:
//          score0 - 1, score0 itself, score0 + 1 (where they exist), and the extremes and
//          small values -32768, -1, 0, 1, 32767, plus 3 random partners.
// Part 3 - 1,000,000 random pairs (some forced equal).
// The expected answer is worked out here with 32-bit integers, which is a different way of
// comparing than the signed 16-bit compare inside decision.v.
//
// compile:  iverilog -o decision_sim decision.v decision_tb.v
// run:      vvp decision_sim        (the answer_key folder must be in the current folder)

module decision_tb;

    reg  signed [15:0] s0, s1;
    wire               ab;

    decision dut (.score0(s0), .score1(s1), .abnormal(ab));

    integer errors = 0, checks = 0, n_key = 0, n_sweep = 0, n_rand = 0;
    integer i0, i1, k, m;
    reg [31:0] rnd = 32'd20261008;
    reg [15:0] key_sc [0:31];
    reg [15:0] key_dec [0:15];
    reg        want;

    task nxt;
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task check(input signed [15:0] a, input signed [15:0] b);
        begin
            s0 = a; s1 = b;
            #1;
            i0 = a; i1 = b;                         // sign-extended into 32-bit integers
            want = (i1 > i0);
            checks = checks + 1;
            if (ab !== want) begin
                errors = errors + 1;
                if (errors <= 10) $display("FAIL score0=%0d score1=%0d: abnormal=%b expected %b", a, b, ab, want);
            end
        end
    endtask

    initial begin
        $readmemh("answer_key/exp_fc2.hex",      key_sc);
        $readmemh("answer_key/exp_decision.hex", key_dec);

        // Part 1: the real key
        for (k = 0; k < 16; k = k + 1) begin
            if (^key_sc[2*k] === 1'bx || ^key_sc[2*k+1] === 1'bx || ^key_dec[k] === 1'bx) begin
                errors = errors + 1; $display("FAIL key file missing or short");
            end else begin
                s0 = key_sc[2*k]; s1 = key_sc[2*k+1];
                #1;
                n_key = n_key + 1; checks = checks + 1;
                if (ab !== key_dec[k][0]) begin
                    errors = errors + 1;
                    $display("FAIL key beat %0d: scores %0d / %0d, abnormal=%b, key says %b", k, s0, s1, ab, key_dec[k][0]);
                end
            end
        end

        // Part 2: all 65,536 values of score0 against 12 partners
        for (i0 = -32768; i0 <= 32767; i0 = i0 + 1) begin
            check(i0[15:0], i0[15:0]);                              // equal: must be Normal
            if (i0 > -32768) check(i0[15:0], i0[15:0] - 16'sd1);
            if (i0 <  32767) check(i0[15:0], i0[15:0] + 16'sd1);
            check(i0[15:0], -16'sd32768);
            check(i0[15:0], -16'sd1);
            check(i0[15:0], 16'sd0);
            check(i0[15:0], 16'sd1);
            check(i0[15:0], 16'sd32767);
            for (m = 0; m < 3; m = m + 1) begin nxt; check(i0[15:0], rnd[31:16]); end
            n_sweep = n_sweep + 1;
        end

        // Part 3: 1,000,000 random pairs, some of them equal
        for (k = 0; k < 1000000; k = k + 1) begin
            nxt; s0 = rnd[31:16];
            nxt; s1 = rnd[31:16];
            nxt; if (rnd[31:29] == 3'd0) s1 = s0;
            check(s0, s1);
            n_rand = n_rand + 1;
        end

        $display("key beats checked     : %0d (beat 9 is an exact tie -> Normal)", n_key);
        $display("score0 values swept   : %0d", n_sweep);
        $display("random pairs          : %0d", n_rand);
        $display("total checks : %0d", checks);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
