module mac_unit #(
    parameter DATA_WIDTH   = 16,   // one sample (e.g. Q4.12 or Q1.15)
    parameter WEIGHT_WIDTH = 16,   // one weight (e.g. Q2.14 or Q1.15)
    parameter ACC_WIDTH    = 48    // running total — wider to avoid overflow
)(
    input  wire                            clk,
    input  wire                            rst_n,      // active-low reset
    input  wire                            clear_acc,  // start a fresh sum (new output channel)
    input  wire                            enable,     // do one multiply-add this cycle
    input  wire signed [DATA_WIDTH-1:0]    data_in,
    input  wire signed [WEIGHT_WIDTH-1:0]  weight_in,
    output reg  signed [ACC_WIDTH-1:0]     acc_out
);

    wire signed [DATA_WIDTH+WEIGHT_WIDTH-1:0] product;
    assign product = data_in * weight_in;

    // sign-extend the 32-bit product up to the 48-bit accumulator width
    wire signed [ACC_WIDTH-1:0] product_ext =
        {{(ACC_WIDTH-(DATA_WIDTH+WEIGHT_WIDTH)){product[DATA_WIDTH+WEIGHT_WIDTH-1]}}, product};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc_out <= 0;
        else if (clear_acc)
            acc_out <= enable ? product_ext : 0;   // start new sum
        else if (enable)
            acc_out <= acc_out + product_ext;       // keep accumulating
    end

endmodule