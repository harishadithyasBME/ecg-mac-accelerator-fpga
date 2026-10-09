`timescale 1ns/1ps
// Runs the REAL layer_ctrl and the REAL addr_gen together (no mac_unit needed:
// we only care which boxes get addressed) through all four layers, and checks
// every single multiply-cycle three independent ways:
//   1. against a formula reference computed here with plain divide/multiply
//      (the DUT itself uses running counters, so this is a different method)
//   2. conv1 only: against conv1_golden.hex, written by Python from plain
//      nested loops (10,240 steps - the file must be in the folder you run from)
//   3. all layers: against step counts and address totals worked out in Python
// It also checks the handshake: layer_ctrl's term_idx must equal the tap
// that addr_gen is on, and filter_idx / position_idx must still show the
// finished output while done is high (that is when a result would be stored).
module addr_gen_tb;

    reg clk = 0, rst_n = 0;
    reg start = 0, init = 0;

    reg [5:0]  num_filters   = 0;
    reg [8:0]  num_positions = 0;
    reg [3:0]  num_channels  = 0;
    reg [9:0]  kernel        = 0;
    reg [10:0] row_len       = 0;
    reg [10:0] num_terms     = 0;

    wire        clear_acc, enable, busy, done;
    wire [10:0] term_idx;
    wire [10:0] data_addr;
    wire [15:0] weight_addr;
    wire [5:0]  filter_idx;
    wire [8:0]  position_idx;
    wire        last_output;

    layer_ctrl ctrl (.clk(clk), .rst_n(rst_n), .start(start), .num_terms(num_terms),
                     .clear_acc(clear_acc), .enable(enable), .busy(busy),
                     .done(done), .term_idx(term_idx));

    addr_gen dut (.clk(clk), .rst_n(rst_n), .init(init), .step(enable), .next_output(done),
                  .num_filters(num_filters), .num_positions(num_positions),
                  .num_channels(num_channels), .kernel(kernel), .row_len(row_len),
                  .data_addr(data_addr), .weight_addr(weight_addr),
                  .filter_idx(filter_idx), .position_idx(position_idx),
                  .last_output(last_output));

    always #5 clk = ~clk;

    // watchdog: the whole legitimate run is about 1.5 ms of simulated time
    initial begin
        #6000000;
        $display("FAIL: timeout");
        $finish;
    end

    // ---------------------------------------------------------------
    // reference model and checker
    // ---------------------------------------------------------------
    integer errors = 0;
    reg     checking   = 0;
    reg     use_golden = 0;
    integer step_i = 0, out_i = 0;
    integer sum_data = 0, sum_weight = 0;
    integer iF = 1, iP = 1, iT = 1, iK = 1, iROW = 0;

    reg [26:0] golden [0:10239];

    integer e_filt, e_rem, e_pos, e_term, e_ch, e_k, e_data, e_weight;
    reg     e_last;

    always @(negedge clk) begin
        if (checking && enable) begin
            e_filt   = step_i / (iP * iT);
            e_rem    = step_i % (iP * iT);
            e_pos    = e_rem / iT;
            e_term   = e_rem % iT;
            e_ch     = e_term / iK;
            e_k      = e_term % iK;
            e_data   = e_ch * iROW + e_pos + e_k;
            e_weight = e_filt * iT + e_term;
            e_last   = (e_filt == iF - 1) && (e_pos == iP - 1);

            if (data_addr !== e_data || weight_addr !== e_weight ||
                filter_idx !== e_filt || position_idx !== e_pos ||
                term_idx !== e_term || last_output !== e_last) begin
                errors = errors + 1;
                if (errors <= 8)
                    $display("  mismatch at step %0d: data=%0d (want %0d) weight=%0d (want %0d) filter=%0d (want %0d) pos=%0d (want %0d) term=%0d (want %0d) last=%b (want %b)",
                             step_i, data_addr, e_data, weight_addr, e_weight, filter_idx, e_filt,
                             position_idx, e_pos, term_idx, e_term, last_output, e_last);
            end
            if (use_golden && golden[step_i] !== {data_addr, weight_addr}) begin
                errors = errors + 1;
                if (errors <= 8)
                    $display("  Python golden file disagrees at step %0d: file=%h dut={%0d,%0d}",
                             step_i, golden[step_i], data_addr, weight_addr);
            end
            sum_data   = sum_data   + data_addr;
            sum_weight = sum_weight + weight_addr;
            step_i     = step_i + 1;
        end

        if (checking && done) begin
            e_filt = out_i / iP;
            e_pos  = out_i % iP;
            e_last = (out_i == iF * iP - 1);
            if (filter_idx !== e_filt || position_idx !== e_pos || last_output !== e_last) begin
                errors = errors + 1;
                if (errors <= 8)
                    $display("  done-cycle mismatch at output %0d: filter=%0d (want %0d) pos=%0d (want %0d) last=%b (want %b)",
                             out_i, filter_idx, e_filt, position_idx, e_pos, last_output, e_last);
            end
            out_i = out_i + 1;
        end
    end

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------
    task set_layer(input integer f, input integer p, input integer c, input integer k, input integer row);
        begin
            num_filters = f; num_positions = p; num_channels = c; kernel = k; row_len = row;
            num_terms   = c * k;
            iF = f; iP = p; iT = c * k; iK = k; iROW = row;
        end
    endtask

    // push n answers through layer_ctrl, one after another
    task run_outputs(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk); start = 1;
                @(negedge clk); start = 0;
                wait (done);
                @(negedge clk);        // middle of the done cycle: the checker samples here
                #1;                    // let the checker finish before we carry on
            end
        end
    endtask

    task run_layer(input [255:0] name,
                   input integer f, input integer p, input integer c, input integer k, input integer row,
                   input integer exp_steps, input integer exp_sum_data, input integer exp_sum_weight,
                   input golden_on);
        integer errors_before;
        begin
            errors_before = errors;
            set_layer(f, p, c, k, row);
            step_i = 0; out_i = 0; sum_data = 0; sum_weight = 0;
            use_golden = golden_on; checking = 1;
            run_outputs(f * p);
            checking = 0;
            @(negedge clk); @(negedge clk);

            if (step_i !== exp_steps) begin
                errors = errors + 1;
                $display("  wrong number of multiply cycles: %0d (want %0d)", step_i, exp_steps);
            end
            if (sum_data !== exp_sum_data || sum_weight !== exp_sum_weight) begin
                errors = errors + 1;
                $display("  address totals differ from Python: data=%0d (want %0d) weight=%0d (want %0d)",
                         sum_data, exp_sum_data, sum_weight, exp_sum_weight);
            end
            // after the last output everything must have wrapped back to the start
            if (data_addr !== 0 || weight_addr !== 0 || filter_idx !== 0 || position_idx !== 0) begin
                errors = errors + 1;
                $display("  did not wrap back to the start: data=%0d weight=%0d filter=%0d pos=%0d",
                         data_addr, weight_addr, filter_idx, position_idx);
            end

            if (errors == errors_before)
                $display("PASS [%0s]: %0d multiply cycles all correct, totals match Python, wrapped back to start", name, step_i);
            else
                $display("FAIL [%0s]", name);
        end
    endtask

    initial begin
        $dumpfile("addr_gen_tb.vcd");
        $dumpvars(0, addr_gen_tb);

        $readmemh("conv1_golden.hex", golden);
        if (golden[0] === 27'bx) begin
            $display("FAIL: conv1_golden.hex not found - save it in the folder you run vvp from");
            errors = errors + 1;
        end

        #12 rst_n = 1;

        // numbers: filters, positions, channels, kernel, row_len,  steps, sum_data, sum_weight, use golden file
        run_layer("conv1",                   8, 256, 1,   5, 260,  10240,  1326080,    199680, 1'b1);
        run_layer("conv1 again, no init",    8, 256, 1,   5, 260,  10240,  1326080,    199680, 1'b1);

        // start conv1, stop after 3 answers, call init, then the whole layer must run clean from the top
        set_layer(8, 256, 1, 5, 260);
        step_i = 0; out_i = 0; use_golden = 1; checking = 1;
        run_outputs(3);
        checking = 0;
        @(negedge clk); init = 1; @(negedge clk); init = 0; @(negedge clk);
        run_layer("conv1 after init mid-layer", 8, 256, 1, 5, 260, 10240, 1326080, 199680, 1'b1);

        run_layer("conv2",                  16, 124, 8,   5, 128,  79360, 40592640, 25355520, 1'b0);
        run_layer("fc1",                    32,   1, 1, 992,   0,  31744, 15729152, 503824896, 1'b0);
        run_layer("fc2",                     2,   1, 1,  32,   0,     64,      992,      2016, 1'b0);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end
endmodule
