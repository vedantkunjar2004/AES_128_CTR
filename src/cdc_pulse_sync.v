module cdc_pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_in,        // single-cycle pulse in the src_clk domain

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse      // single-cycle pulse in the dst_clk domain
);

    // source side: toggle on every input pulse
    reg src_toggle;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            src_toggle <= 1'b0;
        else if (src_in)
            src_toggle <= ~src_toggle;
    end

    // destination side: 2-FF sync then edge detect
    reg dst_sync0, dst_sync1, dst_sync2;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_sync0 <= 1'b0;
            dst_sync1 <= 1'b0;
            dst_sync2 <= 1'b0;
        end else begin
            dst_sync0 <= src_toggle;  // first stage, may go metastable, expected and normal
            dst_sync1 <= dst_sync0;   // second stage, resolved, safe to use
            dst_sync2 <= dst_sync1;   // one cycle behind dst_sync1, for edge detection only
        end
    end

    assign dst_pulse = dst_sync1 ^ dst_sync2;

endmodule