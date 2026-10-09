// fc2_stage.v
// Layer 4 of the network (second fully connected layer) and the final decision, wired together
// from the modules we already built and tested:
//
//     buffer C (32 values from fc1) -> fc2 (2 neurons, 32 inputs each) -> score0, score1
//                                   -> decision -> abnormal
//
// Same pattern as fc1_stage.v. Differences: only 2 neurons with 32 inputs each, NO ReLU (the scores
// are raw and may be negative), and the two results are not stored in a buffer but in two
// 16-bit registers, score0 (Normal) and score1 (Abnormal), which feed the decision module.
// No new maths: this file only connects the finished modules and adds the one-clock-delay
// registers and the two score registers.
//
// ---------------------------------------------------------------------------
// WHAT IS CONNECTED TO WHAT   (every connection below is made by name)
// ---------------------------------------------------------------------------
//   layer_ctrl   : counts the 32 taps of one neuron. Gives clear_acc, enable, done.
//   addr_gen     : turns "tap being used" into addresses (1 row, 1 position per neuron):
//                  data_addr = tap number (0..31), weight_addr = neuron * 32 + tap (0..63)
//                  Takes layer_ctrl's enable (as step) and done (as next_output), both UNdelayed.
//   in_buf       : data_buffer (32 words) = buffer C as fc1 leaves it.  read address = addr_gen data_addr
//   weight_rom   : all 32,488 weights.  read address = fc2 start (32,424) + addr_gen weight_addr
//   mac_unit     : sample * weight, summed.  Gets sample and weight (one clock after their address)
//                  together with clear_acc / enable DELAYED by one clock.
//   bias_rom     : biases.  address = fc2 start (56) + neuron number, DELAYED by one clock
//   bias_rescale : adds the bias, shifts right by 14, saturates to 16 bits, NO ReLU.
//                  (bias shift 9, output shift 14, ReLU off - the numbers in make_answer_key.py)
//   score regs   : on the done_d clock the finished value goes into score0 (neuron 0) or score1 (neuron 1),
//                  chosen by the neuron number DELAYED by one clock
//   decision     : abnormal = score1 higher than score0 (a tie means Normal)
//
// ---------------------------------------------------------------------------
// THE ONE-CLOCK-DELAY RULE (same as the other layers)
// ---------------------------------------------------------------------------
//   weight_rom and data_buffer give their data ONE CLOCK AFTER the address, so everything the MAC
//   side uses (mac_unit control, bias address, score register enable and select) is a copy of the
//   layer_ctrl / addr_gen signal delayed by exactly one clock: clear_d, enable_d, done_d, last_d,
//   filter_d. addr_gen and layer_ctrl themselves are NOT delayed: they create the addresses.
//
// ---------------------------------------------------------------------------
// HOW TO USE IT
// ---------------------------------------------------------------------------
//   1. Load the layer's input: for each of the 32 values (Q7.9) set in_we = 1, in_waddr = the
//      number (0..31), in_wdata = the value, one value per clock.
//      (In the final design this buffer is simply buffer C, written by fc1.)
//   2. Pulse start_layer for one clock (only while layer_busy = 0; not during loading).
//   3. Wait for layer_done (one-clock pulse). From that clock on score0, score1 and abnormal are
//      final, and they stay the same until the next run finishes its first neuron.
//   One neuron takes 32 clocks of work + 1 done clock + 1 idle clock = 34 clocks, so one beat
//   takes 2 x 34 + 2 = 70 clocks for this layer.
//
// Notes for whoever extends this (top level):
//   - Scores are Q6.10 signed numbers. The score registers have no reset: they hold nothing
//     meaningful until the first run has finished, so use abnormal only after layer_done.
//
module fc2_stage (
    input  wire               clk,
    input  wire               rst_n,        // active low, asynchronous (like the other modules)

    // load the layer's input (buffer C contents)
    input  wire               in_we,
    input  wire [4:0]         in_waddr,     // 0 .. 31
    input  wire signed [15:0] in_wdata,     // Q7.9

    // run the layer
    input  wire               start_layer,  // one-clock pulse
    output wire               layer_busy,   // 1 from the clock after start_layer until the clock before layer_done
    output wire               layer_done,   // one-clock pulse: score0, score1 and abnormal are final

    // results
    output wire signed [15:0] score0,       // class 0, Normal   (Q6.10)
    output wire signed [15:0] score1,       // class 1, Abnormal (Q6.10)
    output wire               abnormal      // 1 = Abnormal (score1 higher), 0 = Normal (also on a tie)
);

    // ---------------------------------------------------------------------
    // the shape of fc2 (one place, so a change cannot be missed)
    // ---------------------------------------------------------------------
    localparam [5:0]  NUM_FILTERS   = 6'd2;      // neurons = the two classes
    localparam [8:0]  NUM_POSITIONS = 9'd1;      // a neuron has just one answer
    localparam [3:0]  NUM_CHANNELS  = 4'd1;
    localparam [9:0]  KERNEL        = 10'd32;    // inputs per neuron
    localparam [10:0] ROW_LEN       = 11'd0;     // not used when there is only one input row
    localparam [10:0] NUM_TERMS     = 11'd32;    // taps per answer
    localparam [14:0] W_BASE        = 15'd32424; // fc2 weights start at weight_rom address 32,424
    localparam [5:0]  B_BASE        = 6'd56;     // fc2 biases start at bias_rom address 56
    localparam [4:0]  BIAS_SHIFT    = 5'd9;
    localparam [4:0]  OUT_SHIFT     = 5'd14;

    // ---------------------------------------------------------------------
    // control: layer_ctrl + addr_gen   (these see the UNdelayed signals)
    // ---------------------------------------------------------------------
    // (lint: term_idx, the position and the top address bits are intentionally not used)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [10:0] term_idx;
    wire [10:0] data_addr;
    wire [15:0] weight_addr;
    wire [8:0]  position_idx;      // always 0 for a fully connected layer
    /* verilator lint_on UNUSEDSIGNAL */
    wire        clear_acc, enable, busy, done;
    wire [5:0]  filter_idx;
    wire        last_output;

    // 'active' is high from start_layer until the very last neuron's done clock. While it is
    // high and layer_ctrl is idle, a new neuron is started.
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
    wire signed [15:0] sample;     // from the input buffer (buffer C contents)
    wire signed [15:0] weight;     // from the weight ROM

    data_buffer #(.DEPTH(32)) in_buf (
        .clk  (clk),
        .we   (in_we),
        .waddr(in_waddr),
        .wdata(in_wdata),
        .raddr(data_addr[4:0]),    // largest address used: 31
        .rdata(sample)
    );

    wire [14:0] w_rom_addr = W_BASE + weight_addr[14:0];   // largest fc2 address: 32,424 + 63 = 32,487

    weight_rom wrom (
        .clk (clk),
        .addr(w_rom_addr),
        .data(weight)
    );

    // ---------------------------------------------------------------------
    // the one-clock delay registers
    // ---------------------------------------------------------------------
    reg        clear_d, enable_d, done_d, last_d;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [5:0]  filter_d;       // only bit 0 is needed: the neurons are 0 and 1
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
    end

    // ---------------------------------------------------------------------
    // multiply-accumulate, bias, rescale (no ReLU)
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

    wire signed [15:0] act;        // finished raw score (valid while done_d = 1)
    /* verilator lint_off UNUSEDSIGNAL */
    wire               act_ovf;    // 1 = this output was clamped (diagnostic only, not used)
    /* verilator lint_on UNUSEDSIGNAL */

    bias_rescale rescale (
        .acc_in    (acc),
        .bias_in   (bias),
        .bias_shift(BIAS_SHIFT),
        .out_shift (OUT_SHIFT),
        .apply_relu(1'b0),
        .result    (act),
        .overflow  (act_ovf)
    );

    // ---------------------------------------------------------------------
    // the two score registers
    // ---------------------------------------------------------------------
    reg signed [15:0] score0_r, score1_r;

    always @(posedge clk) begin
        if (done_d && !filter_d[0]) score0_r <= act;
        if (done_d &&  filter_d[0]) score1_r <= act;
    end

    assign score0 = score0_r;
    assign score1 = score1_r;

    decision dec (
        .score0  (score0_r),
        .score1  (score1_r),
        .abnormal(abnormal)
    );

    // ---------------------------------------------------------------------
    // layer finished: one clock after the last score was stored
    // ---------------------------------------------------------------------
    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_r <= 1'b0;
        else        done_r <= done_d && last_d;
    end

    assign layer_done = done_r;
    assign layer_busy = active | done_d;

endmodule
