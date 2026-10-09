// fc1_stage.v
// Layer 3 of the network (first fully connected layer), wired together from the modules we
// already built and tested:
//
//     buffer B (992 values, the flattened conv2 result) -> fc1 (32 neurons, 992 inputs each)
//                                                       -> ReLU -> buffer C (32 values)
//
// Same pattern as conv1_stage.v / conv2_stage.v, but simpler: there is no pooling, so the
// pooling holder is not used. Every finished output (one per neuron) is written straight into
// buffer C at the neuron's own number. No new maths: this file only connects the finished modules
// and adds the one-clock-delay registers.
//
// ---------------------------------------------------------------------------
// WHAT IS CONNECTED TO WHAT   (every connection below is made by name)
// ---------------------------------------------------------------------------
//   layer_ctrl   : counts the 992 taps of one neuron. Gives clear_acc, enable, done.
//   addr_gen     : turns "tap being used" into addresses. Takes layer_ctrl's enable (as step) and
//                  done (as next_output), both UNdelayed. For a fully connected layer it is used with
//                  1 row and 1 position: data_addr = tap number (0..991), weight_addr = neuron * 992 + tap.
//   in_buf       : data_buffer (992 words) = buffer B as conv2 leaves it.  read address = addr_gen data_addr
//   weight_rom   : all 32,488 weights.  read address = fc1 start (680) + addr_gen weight_addr
//   mac_unit     : sample * weight, summed.  Gets sample and weight (one clock after their address)
//                  together with clear_acc / enable DELAYED by one clock.
//   bias_rom     : biases.  address = fc1 start (24) + neuron number, DELAYED by one clock
//   bias_rescale : adds the bias, shifts right by 16, saturates to 16 bits, ReLU.
//                  (bias shift 10, output shift 16, ReLU on - the numbers in make_answer_key.py)
//   buf_c        : data_buffer (32 words), one value per neuron (Q7.9).
//                  write enable = done DELAYED, write address = neuron number DELAYED
//
// ---------------------------------------------------------------------------
// THE ONE-CLOCK-DELAY RULE (same as conv1 / conv2)
// ---------------------------------------------------------------------------
//   weight_rom and data_buffer give their data ONE CLOCK AFTER the address, so everything the MAC
//   side uses (mac_unit control, bias address, write enable, write address) is a copy of the
//   layer_ctrl / addr_gen signal delayed by exactly one clock: clear_d, enable_d, done_d, last_d,
//   filter_d. addr_gen and layer_ctrl themselves are NOT delayed: they create the addresses.
//
// ---------------------------------------------------------------------------
// HOW TO USE IT
// ---------------------------------------------------------------------------
//   1. Load the layer's input: for each of the 992 values (Q6.10, flatten order) set in_we = 1,
//      in_waddr = the number (0..991), in_wdata = the value, one value per clock.
//      (In the final design this buffer is simply buffer B, written by conv2.)
//   2. Pulse start_layer for one clock (only while layer_busy = 0; not during loading).
//   3. Wait for layer_done (one-clock pulse). From that clock on buffer C is complete.
//   4. Read buffer C through c_raddr / c_rdata (c_rdata follows c_raddr ONE CLOCK later).
//   One neuron takes 992 clocks of work + 1 done clock + 1 idle clock = 994 clocks, so one beat
//   takes 32 x 994 + 2 = 31,810 clocks for this layer.
//
// Notes for whoever extends this (top level):
//   - Neuron values are Q7.9 (the output shift of 16 puts the binary point there).
//   - There is no reset on the memories; buffer C holds old data until this layer rewrites it.
//
module fc1_stage (
    input  wire               clk,
    input  wire               rst_n,        // active low, asynchronous (like the other modules)

    // load the layer's input (buffer B contents)
    input  wire               in_we,
    input  wire [9:0]         in_waddr,     // 0 .. 991
    input  wire signed [15:0] in_wdata,     // Q6.10

    // run the layer
    input  wire               start_layer,  // one-clock pulse
    output wire               layer_busy,   // 1 from the clock after start_layer until the clock before layer_done
    output wire               layer_done,   // one-clock pulse: buffer C is complete

    // read buffer C (1-clock registered read), addresses 0 .. 31
    input  wire [4:0]         c_raddr,
    output wire signed [15:0] c_rdata
);

    // ---------------------------------------------------------------------
    // the shape of fc1 (one place, so a change cannot be missed)
    // ---------------------------------------------------------------------
    localparam [5:0]  NUM_FILTERS   = 6'd32;     // neurons
    localparam [8:0]  NUM_POSITIONS = 9'd1;      // a neuron has just one answer
    localparam [3:0]  NUM_CHANNELS  = 4'd1;
    localparam [9:0]  KERNEL        = 10'd992;   // inputs per neuron
    localparam [10:0] ROW_LEN       = 11'd0;     // not used when there is only one input row
    localparam [10:0] NUM_TERMS     = 11'd992;   // taps per answer
    localparam [14:0] W_BASE        = 15'd680;   // fc1 weights start at weight_rom address 680
    localparam [5:0]  B_BASE        = 6'd24;     // fc1 biases start at bias_rom address 24
    localparam [4:0]  BIAS_SHIFT    = 5'd10;
    localparam [4:0]  OUT_SHIFT     = 5'd16;

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
    wire signed [15:0] sample;     // from the input buffer (buffer B contents)
    wire signed [15:0] weight;     // from the weight ROM

    data_buffer #(.DEPTH(992)) in_buf (
        .clk  (clk),
        .we   (in_we),
        .waddr(in_waddr),
        .wdata(in_wdata),
        .raddr(data_addr[9:0]),    // largest address used: 991
        .rdata(sample)
    );

    wire [14:0] w_rom_addr = W_BASE + weight_addr[14:0];   // largest fc1 address: 680 + 31,743 = 32,423

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
    reg [5:0]  filter_d;       // bit 5 is not needed: neurons go 0..31
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

    wire signed [15:0] act;        // finished post-ReLU neuron value (valid while done_d = 1)
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
    // buffer C: one value per neuron, written straight from bias_rescale (no pooling)
    // ---------------------------------------------------------------------
    data_buffer #(.DEPTH(32)) buf_c (
        .clk  (clk),
        .we   (done_d),
        .waddr(filter_d[4:0]),
        .wdata(act),
        .raddr(c_raddr),
        .rdata(c_rdata)
    );

    // ---------------------------------------------------------------------
    // layer finished: one clock after the last neuron value was written
    // ---------------------------------------------------------------------
    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_r <= 1'b0;
        else        done_r <= done_d && last_d;
    end

    assign layer_done = done_r;
    assign layer_busy = active | done_d;

endmodule
