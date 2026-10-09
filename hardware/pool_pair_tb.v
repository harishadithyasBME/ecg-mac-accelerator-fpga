`timescale 1ns/1ps
// pool_pair_tb.v
// Tests the pooling holder (pool_pair.v, which uses max_pool.v).
//
// Part 1 - REAL DATA, conv1: the 16 real beats from the answer key. For every filter
//          and every pair (positions 2p, 2p+1) the finished post-ReLU outputs
//          (answer_key/exp_conv1_relu.hex) are fed in ONE AT A TIME, exactly like the
//          MAC unit would deliver them, and each pooled value that comes out must equal
//          the answer key's pooled value (answer_key/exp_conv1_pool.hex, written by the
//          Python model). 16 beats x 8 filters x 128 pairs = 16,384 pooled values.
// Part 2 - REAL DATA, conv2: same with exp_conv2_relu.hex -> exp_conv2_pool.hex.
//          16 beats x 16 filters x 62 pairs = 15,872 pooled values.
//          Beats use three delivery styles: an output every clock, random 0-3 idle clocks
//          between outputs, and 30 idle clocks between the two halves of every pair
//          (the parked number must survive the wait). On every idle clock the inputs
//          carry random garbage with in_valid = 0 - the holder must ignore it.
// Part 3 - directed pairs: bigger first, bigger second, equal, both negative, the two
//          16-bit extremes, short/long waits, pairs back to back.
// Part 4 - 20,000 random pairs (extremes and ties over-represented, random waits)
//          compared with the larger of the two computed here.
// On every clock it also checks that out_valid is 1 ONLY for the second number of a pair.
// A watchdog stops the run if it hangs. Gate-level run: same file, netlist instead of RTL.

module pool_pair_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                in_valid = 1'b0;
    reg                pos_odd  = 1'b0;
    reg signed [15:0]  in_val   = 16'sd0;
    wire               out_valid;
    wire signed [15:0] out_val;

    pool_pair dut (.clk(clk), .in_valid(in_valid), .pos_odd(pos_odd), .in_val(in_val),
                   .out_valid(out_valid), .out_val(out_val));

    // watchdog
    initial begin
        #400000000;
        $display("FAIL: timeout - the testbench did not finish");
        $finish;
    end

    // ------------------------------------------------------------------
    // answer key
    // ------------------------------------------------------------------
    reg [15:0] relu1 [0:16*2048-1];       // conv1 after ReLU, before pooling   (f*256 + i)
    reg [15:0] pool1 [0:16*1024-1];       // conv1 pooled                       (ch*128 + p)
    reg [15:0] relu2 [0:16*1984-1];       // conv2 after ReLU, before pooling   (f*124 + i)
    reg [15:0] pool2 [0:16*992-1];        // conv2 pooled                       (ch*62 + p)

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    integer errors = 0, checks = 0, n_conv1 = 0, n_conv2 = 0, n_other = 0;
    reg [31:0] rnd = 32'd20261008;

    task nxt;                              // small deterministic random generator (use the upper bits)
        begin rnd = rnd * 32'd1664525 + 32'd1013904223; end
    endtask

    task fail(input [8*44-1:0] what, input integer where, input [15:0] got, input [15:0] exp);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("FAIL %0s (item %0d): got %h expected %h", what, where, got, exp);
        end
    endtask

    // one clock: apply the inputs just after the falling edge, look at the outputs just before the
    // next falling edge. 'exp' is the pooled value expected when v = 1 and odd = 1.
    task step(input v, input odd, input [15:0] val, input [15:0] exp, input integer tag);
        begin
            @(negedge clk);
            in_valid = v; pos_odd = odd; in_val = val;
            #2;
            checks = checks + 1;
            if (out_valid !== (v & odd))
                fail("out_valid wrong", tag, {15'd0, out_valid}, {15'd0, (v & odd)});
            if (v & odd) begin
                checks = checks + 1;
                if (out_val !== exp)
                    fail("pooled value wrong", tag, out_val, exp);
            end
        end
    endtask

    task idle(input integer n);            // n idle clocks: in_valid = 0, garbage on the other inputs
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                nxt;
                step(1'b0, rnd[31], rnd[30:15], 16'h0000, 0);
            end
        end
    endtask

    // waiting style: 0 = none, 1 = 0..3 random idle clocks, 2 = 30 clocks between the two halves of a pair
    task gap(input integer mode, input integer mid);
        begin
            nxt;
            if (mode == 1)                       idle(rnd[31:30]);
            else if (mode == 2 && mid == 1)      idle(30);
            else if (mode == 2)                  idle(rnd[31:30]);
        end
    endtask

    // ------------------------------------------------------------------
    // Parts 1 and 2: one beat through one conv layer
    // ------------------------------------------------------------------
    task run_layer(input integer layer, input integer b, input integer mode);
        integer nf, npool, f, p;
        reg [15:0] first, second, mx, kv;
        begin
            nf    = (layer == 1) ? 8   : 16;
            npool = (layer == 1) ? 128 : 62;
            for (f = 0; f < nf; f = f + 1)
                for (p = 0; p < npool; p = p + 1) begin
                    if (layer == 1) begin
                        first  = relu1[b*2048 + f*256 + 2*p];
                        second = relu1[b*2048 + f*256 + 2*p + 1];
                        kv     = pool1[b*1024 + f*128 + p];
                    end else begin
                        first  = relu2[b*1984 + f*124 + 2*p];
                        second = relu2[b*1984 + f*124 + 2*p + 1];
                        kv     = pool2[b*992 + f*62 + p];
                    end
                    mx = ($signed(first) > $signed(second)) ? first : second;
                    checks = checks + 1;                       // the key and this file's own max must agree
                    if (kv !== mx) fail("answer key vs own max of the pair", layer*100000 + b*1000 + p, kv, mx);
                    gap(mode, 0);
                    step(1'b1, 1'b0, first,  16'h0000, 1);     // first of the pair: parked
                    gap(mode, 1);
                    step(1'b1, 1'b1, second, kv, 2);           // second: pooled value comes out
                    if (layer == 1) n_conv1 = n_conv1 + 1; else n_conv2 = n_conv2 + 1;
                end
        end
    endtask

    // ------------------------------------------------------------------
    // Parts 3 and 4: any pair of signed 16-bit numbers
    // ------------------------------------------------------------------
    reg [15:0] pa, pb, pmx;

    task pair(input [15:0] a, input [15:0] b, input integer wait_mid);
        begin
            pmx = ($signed(a) > $signed(b)) ? a : b;
            step(1'b1, 1'b0, a, 16'h0000, 10);
            idle(wait_mid);
            step(1'b1, 1'b1, b, pmx, 11);
            n_other = n_other + 1;
        end
    endtask

    function [15:0] pick;                  // random 16-bit value, extremes over-represented
        input [31:0] r;
        begin
            case (r[31:29])
                3'd0:    pick = 16'h8000;
                3'd1:    pick = 16'h7FFF;
                3'd2:    pick = 16'h0000;
                3'd3:    pick = 16'hFFFF;
                3'd4:    pick = 16'h0001;
                default: pick = r[28:13];
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer b, n, k;
    initial begin
        $readmemh("answer_key/exp_conv1_relu.hex", relu1);
        $readmemh("answer_key/exp_conv1_pool.hex", pool1);
        $readmemh("answer_key/exp_conv2_relu.hex", relu2);
        $readmemh("answer_key/exp_conv2_pool.hex", pool2);
        for (k = 0; k < 16*2048; k = k + 1) if (^relu1[k] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv1_relu.hex missing or short"); k = 16*2048; end
        for (k = 0; k < 16*1024; k = k + 1) if (^pool1[k] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv1_pool.hex missing or short"); k = 16*1024; end
        for (k = 0; k < 16*1984; k = k + 1) if (^relu2[k] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv2_relu.hex missing or short"); k = 16*1984; end
        for (k = 0; k < 16*992;  k = k + 1) if (^pool2[k] === 1'bx) begin errors = errors + 1; $display("FAIL key file exp_conv2_pool.hex missing or short"); k = 16*992;  end

        repeat (3) @(negedge clk);
        idle(4);                                               // garbage at the start: nothing may come out

        // Part 1: conv1, 16 real beats
        for (b = 0; b < 16; b = b + 1) run_layer(1, b, b % 3);
        // Part 2: conv2, 16 real beats
        for (b = 0; b < 16; b = b + 1) run_layer(2, b, b % 3);

        // Part 3: directed pairs (a = first, b = second)
        pair(5, 9, 0);          pair(9, 5, 0);          pair(7, 7, 0);
        pair(-3, -8, 0);        pair(-8, -3, 0);        pair(-8, -8, 0);
        pair(-32768, 32767, 0); pair(32767, -32768, 0); pair(-32768, -32768, 0); pair(32767, 32767, 0);
        pair(0, -1, 0);         pair(-1, 0, 0);         pair(0, 0, 0);          pair(1, 0, 0);
        pair(1234, 1000, 100);                                 // parked number must survive 100 idle clocks of garbage
        pair(-5, 77, 100);
        pair(300, 301, 1);      pair(301, 300, 1);      pair(-300, -301, 2);    pair(-301, -300, 2);
        idle(5);

        // Part 4: 20,000 random pairs
        for (n = 0; n < 20000; n = n + 1) begin
            nxt; pa = pick(rnd);
            nxt; pb = pick(rnd);
            nxt; if (rnd[31:29] == 3'd0) pb = pa;              // ties
            nxt; if (rnd[31:30] != 2'd0) idle(rnd[31:30]);     // 0..3 clocks before the pair
            nxt; pair(pa, pb, rnd[31:28]);                     // 0..15 clocks between the halves
        end
        idle(3);

        // totals
        checks = checks + 2;
        if (n_conv1 !== 16*8*128)  begin errors = errors + 1; $display("FAIL conv1 pooled outputs checked: %0d, expected %0d", n_conv1, 16*8*128);  end
        if (n_conv2 !== 16*16*62)  begin errors = errors + 1; $display("FAIL conv2 pooled outputs checked: %0d, expected %0d", n_conv2, 16*16*62);  end

        $display("conv1 pooled values checked : %0d (16 beats x 8 filters x 128)", n_conv1);
        $display("conv2 pooled values checked : %0d (16 beats x 16 filters x 62)", n_conv2);
        $display("directed + random pairs     : %0d", n_other);
        $display("total checks : %0d", checks);
        $display("total errors : %0d", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("FAIL: some tests failed");
        $finish;
    end

endmodule
