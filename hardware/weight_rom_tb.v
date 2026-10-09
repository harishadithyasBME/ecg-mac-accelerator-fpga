`timescale 1ns/1ps
// Testbench for weight_rom.v  (needs weights.hex in the folder you run vvp from)
//
// Every weight is checked two independent ways:
//   1. against this testbench's own copy of weights.hex (every one of the 32,488
//      addresses, then 40,000 random addresses back to back, then the extremes)
//   2. against numbers Python worked out straight from the .pkl file, NOT from
//      the hex file: 28 spot values written in plain signed decimal, plus a
//      checksum for each layer's block of weights (conv1, conv2, fc1, fc2),
//      plus the sum and XOR of all 32,488 weights. The per-layer checksum
//      multiplies each weight by its position, so a swapped, shifted, dropped
//      or changed weight cannot hide.
// It also checks the one-cycle delay itself: after the address changes, the
// data must NOT change until the next clock edge, and must be correct after it.
module weight_rom_tb;

    localparam DEPTH = 32488;

    reg                clk  = 0;
    reg  [14:0]        addr = 0;
    wire signed [15:0] data;

    weight_rom dut (.clk(clk), .addr(addr), .data(data));

    always #5 clk = ~clk;

    // the whole legitimate run is about 0.75 ms of simulated time
    initial begin
        #6000000;
        $display("FAIL: timeout");
        $finish;
    end

    reg [15:0] expected [0:DEPTH-1];

    integer    errors      = 0;
    integer    prev_addr   = 0;
    reg        have_prev   = 0;
    reg [15:0] seen;
    reg        checksum_on = 0;

    // running totals, built from what the ROM actually outputs
    integer    total_sum = 0;
    reg [15:0] xor_all   = 16'h0000;
    reg [31:0] seg_sum   [0:3];
    integer    seg_start [0:3];

    function integer seg_of(input integer a);
        seg_of = (a < 40) ? 0 : (a < 680) ? 1 : (a < 32424) ? 2 : 3;
    endfunction

    // One clock of the test. At the falling edge the ROM is showing the answer
    // for the PREVIOUS address, so check that, then ask for address a.
    task step(input integer a);
        integer s;
        begin
            @(negedge clk);
            if (have_prev) begin
                if (data !== expected[prev_addr]) begin
                    errors = errors + 1;
                    if (errors <= 8)
                        $display("  mismatch at address %0d: rom=%h want=%h", prev_addr, data, expected[prev_addr]);
                end
                if (checksum_on) begin
                    s = seg_of(prev_addr);
                    seg_sum[s] = seg_sum[s] + (prev_addr - seg_start[s] + 1) * {16'b0, data};
                    total_sum  = total_sum + data;
                    xor_all    = xor_all ^ data;
                end
            end
            seen = data;
            addr = a;
            #1;
            if (data !== seen) begin
                errors = errors + 1;
                if (errors <= 8)
                    $display("  data changed before the clock edge (read is not registered) at address %0d", a);
            end
            prev_addr = a;
            have_prev = 1;
        end
    endtask

    // one address, then look at what comes out one clock later
    task spot(input integer a, input integer want_dec);
        reg signed [15:0] w;
        begin
            have_prev = 0;
            step(a);
            @(negedge clk);
            w = want_dec;
            if (data !== w) begin
                errors = errors + 1;
                $display("  Python spot value differs at address %0d: rom=%0d want=%0d", a, data, want_dec);
            end
        end
    endtask

    task check_seg(input integer s, input [31:0] want);
        begin
            if (seg_sum[s] !== want) begin
                errors = errors + 1;
                $display("  layer %0d position-checksum differs from Python: rom=%h want=%h", s, seg_sum[s], want);
            end
        end
    endtask

    integer i, n, seed, r, eb;

    initial begin
        $dumpfile("weight_rom_tb.vcd");
        $dumpvars(0, weight_rom_tb);

        seg_start[0] = 0;  seg_start[1] = 40;  seg_start[2] = 680;  seg_start[3] = 32424;
        for (i = 0; i < 4; i = i + 1) seg_sum[i] = 32'd0;

        $readmemh("weights.hex", expected);
        if (expected[0] === 16'bx || expected[DEPTH-1] === 16'bx) begin
            $display("FAIL: weights.hex missing or too short - save it in the folder you run vvp from");
            errors = errors + 1;
        end

        #12;

        // ---- 1. every address, in order, plus the checksums ----
        eb = errors;
        have_prev = 0; checksum_on = 1;
        for (i = 0; i < DEPTH; i = i + 1) step(i);
        step(DEPTH - 1);                       // one more clock to catch the last answer
        checksum_on = 0; have_prev = 0;
        if (errors == eb) $display("PASS [sweep]: all %0d addresses read back correctly, one clock after the address", DEPTH);
        else              $display("FAIL [sweep]");

        // ---- 2. numbers worked out in Python from the .pkl ----
        eb = errors;
        check_seg(0, 32'h01b57fbb);            // conv1 : 40 weights
        check_seg(1, 32'h78b0605c);            // conv2 : 640 weights
        check_seg(2, 32'h09a54d0b);            // fc1   : 31,744 weights
        check_seg(3, 32'h046ce93b);            // fc2   : 64 weights
        if (total_sum !== 1227494) begin
            errors = errors + 1;
            $display("  sum of all weights differs from Python: rom=%0d want=1227494", total_sum);
        end
        if (xor_all !== 16'h9350) begin
            errors = errors + 1;
            $display("  XOR of all weights differs from Python: rom=%h want=9350", xor_all);
        end
        if (errors == eb) $display("PASS [python checksums]: 4 layer checksums, total sum and XOR all match Python");
        else              $display("FAIL [python checksums]");

        eb = errors;
        spot(    0,  12497);  spot(    1, -15674);  spot(    2,  -9950);  spot(    3,  -9082);  spot(    4,  -8986);
        spot(   39, -14490);  spot(   40,   3393);  spot(   41,   2369);
        spot(  679,  -4513);  spot(  680,   -739);  spot(  681,   1156);
        spot(32423,   2594);  spot(32424,   5019);  spot(32425,   3149);  spot(32486,   8752);  spot(32487,  -6413);
        spot( 1582,  -1444);  spot( 2373,    232);  spot( 3084,    320);  spot( 4943,   1961);
        spot(10611,   -658);  spot(11982,  -1375);  spot(12937,  -1445);  spot(17559,    331);
        spot(19096,   -849);  spot(21329,  -1302);  spot(26911,   -691);  spot(31059,   1686);
        if (errors == eb) $display("PASS [python spot values]: 28 weights match Python's signed decimal values, including all layer boundaries");
        else              $display("FAIL [python spot values]");

        // ---- 3. random addresses, a new one every clock ----
        eb = errors;
        seed = 12345;
        have_prev = 0;
        for (n = 0; n < 40000; n = n + 1) begin
            r = {$random(seed)} % DEPTH;       // braces make it unsigned, so r is 0 .. DEPTH-1
            step(r);
        end
        step(prev_addr);
        have_prev = 0;
        if (errors == eb) $display("PASS [random]: 40000 random addresses, one new address every clock, all correct");
        else              $display("FAIL [random]");

        // ---- 4. first and last address back and forth, then holding one address ----
        eb = errors;
        have_prev = 0;
        for (n = 0; n < 200; n = n + 1) step((n % 2) ? DEPTH - 1 : 0);
        step(prev_addr);
        have_prev = 0;
        for (n = 0; n < 8; n = n + 1) step(12345);
        for (n = 0; n < 8; n = n + 1) step(32487);
        step(prev_addr);
        have_prev = 0;
        if (errors == eb) $display("PASS [extremes and hold]: first/last address alternating, and data stays put while the address is held");
        else              $display("FAIL [extremes and hold]");

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
