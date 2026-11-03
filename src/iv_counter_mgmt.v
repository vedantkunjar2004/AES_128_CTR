// Counter block for CTR mode 
module iv_counter_mgmt (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         zeroize,

    input  wire         iv_load,
    input  wire [127:0] iv_in,

    input  wire         advance,
    
    output reg  [127:0] value_out
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            value_out <= 128'd0; // Resets the counter value
        else if(zeroize)
            value_out <= 128'd0; 
        else if (iv_load)
            value_out <= iv_in; // Loads initial counter value
        else if (advance)
            value_out <= value_out + 128'd1; // After an AES block is completed: increments the counter value 
    end
endmodule