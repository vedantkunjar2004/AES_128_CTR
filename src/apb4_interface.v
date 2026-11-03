// Pure APB4 protocol shim. Holds no state and no security logic - it
// just decodes the SETUP/ACCESS phase and forwards a flat internal
// register-file bus to register_bank. This is a zero-wait-state slave:
// every access completes in the ACCESS cycle it starts in (PREADY tied
// high), which is legal for APB4 and works here since every register
// in register_bank is a single-cycle read/write.
//
// If a future register needs to stall (e.g. TX FIFO backpressure using
// wait states instead of a dropped-push error), that logic belongs
// here, driven by a hold input from register_bank. Not implemented yet -
// see the PT_PUSH handling in register_bank.v for the current approach.

module apb4_interface #(
    parameter PADDR_WIDTH = 7          // paddr[6:2] maps to the 5-bit reg_addr (32 word slots)
)(
    // APB4 slave port (processor side)
    //input  wire                     pclk,
    //input  wire                     presetn,
    input  wire [PADDR_WIDTH-1:0]   paddr,
    input  wire                     psel,
    input  wire                     penable,
    input  wire                     pwrite,
    input  wire [31:0]              pwdata,
    input  wire [3:0]               pstrb,
    input  wire [2:0]               pprot,
    output wire                     pready,
    output wire [31:0]              prdata,
    output wire                     pslverr,

    // internal register-file bus (register_bank side)
    output wire [4:0]               reg_addr,
    output wire [31:0]              reg_wdata,
    output wire [3:0]               reg_wstrb,
    output wire                     reg_wen,
    output wire                     reg_ren,
    output wire [2:0]               reg_pprot,
    input  wire [31:0]              reg_rdata,
    input  wire                     reg_err
);

       // ACCESS phase: PSEL and PENABLE are both driven by the master;
    // the slave just samples them combinationally each cycle.
    wire access_phase = psel & penable;
    
    assign reg_addr  = paddr[6:2];
    assign reg_wdata = pwdata;
    assign reg_wstrb = pstrb;
    assign reg_pprot = pprot;
    assign reg_wen   = access_phase & pwrite;
    assign reg_ren   = access_phase & ~pwrite;
    
    assign pready  = 1'b1;                 // zero-wait-state slave
    assign prdata  = reg_rdata;
    assign pslverr = access_phase & reg_err;

endmodule