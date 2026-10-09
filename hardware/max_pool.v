// max_pool.v
// Max-pooling (window=2), reduced to its actual hardware primitive: compare
// two neighboring activations, keep the larger one. One shared instance is
// reused sequentially across every pooling pair conv1/conv2 produce, the
// same "one small verified block, reused" approach as mac_unit.v and
// layer_ctrl.v, rather than building a wide parallel comparator tree.
//
// Purely combinational, like bias_rescale.v: a comparison needs no memory
// of previous cycles.
//
// In the real pipeline this only ever runs AFTER ReLU (see bias_rescale.v),
// so both inputs happen to be non-negative in practice. The module itself
// makes no such assumption and correctly compares any two signed 16-bit
// values, including negative ones, so it is not silently dependent on how
// it happens to be used today.
//
//   a, b    : the two neighboring activations being pooled
//   max_val : the larger of the two (b is returned on a tie)
//
module max_pool #(
    parameter DATA_WIDTH = 16
)(
    input  wire signed [DATA_WIDTH-1:0] a,
    input  wire signed [DATA_WIDTH-1:0] b,
    output wire signed [DATA_WIDTH-1:0] max_val
);

    assign max_val = (a > b) ? a : b;

endmodule
