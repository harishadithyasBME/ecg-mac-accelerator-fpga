// weight_rom.v
// Read-only memory holding ALL 32,488 weights of the network (conv1, conv2,
// fc1, fc2 stored one after another), loaded from weights.hex.
//
// It is meant to become FPGA block RAM (BRAM). Block RAM reads are
// synchronous: you present an address, and the weight shows up on `data`
// ONE CLOCK EDGE LATER, then stays there until the next edge.
//
//     cycle n   : addr = A
//     cycle n+1 : data = weight[A]        (addr may already be showing a new value)
//
// That one-cycle delay is why layer_ctrl's clear_acc / enable / done, and the
// result's write address, will have to be delayed by one cycle when this ROM
// is wired in (done at the conv1 wiring step, not here).
//
// Layer start addresses inside this ROM (the same numbers export_rom_files.py prints):
//     conv1 = 0     conv2 = 40     fc1 = 680     fc2 = 32424
// addr_gen's weight_addr is relative to its own layer, so whoever wires this
// ROM adds the layer's start address first.
//
// Addresses 32,488 and above do not exist. addr_gen never produces them;
// the real hardware returns unspecified data for them (simulation shows x).
//
module weight_rom #(
    parameter DEPTH     = 32488,                 // number of weights
    parameter AW        = $clog2(DEPTH),         // address width: 15 bits (covers 0..32,767)
    parameter INIT_FILE = "weights.hex"          // one 4-digit hex weight per line
)(
    input  wire                 clk,
    input  wire [AW-1:0]        addr,
    output reg  signed [15:0]   data
);

    (* rom_style = "block" *) reg signed [15:0] mem [0:DEPTH-1];

    initial $readmemh(INIT_FILE, mem);

    always @(posedge clk)
        data <= mem[addr];

endmodule
