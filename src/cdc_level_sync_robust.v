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
