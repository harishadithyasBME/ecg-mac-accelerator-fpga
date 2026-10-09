// decision.v
// The final decision of the network: which of the two class scores is higher.
//
//     score0 = score of class 0 (Normal)       score1 = score of class 1 (Abnormal)
//     abnormal = 1   when score1 is HIGHER than score0
//     abnormal = 0   when score0 is higher, and also when they are EQUAL (a tie means Normal)
//
// The scores are signed 16-bit numbers (Q6.10) and can be negative, so the comparison is a
// SIGNED one. Purely combinational: no clock, the answer follows the inputs immediately.
// (Same rule as the Python model: Abnormal only if score1 > score0.)
//
module decision (
    input  wire signed [15:0] score0,    // class 0, Normal
    input  wire signed [15:0] score1,    // class 1, Abnormal
    output wire               abnormal   // 1 = Abnormal, 0 = Normal
);

    assign abnormal = (score1 > score0);

endmodule
