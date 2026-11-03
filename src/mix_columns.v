// Skipped during Round 10 
module mix_columns (
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    wire [7:0] b0  = state_in[127:120];
    wire [7:0] b1  = state_in[119:112];
    wire [7:0] b2  = state_in[111:104];
    wire [7:0] b3  = state_in[103:96];
    wire [7:0] b4  = state_in[95:88];
    wire [7:0] b5  = state_in[87:80];
    wire [7:0] b6  = state_in[79:72];
    wire [7:0] b7  = state_in[71:64];
    wire [7:0] b8  = state_in[63:56];
    wire [7:0] b9  = state_in[55:48];
    wire [7:0] b10 = state_in[47:40];
    wire [7:0] b11 = state_in[39:32];
    wire [7:0] b12 = state_in[31:24];
    wire [7:0] b13 = state_in[23:16];
    wire [7:0] b14 = state_in[15:8];
    wire [7:0] b15 = state_in[7:0];
    
    
    // Multiply by 2 in GF(2^8)
    // If MSB is 1 then left shift the byte by 1 and XOR witha constant 8h'1B
    // If MSB is 0 then simply left shift the byte by 1 
    function automatic [7:0] xtime;
        input [7:0] a;
        begin
            xtime = a[7] ? ({a[6:0], 1'b0} ^ 8'h1B) : {a[6:0], 1'b0};
        end
    endfunction

    // Multiply by 3 in GF (2^8)
    // (B * 3) = (B * 2) + B
    function automatic [7:0] mul3;
        input [7:0] a;
        begin
            mul3 = xtime(a) ^ a;
        end
    endfunction


    // Matrix multiplication of a column with a default 4x4 matrix 
    // Outputs a 32 bit word 
    // Default matrix:
    // [02 03 01 01]
    // [01 02 03 01]
    // [01 01 02 03]
    // [03 01 01 02]
    
    function automatic [31:0] mix_one_column;
        input [7:0] s0, s1, s2, s3;
        begin
            mix_one_column = {
                xtime(s0) ^ mul3(s1) ^ s2        ^ s3,
                s0        ^ xtime(s1) ^ mul3(s2) ^ s3,
                s0        ^ s1        ^ xtime(s2) ^ mul3(s3),
                mul3(s0)  ^ s1        ^ s2        ^ xtime(s3)
            };
        end
    endfunction
    
    // Post matrix multiplication we obtain 4 words
    // Later given as input to round key operation. 
    assign state_out = {
        mix_one_column(b0,  b1,  b2,  b3),
        mix_one_column(b4,  b5,  b6,  b7),
        mix_one_column(b8,  b9,  b10, b11),
        mix_one_column(b12, b13, b14, b15)
    };
endmodule