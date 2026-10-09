// pool_pair.v
// The "pooling holder": max-pool (window 2) for ONE output stream that arrives
// one number at a time, the way our single shared MAC unit produces it.
//
// Why it exists
//   Max-pool keeps the bigger of two NEIGHBOURING conv outputs (positions 2p and
//   2p+1 of the same filter). The MAC unit finishes them one after the other,
//   so when the first one appears its partner does not exist yet. This module
//   parks the first number in one register and, when the second arrives, hands
//   both to max_pool and passes the winner on. The unpooled outputs are never
//   stored anywhere.
//
// How it works (every number is one finished, post-ReLU output)
//   in_valid = 1, pos_odd = 0 : first of a pair  -> copy in_val into 'held'
//                                                   out_valid = 0 (nothing to write yet)
//   in_valid = 1, pos_odd = 1 : second of a pair -> out_val = larger of 'held' and in_val
//                                                   out_valid = 1 (write out_val now)
//   in_valid = 0              : nothing happens; 'held' keeps its value for as
//                               long as it takes (idle clocks between outputs are fine)
//
//   pos_odd is simply the lowest bit of the output's position number
//   (0 = even = first of a pair, 1 = odd = second). Because every number says by
//   itself whether it is first or second, there is no toggle flag inside this
//   module that could ever fall out of step.
//
// Timing
//   Inputs are used in the same clock they are presented, nothing is delayed:
//   out_valid / out_val are combinational (like max_pool and bias_rescale), so
//   the pooled value is available in the SAME clock as the second number and the
//   write into the buffer can happen at that clock edge. The only state is 'held'.
//
// Rules for the user of this module
//   - in_valid must be 1 for exactly one clock per finished output, with in_val
//     and pos_odd belonging to that same output.
//   - A pair is always (even position, then the next odd position) of the same
//     filter, so the number of positions per filter must be even
//     (conv1: 256, conv2: 124 - both are).
//   - There is no reset: 'held' is unknown until the first pair starts, and it is
//     never used before that (out_valid is 0 until a second number arrives).
//   - The pooled position is p = position / 2, i.e. position[MSB:1].
//
module pool_pair #(
    parameter DATA_WIDTH = 16
)(
    input  wire                         clk,
    input  wire                         in_valid,   // 1 = in_val is a finished output this clock
    input  wire                         pos_odd,    // lowest bit of that output's position
    input  wire signed [DATA_WIDTH-1:0] in_val,     // the finished (post-ReLU) output
    output wire                         out_valid,  // 1 = out_val is a finished pooled value
    output wire signed [DATA_WIDTH-1:0] out_val     // larger of the pair (meaningful only when out_valid = 1)
);

    reg signed [DATA_WIDTH-1:0] held;               // the parked first number of a pair

    always @(posedge clk)
        if (in_valid && !pos_odd)
            held <= in_val;

    max_pool #(.DATA_WIDTH(DATA_WIDTH)) compare (
        .a      (held),
        .b      (in_val),
        .max_val(out_val)
    );

    assign out_valid = in_valid && pos_odd;

endmodule
