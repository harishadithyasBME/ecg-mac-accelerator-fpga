// ecg_top.v
// The whole ECG classifier: one heartbeat in (260 samples), one decision out (Normal / Abnormal).
//
//   samples -> conv1 -> ReLU -> pool -> conv2 -> ReLU -> pool -> fc1 -> ReLU -> fc2 -> decision
//
// ONE shared multiply-accumulate unit (mac_unit) does all the arithmetic of all four layers, one after
// the other. The layer sequencer (layer_seq) says which layer is running; a small table in this file
// turns the layer number into that layer's settings (how many filters, where its weights start, ...).
// Everything else is the wiring that was already built and tested layer by layer in conv1_stage.v,
// conv2_stage.v, fc1_stage.v and fc2_stage.v - this file is those four files merged into one,
// with the settings that differ between the layers chosen by the layer number.
//
// ---------------------------------------------------------------------------
// HOW TO USE IT
// ---------------------------------------------------------------------------
//   1. Load the beat: for each of the 260 samples (Q4.12, signed) set in_we = 1, in_waddr = the sample
//      number (0..259), in_wdata = the value, one value per clock. Do NOT write during a beat.
//   2. Pulse start_beat for one clock (while beat_busy = 0).
//   3. Wait for beat_done (one-clock pulse). From that clock on score0 (Normal), score1 (Abnormal) and
//      abnormal are final. They stay unchanged until the next beat reaches its last layer.
//   One beat takes exactly 129,552 clocks from the start_beat clock to the beat_done clock
//   (conv1 14,338 + conv2 83,330 + fc1 31,810 + fc2 70 clocks of work, plus 1 clock to start the
//   first layer and 1 clock between layers = 4 clocks), i.e. 2.59 ms at 50 MHz.
//
// ---------------------------------------------------------------------------
// WHAT IS CONNECTED TO WHAT   (every connection below is made by name)
// ---------------------------------------------------------------------------
//   layer_seq    : layer number (0 conv1, 1 conv2, 2 fc1, 3 fc2), start_layer pulse, beat_busy, beat_done
//   layer table  : (below) the settings of the running layer: number of filters / positions / channels,
//                  window length, row length, taps per answer, first weight address, first bias address,
//                  the two shift amounts and whether ReLU is applied. Numbers from make_answer_key.py (LAYERS).
//   layer_ctrl   : counts the taps of one answer. Gives clear_acc, enable, done.
//   addr_gen     : turns "tap being used" into addresses. Takes layer_ctrl's enable (as step) and done
//                  (as next_output), both UNdelayed. init = start_layer.
//   in_buf       : data_buffer (260 words) = the beat's samples.            (read by conv1)
//   buf_a        : data_buffer (1,024 words) = conv1 results, pooled.       (written by conv1, read by conv2)
//   buf_b        : data_buffer (992 words) = conv2 results, pooled, already in flatten order.
//                                                                            (written by conv2, read by fc1)
//   buf_c        : data_buffer (32 words) = fc1 results.                    (written by fc1, read by fc2)
//                  All four buffers get the same read address (addr_gen data_addr); the one that belongs
//                  to the running layer is chosen by the layer number ('sample').
//   weight_rom   : all 32,488 weights.  read address = the layer's first weight address + addr_gen weight_addr
//   mac_unit     : sample * weight, summed.  Gets sample and weight (one clock after their address)
//                  together with clear_acc / enable DELAYED by one clock.
//   bias_rom     : biases.  address = the layer's first bias address + filter number, DELAYED by one clock
//   bias_rescale : adds the bias, shifts, saturates to 16 bits, ReLU (not for fc2) - shifts chosen by the layer
//   pool_pair    : the pooling holder, used by conv1 and conv2 only.
//   buf_a / buf_b / buf_c write: see "WHERE THE RESULTS GO" below
//   score regs   : fc2's two results (score0 = Normal, score1 = Abnormal)
//   decision     : abnormal = score1 higher than score0 (a tie means Normal)
//
// ---------------------------------------------------------------------------
// THE ONE-CLOCK-DELAY RULE (same as in the layer files)
// ---------------------------------------------------------------------------
//   weight_rom and data_buffer give their data ONE CLOCK AFTER the address, so everything the MAC
//   side uses (mac_unit control, bias address, pooling, write addresses, score registers) is a copy
//   of the layer_ctrl / addr_gen signal delayed by exactly one clock: clear_d, enable_d, done_d, last_d,
//   filter_d, pos_d. addr_gen and layer_ctrl themselves are NOT delayed: they create the addresses.
//   mac_unit registers its sum, so when done_d is high acc is the finished sum, and filter_d / pos_d still
//   describe that finished output (addr_gen moves on at the end of the done clock).
//
// ---------------------------------------------------------------------------
// WHERE THE RESULTS GO   (all use done_d / the delayed filter and position)
// ---------------------------------------------------------------------------
//   conv1 (layer 0) : pool_pair -> buf_a at  filter * 128 + position / 2
//   conv2 (layer 1) : pool_pair -> buf_b at  filter * 62  + position / 2   (filter * 62 = filter * 64 - filter * 2)
//   fc1   (layer 2) : buf_c at  filter                 (no pooling)
//   fc2   (layer 3) : score0 (neuron 0) or score1 (neuron 1)
//   Only the buffer of the running layer is written (the layer number gates the write enables).
//
// ---------------------------------------------------------------------------
// WHEN THE NEXT LAYER MAY START
// ---------------------------------------------------------------------------
//   A layer's layer_done comes one clock AFTER its last result was written, and the sequencer needs
//   one more clock before start_layer, so the next layer always starts on completely written data.
//
// Notes for whoever extends this (Vivado / timing):
//   - out_val of pool_pair and the result of bias_rescale are combinational in the same clock as the
//     finished sum: the path mac_unit -> bias_rescale -> max_pool -> buffer write is one clock long.
//     bias_rescale now shifts by an amount chosen by the layer (a variable shifter instead of fixed
//     wires), which makes this path longer than in the single-layer files. If it does not meet the
//     clock in Vivado, add a register after bias_rescale (and delay filter_d / pos_d / done_d one more clock).
//   - There is no reset on the memories; the buffers hold old data until a layer rewrites them.
//
module ecg_top (
    input  wire               clk,
    input  wire               rst_n,        // active low, asynchronous (like the other modules)

    // load the beat (260 samples, Q4.12)
    input  wire               in_we,
    input  wire [8:0]         in_waddr,     // 0 .. 259
    input  wire signed [15:0] in_wdata,

    // run the beat
    input  wire               start_beat,   // one-clock pulse
    output wire               beat_busy,    // 1 from the clock after start_beat until the clock before beat_done
    output wire               beat_done,    // one-clock pulse: score0, score1 and abnormal are final

    // results
    output wire signed [15:0] score0,       // class 0, Normal   (Q6.10)
    output wire signed [15:0] score1,       // class 1, Abnormal (Q6.10)
    output wire               abnormal      // 1 = Abnormal (score1 higher), 0 = Normal (also on a tie)
);

    // ---------------------------------------------------------------------
    // the sequencer
    // ---------------------------------------------------------------------
    wire [1:0] layer;            // 0 conv1, 1 conv2, 2 fc1, 3 fc2
    wire       start_layer;
    wire       layer_done;

    layer_seq seq (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_beat (start_beat),
        .layer_done (layer_done),
        .layer      (layer),
        .start_layer(start_layer),
        .beat_busy  (beat_busy),
        .beat_done  (beat_done)
    );

    wire l_conv1 = (layer == 2'd0);
    wire l_conv2 = (layer == 2'd1);
    wire l_fc1   = (layer == 2'd2);
    wire l_fc2   = (layer == 2'd3);

    // ---------------------------------------------------------------------
    // the layer table: the settings of each layer in ONE place (from make_answer_key.py, LAYERS)
    //                    filters positions channels window row  taps  weights bias  bias  out   ReLU
    //                                                        len        start  start shift shift
    //   conv1 (layer 0)     8      256       1        5       0     5       0     0    12    16    yes
    //   conv2 (layer 1)    16      124       8        5     128    40      40     8    10    15    yes
    //   fc1   (layer 2)    32        1       1      992       0   992     680    24    10    16    yes
    //   fc2   (layer 3)     2        1       1       32       0    32   32424    56     9    14    no
    // ---------------------------------------------------------------------
    reg [5:0]  num_filters;
    reg [8:0]  num_positions;
    reg [3:0]  num_channels;
    reg [9:0]  kernel;
    reg [10:0] row_len;
    reg [10:0] num_terms;
    reg [14:0] w_base;
    reg [5:0]  b_base;
    reg [4:0]  bias_shift;
    reg [4:0]  out_shift;

    always @(*) begin
        case (layer)
            2'd0: begin   // conv1
                num_filters   = 6'd8;
                num_positions = 9'd256;
                num_channels  = 4'd1;
                kernel        = 10'd5;
                row_len       = 11'd0;
                num_terms     = 11'd5;
                w_base        = 15'd0;
                b_base        = 6'd0;
                bias_shift    = 5'd12;
                out_shift     = 5'd16;
            end
            2'd1: begin   // conv2
                num_filters   = 6'd16;
                num_positions = 9'd124;
                num_channels  = 4'd8;
                kernel        = 10'd5;
                row_len       = 11'd128;
                num_terms     = 11'd40;
                w_base        = 15'd40;
                b_base        = 6'd8;
                bias_shift    = 5'd10;
                out_shift     = 5'd15;
            end
            2'd2: begin   // fc1
                num_filters   = 6'd32;
                num_positions = 9'd1;
                num_channels  = 4'd1;
                kernel        = 10'd992;
                row_len       = 11'd0;
                num_terms     = 11'd992;
                w_base        = 15'd680;
                b_base        = 6'd24;
                bias_shift    = 5'd10;
                out_shift     = 5'd16;
            end
            default: begin   // fc2
                num_filters   = 6'd2;
                num_positions = 9'd1;
                num_channels  = 4'd1;
                kernel        = 10'd32;
                row_len       = 11'd0;
                num_terms     = 11'd32;
                w_base        = 15'd32424;
                b_base        = 6'd56;
                bias_shift    = 5'd9;
                out_shift     = 5'd14;
            end
        endcase
    end

    wire apply_relu = !l_fc2;       // fc2 delivers the raw scores

    // ---------------------------------------------------------------------
    // control: layer_ctrl + addr_gen   (these see the UNdelayed signals)
    // ---------------------------------------------------------------------
    // (lint: term_idx, the top address bits and the top position bit are intentionally not used)
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
        .num_terms(num_terms),
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
        .num_filters  (num_filters),
        .num_positions(num_positions),
        .num_channels (num_channels),
        .kernel       (kernel),
        .row_len      (row_len),
        .data_addr    (data_addr),
        .weight_addr  (weight_addr),
        .filter_idx   (filter_idx),
        .position_idx (position_idx),
        .last_output  (last_output)
    );

    // ---------------------------------------------------------------------
    // the one-clock delay registers
    // ---------------------------------------------------------------------
    reg        clear_d, enable_d, done_d, last_d;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [8:0]  pos_d;          // bit 8 is not needed: positions go 0..255
    /* verilator lint_on UNUSEDSIGNAL */
    reg [5:0]  filter_d;

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
    // the four data buffers (each gives its data one clock after the address)
    // ---------------------------------------------------------------------
    wire signed [15:0] s_in, s_a, s_b, s_c;      // what each buffer delivers
    wire signed [15:0] act;                      // finished output of the running layer (valid while done_d = 1)
    wire               pool_valid;
    wire signed [15:0] pool_val;

    // conv1 write address = filter * 128 + position / 2
    wire [9:0] a_waddr = {filter_d[2:0], pos_d[7:1]};

    // conv2 write address = filter * 62 + position / 2, with filter * 62 = filter * 64 - filter * 2
    wire [9:0] filter_x62 = {filter_d[3:0], 6'b000000} - {5'b00000, filter_d[3:0], 1'b0};
    wire [9:0] b_waddr    = filter_x62 + {4'b0000, pos_d[6:1]};          // largest: 15 * 62 + 61 = 991

    data_buffer #(.DEPTH(260)) in_buf (
        .clk  (clk),
        .we   (in_we),
        .waddr(in_waddr),
        .wdata(in_wdata),
        .raddr(data_addr[8:0]),        // largest address used: 255 + 4 = 259
        .rdata(s_in)
    );

    data_buffer #(.DEPTH(1024)) buf_a (
        .clk  (clk),
        .we   (pool_valid && l_conv1),
        .waddr(a_waddr),
        .wdata(pool_val),
        .raddr(data_addr[9:0]),        // largest address used: 7 * 128 + 123 + 4 = 1023
        .rdata(s_a)
    );

    data_buffer #(.DEPTH(992)) buf_b (
        .clk  (clk),
        .we   (pool_valid && l_conv2),
        .waddr(b_waddr),
        .wdata(pool_val),
        .raddr(data_addr[9:0]),        // largest address used: 991
        .rdata(s_b)
    );

    data_buffer #(.DEPTH(32)) buf_c (
        .clk  (clk),
        .we   (done_d && l_fc1),
        .waddr(filter_d[4:0]),
        .wdata(act),
        .raddr(data_addr[4:0]),        // largest address used: 31
        .rdata(s_c)
    );

    // which buffer feeds the MAC: the one that belongs to the running layer
    reg signed [15:0] sample;
    always @(*) begin
        case (layer)
            2'd0:    sample = s_in;
            2'd1:    sample = s_a;
            2'd2:    sample = s_b;
            default: sample = s_c;
        endcase
    end

    // ---------------------------------------------------------------------
    // weights and biases
    // ---------------------------------------------------------------------
    wire signed [15:0] weight;
    wire [14:0] w_rom_addr = w_base + weight_addr[14:0];      // largest address: 32,424 + 63 = 32,487

    weight_rom wrom (
        .clk (clk),
        .addr(w_rom_addr),
        .data(weight)
    );

    wire signed [15:0] bias;

    bias_rom brom (
        .addr(b_base + filter_d),
        .data(bias)
    );

    // ---------------------------------------------------------------------
    // multiply-accumulate, bias, rescale (+ ReLU except for fc2)
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

    /* verilator lint_off UNUSEDSIGNAL */
    wire act_ovf;                  // 1 = this output was clamped (diagnostic only, not used)
    /* verilator lint_on UNUSEDSIGNAL */

    bias_rescale rescale (
        .acc_in    (acc),
        .bias_in   (bias),
        .bias_shift(bias_shift),
        .out_shift (out_shift),
        .apply_relu(apply_relu),
        .result    (act),
        .overflow  (act_ovf)
    );

    // ---------------------------------------------------------------------
    // pooling holder (conv1 and conv2 only)
    // ---------------------------------------------------------------------
    pool_pair pool (
        .clk      (clk),
        .in_valid (done_d && !layer[1]),
        .pos_odd  (pos_d[0]),
        .in_val   (act),
        .out_valid(pool_valid),
        .out_val  (pool_val)
    );

    // ---------------------------------------------------------------------
    // fc2's two results and the decision
    // ---------------------------------------------------------------------
    reg signed [15:0] score0_r, score1_r;

    always @(posedge clk) begin
        if (done_d && l_fc2 && !filter_d[0]) score0_r <= act;
        if (done_d && l_fc2 &&  filter_d[0]) score1_r <= act;
    end

    assign score0 = score0_r;
    assign score1 = score1_r;

    decision dec (
        .score0  (score0_r),
        .score1  (score1_r),
        .abnormal(abnormal)
    );

    // ---------------------------------------------------------------------
    // layer finished: one clock after the last result of the layer was written
    // ---------------------------------------------------------------------
    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_r <= 1'b0;
        else        done_r <= done_d && last_d;
    end

    assign layer_done = done_r;

endmodule
