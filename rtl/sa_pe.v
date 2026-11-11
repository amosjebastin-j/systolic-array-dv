// Processing element: output-stationary INT8 MAC
module sa_pe (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clr,      // synchronous clear of acc and pass regs
    input  wire               en,       // compute enable
    input  wire signed [7:0]  a_in,
    input  wire signed [7:0]  b_in,
    output reg  signed [7:0]  a_out,
    output reg  signed [7:0]  b_out,
    output reg  signed [31:0] acc
);
`ifdef BUG_SIGN
    // Injected bug: B operand treated as unsigned
    wire signed [16:0] prod = a_in * $signed({1'b0, b_in});
`else
    wire signed [15:0] prod = a_in * b_in;
`endif
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= 8'sd0; b_out <= 8'sd0; acc <= 32'sd0;
        end else if (clr) begin
            a_out <= 8'sd0; b_out <= 8'sd0;
`ifndef BUG_NOCLR
            acc   <= 32'sd0;
`endif
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            acc   <= acc + prod;
        end
    end
endmodule
