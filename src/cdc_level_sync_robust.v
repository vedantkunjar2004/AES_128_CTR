// Synchronizes a level signal from src_clk into dst_clk without
// relying on dst_clk being fast enough to catch every transition
// directly. A plain 2-FF synchronizer only works correctly if the
// source level stays stable for at least 2-3 dst_clk periods around
// every change - fine for a level that only changes on a deliberate
// action (e.g. key_lock), but not fine for a level that goes high and
// then low again on its own within a bounded window (e.g. busy,
// key_ready): if dst_clk's period is longer than that window, dst_clk
// could sample 0 right before and right after the window and never
// see the 1 at all.
//
// Instead, both the rising and falling edge of src_in are individually
// detected in src_clk, each edge is pulse-synced into dst_clk on its
// own cdc_pulse_sync instance, and the level is reconstructed in
// dst_clk with a set/clear register driven by those two synced pulses.
//
// This is robust to dst_clk being much slower than src_clk as long as
// the two edges are spaced at least about 3 dst_clk periods apart. If
// dst_clk is so slow that even that margin is violated, the two
// pulse-syncs can merge or reorder and the reconstructed level can be
// wrong - no synchronization technique escapes this entirely, since
// conveying a transition to an arbitrarily slower observer in bounded
// time is a fundamental limit, not a tooling gap. Document the assumed
// minimum src_in pulse width against the target dst_clk period in the
// CDC report.
//
// Used for: aes_engine.busy and aes_engine.key_ready (both crypto_clk)
// into register_bank's busy_sync / key_ready_sync (pclk).

module cdc_level_sync_robust (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_in,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output reg  dst_out
);

    // src_clk: edge detect
    reg src_in_d;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            src_in_d <= 1'b0;
        else
            src_in_d <= src_in;
    end

    wire rise_pulse = src_in  & ~src_in_d;
    wire fall_pulse = ~src_in &  src_in_d;

    // independently pulse-sync each edge
    wire rise_pulse_dst, fall_pulse_dst;

    cdc_pulse_sync u_rise_sync (
        .src_clk   (src_clk), .src_rst_n (src_rst_n), .src_in    (rise_pulse),
        .dst_clk   (dst_clk), .dst_rst_n (dst_rst_n), .dst_pulse (rise_pulse_dst)
    );
    cdc_pulse_sync u_fall_sync (
        .src_clk   (src_clk), .src_rst_n (src_rst_n), .src_in    (fall_pulse),
        .dst_clk   (dst_clk), .dst_rst_n (dst_rst_n), .dst_pulse (fall_pulse_dst)
    );

    // dst_clk: reconstruct the level
    // dst_out used to be written by two independent if statements,
    // which lint flagged (STARC05-2.2.3.3, don't assign the same
    // signal from more than one branch in an always block). Rewritten
    // as if/else with the same priority as before: rise wins if both
    // pulses land on the same cycle.
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_out <= 1'b0;
        end else if (rise_pulse_dst) begin
            dst_out <= 1'b1;
        end else if (fall_pulse_dst) begin
            dst_out <= 1'b0;
        end
    end

endmodule