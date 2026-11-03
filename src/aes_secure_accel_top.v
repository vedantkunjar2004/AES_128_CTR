module aes_crypto_accel_top #(
    parameter PADDR_WIDTH    = 7,
    parameter TX_FIFO_ADDR_W = 4,   // TX FIFO depth = 2^TX_FIFO_ADDR_W blocks
    parameter RX_FIFO_ADDR_W = 4    // RX FIFO depth = 2^RX_FIFO_ADDR_W blocks
)(
    // pclk domain: APB4 slave port
    input  wire                   pclk,
    input  wire                   presetn,
    input  wire [PADDR_WIDTH-1:0] paddr,
    input  wire                   psel,
    input  wire                   penable,
    input  wire                   pwrite,
    input  wire [31:0]            pwdata,
    input  wire [3:0]             pstrb,
    input  wire [2:0]             pprot,
    output wire                   pready,
    output wire [31:0]            prdata,
    output wire                   pslverr,

    // crypto_clk domain
    input  wire                   crypto_clk,
    input  wire                   crypto_rst_n
);

    // internal register-file bus between apb4_interface and register_bank
    wire [4:0]  reg_addr;
    wire [31:0] reg_wdata;
    wire [3:0]  reg_wstrb;
    wire        reg_wen, reg_ren;
    wire [2:0]  reg_pprot;
    wire [31:0] reg_rdata;
    wire        reg_err;

    apb4_interface #(
        .PADDR_WIDTH (PADDR_WIDTH)
    ) u_apb4_interface (
        .paddr     (paddr),
        .psel      (psel),
        .penable   (penable),
        .pwrite    (pwrite),
        .pwdata    (pwdata),
        .pstrb     (pstrb),
        .pprot     (pprot),
        .pready    (pready),
        .prdata    (prdata),
        .pslverr   (pslverr),
        .reg_addr  (reg_addr),
        .reg_wdata (reg_wdata),
        .reg_wstrb (reg_wstrb),
        .reg_wen   (reg_wen),
        .reg_ren   (reg_ren),
        .reg_pprot (reg_pprot),
        .reg_rdata (reg_rdata),
        .reg_err   (reg_err)
    );

    // register_bank signals that feed into the CDC logic below
    wire [127:0] key_bus, iv_bus;
    wire         key_load_pulse, iv_load_pulse, zeroize_pulse;

    wire [127:0] tx_wr_data;
    wire         tx_wr_en, tx_full;

    wire [127:0] rx_rd_data;
    wire         rx_rd_en, rx_empty;

    wire         busy_sync, key_ready_sync;
    wire [31:0]  cycle_count_sync;   // driven by the CYCLE_COUNT fifo's read data below

    register_bank u_register_bank (
        .pclk      (pclk),
        .presetn   (presetn),

        .reg_addr  (reg_addr),
        .reg_wdata (reg_wdata),
        .reg_wstrb (reg_wstrb),
        .reg_wen   (reg_wen),
        .reg_ren   (reg_ren),
        .reg_pprot (reg_pprot),
        .reg_rdata (reg_rdata),
        .reg_err   (reg_err),

        .key_bus        (key_bus),
        .key_load_pulse (key_load_pulse),
        .iv_bus         (iv_bus),
        .iv_load_pulse  (iv_load_pulse),
        .zeroize_pulse  (zeroize_pulse),

        .tx_wr_data (tx_wr_data),
        .tx_wr_en   (tx_wr_en),
        .tx_full    (tx_full),

        .rx_rd_en   (rx_rd_en),
        .rx_rd_data (rx_rd_data),
        .rx_empty   (rx_empty),

        .busy_sync        (busy_sync),
        .key_ready_sync   (key_ready_sync),
        .cycle_count_sync (cycle_count_sync)
    );

    // TX FIFO: plaintext, pclk to crypto_clk
    wire [127:0] tx_fifo_rd_data;
    wire         tx_fifo_rd_en, tx_fifo_empty;

    async_fifo #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (TX_FIFO_ADDR_W)
    ) u_tx_fifo (
        .wr_clk   (pclk),
        .wr_rst_n (presetn),
        .wr_en    (tx_wr_en),
        .wr_data  (tx_wr_data),
        .full     (tx_full),

        .rd_clk   (crypto_clk),
        .rd_rst_n (crypto_rst_n),
        .rd_en    (tx_fifo_rd_en),
        .rd_data  (tx_fifo_rd_data),
        .empty    (tx_fifo_empty)
    );

    // RX FIFO: ciphertext, crypto_clk to pclk
    wire [127:0] rx_fifo_wr_data;
    wire         rx_fifo_wr_en, rx_fifo_full;

    async_fifo #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (RX_FIFO_ADDR_W)
    ) u_rx_fifo (
        .wr_clk   (crypto_clk),
        .wr_rst_n (crypto_rst_n),
        .wr_en    (rx_fifo_wr_en),
        .wr_data  (rx_fifo_wr_data),
        .full     (rx_fifo_full),

        .rd_clk   (pclk),
        .rd_rst_n (presetn),
        .rd_en    (rx_rd_en),
        .rd_data  (rx_rd_data),
        .empty    (rx_empty)
    );

    // control pulse crossings: pclk to crypto_clk
    wire key_load_pulse_sync, iv_load_pulse_sync, zeroize_sync;

    cdc_pulse_sync u_key_load_sync (
        .src_clk (pclk),       .src_rst_n (presetn),      .src_in    (key_load_pulse),
        .dst_clk (crypto_clk), .dst_rst_n (crypto_rst_n), .dst_pulse (key_load_pulse_sync)
    );

    cdc_pulse_sync u_iv_load_sync (
        .src_clk (pclk),       .src_rst_n (presetn),      .src_in    (iv_load_pulse),
        .dst_clk (crypto_clk), .dst_rst_n (crypto_rst_n), .dst_pulse (iv_load_pulse_sync)
    );

    cdc_pulse_sync u_zeroize_sync (
        .src_clk (pclk),       .src_rst_n (presetn),      .src_in    (zeroize_pulse),
        .dst_clk (crypto_clk), .dst_rst_n (crypto_rst_n), .dst_pulse (zeroize_sync)
    );

    // control_fsm and aes_engine both run on crypto_clk, so no CDC needed between them
    wire         aes_key_load, aes_iv_load, aes_zeroize, aes_start;
    wire [127:0] aes_key_in, aes_iv_in, aes_data_in, aes_data_out;
    wire         aes_key_ready, aes_busy, aes_done;
    wire [31:0]  cycle_count_hold;
    wire         cycle_count_valid;

    control_fsm u_control_fsm (
        .clk   (crypto_clk),
        .rst_n (crypto_rst_n),

        .key_load_pulse_sync (key_load_pulse_sync),
        .iv_load_pulse_sync  (iv_load_pulse_sync),
        .zeroize_sync        (zeroize_sync),

        .key_bus (key_bus),
        .iv_bus  (iv_bus),

        .tx_fifo_rd_en   (tx_fifo_rd_en),
        .tx_fifo_rd_data (tx_fifo_rd_data),
        .tx_fifo_empty   (tx_fifo_empty),

        .rx_fifo_wr_en   (rx_fifo_wr_en),
        .rx_fifo_wr_data (rx_fifo_wr_data),
        .rx_fifo_full    (rx_fifo_full),

        .aes_key_load  (aes_key_load),
        .aes_key_in    (aes_key_in),
        .aes_key_ready (aes_key_ready),
        .aes_iv_load   (aes_iv_load),
        .aes_iv_in     (aes_iv_in),
        .aes_zeroize   (aes_zeroize),
        .aes_start     (aes_start),
        .aes_data_in   (aes_data_in),
        .aes_busy      (aes_busy),
        .aes_done      (aes_done),
        .aes_data_out  (aes_data_out),

        .cycle_count_hold (cycle_count_hold),
        .cycle_count_valid (cycle_count_valid)
    );

    aes_engine u_aes_engine (
        .clk       (crypto_clk),
        .rst_n     (crypto_rst_n),
        .zeroize   (aes_zeroize),

        .key_load  (aes_key_load),
        .key_in    (aes_key_in),
        .key_ready (aes_key_ready),

        .iv_load   (aes_iv_load),
        .iv_in     (aes_iv_in),

        .start     (aes_start),
        .data_in   (aes_data_in),
        .busy      (aes_busy),
        .done      (aes_done),
        .data_out  (aes_data_out)
    );

    // status crossings: crypto_clk to pclk
    cdc_level_sync_robust u_busy_sync (
        .src_clk (crypto_clk), .src_rst_n (crypto_rst_n), .src_in  (aes_busy),
        .dst_clk (pclk),       .dst_rst_n (presetn),      .dst_out (busy_sync)
    );

    cdc_level_sync_robust u_key_ready_sync (
        .src_clk (crypto_clk), .src_rst_n (crypto_rst_n), .src_in  (aes_key_ready),
        .dst_clk (pclk),       .dst_rst_n (presetn),      .dst_out (key_ready_sync)
    );

    // CYCLE_COUNT: dedicated async_fifo, crypto_clk to pclk.
    // cycle_count_hold updates on the same crypto_clk edge that
    // cycle_count_valid pulses, so it still holds the previous block's
    // value during the cycle the pulse actually fires. The enable is
    // re-registered by one cycle here so it lines up with
    // cycle_count_hold's settled value, then both are handed to an
    // async_fifo. The fifo drops (never corrupts) an update that lands
    // while it's momentarily full, which is the right behavior for a
    // "latest known" status register.
    reg cycle_count_valid_d1;
    always @(posedge crypto_clk or negedge crypto_rst_n) begin
        if (!crypto_rst_n)
            cycle_count_valid_d1 <= 1'b0;
        else
            cycle_count_valid_d1 <= cycle_count_valid;
    end

    wire [31:0] cyc_count_fifo_rd_data;
    wire        cyc_count_fifo_empty, cyc_count_fifo_full;

    async_fifo #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (2)
    ) u_cycle_count_fifo (
        .wr_clk   (crypto_clk),
        .wr_rst_n (crypto_rst_n),
        .wr_en    (cycle_count_valid_d1),
        .wr_data  (cycle_count_hold),
        .full     (cyc_count_fifo_full),

        .rd_clk   (pclk),
        .rd_rst_n (presetn),
        .rd_en    (~cyc_count_fifo_empty),
        .rd_data  (cyc_count_fifo_rd_data),
        .empty    (cyc_count_fifo_empty)
    );

    assign cycle_count_sync = cyc_count_fifo_rd_data;

endmodule