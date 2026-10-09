// layer_seq.v
// The layer sequencer: runs the four layers of the network one after the other.
//
//     start_beat  ->  conv1  ->  conv2  ->  fc1  ->  fc2  ->  beat_done
//     (layer 0)      (layer 1)  (layer 2)  (layer 3)
//
// It knows nothing about the maths. It only says WHICH layer is running (layer = 0, 1, 2, 3), gives
// ONE clock pulse (start_layer) when a layer should begin, and waits for the datapath to say
// layer_done. Then it moves on to the next layer.
//
// ---------------------------------------------------------------------------
// HOW IT WORKS
// ---------------------------------------------------------------------------
//   three states:   IDLE : nothing running, waiting for start_beat
//                   GO   : lasts exactly ONE clock; start_layer is high in this clock
//                   RUN  : a layer is running, waiting for layer_done
//
//   IDLE --start_beat--> GO (layer = 0) --1 clock--> RUN --layer_done--> GO (layer + 1) --> RUN ...
//   RUN with layer = 3 and layer_done --> IDLE   (beat_done is high in that same clock)
//
//   - start_layer comes exactly ONE clock after start_beat (for layer 0) and exactly ONE clock after
//     each layer_done (for layers 1, 2, 3). The layer number changes in the clock BEFORE start_layer,
//     so the layer's settings are stable when the layer starts.
//   - layer_done is only listened to in state RUN. A layer_done in IDLE or GO is ignored.
//   - start_beat is only accepted when no beat is running (IDLE) or in the very clock in which the
//     beat finishes (beat_done = 1, then the next beat starts at once). At any other time it is ignored.
//   - beat_done is high for ONE clock, in the same clock as the fourth layer_done.
//   - beat_busy is high from the clock after an accepted start_beat until the clock before beat_done;
//     it is 0 in the beat_done clock itself.
//   - rst_n (active low, asynchronous) puts everything back to IDLE, layer 0.
//   - Between beats the layer number stays at 3 (it is set back to 0 by the next start_beat).
//
module layer_seq (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start_beat,    // pulse: run the four layers once
    input  wire       layer_done,    // from the datapath: one-clock pulse when the running layer is finished

    output wire [1:0] layer,         // 0 = conv1, 1 = conv2, 2 = fc1, 3 = fc2
    output wire       start_layer,   // one-clock pulse: the datapath starts layer 'layer' now
    output wire       beat_busy,     // a beat is running
    output wire       beat_done      // one-clock pulse: all four layers are finished
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_GO   = 2'd1,
                     S_RUN  = 2'd2;

    reg [1:0] state;
    reg [1:0] layer_r;

    wire last_layer = (layer_r == 2'd3);

    // all four layers finished: the fourth layer_done, while running
    assign beat_done = (state == S_RUN) && layer_done && last_layer;

    // a new beat may start when nothing runs, or in the clock the old one finishes
    wire accept = start_beat && ((state == S_IDLE) || beat_done);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            layer_r <= 2'd0;
        end else if (accept) begin
            state   <= S_GO;
            layer_r <= 2'd0;
        end else begin
            case (state)
                S_GO: begin
                    state <= S_RUN;                  // GO lasts one clock
                end
                S_RUN: begin
                    if (layer_done) begin
                        if (last_layer) begin
                            state <= S_IDLE;         // beat finished
                        end else begin
                            layer_r <= layer_r + 2'd1;
                            state   <= S_GO;         // next layer starts in the next clock
                        end
                    end
                end
                default: begin
                    state <= S_IDLE;                 // IDLE stays idle; the unused code 3 falls back to IDLE
                end
            endcase
        end
    end

    assign layer       = layer_r;
    assign start_layer = (state == S_GO);
    assign beat_busy   = (state != S_IDLE) && !beat_done;

endmodule
