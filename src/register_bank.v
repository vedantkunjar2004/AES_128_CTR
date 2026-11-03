// Register map (word-aligned, reg_addr = paddr[6:2]):
//   0x00 CTRL          RW   bit0 KEY_LOAD (pulse) | bit1 IV_LOAD (pulse)
//                            bit2 PT_PUSH (pulse)  | bit3 ZEROIZE (pulse)
//                            bit4 KEY_LOCK (W1S, sticky, clears on reset only)
//   0x04 STATUS        RO   bit0 BUSY | bit1 KEY_READY | bit2 TX_FIFO_FULL
//                            bit3 RX_FIFO_EMPTY | bit4 SEC_VIOLATION (W1C)
//   0x10-0x1C KEY0-KEY3 WO  privileged, always reads 0 (S1)
//   0x20-0x2C IV0-IV3   RW
//   0x30-0x3C PT0-PT3   RW  (staging only, pushed to TX FIFO on PT_PUSH)
//   0x40-0x4C CT0-CT3   RO  reads 0 until a fresh result is ready (S6);
//                            read CT0 to CT1 to CT2 to CT3 in that order,
//                            the CT3 read marks this result consumed and
//                            lets the next queued result advance into place.
//   0x50 CYCLE_COUNT    RO  DV hook for S4 (constant-time check)
//
// KEY0/IV0/PT0/CT0 hold the most significant 32 bits of their 128-bit
// value; word3 holds the least significant 32 bits.


module register_bank (
    input  wire         pclk,
    input  wire         presetn,

    // internal register-file bus, from apb4_interface
    input  wire [4:0]   reg_addr,
    input  wire [31:0]  reg_wdata,
    input  wire [3:0]   reg_wstrb,
    input  wire         reg_wen,
    input  wire         reg_ren,
    input  wire [2:0]   reg_pprot,      // reg_pprot[0]: 1 = privileged (APB4 PPROT[0] convention)
    output reg  [31:0]  reg_rdata,
    output wire         reg_err,

    // quasi-static key/IV bus plus one-cycle pclk strobes
    output reg  [127:0] key_bus,
    output wire          key_load_pulse,
    output reg  [127:0] iv_bus,
    output wire          iv_load_pulse,
    output wire          zeroize_pulse,

    // TX FIFO write port (wr_clk = pclk side of async_fifo)
    output wire [127:0] tx_wr_data,
    output wire          tx_wr_en,
    input  wire          tx_full,

    // RX FIFO read port (rd_clk = pclk side of async_fifo)
    output wire          rx_rd_en,
    input  wire [127:0] rx_rd_data,
    input  wire          rx_empty,

    // status, already synchronized into the pclk domain upstream
    input  wire          busy_sync,
    input  wire          key_ready_sync,
    input  wire [31:0]  cycle_count_sync
);

    // address map
    localparam ADDR_CTRL         = 5'd0;
    localparam ADDR_STATUS       = 5'd1;
    localparam GRP_KEY           = 3'd1;   // reg_addr[4:2]==1 -> 0x10-0x1C
    localparam GRP_IV            = 3'd2;   // 0x20-0x2C
    localparam GRP_PT            = 3'd3;   // 0x30-0x3C
    localparam GRP_CT            = 3'd4;   // 0x40-0x4C
    localparam ADDR_CYCLE_COUNT  = 5'd20;  // 0x50

    wire [2:0] grp      = reg_addr[4:2];
    wire [1:0] word_sel = reg_addr[1:0];

    wire is_ctrl_reg = (reg_addr == ADDR_CTRL);
    wire is_key_grp  = (grp == GRP_KEY);
    wire is_iv_grp   = (grp == GRP_IV);
    wire is_pt_grp   = (grp == GRP_PT);
    wire is_ct_grp   = (grp == GRP_CT);

    // S5: privilege gating
    // CTRL and KEY0-3 are the security registers in scope for S5. This
    // means PT_PUSH also requires PPROT[0] - confirm that's intentional.
    wire is_security_reg = is_ctrl_reg || is_key_grp;
    wire priv_ok          = reg_pprot[0];
    wire unpriv_access     = (reg_wen | reg_ren) & is_security_reg & ~priv_ok;

    // S2: sticky KEY_LOCK
    reg key_lock;

    always @(posedge pclk or negedge presetn) begin
        if (!presetn)
            key_lock <= 1'b0;
        else if (reg_wen && is_ctrl_reg && !unpriv_access && reg_wstrb[0] && reg_wdata[4])
            key_lock <= 1'b1;   // W1S, cannot be cleared by software, only by presetn
    end

    // CTRL pulses (single pclk cycle, aligned with the write itself)
    wire pt_push_attempt = reg_wen && is_ctrl_reg && !unpriv_access && reg_wstrb[0] && reg_wdata[2];
    wire pt_push_dropped = pt_push_attempt && tx_full;

    assign key_load_pulse = reg_wen && is_ctrl_reg && !unpriv_access && reg_wstrb[0] && reg_wdata[0];
    assign iv_load_pulse  = reg_wen && is_ctrl_reg && !unpriv_access && reg_wstrb[0] && reg_wdata[1];
    assign zeroize_pulse  = reg_wen && is_ctrl_reg && !unpriv_access && reg_wstrb[0] && reg_wdata[3];

    reg [127:0] pt_bus;
    assign tx_wr_en   = pt_push_attempt && !tx_full;
    assign tx_wr_data = pt_bus;

    assign reg_err = unpriv_access | pt_push_dropped;

    // S3: zeroize
    // zeroize_pulse also feeds the crypto_clk domain (key_expansion
    // RAM, round-datapath pipeline regs) via the top-level
    // synchronizer, already implemented inside aes_engine.v. Here we
    // only clear the staged copy so a stale key can't be reloaded by
    // firing KEY_LOAD again without new writes.

    // KEY0-3
    // Byte-lane merge, one case arm per word_sel - every index below
    // is a compile-time constant (see file header: lint fix for
    // ImproperRangeIndex-ML).
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            key_bus <= 128'd0;
        end else if (zeroize_pulse) begin
            key_bus <= 128'd0;
        end else if (reg_wen && is_key_grp && !unpriv_access && !key_lock) begin
            case (word_sel)
                2'd0: begin
                    if (reg_wstrb[0]) key_bus[96 +: 8]  <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) key_bus[104 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) key_bus[112 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) key_bus[120 +: 8] <= reg_wdata[24 +: 8];
                end
                2'd1: begin
                    if (reg_wstrb[0]) key_bus[64 +: 8] <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) key_bus[72 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) key_bus[80 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) key_bus[88 +: 8] <= reg_wdata[24 +: 8];
                end
                2'd2: begin
                    if (reg_wstrb[0]) key_bus[32 +: 8] <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) key_bus[40 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) key_bus[48 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) key_bus[56 +: 8] <= reg_wdata[24 +: 8];
                end
                default: begin
                    if (reg_wstrb[0]) key_bus[0 +: 8]  <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) key_bus[8 +: 8]  <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) key_bus[16 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) key_bus[24 +: 8] <= reg_wdata[24 +: 8];
                end
            endcase
        end
    end

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            iv_bus <= 128'd0;
        end else if (reg_wen && is_iv_grp) begin
            case (word_sel)
                2'd0: begin
                    if (reg_wstrb[0]) iv_bus[96 +: 8]  <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) iv_bus[104 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) iv_bus[112 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) iv_bus[120 +: 8] <= reg_wdata[24 +: 8];
                end
                2'd1: begin
                    if (reg_wstrb[0]) iv_bus[64 +: 8] <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) iv_bus[72 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) iv_bus[80 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) iv_bus[88 +: 8] <= reg_wdata[24 +: 8];
                end
                2'd2: begin
                    if (reg_wstrb[0]) iv_bus[32 +: 8] <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) iv_bus[40 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) iv_bus[48 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) iv_bus[56 +: 8] <= reg_wdata[24 +: 8];
                end
                default: begin
                    if (reg_wstrb[0]) iv_bus[0 +: 8]  <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) iv_bus[8 +: 8]  <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) iv_bus[16 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) iv_bus[24 +: 8] <= reg_wdata[24 +: 8];
                end
            endcase
        end
    end

    // PT0-3 (staging only)
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            pt_bus <= 128'd0;
        end else if (reg_wen && is_pt_grp) begin
            case (word_sel)
                2'd0: begin
                    if (reg_wstrb[0]) pt_bus[96 +: 8]  <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) pt_bus[104 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) pt_bus[112 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) pt_bus[120 +: 8] <= reg_wdata[24 +: 8];
                end
                2'd1: begin
                    if (reg_wstrb[0]) pt_bus[64 +: 8] <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) pt_bus[72 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) pt_bus[80 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) pt_bus[88 +: 8] <= reg_wdata[24 +: 8];
                end
                2'd2: begin
                    if (reg_wstrb[0]) pt_bus[32 +: 8] <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) pt_bus[40 +: 8] <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) pt_bus[48 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) pt_bus[56 +: 8] <= reg_wdata[24 +: 8];
                end
                default: begin
                    if (reg_wstrb[0]) pt_bus[0 +: 8]  <= reg_wdata[0  +: 8];
                    if (reg_wstrb[1]) pt_bus[8 +: 8]  <= reg_wdata[8  +: 8];
                    if (reg_wstrb[2]) pt_bus[16 +: 8] <= reg_wdata[16 +: 8];
                    if (reg_wstrb[3]) pt_bus[24 +: 8] <= reg_wdata[24 +: 8];
                end
            endcase
        end
    end


    reg [127:0] ct_shadow;
    reg         rx_rd_en_d;
    reg         ct_valid;

    wire rx_rd_en_int = !rx_empty && !ct_valid;
    assign rx_rd_en = rx_rd_en_int;

    // software must read CT0 to CT1 to CT2 to CT3 in that order; the
    // CT3 read is what marks this result consumed
    wire ct_consumed = reg_ren && is_ct_grp && (word_sel == 2'd3);

    always @(posedge pclk or negedge presetn) begin
        if (!presetn)
            rx_rd_en_d <= 1'b0;
        else
            rx_rd_en_d <= rx_rd_en_int;
    end

    always @(posedge pclk or negedge presetn) begin
        if (!presetn)
            ct_shadow <= 128'd0;
        else if (rx_rd_en_d)
            ct_shadow <= rx_rd_data;
    end

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ct_valid <= 1'b0;
        end else if (zeroize_pulse) begin
            ct_valid <= 1'b0;
        end else if (rx_rd_en_d) begin
            ct_valid <= 1'b1;
        end else if (ct_consumed) begin
            ct_valid <= 1'b0;
        end
    end
    
    reg sec_violation;
    always @(posedge pclk or negedge presetn) begin
        if (!presetn)
            sec_violation <= 1'b0;
        else if (unpriv_access)
            sec_violation <= 1'b1;
        else if (reg_wen && reg_addr == ADDR_STATUS && reg_wstrb[0] && reg_wdata[4])
            sec_violation <= 1'b0;
    end

    // PRDATA mux
    // IV/PT/CT reads: one case arm per word_sel, same reasoning as the
    // write side above - every index is a compile-time constant.
    always @(*) begin
        case (reg_addr)
            ADDR_CTRL:         reg_rdata = {27'd0, key_lock, 4'd0};   // strobes read back 0
            ADDR_STATUS:       reg_rdata = {27'd0, sec_violation, rx_empty, tx_full,
                                             key_ready_sync, busy_sync};
            ADDR_CYCLE_COUNT:  reg_rdata = cycle_count_sync;
            default: begin
                if (is_key_grp) begin
                    reg_rdata = 32'd0;                                    // S1
                end else if (is_iv_grp) begin
                    case (word_sel)
                        2'd0:    reg_rdata = iv_bus[96 +: 32];
                        2'd1:    reg_rdata = iv_bus[64 +: 32];
                        2'd2:    reg_rdata = iv_bus[32 +: 32];
                        default: reg_rdata = iv_bus[0  +: 32];
                    endcase
                end else if (is_pt_grp) begin
                    case (word_sel)
                        2'd0:    reg_rdata = pt_bus[96 +: 32];
                        2'd1:    reg_rdata = pt_bus[64 +: 32];
                        2'd2:    reg_rdata = pt_bus[32 +: 32];
                        default: reg_rdata = pt_bus[0  +: 32];
                    endcase
                end else if (is_ct_grp) begin
                    if (!ct_valid) begin
                        reg_rdata = 32'd0;                                // S6
                    end else begin
                        case (word_sel)
                            2'd0:    reg_rdata = ct_shadow[96 +: 32];
                            2'd1:    reg_rdata = ct_shadow[64 +: 32];
                            2'd2:    reg_rdata = ct_shadow[32 +: 32];
                            default: reg_rdata = ct_shadow[0  +: 32];
                        endcase
                    end
                end else begin
                    reg_rdata = 32'd0;                                    // unmapped
                end
            end
        endcase
    end

endmodule