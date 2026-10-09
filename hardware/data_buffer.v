// data_buffer.v
// A small memory for DATA (as opposed to weight_rom / bias_rom, which hold the
// fixed trained numbers). The same module is used four times, with a different
// DEPTH each time:
//
//     input buffer      DEPTH = 260    the heartbeat's samples (Q4.12)
//     activation A      DEPTH = 1024   conv1 output after ReLU + pooling  (8 x 128)
//     activation B      DEPTH = 992    conv2 output after ReLU + pooling  (16 x 62), already flattened
//     activation C      DEPTH = 32     fc1 output
//
// One write port and one read port, both on the same clock.
//
//   Write : when we = 1, wdata is stored at waddr on the next clock edge.
//   Read  : the address is given on raddr; the value appears on rdata ONE CLOCK
//           EDGE LATER (registered read), and then stays until the next edge.
//           This is the same one-cycle delay as weight_rom, so a sample read
//           from here and a weight read from weight_rom arrive together.
//
//   Read and write of the SAME address in the SAME clock: the read returns the
//   OLD value (read-first); the new value shows up on the following read.
//   The design never does this on purpose (a layer reads one buffer while it
//   writes a different one), but the behaviour is fixed so it is never a surprise.
//
//   There is no reset and no initial content: a location that was never written
//   holds nothing meaningful (simulation shows x; real hardware may show 0 or old
//   data). Never read a location before the layer before it has written it.
//
//   Addresses must stay inside 0 .. DEPTH-1. Outside that range simulation shows x
//   and ignores the write, but real hardware may behave differently (the 992-word
//   buffer, for instance, sits in a 1024-word block RAM), so never use such addresses.
//
// The tools decide whether each instance becomes block RAM or LUT RAM. Because
// the read is registered in the code, both behave identically clock for clock.
//
module data_buffer #(
    parameter DEPTH = 1024,
    parameter AW    = $clog2(DEPTH)       // address width (DEPTH = 1 is not supported)
)(
    input  wire                clk,
    input  wire                we,
    input  wire [AW-1:0]       waddr,
    input  wire signed [15:0]  wdata,
    input  wire [AW-1:0]       raddr,
    output reg  signed [15:0]  rdata
);

    reg signed [15:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata <= mem[raddr];              // sees the old value when waddr == raddr in this cycle
    end

endmodule
