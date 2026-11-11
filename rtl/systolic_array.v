// N x N (N <= 8) output-stationary systolic array. A enters from the left (row-skewed),
// B enters from the top (column-skewed). C[i][j] accumulates in PE(i,j).
module systolic_array #(parameter N = 4) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clr,
    input  wire              en,
    input  wire [8*N-1:0]    a_feed,   // one int8 per row
    input  wire [8*N-1:0]    b_feed,   // one int8 per column
    output wire [32*N*N-1:0] c_flat    // C[i][j] at index (i*N+j)
);
    wire [7:0] a_bus [0:N-1][0:N];
    wire [7:0] b_bus [0:N][0:N-1];
    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_edge
            assign a_bus[i][0] = a_feed[8*i +: 8];
            assign b_bus[0][i] = b_feed[8*i +: 8];
        end
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                wire [31:0] acc;
                sa_pe u_pe (
                    .clk(clk), .rst_n(rst_n), .clr(clr), .en(en),
                    .a_in(a_bus[i][j]), .b_in(b_bus[i][j]),
                    .a_out(a_bus[i][j+1]), .b_out(b_bus[i+1][j]),
                    .acc(acc)
                );
                assign c_flat[32*(i*N+j) +: 32] = acc;
            end
        end
    endgenerate
endmodule
