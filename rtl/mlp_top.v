// DLRM MLP-layer engine: INT8 systolic-array GEMM with an AXI4 DMA and INT8 requantization.
//
// One operation (software writes addresses + quantization params, then START):
//   1. DMA reads A (N*N int8, row-major) from A_ADDR and B from B_ADDR over AXI4 (INCR bursts)
//   2. systolic array computes C = A x B in int32
//   3. every C element is requantized to int8 (scale, round, zero-point, optional ReLU)
//   4. DMA writes the N*N int8 results to C_ADDR over AXI4
// Bursts are at most 16 beats and never cross a 4 KB boundary (AXI rule).
//
// APB3 register map (byte addresses, 32-bit registers, no wait states):
//   0x00 CTRL     RW  bit0 START (write 1; reads 0), bit1 RELU_EN
//   0x04 STATUS   RO  bit0 BUSY, bit1 DONE, bit2 ERR          (DONE/ERR cleared by START)
//   0x08 A_ADDR   RW  source of A   (must be 4-byte aligned)
//   0x0C B_ADDR   RW  source of B   (must be 4-byte aligned)
//   0x10 C_ADDR   RW  destination   (must be 4-byte aligned)
//   0x14 RQ_MULT  RW  [15:0] signed multiplier (reset 1)
//   0x18 RQ_SHIFT RW  [4:0]  right shift
//   0x1C RQ_ZP    RW  [7:0]  signed output zero-point
//   0x20 CYCLES   RO  clock cycles of the last operation (START -> DONE)
//   0x24 ERR_INFO RO  bit0 read SLVERR/DECERR, bit1 write SLVERR/DECERR, bit2 misaligned address
//   0x28 ID       RO  0x4D4C01NN
// PSLVERR: unmapped address, write to a read-only register, write to any
// configuration register (0x00-0x1C) while BUSY.
module mlp_top #(parameter N = 4) (       // N must be even (N*N bytes = whole 32-bit beats)
    input  wire        clk,
    input  wire        rst_n,
    // APB3 slave
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    output wire        irq,
    // AXI4 master, read channels
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    // AXI4 master, write channels
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    input  wire [1:0]  m_axi_bresp
);
    localparam NN    = N * N;
    localparam BEATS = NN / 4;              // 32-bit beats per matrix

    // ------------------------------------------------------------------ registers
    reg        relu_en;
    reg [31:0] a_addr, b_addr, c_addr;
    reg [15:0] rq_mult;
    reg [4:0]  rq_shift;
    reg [7:0]  rq_zp;
    reg [31:0] cycles;
    reg        done, err_rd, err_wr, err_align;

    localparam S_IDLE = 3'd0, S_RD_AR = 3'd1, S_RD_R = 3'd2, S_COMP = 3'd3,
               S_COMP_W = 3'd4, S_WR_AW = 3'd5, S_WR_W = 3'd6, S_WR_B = 3'd7;
    reg [2:0] state;
    wire busy = (state != S_IDLE);

    // ------------------------------------------------------------------ APB decode
    wire is_ctrl = paddr == 12'h000, is_stat = paddr == 12'h004, is_aadr = paddr == 12'h008,
         is_badr = paddr == 12'h00C, is_cadr = paddr == 12'h010, is_mult = paddr == 12'h014,
         is_shft = paddr == 12'h018, is_zp   = paddr == 12'h01C, is_cyc  = paddr == 12'h020,
         is_einf = paddr == 12'h024, is_id   = paddr == 12'h028;
    wire is_cfg  = is_ctrl | is_aadr | is_badr | is_cadr | is_mult | is_shft | is_zp;
    wire is_ro   = is_stat | is_cyc | is_einf | is_id;
    wire mapped  = is_cfg | is_ro;
    wire access  = psel & penable;
    wire err     = !mapped || (pwrite && is_ro) || (pwrite && is_cfg && busy);
    assign pready  = 1'b1;
    assign pslverr = access && err;
    wire do_write  = access && pwrite && !err;
    wire start     = do_write && is_ctrl && pwdata[0];
    wire misaligned = (|a_addr[1:0]) | (|b_addr[1:0]) | (|c_addr[1:0]);
    assign irq = done;

    always @(*) begin
        prdata = 32'd0;
        if (!pwrite) begin
            if (is_ctrl) prdata = {30'd0, relu_en, 1'b0};
            if (is_stat) prdata = {29'd0, err_rd | err_wr | err_align, done, busy};
            if (is_aadr) prdata = a_addr;
            if (is_badr) prdata = b_addr;
            if (is_cadr) prdata = c_addr;
            if (is_mult) prdata = {16'd0, rq_mult};
            if (is_shft) prdata = {27'd0, rq_shift};
            if (is_zp)   prdata = {24'd0, rq_zp};
            if (is_cyc)  prdata = cycles;
            if (is_einf) prdata = {29'd0, err_align, err_wr, err_rd};
            if (is_id)   prdata = {16'h4D4C, 8'h01, N[7:0]};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            relu_en <= 1'b0; a_addr <= 32'd0; b_addr <= 32'd0; c_addr <= 32'd0;
            rq_mult <= 16'd1; rq_shift <= 5'd0; rq_zp <= 8'd0;
        end else if (do_write) begin
            if (is_ctrl) relu_en  <= pwdata[1];
            if (is_aadr) a_addr   <= pwdata;
            if (is_badr) b_addr   <= pwdata;
            if (is_cadr) c_addr   <= pwdata;
            if (is_mult) rq_mult  <= pwdata[15:0];
            if (is_shft) rq_shift <= pwdata[4:0];
            if (is_zp)   rq_zp    <= pwdata[7:0];
        end
    end

    // ------------------------------------------------------------------ DMA burst sizing
    reg  [31:0] cur_addr;
    reg  [7:0]  beats_left;           // beats still to move for the current matrix
    reg  [4:0]  blen, beat;           // beats in the current burst / beat counter
    reg  [7:0]  bidx;                 // byte index into the matrix buffer
    reg         phase_b;              // 0: reading A, 1: reading B

    wire [12:0] to_4k  = 13'h1000 - {1'b0, cur_addr[11:0]};   // bytes to the 4 KB boundary
    wire [10:0] beats_4k = to_4k[12:2];
    wire [7:0]  b16    = (beats_left > 8'd16) ? 8'd16 : beats_left;
`ifdef BUG_4K
    wire [4:0]  blen_next = b16[4:0];                            // injected bug: ignores 4 KB rule
`else
    wire [4:0]  blen_next = ({3'd0, b16} > beats_4k) ? beats_4k[4:0] : b16[4:0];
`endif

    // ------------------------------------------------------------------ operand buffers
    reg  [8*NN-1:0]  a_buf, b_buf;
    wire [32*NN-1:0] c_flat;
    wire [8*NN-1:0]  q_flat;
    wire core_busy, core_done;

    sa_core #(.N(N)) u_core (
        .clk(clk), .rst_n(rst_n), .start(state == S_COMP),
        .a_flat(a_buf), .b_flat(b_buf), .busy(core_busy), .done(core_done), .c_flat(c_flat)
    );

    genvar g;
    generate
        for (g = 0; g < NN; g = g + 1) begin : g_rq
            mlp_requant u_rq (
                .acc(c_flat[32*g +: 32]), .mult(rq_mult), .shift(rq_shift), .zp(rq_zp),
                .relu(relu_en), .q(q_flat[8*g +: 8])
            );
        end
    endgenerate

    // ------------------------------------------------------------------ AXI outputs
    assign m_axi_arvalid = (state == S_RD_AR);
    assign m_axi_araddr  = cur_addr;
    assign m_axi_arlen   = {3'd0, blen_next} - 8'd1;
    assign m_axi_arsize  = 3'd2;              // 4 bytes per beat
    assign m_axi_arburst = 2'b01;             // INCR
    assign m_axi_rready  = (state == S_RD_R);

    assign m_axi_awvalid = (state == S_WR_AW);
    assign m_axi_awaddr  = cur_addr;
    assign m_axi_awlen   = {3'd0, blen_next} - 8'd1;
    assign m_axi_awsize  = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_wvalid  = (state == S_WR_W);
    assign m_axi_wdata   = q_flat[8*bidx +: 32];
    assign m_axi_wstrb   = 4'hF;
`ifdef BUG_WLAST
    assign m_axi_wlast   = (blen == 5'd1) ? 1'b1 : (beat == blen - 5'd2);   // injected bug: one beat early
`else
    assign m_axi_wlast   = (beat == blen - 5'd1);
`endif
    assign m_axi_bready  = (state == S_WR_B);

    // ------------------------------------------------------------------ DMA / control FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; err_rd <= 1'b0; err_wr <= 1'b0; err_align <= 1'b0;
            cycles <= 32'd0; cur_addr <= 32'd0; beats_left <= 8'd0; blen <= 5'd0; beat <= 5'd0;
            bidx <= 8'd0; phase_b <= 1'b0; a_buf <= {8*NN{1'b0}}; b_buf <= {8*NN{1'b0}};
        end else begin
            if (busy) cycles <= cycles + 32'd1;
            case (state)
                S_IDLE: if (start) begin
                    done <= 1'b0; err_rd <= 1'b0; err_wr <= 1'b0; err_align <= 1'b0; cycles <= 32'd0;
                    if (misaligned) begin
                        err_align <= 1'b1; done <= 1'b1;                    // reject, no bus traffic
                    end else begin
                        phase_b <= 1'b0; cur_addr <= a_addr; beats_left <= BEATS; bidx <= 8'd0;
                        state <= S_RD_AR;
                    end
                end
                S_RD_AR: if (m_axi_arready) begin
                    blen <= blen_next; beat <= 5'd0; state <= S_RD_R;
                end
                S_RD_R: if (m_axi_rvalid) begin
                    if (phase_b) b_buf[8*bidx +: 32] <= m_axi_rdata;
                    else         a_buf[8*bidx +: 32] <= m_axi_rdata;
                    if (m_axi_rresp != 2'b00) err_rd <= 1'b1;
                    bidx <= bidx + 8'd4;
                    beat <= beat + 5'd1;
                    if (beat == blen - 5'd1) begin                          // burst finished
                        cur_addr   <= cur_addr + {25'd0, blen, 2'b00};
                        beats_left <= beats_left - {3'd0, blen};
                        if (beats_left == {3'd0, blen}) begin                // matrix finished
                            if (!phase_b) begin
                                phase_b <= 1'b1; cur_addr <= b_addr; beats_left <= BEATS;
                                bidx <= 8'd0; state <= S_RD_AR;
                            end else
                                state <= S_COMP;
                        end else
                            state <= S_RD_AR;
                    end
                end
                S_COMP:   state <= S_COMP_W;
                S_COMP_W: if (core_done) begin
                    cur_addr <= c_addr; beats_left <= BEATS; bidx <= 8'd0; state <= S_WR_AW;
                end
                S_WR_AW: if (m_axi_awready) begin
                    blen <= blen_next; beat <= 5'd0; state <= S_WR_W;
                end
                S_WR_W: if (m_axi_wready) begin
                    bidx <= bidx + 8'd4;
                    beat <= beat + 5'd1;
                    if (beat == blen - 5'd1) state <= S_WR_B;
                end
                S_WR_B: if (m_axi_bvalid) begin
                    if (m_axi_bresp != 2'b00) err_wr <= 1'b1;
                    cur_addr   <= cur_addr + {25'd0, blen, 2'b00};
                    beats_left <= beats_left - {3'd0, blen};
                    if (beats_left == {3'd0, blen}) begin
                        done <= 1'b1; state <= S_IDLE;
                    end else
                        state <= S_WR_AW;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
