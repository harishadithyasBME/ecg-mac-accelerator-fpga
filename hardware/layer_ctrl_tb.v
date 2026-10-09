`timescale 1ns/1ps
// Wires layer_ctrl -> mac_unit with two small memories, then checks that for
// several N the MAC ends up holding exactly the dot product, and that the
// control protocol is right (one clear_acc, N enables, one done pulse).
module layer_ctrl_tb;

    reg clk = 0, rst_n = 0, start = 0;
    reg [10:0] num_terms = 0;

    wire clear_acc, enable, busy, done;
    wire [10:0] term_idx;

    reg signed [15:0] data_mem   [0:1023];
    reg signed [15:0] weight_mem [0:1023];
    wire signed [15:0] data_in   = data_mem[term_idx];
    wire signed [15:0] weight_in = weight_mem[term_idx];
    wire signed [47:0] acc_out;

    layer_ctrl ctrl (.clk(clk), .rst_n(rst_n), .start(start), .num_terms(num_terms),
                     .clear_acc(clear_acc), .enable(enable), .busy(busy),
                     .done(done), .term_idx(term_idx));

    mac_unit   mac  (.clk(clk), .rst_n(rst_n), .clear_acc(clear_acc), .enable(enable),
                     .data_in(data_in), .weight_in(weight_in), .acc_out(acc_out));

    always #5 clk = ~clk;

    // protocol monitors (sample at each rising edge)
    integer cnt_en, cnt_clr, cnt_done;
    always @(posedge clk) begin
        if (enable)    cnt_en   <= cnt_en + 1;
        if (clear_acc) cnt_clr  <= cnt_clr + 1;
        if (done)      cnt_done <= cnt_done + 1;
    end

    integer errors = 0;
    integer i;
    reg signed [47:0] expected;

    task fill_random;
        integer k;
        begin
            for (k = 0; k < 1024; k = k + 1) begin
                data_mem[k]   = $random;
                weight_mem[k] = $random;
            end
        end
    endtask

    task fill_max;                       // worst case: every product = (-32768)^2 = 2^30
        integer k;
        begin
            for (k = 0; k < 1024; k = k + 1) begin
                data_mem[k]   = -32768;
                weight_mem[k] = -32768;
            end
        end
    endtask

    task run_test(input integer n, input [255:0] name);
        begin
            expected = 0;
            for (i = 0; i < n; i = i + 1)
                expected = expected + data_mem[i] * weight_mem[i];

            cnt_en = 0; cnt_clr = 0; cnt_done = 0;
            @(negedge clk); num_terms = n; start = 1;
            @(negedge clk); start = 0;

            wait (done);
            #1;
            if (acc_out !== expected) begin
                $display("FAIL [%0s] N=%0d: acc_out=%0d expected=%0d", name, n, acc_out, expected);
                errors = errors + 1;
            end
            if (cnt_en !== n || cnt_clr !== 1) begin
                $display("FAIL [%0s] N=%0d: enable cycles=%0d (want %0d), clear_acc pulses=%0d (want 1)",
                         name, n, cnt_en, n, cnt_clr);
                errors = errors + 1;
            end
            @(negedge clk); @(negedge clk);
            if (cnt_done !== 1 || done !== 0 || busy !== 0) begin
                $display("FAIL [%0s] N=%0d: done pulses=%0d (want 1), done=%b busy=%b afterwards",
                         name, n, cnt_done, done, busy);
                errors = errors + 1;
            end
            if (acc_out === expected && cnt_en === n && cnt_clr === 1)
                $display("PASS [%0s] N=%0d: acc_out=%0d", name, n, acc_out);
        end
    endtask

    // Watchdog: the whole legitimate run takes ~21 us, so 200 us means the
    // controller never asserted done. Fail loudly instead of hanging.
    initial begin
        #200000;
        $display("FAIL: timeout - controller never asserted done");
        $finish;
    end

    initial begin
        $dumpfile("layer_ctrl_tb.vcd");
        $dumpvars(0, layer_ctrl_tb);
        fill_random;
        #12 rst_n = 1;

        run_test(1,   "single term    ");
        run_test(5,   "conv1 size     ");
        run_test(40,  "conv2 size     ");
        run_test(32,  "fc2 size       ");
        run_test(992, "fc1 size       ");
        fill_random;
        run_test(5,   "reuse, new data");   // proves clear_acc wipes the previous sum
        fill_max;
        run_test(992, "worst-case fc1 ");   // proves the 48-bit accumulator cannot overflow

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
