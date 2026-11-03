module async_fifo #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 4              // FIFO depth = 2^ADDR_WIDTH entries
)(
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg                   full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output reg                   empty
);

    localparam DEPTH = (1 << ADDR_WIDTH);

    // Dual-port memory: written in wr_clk domain, read in rd_clk domain
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // write domain registers
    reg  [ADDR_WIDTH:0] wptr_bin, wptr_gray; // 1 extra bit for full logic
    reg  [ADDR_WIDTH:0] rptr_gray_wsync1, rptr_gray_wsync2;  // read ptr, synced in

    // If wr_en is high and fifo isnt full then wptr binary is incremented by 1 
    wire [ADDR_WIDTH:0] wptr_bin_next   = wptr_bin + (wr_en & ~full); 
    
    // Binary to gray conversion of wptr_bin_next
    wire [ADDR_WIDTH:0] wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;
    
    // Full logic: lap bit method: MSB of wptr and rptr are compared in graycode 
    // In gray code a full lap difference is represented by 2 top MSBs inverted while rest bits are exactly same. 
    wire full_next = (wptr_gray_next == {~rptr_gray_wsync2[ADDR_WIDTH:ADDR_WIDTH-1], rptr_gray_wsync2[ADDR_WIDTH-2:0]});


    // read domain registers
    reg  [ADDR_WIDTH:0] rptr_bin, rptr_gray; // 1 extra bit for empty logic
    reg  [ADDR_WIDTH:0] wptr_gray_rsync1, wptr_gray_rsync2;  // write ptr, synced in

    // If rd_en is high and fifo isnt empty then rptr binary is incremented by 1 
    wire [ADDR_WIDTH:0] rptr_bin_next   = rptr_bin + (rd_en & ~empty);
    
    // Binary to gray conversion of rptr_bin_next
    wire [ADDR_WIDTH:0] rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;
    
    // Empty logic: If all bits of  wptr and rptr are completely same then fifo is empty
    wire empty_next = (rptr_gray_next == wptr_gray_rsync2);


    // write domain logic
    // Synchronized rptr_gray in wr_clk domain
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rptr_gray_wsync1 <= 0;
            rptr_gray_wsync2 <= 0;
        end else begin
            rptr_gray_wsync1 <= rptr_gray;
            rptr_gray_wsync2 <= rptr_gray_wsync1;
        end
    end

    // Write Pointer and Flag Logic 
    // if reset then wptr is reset to 0 and full is also reset to 0
    // else wptr is updated with the current value of wptr_next
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wptr_bin  <= 0;
            wptr_gray <= 0;
            full      <= 1'b0;
        end else begin
            wptr_bin  <= wptr_bin_next;
            wptr_gray <= wptr_gray_next;
            full      <= full_next;
        end
    end
     
    // Missing asynchronous reset signal because the standard BRAM/SRAM cells dont have the reset port in them.
    // Probably will throw a lint error that can be waived.
    // if wr_en is high and fifo is not full,
    // then the wr_data replaces whatever is present in the addr location of wptr in the memory.
    always @(posedge wr_clk) begin
        if (wr_en && !full) begin
            mem[wptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end


    // read domain logic
    // Synchronized write pointer in rd_clk domain
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wptr_gray_rsync1 <= 0;
            wptr_gray_rsync2 <= 0;
        end else begin
            wptr_gray_rsync1 <= wptr_gray;
            wptr_gray_rsync2 <= wptr_gray_rsync1;
        end
    end

    // if reset then pass 0 as output
    // If rd_en is high and fifo is not empty
    // then rd_data is given the value of whatever is present in the memory address of rptr.
    // And the rptr is incremented 
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rptr_bin  <= 0;
            rptr_gray <= 0;
            rd_data   <= {DATA_WIDTH{1'b0}};
            empty     <= 1'b1;
        end else begin
            if (rd_en && !empty) 
                rd_data <= mem[rptr_bin[ADDR_WIDTH-1:0]];
            rptr_bin  <= rptr_bin_next;
            rptr_gray <= rptr_gray_next;
            empty     <= empty_next;
        end
    end

endmodule