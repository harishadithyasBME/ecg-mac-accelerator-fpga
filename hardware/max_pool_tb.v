`timescale 1ns/1ps
module max_pool_tb;

    reg  signed [15:0] a, b;
    wire signed [15:0] max_val;

    max_pool dut (.a(a), .b(b), .max_val(max_val));

    integer errors = 0;

    task check(input [255:0] name, input signed [15:0] va, input signed [15:0] vb, input signed [15:0] expected);
        begin
            a = va; b = vb;
            #1;
            if (max_val !== expected) begin
                $display("FAIL [%0s]: a=%0d b=%0d -> max_val=%0d (want %0d)", name, va, vb, max_val, expected);
                errors = errors + 1;
            end else begin
                $display("PASS [%0s]: a=%0d b=%0d -> max_val=%0d", name, va, vb, max_val);
            end
        end
    endtask

    initial begin
        // typical post-ReLU case: both non-negative, a is larger
        check("a larger, both positive",  9,    5,    9);
        // typical post-ReLU case: both non-negative, b is larger
        check("b larger, both positive",  2,    9,    9);
        // tie: module is specified to return b on a tie
        check("tie, equal values",        7,    7,    7);

        // the module makes no non-negative assumption - prove it handles
        // negative values correctly too, even though real usage is post-ReLU
        check("both negative, a less negative (larger)", -5,  -10,  -5);
        check("both negative, b less negative (larger)", -10, -5,   -5);
        check("mixed sign, positive wins",  3,   -100,  3);
        check("mixed sign, negative wins", -100,  3,    3);

        // the full 16-bit signed range, to confirm no sign-handling bug at the edges
        check("max positive vs min negative", 16'sd32767, -16'sd32768, 16'sd32767);
        check("min negative vs max positive", -16'sd32768, 16'sd32767, 16'sd32767);
        check("both at min negative (tie)",   -16'sd32768, -16'sd32768, -16'sd32768);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
