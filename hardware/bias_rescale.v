// bias_rescale.v
// Closes the two gaps left open by mac_unit.v (see its report, Section 12):
// bias addition and inter-layer rescaling. Also applies ReLU, since it's a
// one-line check on the same value and not worth a separate module.
//
// Purely combinational: one shared instance serves every layer. Which layer
// is selected by what's fed into bias_shift / out_shift / apply_relu, the
// same "parameters as inputs, not per-layer copies" idea as layer_ctrl's
// num_terms.
//
//   acc_in      : the finished acc_out from mac_unit (Q-format = sum of the
//                 two operand formats, e.g. Q26 for conv1, Q29 elsewhere)
//   bias_in     : this output channel's bias, already in Q2.14 or Q1.15
//   bias_shift  : how far to shift bias_in left to match acc_in's format
//                 (12 for conv1, 14 for conv2/fc1/fc2)
//   out_shift   : how far to shift the sum right to land on Q2.14
//                 (12 for conv1, 15 for conv2/fc1/fc2)
//   apply_relu  : 1 for conv1/conv2/fc1, 0 for fc2 (raw class scores)
//   result      : final Q2.14 activation, saturated to 16-bit signed range
//   overflow    : 1 if saturation actually clamped something this cycle
//                 (diagnostic only - flags the activation-range question
//                 left open in the Phase 2.1 report, Section 7.3)
//
module bias_rescale #(
    parameter ACC_WIDTH = 48,
    parameter OUT_WIDTH = 16
)(
    input  wire signed [ACC_WIDTH-1:0] acc_in,
    input  wire signed [OUT_WIDTH-1:0] bias_in,
    input  wire [4:0]                  bias_shift,
    input  wire [4:0]                  out_shift,
    input  wire                        apply_relu,
    output wire signed [OUT_WIDTH-1:0] result,
    output wire                        overflow
);

    // Sign-extend the bias to the accumulator's width, then shift it up to
    // match acc_in's fractional-bit count (same "fractional bits add" rule
    // from Phase 2.1, run in reverse to align two different formats).
    wire signed [ACC_WIDTH-1:0] bias_ext     = {{(ACC_WIDTH-OUT_WIDTH){bias_in[OUT_WIDTH-1]}}, bias_in};
    wire signed [ACC_WIDTH-1:0] bias_shifted = bias_ext <<< bias_shift;

    wire signed [ACC_WIDTH-1:0] summed  = acc_in + bias_shifted;

    // Arithmetic right shift on a signed value floors toward negative
    // infinity, same as Python's integer >> - this must match, or hardware
    // and the golden model disagree on every negative activation.
    wire signed [ACC_WIDTH-1:0] rescaled = summed >>> out_shift;

    localparam signed [ACC_WIDTH-1:0] MAXV =  (1 <<< (OUT_WIDTH-1)) - 1;  //  32767 for OUT_WIDTH=16
    localparam signed [ACC_WIDTH-1:0] MINV = -(1 <<< (OUT_WIDTH-1));      // -32768

    wire ovf_hi = (rescaled > MAXV);
    wire ovf_lo = (rescaled < MINV);
    wire signed [ACC_WIDTH-1:0] clamped = ovf_hi ? MAXV : ovf_lo ? MINV : rescaled;

    wire signed [OUT_WIDTH-1:0] relu_applied =
        (apply_relu && clamped[ACC_WIDTH-1]) ? {OUT_WIDTH{1'b0}} : clamped[OUT_WIDTH-1:0];

    assign result   = relu_applied;
    assign overflow = ovf_hi | ovf_lo;

endmodule
