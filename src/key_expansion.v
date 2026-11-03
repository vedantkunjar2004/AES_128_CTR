// The master key is mathematically expanded into 11 distinct round keys.
// (one for initial XOR and one for each of 10 rounds.)
module key_expansion (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         zeroize,
    input  wire         start,
    input  wire [127:0] key_in,
    input  wire [3:0]   round_addr, 
    output reg          done,
    output wire [127:0] round_key_out
);

    // Memory to hold 11 round keys where key_mem[0] is the master key
    reg [127:0] key_mem [0:10];
    
    reg [3:0] round_no;
    reg [3:0] next_round_no;
    
    reg busy;
    reg next_busy;
    reg next_done;

    // Previous key selection based on current round_no
    wire [127:0] prev_key = (round_no == 4'd0) ? key_in : key_mem[round_no - 1];

    // 128-bit key is divided into 4, 32-bit words
    wire [31:0] w0_old = prev_key[127:96];
    wire [31:0] w1_old = prev_key[95:64];
    wire [31:0] w2_old = prev_key[63:32];
    wire [31:0] w3_old = prev_key[31:0];

    // Circular left shift by 1 performed byte wise
    wire [31:0] rot_w3 = {w3_old[23:0], w3_old[31:24]};

    // The rotated word undergoes byte by byte substitution again
    wire [7:0] s0, s1, s2, s3;
    sbox sb0 (.byte_in(rot_w3[31:24]), .byte_out(s0));
    sbox sb1 (.byte_in(rot_w3[23:16]), .byte_out(s1));
    sbox sb2 (.byte_in(rot_w3[15:8]),  .byte_out(s2));
    sbox sb3 (.byte_in(rot_w3[7:0]),   .byte_out(s3));
    wire [31:0] sub_w3 = {s0, s1, s2, s3};

    // The Substituted word is then XOR with Round constant. Round constant is predefined for each round.
    function automatic [7:0] rcon; 
        input [3:0] r_no;
        begin
            case (r_no)
                4'd1:  rcon = 8'h01;
                4'd2:  rcon = 8'h02;
                4'd3:  rcon = 8'h04;
                4'd4:  rcon = 8'h08;
                4'd5:  rcon = 8'h10;
                4'd6:  rcon = 8'h20;
                4'd7:  rcon = 8'h40;
                4'd8:  rcon = 8'h80;
                4'd9:  rcon = 8'h1B;
                4'd10: rcon = 8'h36;
                default: rcon = 8'h00;
            endcase
        end
    endfunction

    // The round constant for current round
    wire [31:0] rcon_word = {rcon(round_no), 24'h0};

    // The updated 128-bit key after undergoing g-function and XOR operations
    wire [31:0] w0_new = w0_old ^ (sub_w3 ^ rcon_word);
    wire [31:0] w1_new = w1_old ^ w0_new;
    wire [31:0] w2_new = w2_old ^ w1_new;
    wire [31:0] w3_new = w3_old ^ w2_new;

    always @(*) begin
        next_round_no = round_no;
        next_busy     = busy;
        next_done     = 1'b0;
        // Fix: gate on ~busy so a re-asserted/stray start can't restart
        // expansion mid-way through and corrupt key_mem (mirrors the same
        // protection aes_engine already applies to round_datapath's start).
        if (start && !busy) begin
            next_round_no = 4'd1;
            next_busy     = 1'b1;          
        end else if (busy) begin
	     // After the final round, done flag is asserted and busy flag is deasserted
            if (round_no == 4'd10) begin
                next_round_no = 4'd0;
                next_busy     = 1'b0;
                next_done     = 1'b1;
            end else begin
		// Else round number is incremented
                next_round_no = round_no + 4'd1;
                next_busy     = 1'b1;     
            end
        end
    end

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            round_no <= 4'd0;
            busy     <= 1'b0;
            done     <= 1'b0;
	    // Resets all the round keys to 0
            for (k = 0; k <= 10; k = k + 1)
                key_mem[k] <= 128'd0;
        end
        else if (zeroize) begin
            round_no <= 4'd0;
            busy     <= 1'b0;
            done     <= 1'b0;
	    // Resets all the round keys to 0
            for (k = 0; k <= 10; k = k + 1)
                key_mem[k] <= 128'd0; 
        end else begin
            round_no <= next_round_no;
            busy     <= next_busy;
            done     <= next_done;

            if (start && !busy) begin // Loads the master key and Starts the key expansion 
                key_mem[0] <= key_in; // Master key is loaded into the key_mem[0] register 
            end else if (busy) begin
	    // After each round the register is updated with the corresponding round key of that round
                key_mem[round_no] <= {w0_new, w1_new, w2_new, w3_new};
            end
        end
    end

    // The AES datapath does not wait for a key to be generated every round.
    // It selects the corresponding round key from key_mem register 
    assign round_key_out = key_mem[round_addr];

endmodule