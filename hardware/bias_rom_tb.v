`timescale 1ns/1ps
// Testbench for bias_rom.v  (needs biases.hex in the folder you run vvp from)
//
// All 58 biases are checked two independent ways:
//   1. against numbers Python wrote straight from the .pkl file, as plain signed
//      decimals (the py[] table below - NOT read from the hex file)
//   2. against this testbench's own copy of biases.hex
// Each layer is checked on its own using "layer start + filter number" as the
// address, exactly how the real design will look them up:
//     conv1 starts at 0 (8 biases), conv2 at 8 (16), fc1 at 24 (32), fc2 at 56 (2)
// The read is supposed to be instant (no clock): every check looks at the
// output 1 ns after the address changes.
module bias_rom_tb;

    localparam DEPTH = 58;

    reg  [5:0]         addr = 0;
    wire signed [15:0] data;

    bias_rom dut (.addr(addr), .data(data));

    reg signed [15:0] py       [0:DEPTH-1];   // from Python, decimal
    reg        [15:0] expected [0:DEPTH-1];   // from biases.hex

    integer errors = 0;

    task check(input integer a);
        begin
            addr = a;
            #1;
            if (data !== py[a] || data !== expected[a]) begin
                errors = errors + 1;
                if (errors <= 8)
                    $display("  mismatch at address %0d: rom=%0d python=%0d hexfile=%0d",
                             a, data, py[a], $signed(expected[a]));
            end
        end
    endtask

    task check_layer(input [63:0] name, input integer start, input integer count);
        integer f, eb;
        begin
            eb = errors;
            for (f = 0; f < count; f = f + 1) check(start + f);
            if (errors == eb) $display("PASS [%0s]: %0d biases at addresses %0d..%0d match Python", name, count, start, start + count - 1);
            else              $display("FAIL [%0s]", name);
        end
    endtask

    integer i, n, seed, r, eb, sum;

    initial begin
        $dumpfile("bias_rom_tb.vcd");
        $dumpvars(0, bias_rom_tb);

        // ---- Python's numbers (conv1, conv2, fc1, fc2 one after another) ----
        py[ 0] =  -3669;  py[ 1] =   4628;  py[ 2] = -12982;  py[ 3] =  14952;  py[ 4] =   7804;
        py[ 5] =   8132;  py[ 6] = -18461;  py[ 7] =  -4418;  py[ 8] =  -1289;  py[ 9] =   5441;
        py[10] =   1348;  py[11] =    885;  py[12] =   5280;  py[13] =  -2568;  py[14] =   1449;
        py[15] =   3489;  py[16] =  -3213;  py[17] =   2903;  py[18] =   7282;  py[19] =    572;
        py[20] =   2905;  py[21] =  -2058;  py[22] =  -1908;  py[23] =  -6859;  py[24] =     86;
        py[25] =    984;  py[26] =   1168;  py[27] =   1824;  py[28] =    547;  py[29] =    -67;
        py[30] =   -588;  py[31] =   1361;  py[32] =    813;  py[33] =   -228;  py[34] =    265;
        py[35] =   1658;  py[36] =   -643;  py[37] =    179;  py[38] =   1390;  py[39] =   -961;
        py[40] =    754;  py[41] =   -168;  py[42] =    565;  py[43] =  -1052;  py[44] =   -826;
        py[45] =    524;  py[46] =    457;  py[47] =    150;  py[48] =   -521;  py[49] =   1819;
        py[50] =    871;  py[51] =    738;  py[52] =   1676;  py[53] =    -42;  py[54] =   1881;
        py[55] =   1621;  py[56] =   5160;  py[57] =   4509;

        $readmemh("biases.hex", expected);
        if (expected[0] === 16'bx || expected[DEPTH-1] === 16'bx) begin
            $display("FAIL: biases.hex missing or too short - save it in the folder you run vvp from");
            errors = errors + 1;
        end

        #5;

        check_layer("conv1",  0,  8);
        check_layer("conv2",  8, 16);
        check_layer("fc1",   24, 32);
        check_layer("fc2",   56,  2);

        // random order: the answer must depend only on the address, never on what was read before
        eb = errors;
        seed = 777;
        for (n = 0; n < 5000; n = n + 1) begin
            r = {$random(seed)} % DEPTH;
            check(r);
        end
        if (errors == eb) $display("PASS [random]: 5000 random addresses, every answer correct");
        else              $display("FAIL [random]");

        // total of all 58 as a last whole-table check (Python: 35549)
        eb = errors;
        sum = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            addr = i;
            #1;
            sum = sum + data;
        end
        if (sum !== 35549) begin
            errors = errors + 1;
            $display("  sum of all biases differs from Python: rom=%0d want=35549", sum);
        end
        if (errors == eb) $display("PASS [total]: sum of all 58 biases = 35549, same as Python");
        else              $display("FAIL [total]");

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
