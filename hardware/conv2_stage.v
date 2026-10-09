// conv2_stage.v
// Layer 2 of the network, wired together from the modules we already built and tested:
//
//     buffer A (8 x 128, from conv1) -> conv2 (16 filters, 8 rows, window 5, 124 positions) -> ReLU
//                                    -> max-pool of 2 -> buffer B (16 x 62 = 992 values)
//
// Same pattern as conv1_stage.v (read that header first). No new maths: this file only connects
// the finished modules and adds the one-clock-delay registers and the write address.
//
// ---------------------------------------------------------------------------
// WHAT IS CONNECTED TO WHAT   (every connection below is made by name)
// ---------------------------------------------------------------------------
//   layer_ctrl   : counts the 40 taps of one answer (8 rows x 5). Gives clear_acc, enable, done.
//   addr_gen     : turns "tap being used" into addresses. Takes layer_ctrl's enable (as step) and
//                  done (as next_output), both UNdelayed.  data_addr = row * 128 + position + k.
//   in_buf       : data_buffer (1,024 words) = buffer A as conv1 leaves it (row * 128 + p).
//                  read address = addr_gen data_addr
//   weight_rom   : all 32,488 weights.  read address = conv2 start (40) + addr_gen weight_addr
//   mac_unit     : sample * weight, summed.  Gets sample and weight (one clock after their address)
//                  together with clear_acc / enable DELAYED by one clock.
//   bias_rom     : biases.  address = conv2 start (8) + filter number, DELAYED by one clock
//   bias_rescale : adds the bias, shifts right by 15, saturates to 16 bits, ReLU.
//                  (bias shift 10, output shift 15, ReLU on - the numbers in make_answer_key.py)
//   pool_pair    : the pooling holder.  in_valid = done DELAYED, pos_odd = lowest bit of position DELAYED
//   buf_b        : data_buffer (992 words), the pooled results, already in the order fc1 reads them.
//                  write address = filter * 62 + position / 2  (filter DELAYED, position DELAYED)
//                  filter * 62 is built as filter * 64 - filter * 2 (shifts and one subtraction, no multiplier)
//
// ---------------------------------------------------------------------------
// THE ONE-CLOCK-DELAY RULE (same as conv1)
// ---------------------------------------------------------------------------
//   weight_rom and data_buffer give their data ONE CLOCK AFTER the address, so everything the MAC
//   side uses (mac_unit control, bias address, pooling, write address) is a copy of the layer_ctrl /
//   addr_gen signal delayed by exactly one clock: clear_d, enable_d, done_d, last_d, filter_d, pos_d.
//   addr_gen and layer_ctrl themselves are NOT delayed: they create the addresses.
//   mac_unit registers its sum, so when done_d is high acc_out is the finished sum, and filter_d /
//   pos_d still describe that finished output (addr_gen moves on at the end of the done clock).
//
// ---------------------------------------------------------------------------
// HOW TO USE IT
// ---------------------------------------------------------------------------
//   1. Load the layer's input: for each of the 1,024 values (Q6.10, order row * 128 + p) set
//      in_we = 1, in_waddr = the number (0..1023), in_wdata = the value, one value per clock.
//      (In the final design this buffer is simply buffer A, written by conv1.)
//   2. Pulse start_layer for one clock (only while layer_busy = 0; not during loading).
//   3. Wait for layer_done (one-clock pulse). From that clock on buffer B is complete.
//   4. Read buffer B through b_raddr / b_rdata (b_rdata follows b_raddr ONE CLOCK later).
//      Address = filter * 62 + p, i.e. already the flatten order fc1 expects. Use addresses 0..991.
//   One answer takes 40 clocks of work + 1 done clock + 1 idle clock = 42 clocks, so one beat takes
//   1,984 x 42 + 2 = 83,330 clocks for this layer.
//
// Notes for whoever extends this (top level):
//   - out_val of pool_pair is combinational in the same clock as the second number of a pair: the path
//     mac_unit -> bias_rescale -> max_pool -> buffer write is one clock long (a Vivado timing item).
//   - There is no reset on the memories; buffer B holds old data until this layer rewrites it.
//
module conv2_stage (
    input  wire               clk,
    input  wire               rst_n,        // active low, asynchronous (like the other modules)

    // load the layer's input (buffer A contents)
    input  wire               in_we,
    input  wire [9:0]         in_waddr,     // 0 .. 1023
    input  wire signed [15:0] in_wdata,     // Q6.10

    // run the layer
    input  wire               start_layer,  // one-clock pulse
    output wire               layer_busy,   // 1 from the clock after start_layer until the clock before layer_done
    output wire               layer_done,   // one-clock pulse: buffer B is complete

    // read buffer B (1-clock registered read), addresses 0 .. 991
    input  wire [9:0]         b_raddr,
    output wire signed [15:0] b_rdata
);

    // ---------------------------------------------------------------------
    // the shape of conv2 (one place, so a change cannot be missed)
    // ---------------------------------------------------------------------
    localparam [5:0]  NUM_FILTERS   = 6'd16;
    localparam [8:0]  NUM_POSITIONS = 9'd124;
    localparam [3:0]  NUM_CHANNELS  = 4'd8;
    localparam [9:0]  KERNEL        = 10'd5;
    localparam [10:0] ROW_LEN       = 11'd128;   // one input row (one conv1 filter's pooled output)
    localparam [10:0] NUM_TERMS     = 11'd40;    // taps per answer = channels * kernel
    localparam [14:0] W_BASE        = 15'd40;    // conv2 weights start at weight_rom address 40
    localparam [5:0]  B_BASE        = 6'd8;      // conv2 biases start at bias_rom address 8
    localparam [4:0]  BIAS_SHIFT    = 5'd10;
    localparam [4:0]  OUT_SHIFT     = 5'd15;

    // ---------------------------------------------------------------------
    // control: layer_ctrl + addr_gen   (these see the UNdelayed signals)
    // ---------------------------------------------------------------------
    // (lint: term_idx and the top address bits are intentionally not used - conv2's addresses are small)
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
    wire signed [15:0] sample;     // from the input buffer (buffer A contents)
    wire signed [15:0] weight;     // from the weight ROM

    data_buffer #(.DEPTH(1024)) in_buf (
        .clk  (clk),
        .we   (in_we),
        .waddr(in_waddr),
        .wdata(in_wdata),
        .raddr(data_addr[9:0]),    // largest address used: 7 * 128 + 123 + 4 = 1023
        .rdata(sample)
    );

    wire [14:0] w_rom_addr = W_BASE + weight_addr[14:0];   // largest conv2 address: 40 + 639 = 679

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
    reg [5:0]  filter_d;       // bits 5:4 are not needed: filters go 0..15
    reg [8:0]  pos_d;          // bits 8:7 are not needed: positions go 0..123
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
    // pooling holder and buffer B
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

    // write address = filter * 62 + position / 2, with filter * 62 = filter * 64 - filter * 2
    wire [9:0] filter_x62 = {filter_d[3:0], 6'b000000} - {5'b00000, filter_d[3:0], 1'b0};
    wire [9:0] b_waddr    = filter_x62 + {4'b0000, pos_d[6:1]};          // largest: 15 * 62 + 61 = 991

    data_buffer #(.DEPTH(992)) buf_b (
        .clk  (clk),
        .we   (pool_valid),
        .waddr(b_waddr),
        .wdata(pool_val),
        .raddr(b_raddr),
        .rdata(b_rdata)
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
