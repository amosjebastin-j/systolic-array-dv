// INT32 accumulator -> INT8 output, as in TFLite/PyTorch quantized inference:
//   y = clamp( ((acc * MULT) + 2^(SHIFT-1)) >>> SHIFT  + ZP,  lo, 127 )
//   lo = ZP when ReLU is enabled (real value >= 0), else -128.
// Round-half-up; SHIFT = 0 means no rounding term.
module mlp_requant (
    input  wire signed [31:0] acc,
    input  wire signed [15:0] mult,
    input  wire        [4:0]  shift,
    input  wire signed [7:0]  zp,
    input  wire               relu,
    output reg  signed [7:0]  q
);
    wire signed [47:0] prod = acc * mult;
`ifdef BUG_ROUND
    wire signed [47:0] rnd  = 48'sd0;                                   // injected bug: truncation
`else
    wire signed [47:0] rnd  = (shift == 5'd0) ? 48'sd0 : (48'sd1 <<< (shift - 5'd1));
`endif
    wire signed [47:0] scaled = (prod + rnd) >>> shift;
    wire signed [48:0] y      = scaled + zp;
`ifdef BUG_RELU_ZP
    wire signed [48:0] lo     = relu ? 49'sd0 : -49'sd128;              // injected bug: ReLU ignores ZP
`else
    wire signed [48:0] lo     = relu ? zp : -49'sd128;
`endif
    always @(*) begin
        if (y > 49'sd127)  q = 8'sd127;
        else if (y < lo)   q = lo[7:0];
        else               q = y[7:0];
    end
endmodule
