`timescale 1ns/1ps

module mac_unit_tb;
    reg clk = 0;
    reg rst_n = 0, clear_acc = 0, enable = 0;
    reg signed [15:0] data_in = 0, weight_in = 0;
    wire signed [47:0] acc_out;

    mac_unit dut (
        .clk(clk), .rst_n(rst_n), .clear_acc(clear_acc), .enable(enable),
        .data_in(data_in), .weight_in(weight_in), .acc_out(acc_out)
    );

    always #5 clk = ~clk;

    initial begin
        // --- waveform dump setup for GTKWave ---
        $dumpfile("mac_unit_tb.vcd");
        $dumpvars(0, mac_unit_tb);

        rst_n = 0;
        #12 rst_n = 1;

        @(negedge clk);
        data_in = 16384; weight_in = 16384; clear_acc = 1; enable = 1;
        @(negedge clk);
        clear_acc = 0;
        data_in = 8192; weight_in = -16384;
        @(negedge clk);
        data_in = -16384; weight_in = 16384;
        @(negedge clk);
        enable = 0;
        @(negedge clk);

        if (acc_out === -134217728)
            $display("PASS: acc_out = %d (expected -134217728, i.e. -0.125)", acc_out);
        else
            $display("FAIL: acc_out = %d (expected -134217728)", acc_out);

        $finish;
    end
endmodule