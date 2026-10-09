// addr_gen.v
// One address generator shared by conv1, conv2, fc1 and fc2.
//
// Each clock cycle that the MAC unit does a multiply, this module says WHICH
// box to read for the data (sample / activation) and WHICH box to read for
// the weight. The layer's shape comes in as inputs, so nothing here is
// specific to one layer (same idea as num_terms in layer_ctrl.v).
//
// Counting order, innermost to outermost:
//     k   : step inside one row of the window        (0 .. kernel-1)
//     ch  : which input row / channel                (0 .. num_channels-1)
//     pos : where the window sits (the "position")   (0 .. num_positions-1)
//     filt: which filter / neuron                    (0 .. num_filters-1)
// k and ch together are the "tap" (the step inside one answer):
//     tap = ch * kernel + k      (this equals layer_ctrl's term_idx)
//
// Addresses (relative to the start of the layer's own data and weights):
//     data_addr   = ch * row_len + pos + k
//     weight_addr = filt * (num_channels*kernel) + tap
//
// FC layers use the same module with num_positions = 1 and num_channels = 1.
// Then kernel is simply "how many inputs the neuron looks at"
// (992 for fc1, 32 for fc2) and data_addr = tap.
//
// No multipliers: instead of computing ch*row_len and filt*taps each time,
// the module keeps running base addresses and just adds to them.
//
// How it connects to layer_ctrl.v:
//     step        <- layer_ctrl enable   (a tap is being consumed this cycle)
//     next_output <- layer_ctrl done     (one answer has just been finished)
// step and next_output must never be high in the same cycle (they are not:
// enable is high in RUN, done is high in DONE).
//
// The address outputs show the tap being used THIS cycle and change at the
// clock edge. filter_idx / position_idx stay on the output just finished
// until the end of the done cycle, so whatever stores the result can read
// them while done is high (that is also where the bias is looked up).
//
// Requirements: kernel, num_channels, num_positions and num_filters must be
// at least 1.
//
module addr_gen #(
    parameter F_W  = 6,    // filter/neuron counter width  (holds up to 63;  needs 32)
    parameter P_W  = 9,    // position counter width       (holds up to 511; needs 256)
    parameter C_W  = 4,    // channel counter width        (holds up to 15;  needs 8)
    parameter K_W  = 10,   // kernel counter width         (holds up to 1023; needs 992)
    parameter DA_W = 11,   // data address width           (holds up to 2047; needs 1024)
    parameter WA_W = 16    // weight address width         (holds up to 65535; needs 31,744)
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             init,           // synchronous: go back to the very first tap
    input  wire             step,
    input  wire             next_output,

    input  wire [F_W-1:0]   num_filters,
    input  wire [P_W-1:0]   num_positions,
    input  wire [C_W-1:0]   num_channels,
    input  wire [K_W-1:0]   kernel,
    input  wire [DA_W-1:0]  row_len,        // length of one input row (128 for conv2); unused when num_channels = 1

    output wire [DA_W-1:0]  data_addr,
    output wire [WA_W-1:0]  weight_addr,
    output wire [F_W-1:0]   filter_idx,
    output wire [P_W-1:0]   position_idx,
    output wire             last_output     // high while working on the final output of the layer
);

    reg [K_W-1:0]  k;
    reg [C_W-1:0]  ch;
    reg [P_W-1:0]  pos;
    reg [F_W-1:0]  filt;
    reg [DA_W-1:0] cbase;     // ch * row_len, kept as a running total
    reg [WA_W-1:0] waddr;     // the weight box to read now
    reg [WA_W-1:0] wbase;     // first weight box of the current filter

    wire k_last    = (k    == kernel        - 1'b1);
    wire ch_last   = (ch   == num_channels  - 1'b1);
    wire pos_last  = (pos  == num_positions - 1'b1);
    wire filt_last = (filt == num_filters   - 1'b1);
    wire tap_last  = k_last && ch_last;     // the final multiply of one answer

    // pos and k are narrower than the address, so they are padded with zeros
    // explicitly (they are unsigned counters; no sign extension wanted)
    assign data_addr    = cbase + {{(DA_W-P_W){1'b0}}, pos} + {{(DA_W-K_W){1'b0}}, k};
    assign weight_addr  = waddr;
    assign filter_idx   = filt;
    assign position_idx = pos;
    assign last_output  = pos_last && filt_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k <= 0; ch <= 0; pos <= 0; filt <= 0;
            cbase <= 0; waddr <= 0; wbase <= 0;
        end else if (init) begin
            k <= 0; ch <= 0; pos <= 0; filt <= 0;
            cbase <= 0; waddr <= 0; wbase <= 0;
        end else begin

            // ---- one tap consumed: move to the next tap ----
            if (step) begin
                if (!tap_last) begin
                    waddr <= waddr + 1'b1;                 // next weight of this filter
                    if (!k_last)
                        k <= k + 1'b1;                     // next step along the window
                    else begin
                        k     <= 0;                        // window row finished, next channel
                        ch    <= ch + 1'b1;
                        cbase <= cbase + row_len;
                    end
                end else begin
                    k <= 0; ch <= 0; cbase <= 0;           // answer finished: back to tap 0
                    if (!pos_last)
                        waddr <= wbase;                    // same filter, next position: same weights again
                    else if (!filt_last) begin
                        waddr <= waddr + 1'b1;             // next filter's first weight
                        wbase <= waddr + 1'b1;
                    end else begin
                        waddr <= 0;                        // whole layer finished: wrap
                        wbase <= 0;
                    end
                end
            end

            // ---- one answer finished: move to the next position / filter ----
            if (next_output) begin
                if (!pos_last)
                    pos <= pos + 1'b1;
                else begin
                    pos  <= 0;
                    filt <= filt_last ? {F_W{1'b0}} : filt + 1'b1;
                end
            end
        end
    end

endmodule
