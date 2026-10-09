`timescale 1ns/1ps
// Every expected value here was computed independently in Python (plain
// integer arithmetic - bias << shift, add, >> shift, clamp, ReLU) before
// being written into this file, the same discipline as mac_unit_tb.v.
module bias_rescale_tb;

    reg  signed [47:0] acc_in;
    reg  signed [15:0] bias_in;
    reg  [4:0]         bias_shift, out_shift;
    reg                apply_relu;
    wire signed [15:0] result;
    wire               overflow;

    bias_rescale dut (
        .acc_in(acc_in), .bias_in(bias_in),
        .bias_shift(bias_shift), .out_shift(out_shift), .apply_relu(apply_relu),
        .result(result), .overflow(overflow)
    );

    integer errors = 0;

    task check(
        input [255:0] name,
        input signed [47:0] acc, input signed [15:0] bias,
        input [4:0] bs, input [4:0] os, input relu,
        input signed [15:0] exp_result, input exp_ovf
    );
        begin
            acc_in = acc; bias_in = bias; bias_shift = bs; out_shift = os; apply_relu = relu;
            #1;
            if (result !== exp_result || overflow !== exp_ovf) begin
                $display("FAIL [%0s]: result=%0d (want %0d)  overflow=%b (want %b)",
                         name, result, exp_result, overflow, exp_ovf);
                errors = errors + 1;
            end else begin
                $display("PASS [%0s]: result=%0d  overflow=%b", name, result, overflow);
            end
        end
    endtask

    // Shift pairs below are the REAL, final per-layer values derived from the
    // activation-range check (Colab, run against all 24,526 real test beats),
    // not the earlier illustrative Q14-for-every-layer placeholders:
    //   conv1: <<12 / >>16 -> Q6.10     conv2: <<10 / >>15 -> Q6.10
    //   fc1:   <<10 / >>16 -> Q7.9      fc2:   <<9  / >>14 -> Q6.10
    initial begin
        // conv1 filter 0, the real worked trace, now with the FINAL out_shift (16, not 12)
        check("conv1 filter0 real trace", 48'sd2826372, -16'sd3669, 12, 16, 1'b1, 16'sd0, 1'b0);

        // conv1 FINAL shifts, positive result survives ReLU
        check("conv1, positive",   48'sd80000000, -16'sd3669, 12, 16, 1'b1, 16'sd991, 1'b0);

        // conv2 FINAL shifts (<<10, >>15), positive
        check("conv2, positive",   48'sd600000000, 16'sd2000, 10, 15, 1'b1, 16'sd18373, 1'b0);

        // conv2 FINAL shifts, negative zeroed by ReLU
        check("conv2, ReLU zeroes", -48'sd600000000, 16'sd2000, 10, 15, 1'b1, 16'sd0, 1'b0);

        // fc1 FINAL shifts (<<10, >>16), positive
        check("fc1, positive",     48'sd600000000, 16'sd2000, 10, 16, 1'b1, 16'sd9186, 1'b0);

        // fc2 FINAL shifts (<<9, >>14), ReLU off: small negative class score passes through
        check("fc2, ReLU off, in range", -48'sd6000000, 16'sd2000, 9, 14, 1'b0, -16'sd304, 1'b0);

        // fc2 FINAL shifts: this same magnitude that was fine under the OLD shifts
        // (14/15) now genuinely saturates under the coarser, FINAL shifts (9/14) -
        // a real example of why shift amounts, not just the stored value, matter
        check("fc2, ReLU off, now saturates", -48'sd600000000, 16'sd2000, 9, 14, 1'b0, -16'sd32768, 1'b1);

        // deliberately overflow positive and negative, confirm clamp + flag
        check("saturate positive (conv1 shifts)", 48'sd9999999999, 16'sd0, 12, 16, 1'b0, 16'sd32767, 1'b1);
        check("saturate negative (fc1 shifts)", -48'sd9999999999, 16'sd0, 10, 16, 1'b0, -16'sd32768, 1'b1);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
