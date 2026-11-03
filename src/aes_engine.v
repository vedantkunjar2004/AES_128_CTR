// AES 128 CTR mode top module
module aes_engine(
    input  wire         clk,
    input  wire         rst_n,

    // Zeroize: security wipe, added
    input  wire         zeroize, // Pulse or hold high to clear keys, cipher state, counter, and busy/done

    // Key loading
    input  wire         key_load, // Control signal to load the master key
    input  wire [127:0] key_in, // Loads the master key
    output reg          key_ready, // After the key expansion, key_ready is asserted 

    // IV / counter loading
    input  wire         iv_load, // Control signal to load the initial counter value
    input  wire [127:0] iv_in, // Initial counter value

    // Data path
    input  wire         start, 
    input  wire [127:0] data_in,
    output wire         busy, // direct mirror of round_datapath's internal busy - see round_datapath.v
    output reg          done,
    output reg  [127:0] data_out
);


    // 1. Key Expansion 
    wire [3:0]   round_addr;
    wire [127:0] round_key;
    wire key_done;

    key_expansion u_key_exp (
        .clk           (clk),
        .rst_n         (rst_n), 
        .zeroize       (zeroize),
        .start         (key_load), // As soon as the key_load signal is asserted, key expansion process starts
        .key_in        (key_in),
        .round_addr    (round_addr),
        .done          (key_done),
        .round_key_out (round_key)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_ready <= 1'b0;
        else if(zeroize)
            key_ready <= 1'b0;
        else if (key_load)
            key_ready <= 1'b0;
        else if (key_done)
            key_ready <= 1'b1;
    end

    // 2. Counter Management 
    wire [127:0] counter_val;
    wire         rd_done; 

    wire advance_pulse = busy & (round_addr == 4'd10);

    iv_counter_mgmt u_ctr (
        .clk               (clk),
        .rst_n             (rst_n),
        .zeroize           (zeroize),
        .iv_load           (iv_load),
        .iv_in             (iv_in),
        .advance           (advance_pulse),
        .value_out         (counter_val)
    );

    // 3. Round Datapath
    wire [127:0] rd_block_out;

    // Ignore a new start pulse while a block is already in flight, so a
    // spurious or back-to-back start can't abort an in-progress block.
    // Works whether the caller gives a single-cycle pulse or holds start high.
    // Fix: also require key_ready, so start can never fire before the key
    // schedule has finished expanding (e.g. right after zeroize/key_load).
    wire start_aes = start & ~busy & key_ready;

    round_datapath u_round (
        .clk        (clk),
        .rst_n      (rst_n),
        .zeroize    (zeroize), 
        .start      (start_aes),
        .block_in   (counter_val),
        .round_addr (round_addr),
        .round_key  (round_key), 
        .busy       (busy),      // direct mirror - see comment on the busy port above
        .done       (rd_done),
        .block_out  (rd_block_out)
    );

    reg [127:0] data_in_latched;
    reg [127:0] data_out_held;

    // Combinational block that outputs the ciphertext after every 11 cycles and latches it till next update
    always@(*) begin
        done = rd_done;
        if(rd_done) 
            data_out = rd_block_out ^ data_in_latched; // CTR mode output 
        else 
            data_out = data_out_held;
    end
    
    // Sequential block that registers data_in (for the final XOR) and holds
    // data_out stable between blocks.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_in_latched <= 128'd0;
            data_out_held   <= 128'd0;
        end
        else if (zeroize) begin
            data_in_latched <= 128'd0;
            data_out_held   <= 128'd0;
        end else if (start_aes) begin
            data_in_latched <= data_in;
        end else if (rd_done) begin
            data_out_held   <= data_out;
        end
    end

endmodule