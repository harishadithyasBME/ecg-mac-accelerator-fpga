// layer_ctrl.v
// Sequences the single MAC unit through the N terms of ONE output value
// (one conv filter position, or one fully-connected neuron).
//
//   start  : pulse for one cycle (while IDLE) to begin an output value
//   num_terms : how many multiply-accumulates this output needs (must be >= 1)
//               conv1 = 5, conv2 = 40, fc1 = 992, fc2 = 32
//   term_idx  : which term is being fed this cycle (0 .. num_terms-1);
//               later this becomes the address for the data / weight memories
//   clear_acc : high on the FIRST term only -> MAC starts a fresh sum
//   enable    : high on every term -> MAC accumulates
//   done      : high for ONE cycle after the last term; acc_out is final then
//
module layer_ctrl #(
    parameter CNT_W = 11                    // 11 bits counts up to 2047 (fc1 needs 992)
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire [CNT_W-1:0] num_terms,
    output wire             clear_acc,
    output wire             enable,
    output wire             busy,
    output wire             done,
    output wire [CNT_W-1:0] term_idx
);

    localparam [1:0] IDLE = 2'd0,
                     RUN  = 2'd1,
                     DONE = 2'd2;

    reg [1:0]       state;
    reg [CNT_W-1:0] count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= 0;
        end else begin
            case (state)
                IDLE: begin
                    count <= 0;
                    if (start) state <= RUN;
                end
                RUN: begin
                    if (count == num_terms - 1)
                        state <= DONE;          // this edge also registers the last term
                    else
                        count <= count + 1;
                end
                DONE: begin
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // Outputs depend only on state and count (Moore-style)
    assign enable    = (state == RUN);
    assign clear_acc = (state == RUN) && (count == 0);
    assign busy      = (state == RUN);
    assign done      = (state == DONE);
    assign term_idx  = count;

endmodule
