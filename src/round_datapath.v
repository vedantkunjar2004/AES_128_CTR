// This module controls the 10 AES rounds
module round_datapath (
    input  wire         clk,
    input  wire         rst_n,
    input wire          zeroize,
    input  wire         start,
    input  wire [127:0] block_in, 
    output reg  [3:0]   round_addr,
    input  wire [127:0] round_key,
    output reg          busy,  // exposed so aes_engine can mirror it directly instead of
                                // re-deriving busy from `done` in its own clock domain, which
                                // races: `done` update and a re-registered "busy<=0 on done" both
                                // fire off the same edge, and the latter always samples the pre-edge
                                // (stale) value, so busy would stay high for one extra cycle after done.
    output reg          done,
    output reg  [127:0] block_out
);
    reg [127:0] state; // It stores the intermediate results between the rounds.
    wire [127:0] after_sub, after_shift, mix_result, after_add;

    // 1 round of transformation process
    sub_bytes  u_sub   (.state_in(state),     .state_out(after_sub));
    shift_rows u_shift (.state_in(after_sub), .state_out(after_shift));
    mix_columns u_mix  (.state_in(after_shift), .state_out(mix_result));

    wire [127:0] after_mix = (round_addr == 4'd10) ? after_shift : mix_result;

    add_round_key u_add (.state_in(after_mix), .round_key(round_key), .state_out(after_add));

    reg [127:0] next_state;
    reg [3:0]   next_round_addr;
    reg         next_busy;
    reg         next_done;
    reg [127:0] next_block_out;

    // Combinational logic
    always @(*) begin
        // default hold values
        next_state      = state;
        next_round_addr = round_addr;
        next_busy       = busy;
        next_done       = 1'b0;
        next_block_out  = block_out;

        if (start) begin
            next_state      = block_in ^ round_key; // The initial add_round_key before round 1
            next_round_addr = 4'd1; // The next cycle begins round 1
            next_busy       = 1'b1; // Busy flag asserted 
        end else if (busy) begin
            if (round_addr < 4'd10) begin
                next_state      = after_add; // From rounds 1-9 the completed round becomes state for next round
                next_round_addr = round_addr + 4'd1; // Round is incremented by 1 
            end else begin
                next_block_out  = after_add; // Round 10: Final encrypted block out
                next_busy       = 1'b0; // Busy flag de asserted
                next_done       = 1'b1; // Done flag asserted
                next_round_addr = 4'd0; // Back to round 0, ready for next counter value
            end
        end
    end

    // Sequential logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= 128'd0;
            round_addr <= 4'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
            block_out  <= 128'd0;
        end
        else if(zeroize) begin
            state      <= 128'd0;
            round_addr <= 4'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
            block_out  <= 128'd0;
        end else begin
            state      <= next_state;
            round_addr <= next_round_addr;
            busy       <= next_busy;
            done       <= next_done;
            block_out  <= next_block_out;
        end
    end
endmodule