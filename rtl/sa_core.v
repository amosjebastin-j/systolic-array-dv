// Systolic-array compute core used by mlp_top.
// Operands arrive as packed row-major int8 matrices; a START pulse runs one
// C = A x B (int32) in 1 clear cycle + 3N-2 compute cycles.
module sa_core #(parameter N = 4) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,      // one-cycle pulse, ignored while busy
    input  wire [8*N*N-1:0]  a_flat,     // A[i][k] at byte (i*N+k)
    input  wire [8*N*N-1:0]  b_flat,     // B[k][j] at byte (k*N+j)
    output wire              busy,
    output reg               done,       // one-cycle pulse when C is valid
    output wire [32*N*N-1:0] c_flat
);
    localparam RUN_CYCLES = 3 * N - 2;
    localparam S_IDLE = 2'd0, S_CLR = 2'd1, S_RUN = 2'd2;
    reg [1:0] state;
    reg [7:0] cnt;
    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; cnt <= 8'd0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) state <= S_CLR;
                S_CLR : begin state <= S_RUN; cnt <= 8'd0; end
                S_RUN : if (cnt == RUN_CYCLES - 1) begin state <= S_IDLE; done <= 1'b1; end
                        else cnt <= cnt + 8'd1;
                default: state <= S_IDLE;
            endcase
        end
    end

    // skewed feed: A[r][k] enters row r at cycle r+k, B[k][c] enters column c at cycle k+c
    reg [8*N-1:0] a_feed, b_feed;
    integer r, kk;
    always @(*) begin
        a_feed = {8*N{1'b0}};
        b_feed = {8*N{1'b0}};
        if (state == S_RUN)
            for (r = 0; r < N; r = r + 1) begin
                kk = cnt - r;
                if (kk >= 0 && kk < N) begin
                    a_feed[8*r +: 8] = a_flat[8*(r*N + kk) +: 8];
                    b_feed[8*r +: 8] = b_flat[8*(kk*N + r) +: 8];
                end
            end
    end

    systolic_array #(.N(N)) u_array (
        .clk(clk), .rst_n(rst_n),
        .clr(state == S_CLR), .en(state == S_RUN),
        .a_feed(a_feed), .b_feed(b_feed), .c_flat(c_flat)
    );
endmodule
