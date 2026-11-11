// APB3 wrapper for the systolic array matrix-multiply engine.
//
// Register map (byte addresses, 32-bit registers):
//   0x000 CTRL    W   bit0 = START (self-clearing)
//   0x004 STATUS  R   bit0 = BUSY, bit1 = DONE (cleared by START)
//   0x008 CYCLES  R   compute cycles of the last operation
//   0x00C ID      R   0x5A_00_00_NN (NN = array size)
//   0x100 + 4*(i*N+j)  A[i][j]  RW  int8 in [7:0]
//   0x200 + 4*(i*N+j)  B[i][j]  RW  int8 in [7:0]
//   0x300 + 4*(i*N+j)  C[i][j]  R   int32 (one wait state)
//
// PSLVERR is returned for: unmapped address, write to a read-only register,
// write to A/B while BUSY. START while BUSY is ignored (no error).
module sa_apb_top #(parameter N = 4) (
    input  wire        pclk,
    input  wire        presetn,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    output wire        irq          // level: DONE
);
    localparam NN = N * N;
    localparam RUN_CYCLES = 3 * N - 2;

    reg [7:0] a_mem [0:NN-1];
    reg [7:0] b_mem [0:NN-1];

    // ---------------- control FSM ----------------
    localparam S_IDLE = 2'd0, S_CLR = 2'd1, S_RUN = 2'd2;
    reg [1:0]  state;
    reg [7:0]  cnt;
    reg        done;
    reg [31:0] cycles;
    wire       busy = (state != S_IDLE);

    wire [1:0] region = paddr[9:8];           // 1:A 2:B 3:C
    wire in_mat  = (paddr[11:10] == 2'b00) && (region != 2'd0) && (paddr[7:2] < NN);
    wire is_ctrl = (paddr == 12'h000);
    wire is_stat = (paddr == 12'h004);
    wire is_cyc  = (paddr == 12'h008);
    wire is_id   = (paddr == 12'h00C);
    wire mapped  = is_ctrl | is_stat | is_cyc | is_id | in_mat;
    wire [5:0] el = paddr[7:2];

    wire setup  = psel & ~penable;
    wire access = psel & penable;

    // one wait state for C reads
    reg  wait_done;
    wire c_read = in_mat && (region == 2'd3) && !pwrite;
    assign pready = !(access && c_read && !wait_done);
    always @(posedge pclk or negedge presetn)
        if (!presetn) wait_done <= 1'b0;
        else          wait_done <= access && c_read && !wait_done;

    wire wr_ro   = pwrite && (is_stat | is_cyc | is_id | (in_mat && region == 2'd3));
`ifdef BUG_PSLVERR
    wire wr_busy = 1'b0;   // injected bug: no protection while busy
`else
    wire wr_busy = pwrite && in_mat && (region != 2'd3) && busy;
`endif
    wire err     = !mapped || wr_ro || wr_busy;
    assign pslverr = access && pready && err;

    wire do_write = access && pready && pwrite && !err;
    wire start    = do_write && is_ctrl && pwdata[0] && !busy;

    integer k;
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            for (k = 0; k < NN; k = k + 1) begin a_mem[k] <= 8'd0; b_mem[k] <= 8'd0; end
        end else if (do_write && in_mat) begin
            if (region == 2'd1) a_mem[el] <= pwdata[7:0];
            if (region == 2'd2) b_mem[el] <= pwdata[7:0];
        end
    end

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            state <= S_IDLE; cnt <= 8'd0; done <= 1'b0; cycles <= 32'd0;
        end else begin
            case (state)
                S_IDLE: if (start) begin state <= S_CLR; done <= 1'b0; cycles <= 32'd0; end
                S_CLR : begin state <= S_RUN; cnt <= 8'd0; end
                S_RUN : begin
                    cycles <= cycles + 1;
                    if (cnt == RUN_CYCLES - 1) begin state <= S_IDLE; done <= 1'b1; end
                    else cnt <= cnt + 1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
    assign irq = done;

    // ---------------- skewed operand feed ----------------
    reg [8*N-1:0] a_feed, b_feed;
    integer r, kk;
    always @(*) begin
        a_feed = {8*N{1'b0}};
        b_feed = {8*N{1'b0}};
        if (state == S_RUN) begin
            for (r = 0; r < N; r = r + 1) begin
`ifdef BUG_SKEW
                kk = cnt - r + ((r == N-1) ? 1 : 0); // injected bug: last row mis-skewed
`else
                kk = cnt - r;
`endif
                if (kk >= 0 && kk < N) begin
                    a_feed[8*r +: 8] = a_mem[r*N + kk];   // A[r][kk]
                    b_feed[8*r +: 8] = b_mem[kk*N + r];   // B[kk][r]
                end
            end
        end
    end

    wire [32*NN-1:0] c_flat;
    systolic_array #(.N(N)) u_array (
        .clk(pclk), .rst_n(presetn),
        .clr(state == S_CLR), .en(state == S_RUN),
        .a_feed(a_feed), .b_feed(b_feed), .c_flat(c_flat)
    );

    // ---------------- read mux ----------------
`ifdef BUG_CTRANSPOSE
    wire [5:0] c_el = (el % N) * N + (el / N);   // injected bug: C read transposed
`else
    wire [5:0] c_el = el;
`endif
    always @(*) begin
        prdata = 32'd0;
        if (!pwrite && mapped) begin
            if (is_stat) prdata = {30'd0, done, busy};
            else if (is_cyc) prdata = cycles;
            else if (is_id)  prdata = {8'h5A, 16'h0000, N[7:0]};
            else if (in_mat && region == 2'd1) prdata = {{24{a_mem[el][7]}}, a_mem[el]};
            else if (in_mat && region == 2'd2) prdata = {{24{b_mem[el][7]}}, b_mem[el]};
            else if (in_mat && region == 2'd3) prdata = c_flat[32*c_el +: 32];
        end
    end
endmodule
