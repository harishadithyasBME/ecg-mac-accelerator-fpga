// bias_rom.v
// Read-only memory holding the 58 biases (conv1 8, conv2 16, fc1 32, fc2 2,
// stored one after another), loaded from biases.hex.
//
// Unlike weight_rom, this read is INSTANT (combinational): change addr and
// data follows in the same cycle, no clock involved. 58 numbers is small
// enough that the FPGA builds it from ordinary logic (LUTs) instead of
// block RAM, so there is no one-cycle delay to compensate for.
//
// Where each layer's biases start (the same numbers export_rom_files.py prints):
//     conv1 = 0     conv2 = 8     fc1 = 24     fc2 = 56
// The address for a given output is: layer start + filter_idx.
// addr_gen holds filter_idx steady while layer_ctrl's done is high, which is
// exactly when bias_rescale needs the bias.
//
// Addresses 58..63 do not exist (simulation shows x for them).
//
module bias_rom #(
    parameter DEPTH     = 58,
    parameter AW        = $clog2(DEPTH),         // 6 bits
    parameter INIT_FILE = "biases.hex"           // one 4-digit hex bias per line
)(
    input  wire [AW-1:0]       addr,
    output wire signed [15:0]  data
);

    // No memory-style hint on purpose: block RAM cannot do an instant read, so
    // the tools build this table from LUTs by themselves (16 LUT6, one per output bit).
    reg signed [15:0] mem [0:DEPTH-1];

    initial $readmemh(INIT_FILE, mem);

    assign data = mem[addr];

endmodule
