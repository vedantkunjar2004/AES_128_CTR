// Simply substitutes the input vector of 16 bytes with the corresponding values
// present inside the Sbox and gives out the substituted values as input for next process (Shift rows).
module sub_bytes (
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    genvar i;
    //indexed part select starting with (127 - i*8) and with constant width 8 
    generate
        for (i = 0; i < 16; i = i + 1) begin : byte_sub
            sbox sbox_inst (
                .byte_in  (state_in[127 - i*8 -: 8]), 
                .byte_out (state_out[127 - i*8 -: 8])
            );
        end
    endgenerate
endmodule