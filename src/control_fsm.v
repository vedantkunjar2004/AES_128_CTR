// Crypto_clk domain sequencer, sitting between the TX/RX async FIFOs
// and aes_engine. It pops one plaintext block from the TX FIFO, drives
// aes_engine through one block of CTR encryption, and pushes the
// resulting ciphertext into the RX FIFO - one block at a time, fully
// serialized. A new block is never started until the previous block's
// ciphertext has been pushed to the RX FIFO, which keeps aes_engine's
// internal data_out_held register safe: it is never overwritten by a
// new block before this FSM has consumed the old result.
//
// All *_sync inputs are assumed already synchronized upstream (via
// cdc_pulse_sync) before they reach this module - this module itself
// has no CDC logic, the same discipline register_bank.v follows on the
// pclk side.
//
// KEY_LOAD / IV_LOAD are only forwarded to aes_engine when this FSM is
// genuinely idle and the TX FIFO is empty (fsm_idle below), not just
// when aes_busy is 0. aes_busy reads 0 during the pop-wait/push states
// around a block too, so forwarding a key/IV change during one of
// those windows could let key_expansion start overwriting its
// round-key RAM while round_datapath is still reading from it for a
// block in flight. Software must not issue KEY_LOAD or IV_LOAD while
// STATUS.BUSY is set or the TX FIFO still holds queued plaintext - a
// pulse arriving under those conditions is dropped, not queued. This
// is deliberate: queueing it would leave KEY_READY showing a stale
// ready state while software believes the new key already took
// effect, which is worse than a documented, predictable drop.
//
// ZEROIZE is the one exception: it is wired straight through to
// aes_engine every cycle, unconditionally, so a wipe takes effect
// immediately regardless of what else is going on. It also resets
// this FSM back to IDLE, abandoning any block in flight, since
// waiting for a done pulse from a computation that was just wiped
// would otherwise deadlock the FSM.

module control_fsm (
    input  wire          clk,        // crypto_clk
    input  wire          rst_n,

    // synchronized control pulses (one cdc_pulse_sync instance each, at top level)
    input  wire          key_load_pulse_sync,
    input  wire          iv_load_pulse_sync,
    input  wire          zeroize_sync,

    // quasi-static data buses, wired straight from register_bank
    input  wire [127:0]  key_bus,
    input  wire [127:0]  iv_bus,

    // TX FIFO, crypto_clk read side
    output reg            tx_fifo_rd_en,
    input  wire [127:0]  tx_fifo_rd_data,
    input  wire           tx_fifo_empty,

    // RX FIFO, crypto_clk write side
    output reg            rx_fifo_wr_en,
    output reg  [127:0]  rx_fifo_wr_data,
    input  wire           rx_fifo_full,

    // aes_engine control interface, names mirror aes_engine.v's ports directly
    output reg            aes_key_load,
    output reg  [127:0]  aes_key_in,
    input  wire           aes_key_ready,
    output reg            aes_iv_load,
    output reg  [127:0]  aes_iv_in,
    output wire           aes_zeroize,
    output reg            aes_start,
    output wire [127:0]  aes_data_in,
    input  wire           aes_busy,
    input  wire           aes_done,
    input  wire [127:0]  aes_data_out,

    // DV hook: cycles taken by the most recently completed block
    output reg  [31:0]   cycle_count_hold,
    output wire           cycle_count_valid   // one-cycle pulse: cycle_count_hold just changed
);

    // ZEROIZE: unconditional, immediate passthrough
    assign aes_zeroize = zeroize_sync;

    // aes_data_in is only ever driven from tx_fifo_rd_data, and is only
    // sampled by aes_engine on the one cycle aes_start is asserted
    // (S_START below). It's safe to wire this combinationally with no
    // capture register: tx_fifo_rd_data does not change again until
    // this FSM issues the next tx_fifo_rd_en pulse, which happens well
    // after S_START.
    assign aes_data_in = tx_fifo_rd_data;

    // main block sequencer
    localparam S_IDLE      = 3'd0;
    localparam S_POP_WAIT  = 3'd1;  // one cycle for async_fifo's registered read to catch up
    localparam S_START     = 3'd2;
    localparam S_WAIT_DONE = 3'd3;
    localparam S_PUSH      = 3'd4;

    reg [2:0] state, next_state;

    // Every output gets a default at the top of this block, before the
    // case statement, so every signal is defined on every path through
    // it - no risk of inferring a latch.
    always @(*) begin
        next_state    = state;
        tx_fifo_rd_en = 1'b0;
        aes_start     = 1'b0;
        rx_fifo_wr_en = 1'b0;

        case (state)
            S_IDLE: begin
                // Don't try to pop a block until a key has actually
                // finished expanding. aes_engine's own start gate also
                // checks key_ready internally, so if aes_start were
                // asserted anyway without this check, it would be
                // silently swallowed inside aes_engine and this FSM
                // would sit in S_WAIT_DONE forever waiting for a done
                // pulse that never arrives - a real deadlock.
                if (!tx_fifo_empty && aes_key_ready && !aes_busy) begin
                    tx_fifo_rd_en = 1'b1;
                    next_state    = S_POP_WAIT;
                end
                // This branch and the KEY_LOAD/IV_LOAD forwarding below
                // (gated on fsm_idle, which requires tx_fifo_empty) can
                // never both fire in the same cycle - they depend on
                // opposite values of tx_fifo_empty, so they're mutually
                // exclusive by construction.
            end

            S_POP_WAIT: begin
                // tx_fifo_rd_data becomes valid starting next cycle,
                // since async_fifo registers its read output one cycle
                // after rd_en is sampled high. Nothing to drive this
                // cycle, just let it land.
                next_state = S_START;
            end

            S_START: begin
                // tx_fifo_rd_data (= aes_data_in) is valid now.
                aes_start  = 1'b1;
                next_state = S_WAIT_DONE;
            end

            S_WAIT_DONE: begin
                if (aes_done)
                    next_state = S_PUSH;
                // aes_data_out is valid the same cycle aes_done pulses,
                // and stays valid on every cycle after that too, since
                // aes_engine latches it into its own data_out_held
                // register the cycle after done pulses. That's what
                // makes it safe to move to S_PUSH and use aes_data_out
                // there even several cycles later if rx_fifo_full
                // stalls us.
            end

            S_PUSH: begin
                if (!rx_fifo_full) begin
                    rx_fifo_wr_en = 1'b1;
                    next_state    = S_IDLE;
                end
                // Otherwise stay here, rx_fifo_wr_en stays low and we
                // retry next cycle. This is the intended backpressure
                // path when software is slow to read the previous
                // ciphertext out of register_bank - it ripples back to
                // here, and from here (by not popping TX again until
                // back in S_IDLE) further back to register_bank's
                // tx_full/pt_push_dropped path. No separate flow
                // control signal is needed.
            end

            default: next_state = S_IDLE;  // unreachable in normal operation, recovers if ever hit
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else if (zeroize_sync)
            state <= S_IDLE;   // abandon any block in flight on a wipe, see header comment
        else
            state <= next_state;
    end

    // rx_fifo_wr_data only needs to be valid on the cycle rx_fifo_wr_en
    // is high, which only happens in S_PUSH once aes_data_out is
    // already valid, so it's safe to wire this combinationally.
    always @(*) begin
        rx_fifo_wr_data = aes_data_out;
    end

    // KEY_LOAD / IV_LOAD forwarding
    wire fsm_idle = (state == S_IDLE) && tx_fifo_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aes_key_load <= 1'b0;
            aes_key_in   <= 128'd0;
        end else begin
            aes_key_load <= 1'b0;   // default: single-cycle pulse
            if (key_load_pulse_sync && fsm_idle) begin
                aes_key_load <= 1'b1;
                aes_key_in   <= key_bus;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aes_iv_load <= 1'b0;
            aes_iv_in   <= 128'd0;
        end else begin
            aes_iv_load <= 1'b0;    // default: single-cycle pulse
            if (iv_load_pulse_sync && fsm_idle) begin
                aes_iv_load <= 1'b1;
                aes_iv_in   <= iv_bus;
            end
        end
    end

    // DV hook: cycle counter. Counts cycles from aes_start to aes_done
    // for the block currently in flight, then latches the count into
    // cycle_count_hold and holds it there until the next block starts.
    // This is quasi-static, the same as key_bus/iv_bus, and safe to
    // sample with the pulse-qualified sync used for cycle_count_sync
    // at the top level.
    //
    // This deliberately measures only aes_start-to-aes_done (always
    // exactly 11 cycles by round_datapath's construction, regardless
    // of key or data), not the surrounding FIFO pop/push overhead. The
    // point of this hook is to confirm the crypto computation itself
    // doesn't leak timing information through key/data-dependent
    // variation. Pipeline plumbing overhead, such as an S_PUSH
    // backpressure stall, is real system-level latency but has nothing
    // to do with the cipher, and including it here would make an
    // otherwise constant-time core look non-constant-time for reasons
    // unrelated to the cipher.
    reg [31:0] cycle_counter;
    reg        counting;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter    <= 32'd0;
            counting         <= 1'b0;
            cycle_count_hold <= 32'd0;
        end else if (zeroize_sync) begin
            cycle_counter    <= 32'd0;
            counting         <= 1'b0;
            cycle_count_hold <= 32'd0;
        end else if (aes_start) begin
            cycle_counter <= 32'd1;
            counting      <= 1'b1;
        end else if (counting) begin
            if (aes_done) begin
                cycle_count_hold <= cycle_counter;
                counting         <= 1'b0;
            end else begin
                cycle_counter <= cycle_counter + 32'd1;
            end
        end
    end

    // Pulses exactly one crypto_clk cycle on every cycle_count_hold
    // update above (both the normal aes_done capture and the zeroize
    // clear). This is what lets the pclk side capture the bus safely
    // without a per-bit sync on a multi-bit value, see
    // aes_secure_accel_top.v.
    assign cycle_count_valid = (counting && aes_done) || zeroize_sync;

endmodule