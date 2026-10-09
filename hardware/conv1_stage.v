// conv1_stage.v
// Layer 1 of the network, wired together from the modules we already built and tested:
//
//     input (260 samples) -> conv1 (8 filters, window 5, 256 positions) -> ReLU
//                         -> max-pool of 2 -> buffer A (8 x 128 = 1,024 values)
//
// This file contains no new maths. It only connects the finished modules and adds
// the small glue they need: the one-clock-delay registers and the write address.
//
// ---------------------------------------------------------------------------
// WHAT IS CONNECTED TO WHAT   (every connection below is made by name)
// ---------------------------------------------------------------------------
//   layer_ctrl   : counts the 5 taps of one answer. Gives clear_acc, enable, done.
//   addr_gen     : turns "tap being used" into addresses. Takes layer_ctrl's enable
//                  (as step) and done (as next_output), both UNdelayed.
//   in_buf       : data_buffer (260 words), the beat's samples.   read address = addr_gen data_addr
//   weight_rom   : all 32,488 weights.                            read address = conv1 start (0) + addr_gen weight_addr
//   mac_unit     : sample * weight, summed.  Gets data and weight (they arrive one clock
//                  after their address) together with clear_acc / enable DELAYED by one clock.
//   bias_rom     : the 8 conv1 biases (instant read).             address = conv1 start (0) + filter number, DELAYED by one clock
//   bias_rescale : adds the bias, shifts right by 16, saturates to 16 bits, ReLU.
//                  (bias shift 12, output shift 16, ReLU on - the numbers in make_answer_key.py)
//   pool_pair    : the pooling holder. in_valid = done DELAYED, pos_odd = lowest bit of the
//                  position DELAYED.
//   buf_a        : data_buffer (1,024 words), the pooled results.
//                  write address = filter * 128 + position / 2  (filter DELAYED, position DELAYED)
//
// ---------------------------------------------------------------------------
// THE ONE-CLOCK-DELAY RULE (why there are delay registers)
// ---------------------------------------------------------------------------
//   weight_rom and data_buffer give their data ONE CLOCK AFTER the address.
//   Example, first tap of an answer:
//        clock 0 : addr_gen shows address 0         (layer_ctrl: clear_acc = 1, enable = 1)
//        clock 1 : sample and weight for address 0 are on the wires
//                  -> the MAC must see clear_acc / enable one clock later, at clock 1
//   So everything the MAC side (mac_unit, bias, pooling, write address) uses is a copy of the
//   layer_ctrl / addr_gen signal delayed by exactly one clock:
//        clear_d, enable_d, done_d, last_d, filter_d, pos_d
//   addr_gen and layer_ctrl themselves are NOT delayed: they create the addresses.
//   mac_unit registers its sum, so when done_d is high acc_out is the finished sum.
//   addr_gen moves filter/position on to the next output at the END of the done clock, so the
//   delayed copies filter_d / pos_d are the ones that still describe the finished output
//   while done_d is high.
//
// ---------------------------------------------------------------------------
// HOW TO USE IT
// ---------------------------------------------------------------------------
//   1. Load the beat: for each of the 260 samples (Q4.12) set in_we = 1, in_waddr = sample
//      number (0..259), in_wdata = the sample, one sample per clock.
//   2. Pulse start_layer for one clock (only while layer_busy = 0; not during loading).
//   3. Wait for layer_done (one-clock pulse). From that clock on buffer A is complete.
//   4. Read buffer A through a_raddr / a_rdata (a_rdata follows a_raddr ONE CLOCK later).
//      Address = filter * 128 + p  (the order conv2 expects).
//   One answer takes 5 clocks of work + 1 done clock + 1 idle clock = 7 clocks, so one beat
//   takes 2,048 x 7 = 14,336 clocks (+ a couple at the start/end) for this layer.
//
// Notes for whoever extends this (conv2, top level):
//   - out_val of pool_pair is combinational in the same clock as the second number of a pair:
//     the path  mac_unit -> bias_rescale -> max_pool -> buffer write  is one clock long. If Vivado
//     reports it as too slow, add a register after bias_rescale and delay the write address
//     (and pos_odd / in_valid) by one more clock.
//   - There is no reset on the memories; buffer A holds old data until this layer rewrites it.
//
module conv1_stage (
    input  wire               clk,
    input  wire               rst_n,        // active low, asynchronous (like the other modules)

    // load a beat into the input buffer
    input  wire               in_we,
    input  wire [8:0]         in_waddr,     // 0 .. 259
    input  wire signed [15:0] in_wdata,     // Q4.12

    // run the layer
    input  wire               start_layer,  // one-clock pulse
    output wire               layer_busy,   // 1 from the clock after start_layer until the clock before layer_done
    output wire               layer_done,   // one-clock pulse: buffer A is complete

    // read buffer A (1-clock registered read)
    input  wire [9:0]         a_raddr,
    output wire signed [15:0] a_rdata
);

    // ---------------------------------------------------------------------
    // the shape of conv1 (one place, so a change cannot be missed)
    // ---------------------------------------------------------------------
    localparam [5:0]  NUM_FILTERS   = 6'd8;
    localparam [8:0]  NUM_POSITIONS = 9'd256;
    localparam [3:0]  NUM_CHANNELS  = 4'd1;
    localparam [9:0]  KERNEL        = 10'd5;
    localparam [10:0] ROW_LEN       = 11'd0;     // not used when there is only one input row
    localparam [10:0] NUM_TERMS     = 11'd5;     // taps per answer = channels * kernel
    localparam [14:0] W_BASE        = 15'd0;     // conv1 weights start at weight_rom address 0
    localparam [5:0]  B_BASE        = 6'd0;      // conv1 biases start at bias_rom address 0
    localparam [4:0]  BIAS_SHIFT    = 5'd12;
    localparam [4:0]  OUT_SHIFT     = 5'd16;

    // ---------------------------------------------------------------------
    // control: layer_ctrl + addr_gen   (these see the UNdelayed signals)
    // ---------------------------------------------------------------------
    // (lint: term_idx and the top address bits are intentionally not used - conv1's addresses are small)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [10:0] term_idx;
    wire [10:0] data_addr;
    wire [15:0] weight_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        clear_acc, enable, busy, done;
    wire [5:0]  filter_idx;
    wire [8:0]  position_idx;
    wire        last_output;

    // 'active' is high from start_layer until the very last answer's done clock. While it is
    // high and layer_ctrl is idle, a new answer is started.
    reg  active;
    wire ctrl_idle = !busy && !done;
    wire start     = active && ctrl_idle;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active <= 1'b0;
        else if (start_layer)
            active <= 1'b1;
        else if (done && last_output)
            active <= 1'b0;
    end

    layer_ctrl #(.CNT_W(11)) ctrl (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .num_terms(NUM_TERMS),
        .clear_acc(clear_acc),
        .enable   (enable),
        .busy     (busy),
        .done     (done),
        .term_idx (term_idx)
    );

    addr_gen agen (
        .clk          (clk),
        .rst_n        (rst_n),
        .init         (start_layer),
        .step         (enable),
        .next_output  (done),
        .num_filters  (NUM_FILTERS),
        .num_positions(NUM_POSITIONS),
        .num_channels (NUM_CHANNELS),
        .kernel       (KERNEL),
        .row_len      (ROW_LEN),
        .data_addr    (data_addr),
        .weight_addr  (weight_addr),
        .filter_idx   (filter_idx),
        .position_idx (position_idx),
        .last_output  (last_output)
    );

    // ---------------------------------------------------------------------
    // memories that give their data one clock after the address
    // ---------------------------------------------------------------------
    wire signed [15:0] sample;     // from the input buffer
    wire signed [15:0] weight;     // from the weight ROM

    data_buffer #(.DEPTH(260)) in_buf (
        .clk  (clk),
        .we   (in_we),
        .waddr(in_waddr),
        .wdata(in_wdata),
        .raddr(data_addr[8:0]),    // largest address used: 255 + 4 = 259
        .rdata(sample)
    );

    wire [14:0] w_rom_addr = W_BASE + weight_addr[14:0];   // largest conv1 address: 39

    weight_rom wrom (
        .clk (clk),
        .addr(w_rom_addr),
        .data(weight)
    );

    // ---------------------------------------------------------------------
    // the one-clock delay registers
    // ---------------------------------------------------------------------
    reg        clear_d, enable_d, done_d, last_d;
    reg [5:0]  filter_d;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [8:0]  pos_d;          // bit 8 is not needed: positions go 0..255
    /* verilator lint_on UNUSEDSIGNAL */

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_d  <= 1'b0;
            enable_d <= 1'b0;
            done_d   <= 1'b0;
            last_d   <= 1'b0;
        end else begin
            clear_d  <= clear_acc;
            enable_d <= enable;
            done_d   <= done;
            last_d   <= last_output;
        end
    end

    always @(posedge clk) begin
        filter_d <= filter_idx;
        pos_d    <= position_idx;
    end

    // ---------------------------------------------------------------------
    // multiply-accumulate, bias, rescale + ReLU
    // ---------------------------------------------------------------------
    wire signed [47:0] acc;

    mac_unit mac (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear_acc(clear_d),
        .enable   (enable_d),
        .data_in  (sample),
        .weight_in(weight),
        .acc_out  (acc)
    );

    wire signed [15:0] bias;

    bias_rom brom (
        .addr(B_BASE + filter_d),
        .data(bias)
    );

    wire signed [15:0] act;        // finished post-ReLU output (valid while done_d = 1)
    /* verilator lint_off UNUSEDSIGNAL */
    wire               act_ovf;    // 1 = this output was clamped (diagnostic only, not used)
    /* verilator lint_on UNUSEDSIGNAL */

    bias_rescale rescale (
        .acc_in    (acc),
        .bias_in   (bias),
        .bias_shift(BIAS_SHIFT),
        .out_shift (OUT_SHIFT),
        .apply_relu(1'b1),
        .result    (act),
        .overflow  (act_ovf)
    );

    // ---------------------------------------------------------------------
    // pooling holder and buffer A
    // ---------------------------------------------------------------------
    wire               pool_valid;
    wire signed [15:0] pool_val;

    pool_pair pool (
        .clk      (clk),
        .in_valid (done_d),
        .pos_odd  (pos_d[0]),
        .in_val   (act),
        .out_valid(pool_valid),
        .out_val  (pool_val)
    );

    wire [9:0] a_waddr = {filter_d[2:0], pos_d[7:1]};      // filter * 128 + position / 2

    data_buffer #(.DEPTH(1024)) buf_a (
        .clk  (clk),
        .we   (pool_valid),
        .waddr(a_waddr),
        .wdata(pool_val),
        .raddr(a_raddr),
        .rdata(a_rdata)
    );

    // ---------------------------------------------------------------------
    // layer finished: one clock after the last pooled value was written
    // ---------------------------------------------------------------------
    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_r <= 1'b0;
        else        done_r <= done_d && last_d;
    end

    assign layer_done = done_r;
    assign layer_busy = active | done_d;

endmodule
