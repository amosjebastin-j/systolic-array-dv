`timescale 1ns/1ps
`ifndef SA_N
`define SA_N 4
`endif
// UVM environment for mlp_top (v2: DLRM MLP layer engine).
// Reuses the APB agent from sa_pkg (v1) and adds: a UVM register model (RAL) with adapter and
// predictor, a reactive AXI4 memory slave, an operation-level scoreboard and functional coverage.
package mlp_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import sa_pkg::apb_item;
    import sa_pkg::apb_agent;
    import sa_pkg::sa_base_seq;

    localparam int N     = `SA_N;
    localparam int NN    = N * N;
    localparam int BEATS = NN / 4;

    // =================================================================== shared memory + knobs
    class mlp_cfg extends uvm_object;
        `uvm_object_utils(mlp_cfg)
        byte unsigned mem[int unsigned];
        int unsigned  p_ready = 70, p_gap = 20, lat_min = 0, lat_max = 6, b_dly_max = 4;
        int unsigned  rd_err_lo, rd_err_hi, wr_err_lo, wr_err_hi;   // [lo, hi) answers SLVERR
        function new(string name = "mlp_cfg"); super.new(name); endfunction
        function byte unsigned rd8(int unsigned a); return mem.exists(a) ? mem[a] : 8'h00; endfunction
        function void clear_errors(); rd_err_lo = 0; rd_err_hi = 0; wr_err_lo = 0; wr_err_hi = 0; endfunction
    endclass

    // =================================================================== register model (RAL)
    class mlp_reg_ctrl extends uvm_reg;
        `uvm_object_utils(mlp_reg_ctrl)
        rand uvm_reg_field start, relu_en;
        function new(string name = "ctrl"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
        virtual function void build();
            start   = uvm_reg_field::type_id::create("start");
            relu_en = uvm_reg_field::type_id::create("relu_en");
            start.configure  (this, 1, 0, "WO", 0, 1'b0, 1, 1, 0);
            start.set_compare(UVM_NO_CHECK);                 // START always reads back 0
            relu_en.configure(this, 1, 1, "RW", 0, 1'b0, 1, 1, 0);
        endfunction
    endclass

    class mlp_reg_status extends uvm_reg;
        `uvm_object_utils(mlp_reg_status)
        uvm_reg_field busy, done, err;
        function new(string name = "status"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
        virtual function void build();
            busy = uvm_reg_field::type_id::create("busy");
            done = uvm_reg_field::type_id::create("done");
            err  = uvm_reg_field::type_id::create("err");
            busy.configure(this, 1, 0, "RO", 1, 1'b0, 1, 0, 0);
            done.configure(this, 1, 1, "RO", 1, 1'b0, 1, 0, 0);
            err.configure (this, 1, 2, "RO", 1, 1'b0, 1, 0, 0);
        endfunction
    endclass

    // single-field register, configurable width / access / reset
    class mlp_reg_word extends uvm_reg;
        `uvm_object_utils(mlp_reg_word)
        rand uvm_reg_field value;
        int unsigned width = 32; string access = "RW"; uvm_reg_data_t rst = 0; bit vol = 0;
        function new(string name = "word"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
        function void setup(int unsigned w, string acc, uvm_reg_data_t r, bit v = 0);
            width = w; access = acc; rst = r; vol = v;
        endfunction
        virtual function void build();
            value = uvm_reg_field::type_id::create("value");
            value.configure(this, width, 0, access, vol, rst, 1, access == "RW", 0);
        endfunction
    endclass

    class mlp_reg_block extends uvm_reg_block;
        `uvm_object_utils(mlp_reg_block)
        mlp_reg_ctrl   ctrl;
        mlp_reg_status status;
        mlp_reg_word   a_addr, b_addr, c_addr, rq_mult, rq_shift, rq_zp, cycles, err_info, id;
        function new(string name = "mlp_regs"); super.new(name, UVM_NO_COVERAGE); endfunction
        function mlp_reg_word mk(string nm, int unsigned w, string acc, uvm_reg_data_t r, bit v,
                                 uvm_reg_addr_t off);
            mlp_reg_word rg = mlp_reg_word::type_id::create(nm);
            rg.setup(w, acc, r, v);
            rg.configure(this);
            rg.build();
            default_map.add_reg(rg, off, acc);
            return rg;
        endfunction
        virtual function void build();
            default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN, 1);
            ctrl = mlp_reg_ctrl::type_id::create("ctrl");
            ctrl.configure(this); ctrl.build(); default_map.add_reg(ctrl, 'h00, "RW");
            status = mlp_reg_status::type_id::create("status");
            status.configure(this); status.build(); default_map.add_reg(status, 'h04, "RO");
            a_addr   = mk("a_addr",   32, "RW", 0, 0, 'h08);
            b_addr   = mk("b_addr",   32, "RW", 0, 0, 'h0C);
            c_addr   = mk("c_addr",   32, "RW", 0, 0, 'h10);
            rq_mult  = mk("rq_mult",  16, "RW", 1, 0, 'h14);
            rq_shift = mk("rq_shift",  5, "RW", 0, 0, 'h18);
            rq_zp    = mk("rq_zp",     8, "RW", 0, 0, 'h1C);
            cycles   = mk("cycles",   32, "RO", 0, 1, 'h20);
            err_info = mk("err_info",  3, "RO", 0, 1, 'h24);
            id       = mk("id",       32, "RO", {16'h4D4C, 8'h01, 8'(N)}, 0, 'h28);
            lock_model();
        endfunction
    endclass

    class mlp_reg_adapter extends uvm_reg_adapter;
        `uvm_object_utils(mlp_reg_adapter)
        function new(string name = "mlp_reg_adapter"); super.new(name); endfunction
        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            apb_item t = apb_item::type_id::create("t");
            t.addr  = rw.addr[11:0];
            t.write = (rw.kind == UVM_WRITE);
            t.data  = rw.data[31:0];
            return t;
        endfunction
        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            apb_item t;
            if (!$cast(t, bus_item)) `uvm_fatal("ADAPT", "not an apb_item")
            rw.kind   = t.write ? UVM_WRITE : UVM_READ;
            rw.addr   = t.addr;
            rw.data   = t.write ? t.data : t.rdata;
            rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
        endfunction
    endclass

    // Errored APB transfers do not change DUT state, so they must not update the register mirror.
    class mlp_reg_predictor extends uvm_reg_predictor #(apb_item);
        `uvm_component_utils(mlp_reg_predictor)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        virtual function void write(apb_item tr);
            if (tr.slverr) return;
            super.write(tr);
        endfunction
    endclass

    // =================================================================== AXI4 memory slave
    class mlp_axi_slave extends uvm_component;
        `uvm_component_utils(mlp_axi_slave)
        virtual mlp_axi_if vif;
        mlp_cfg cfg;
        typedef struct { int unsigned addr; int beats; int done; longint ready_at; bit err; } burst_t;
        int unsigned n_rd_bursts, n_wr_bursts, n_split_4k, n_violations;
        int burst_cls;                 // 0: single beat, 1: part of a split transfer, 2: full-length burst
        bit burst_single;
        covergroup cg_burst;
            option.per_instance = 1;
            option.name = "burst";
            cp_len:    coverpoint burst_cls    { bins split_part = {1}; bins full_length = {2}; }
            cp_single: coverpoint burst_single { bins single_beat = {1}; }
        endgroup
        function new(string n, uvm_component p); super.new(n, p); cg_burst = new(); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual mlp_axi_if)::get(this, "", "axi_vif", vif)) `uvm_fatal("VIF", "axi_vif")
            if (!uvm_config_db#(mlp_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "cfg")
        endfunction
        function void note_burst(int unsigned addr, int beats);
            burst_cls = (beats == ((BEATS > 16) ? 16 : BEATS)) ? 2 : 1;
            burst_single = (beats == 1);
            cg_burst.sample();
            if (((addr + 4 * beats) & 32'hFFF) == 0) n_split_4k++;
            if ((addr & 32'hFFF) + 4 * beats > 32'h1000)
                violation($sformatf("burst 0x%08h + %0d bytes crosses a 4 KB boundary", addr, 4 * beats));
        endfunction
        function void violation(string msg);
            n_violations++;
            `uvm_error("AXI", msg)
        endfunction
        task run_phase(uvm_phase phase);
            vif.slv_cb.arready <= 0; vif.slv_cb.rvalid <= 0; vif.slv_cb.awready <= 0;
            vif.slv_cb.wready <= 0; vif.slv_cb.bvalid <= 0;
            fork read_side(); write_side(); join
        endtask
        task read_side();
            burst_t q[$];
            bit ar_rdy, r_pend;
            longint cyc;
            forever begin
                @(vif.slv_cb);
                cyc++;
                if (r_pend && vif.slv_cb.rready) begin
                    r_pend = 0;
                    q[0].done++;
                    if (q[0].done == q[0].beats) void'(q.pop_front());
                end
                if (ar_rdy && vif.slv_cb.arvalid) begin
                    burst_t b;
                    b.addr = vif.slv_cb.araddr; b.beats = vif.slv_cb.arlen + 1; b.done = 0;
                    b.ready_at = cyc + $urandom_range(cfg.lat_min, cfg.lat_max);
                    b.err = (b.addr >= cfg.rd_err_lo && b.addr < cfg.rd_err_hi);
                    q.push_back(b);
                    n_rd_bursts++;
                    note_burst(b.addr, b.beats);
                end
                ar_rdy = ($urandom_range(0, 99) < cfg.p_ready);
                vif.slv_cb.arready <= ar_rdy;
                if (!r_pend && q.size() > 0 && q[0].ready_at <= cyc && $urandom_range(0, 99) >= cfg.p_gap) begin
                    int unsigned a = q[0].addr + 4 * q[0].done;
                    r_pend = 1;
                    vif.slv_cb.rdata <= {cfg.rd8(a + 3), cfg.rd8(a + 2), cfg.rd8(a + 1), cfg.rd8(a)};
                    vif.slv_cb.rresp <= q[0].err ? 2'b10 : 2'b00;
                    vif.slv_cb.rlast <= (q[0].done == q[0].beats - 1);
                end
                vif.slv_cb.rvalid <= r_pend;
            end
        endtask
        task write_side();
            burst_t aw[$];
            longint bq[$];
            bit     bq_err[$];
            bit aw_rdy, w_rdy, b_pend;
            longint cyc;
            forever begin
                @(vif.slv_cb);
                cyc++;
                if (b_pend && vif.slv_cb.bready) begin
                    b_pend = 0; void'(bq.pop_front()); void'(bq_err.pop_front());
                end
                if (aw_rdy && vif.slv_cb.awvalid) begin
                    burst_t b;
                    b.addr = vif.slv_cb.awaddr; b.beats = vif.slv_cb.awlen + 1; b.done = 0;
                    b.err = (b.addr >= cfg.wr_err_lo && b.addr < cfg.wr_err_hi);
                    aw.push_back(b);
                    n_wr_bursts++;
                    note_burst(b.addr, b.beats);
                end
                if (w_rdy && vif.slv_cb.wvalid) begin
                    if (aw.size() == 0) violation("W beat with no outstanding AW");
                    else begin
                        int unsigned a = aw[0].addr + 4 * aw[0].done;
                        bit exp_last = (aw[0].done == aw[0].beats - 1);
                        if (vif.slv_cb.wlast !== exp_last)
                            violation($sformatf("WLAST=%0b on beat %0d of %0d (burst 0x%08h)",
                                                vif.slv_cb.wlast, aw[0].done, aw[0].beats, aw[0].addr));
                        if (vif.slv_cb.wstrb !== 4'hF) violation($sformatf("WSTRB=%h", vif.slv_cb.wstrb));
                        if (!aw[0].err)
                            for (int k = 0; k < 4; k++) cfg.mem[a + k] = vif.slv_cb.wdata[8*k +: 8];
                        aw[0].done++;
                        if (aw[0].done == aw[0].beats) begin
                            bq.push_back(cyc + $urandom_range(0, cfg.b_dly_max));
                            bq_err.push_back(aw[0].err);
                            void'(aw.pop_front());
                        end
                    end
                end
                aw_rdy = ($urandom_range(0, 99) < cfg.p_ready);
                w_rdy  = ($urandom_range(0, 99) < cfg.p_ready);
                vif.slv_cb.awready <= aw_rdy;
                vif.slv_cb.wready  <= w_rdy;
                if (!b_pend && bq.size() > 0 && bq[0] <= cyc) begin
                    b_pend = 1;
                    vif.slv_cb.bresp <= bq_err[0] ? 2'b10 : 2'b00;
                end
                vif.slv_cb.bvalid <= b_pend;
            end
        endtask
        function void report_phase(uvm_phase phase);
            `uvm_info("AXI", $sformatf("read bursts=%0d write bursts=%0d bursts ending on a 4KB boundary=%0d violations=%0d",
                                       n_rd_bursts, n_wr_bursts, n_split_4k, n_violations), UVM_NONE)
        endfunction
    endclass

    // =================================================================== operation record
    class mlp_op extends uvm_object;
        `uvm_object_utils(mlp_op)
        byte          a[NN], b[NN], got[NN];
        int           mult, shift, zp;
        bit           relu, straddle_4k;
        int unsigned  a_addr, b_addr, c_addr;
        bit [2:0]     expect_err, err_info;
        bit [31:0]    status, cycles;
        function new(string name = "mlp_op"); super.new(name); endfunction
    endclass

    // =================================================================== scoreboard + coverage
    class mlp_scoreboard extends uvm_subscriber #(mlp_op);
        `uvm_component_utils(mlp_scoreboard)
        int unsigned n_ops, n_outputs, n_mismatch, n_err_ops;
        // sampled variables
        bit  s_relu, s_rounded, s_4k;
        int  s_shift, s_mult, s_class, s_err;
        string apb_err_seen[$];
        covergroup cg_op;
            option.per_instance = 1;
            option.name = "op";
            cp_relu:  coverpoint s_relu;
            cp_shift: coverpoint s_shift { bins zero = {0}; bins s1_7 = {[1:7]}; bins s8_15 = {[8:15]};
                                           bins s16_23 = {[16:23]}; bins s24_31 = {[24:31]}; }
            cp_mult:  coverpoint s_mult { bins max_neg = {-32768}; bins negative = {[-32767:-1]}; bins one = {1};
                                          bins positive = {[2:32766]}; bins max_pos = {32767}; }
            cp_4k:    coverpoint s_4k;
            x_relu_4k: cross cp_relu, cp_4k;
        endgroup
        covergroup cg_out;
            option.per_instance = 1;
            option.name = "output";
            cp_class: coverpoint s_class { bins in_range = {0}; bins sat_hi = {1}; bins sat_lo = {2};
                                           bins relu_clamp = {3}; }
            cp_round: coverpoint s_rounded { bins rounded_up = {1}; }
            cp_relu:  coverpoint s_relu;
            x_relu_class: cross cp_relu, cp_class {
                ignore_bins relu_no_satlo  = binsof(cp_relu) intersect {1} && binsof(cp_class.sat_lo);
                ignore_bins norelu_noclamp = binsof(cp_relu) intersect {0} && binsof(cp_class.relu_clamp);
            }
        endgroup
        covergroup cg_err;
            option.per_instance = 1;
            option.name = "errors";
            cp_err: coverpoint s_err { bins axi_rd = {1}; bins axi_wr = {2}; bins misaligned = {4};
                                       bins apb_cfg_busy = {8}; bins apb_ro_write = {9}; bins apb_unmapped = {10}; }
        endgroup
        function new(string n, uvm_component p);
            super.new(n, p); cg_op = new(); cg_out = new(); cg_err = new();
        endfunction

        static function int requant(int acc, int mult, int shift, int zp, bit relu, output bit rounded,
                                    output int cls);
            longint p = longint'(acc) * longint'(mult);
            longint r = (shift == 0) ? p : ((p + (longint'(1) <<< (shift - 1))) >>> shift);
            longint y = r + zp;
            longint lo = relu ? zp : -128;
            rounded = (shift != 0) && (r != (p >>> shift)) && (y >= -128) && (y <= 127);
            if (y > 127)      begin cls = 1; return 127; end
            if (y < lo)       begin cls = relu ? 3 : 2; return int'(lo); end
            cls = 0;
            return int'(y);
        endfunction

        function void note_apb_error(int kind);   // 8 cfg-while-busy, 9 RO write, 10 unmapped
            s_err = kind; cg_err.sample();
        endfunction

        function void write(mlp_op t);
            if (t.err_info !== t.expect_err)
                `uvm_error("SB", $sformatf("ERR_INFO=%b expected %b", t.err_info, t.expect_err))
            if (t.status[2] !== (t.expect_err != 0))
                `uvm_error("SB", $sformatf("STATUS.ERR=%b expected %b", t.status[2], t.expect_err != 0))
            if (t.expect_err != 0) begin
                n_err_ops++;
                s_err = t.expect_err; cg_err.sample();
                return;
            end
            s_relu = t.relu; s_shift = t.shift; s_mult = t.mult; s_4k = t.straddle_4k;
            cg_op.sample();
            for (int e = 0; e < NN; e++) begin
                int i = e / N, j = e % N, acc = 0, cls, q;
                bit rnd;
                for (int k = 0; k < N; k++) acc += int'(t.a[i*N+k]) * int'(t.b[k*N+j]);
                q = requant(acc, t.mult, t.shift, t.zp, t.relu, rnd, cls);
                s_class = cls; s_rounded = rnd; cg_out.sample();
                n_outputs++;
                if (int'(t.got[e]) != q) begin
                    n_mismatch++;
                    if (n_mismatch <= 20)
                        `uvm_error("SB", $sformatf("op %0d C[%0d][%0d]: acc=%0d mult=%0d shift=%0d zp=%0d relu=%0b exp %0d got %0d",
                                                   n_ops, i, j, acc, t.mult, t.shift, t.zp, t.relu, q, t.got[e]))
                end
            end
            if (t.cycles <= 3 * N - 2) `uvm_error("SB", $sformatf("CYCLES=%0d too small", t.cycles))
            n_ops++;
        endfunction

        function void check_phase(uvm_phase phase);
            if (n_ops == 0) `uvm_error("SB", "no operations were checked")
            if (n_mismatch > 20) `uvm_error("SB", $sformatf("%0d mismatches in total (first 20 shown)", n_mismatch))
        endfunction
        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("ops checked=%0d  outputs checked=%0d  mismatches=%0d  error ops=%0d",
                                      n_ops, n_outputs, n_mismatch, n_err_ops), UVM_NONE)
            `uvm_info("COV", $sformatf("op=%.1f%%  output=%.1f%%  errors=%.1f%%",
                                       cg_op.get_coverage(), cg_out.get_coverage(), cg_err.get_coverage()), UVM_NONE)
        endfunction
    endclass

    // =================================================================== env
    class mlp_env extends uvm_env;
        `uvm_component_utils(mlp_env)
        apb_agent                     apb;
        mlp_axi_slave                 axi;
        mlp_scoreboard                sb;
        mlp_reg_block                 regs;
        mlp_reg_adapter               adapter;
        mlp_reg_predictor             predictor;
        uvm_analysis_port #(mlp_op)   op_ap;
        mlp_cfg                       cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(mlp_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "cfg")
            apb       = apb_agent::type_id::create("apb", this);
            axi       = mlp_axi_slave::type_id::create("axi", this);
            sb        = mlp_scoreboard::type_id::create("sb", this);
            predictor = mlp_reg_predictor::type_id::create("predictor", this);
            op_ap     = new("op_ap", this);
            regs      = mlp_reg_block::type_id::create("regs");
            regs.build();
            adapter   = mlp_reg_adapter::type_id::create("adapter");
        endfunction
        function void connect_phase(uvm_phase phase);
            regs.default_map.set_sequencer(apb.sqr, adapter);
            regs.default_map.set_auto_predict(0);
            predictor.map     = regs.default_map;
            predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
            op_ap.connect(sb.analysis_export);
        endfunction
    endclass

    // =================================================================== sequences
    // One MLP-layer operation, programmed entirely through the register model.
    class mlp_op_seq extends uvm_sequence;
        `uvm_object_utils(mlp_op_seq)
        mlp_env env;
        rand byte  a[NN], b[NN];
        rand int   mult, shift, zp;
        rand bit   relu, near_4k;
        int        page[3];
        int        misalign = -1;     // -1: none, 0/1/2: make A/B/C address misaligned
        bit [2:0]  expect_err;
        constraint c_ops   { foreach (a[i]) a[i] dist { -128 := 5, 127 := 5, 0 := 10, [-127:126] :/ 80 };
                             foreach (b[i]) b[i] dist { -128 := 5, 127 := 5, 0 := 10, [-127:126] :/ 80 }; }
        constraint c_quant { mult inside {[-32768:32767]}; shift inside {[0:31]}; zp inside {[-128:127]};
                             zp dist { 0 := 50, [-20:20] :/ 30, [-128:127] :/ 20 };
                             mult dist { 1 := 3, 32767 := 2, -32768 := 2, [2:32766] :/ 75, [-32767:-1] :/ 18 };
                             near_4k dist { 0 := 75, 1 := 25 }; }
        function new(string name = "mlp_op_seq"); super.new(name); endfunction
        function void post_randomize();
            // realistic scale for most ops: pick the shift that lands outputs in int8 range
            if (mult != 1 && mult != 32767 && mult != -32768 && $urandom_range(0, 9) != 0) begin
                longint mag = (mult < 0 ? -longint'(mult) : longint'(mult)) * 128 * 128 * N / 4 / 64;
                int bits = 0;
                while (mag > 1) begin mag = mag >> 1; bits++; end
                shift = bits + int'($urandom_range(0, 4)) - 2;
                if (shift < 0) shift = 0;
                if (shift > 31) shift = 31;
            end
        endfunction
        function int unsigned place(int idx);
            int unsigned base = page[idx] * 32'h1000;
            if (near_4k && BEATS > 1) return base + 32'h1000 - 4 * $urandom_range(1, BEATS - 1);
            return base + 4 * $urandom_range(0, (32'h1000 - NN) / 4);
        endfunction
        task wr(uvm_reg rg, uvm_reg_data_t v);
            uvm_status_e st;
            rg.write(st, v, .parent(this));
            if (st != UVM_IS_OK) `uvm_error("SEQ", $sformatf("write %s failed", rg.get_name()))
        endtask
        task body();
            mlp_op op = mlp_op::type_id::create("op");
            uvm_status_e st;
            uvm_reg_data_t v;
            int unsigned addr[3];
            mlp_cfg cfg = env.cfg;
            page[0] = 2 * $urandom_range(1, 33); page[1] = page[0] + 66; page[2] = page[1] + 66;
            foreach (addr[i]) addr[i] = place(i);
            expect_err = 0;
            if (misalign >= 0) begin addr[misalign] += $urandom_range(1, 3); expect_err = 3'b100; end
            for (int i = 0; i < NN; i++) begin
                cfg.mem[addr[0] + i] = a[i]; cfg.mem[addr[1] + i] = b[i]; cfg.mem[addr[2] + i] = 8'h5A;
            end
            if (cfg.rd_err_hi != 0) begin cfg.rd_err_lo = addr[1]; cfg.rd_err_hi = addr[1] + NN; expect_err |= 3'b001; end
            if (cfg.wr_err_hi != 0) begin cfg.wr_err_lo = addr[2]; cfg.wr_err_hi = addr[2] + NN; expect_err |= 3'b010; end
            wr(env.regs.a_addr, addr[0]);
            wr(env.regs.b_addr, addr[1]);
            wr(env.regs.c_addr, addr[2]);
            wr(env.regs.rq_mult, mult & 32'hFFFF);
            wr(env.regs.rq_shift, shift);
            wr(env.regs.rq_zp, zp & 32'hFF);
            wr(env.regs.ctrl, {relu, 1'b1});
            begin
                int k;
                for (k = 0; k < 5000; k++) begin
                    env.regs.status.read(st, v, .parent(this));
                    if (v[1] && !v[0]) break;
                end
                if (k == 5000) `uvm_fatal("SEQ", "timeout waiting for DONE")
            end
            op.status = v;
            env.regs.err_info.read(st, v, .parent(this)); op.err_info = v;
            env.regs.cycles.read(st, v, .parent(this));   op.cycles = v;
            op.a = a; op.b = b; op.mult = mult; op.shift = shift; op.zp = zp; op.relu = relu;
            op.straddle_4k = near_4k && BEATS > 1; op.expect_err = expect_err;
            op.a_addr = addr[0]; op.b_addr = addr[1]; op.c_addr = addr[2];
            for (int i = 0; i < NN; i++) op.got[i] = cfg.rd8(addr[2] + i);
            env.op_ap.write(op);
        endtask
    endclass

    // Directed checks of the register interface that RAL sequences cannot do (expected errors).
    class mlp_apb_err_seq extends sa_base_seq;
        `uvm_object_utils(mlp_apb_err_seq)
        mlp_env env;
        function new(string name = "mlp_apb_err_seq"); super.new(name); endfunction
        task body();
            bit e; bit [31:0] d;
            bit [11:0] ro[] = '{12'h004, 12'h020, 12'h024, 12'h028};
            bit [11:0] um[] = '{12'h02C, 12'h030, 12'h100, 12'hFFC};
            foreach (ro[i]) begin
                wr(ro[i], 32'hFFFF_FFFF, e);
                if (!e) `uvm_error("SEQ", $sformatf("write to RO 0x%03h accepted", ro[i]));
                env.sb.note_apb_error(9);
            end
            foreach (um[i]) begin
                rd(um[i], d, e);
                if (!e) `uvm_error("SEQ", $sformatf("read of unmapped 0x%03h accepted", um[i]));
                env.sb.note_apb_error(10);
            end
        endtask
    endclass

    // Writes every config register while an operation is running: all must get PSLVERR and change nothing.
    class mlp_busy_seq extends uvm_sequence;
        `uvm_object_utils(mlp_busy_seq)
        mlp_env env;
        function new(string name = "mlp_busy_seq"); super.new(name); endfunction
        task body();
            mlp_op_seq s = mlp_op_seq::type_id::create("busy_op");
            uvm_reg cfg_regs[$];
            uvm_status_e st;
            uvm_reg_data_t v_old, v_new;
            s.env = env;
            if (!s.randomize() with { near_4k == 0; }) `uvm_fatal("RND", "op")
            env.cfg.lat_min = 200; env.cfg.lat_max = 300;    // keep the op busy long enough
            fork
                s.start(null, this);
                begin
                    // wait until the op has started (BUSY), then hammer the config registers
                    uvm_reg_data_t v;
                    do env.regs.status.read(st, v, .parent(this)); while (!v[0]);
                    cfg_regs = '{env.regs.ctrl, env.regs.a_addr, env.regs.b_addr, env.regs.c_addr,
                                 env.regs.rq_mult, env.regs.rq_shift, env.regs.rq_zp};
                    foreach (cfg_regs[i]) begin
                        cfg_regs[i].read(st, v_old, .parent(this));
                        cfg_regs[i].write(st, 32'h1234_5679, .parent(this));
                        if (st != UVM_NOT_OK) `uvm_error("SEQ", {"write while BUSY accepted: ", cfg_regs[i].get_name()})
                        env.sb.note_apb_error(8);
                        cfg_regs[i].read(st, v_new, .parent(this));
                        if (v_new != v_old) `uvm_error("SEQ", {"register changed while BUSY: ", cfg_regs[i].get_name()})
                    end
                end
            join
            env.cfg.lat_min = 0; env.cfg.lat_max = 6;
        endtask
    endclass

    // =================================================================== tests
    class mlp_base_test extends uvm_test;
        `uvm_component_utils(mlp_base_test)
        mlp_env env;
        mlp_cfg cfg;
        function new(string n, uvm_component p); super.new(n, p); endfunction
        function void build_phase(uvm_phase phase);
            cfg = mlp_cfg::type_id::create("cfg");
            uvm_config_db#(mlp_cfg)::set(this, "*", "cfg", cfg);
            env = mlp_env::type_id::create("env", this);
        endfunction
        task run_ops(int n, bit force_4k = 0);
            repeat (n) begin
                mlp_op_seq s = mlp_op_seq::type_id::create("op");
                s.env = env;
                if (!s.randomize() with { force_4k -> near_4k == 1; }) `uvm_fatal("RND", "op")
                s.start(null);
            end
        endtask
        task run_directed();
            // ReLU with a negative zero-point, saturation both ways, rounding ties, extreme scales
            int m[$] = '{1, 1, 1, 3, 32767, -32768, -1};
            int sh[$] = '{0, 0, 1, 2, 31, 20, 0};
            int z[$] = '{0, -5, 0, 10, 0, 3, 0};
            bit r[$] = '{0, 1, 0, 0, 0, 1, 0};
            foreach (m[k]) begin
                mlp_op_seq s = mlp_op_seq::type_id::create("dir");
                s.env = env;
                if (!s.randomize() with { mult == m[k]; zp == z[k]; relu == r[k]; near_4k == 0; }) `uvm_fatal("RND", "dir")
                s.shift = sh[k];
                if (k == 0) foreach (s.a[i]) begin s.a[i] = 127; s.b[i] = (i % 2) ? 127 : -128; end
                s.start(null);
            end
        endtask
        task run_errors();
            mlp_op_seq s;
            mlp_apb_err_seq ae = mlp_apb_err_seq::type_id::create("apb_err");
            mlp_busy_seq bs = mlp_busy_seq::type_id::create("busy");
            for (int k = 0; k < 5; k++) begin
                s = mlp_op_seq::type_id::create("err_op");
                s.env = env;
                if (!s.randomize() with { near_4k == 0; }) `uvm_fatal("RND", "err op")
                cfg.clear_errors();
                if (k == 0) cfg.rd_err_hi = 1;          // marker: sequence fills in the real range
                if (k == 1) cfg.wr_err_hi = 1;
                if (k >= 2) s.misalign = k - 2;
                s.start(null);
                cfg.clear_errors();
            end
            ae.env = env; ae.start(env.apb.sqr);
            bs.env = env; bs.start(null);
            run_ops(2);                                   // recovery after errors
        endtask
        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            `uvm_info("TEST", (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL)) == 0 ?
                      "*** TEST PASSED ***" : "*** TEST FAILED ***", UVM_NONE)
        endfunction
    endclass

    // Register model checks: reset values of all registers + walking-ones bit bash of the RW registers.
    class mlp_ral_test extends mlp_base_test;
        `uvm_component_utils(mlp_ral_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            uvm_reg_hw_reset_seq rst_seq = uvm_reg_hw_reset_seq::type_id::create("rst_seq");
            uvm_reg_bit_bash_seq bash    = uvm_reg_bit_bash_seq::type_id::create("bash");
            mlp_apb_err_seq ae = mlp_apb_err_seq::type_id::create("apb_err");
            phase.raise_objection(this);
            // CTRL.START would launch an operation; RO registers answer writes with PSLVERR
            uvm_resource_db#(bit)::set({"REG::", env.regs.ctrl.get_full_name()},     "NO_REG_BIT_BASH_TEST", 1, this);
            uvm_resource_db#(bit)::set({"REG::", env.regs.status.get_full_name()},   "NO_REG_BIT_BASH_TEST", 1, this);
            uvm_resource_db#(bit)::set({"REG::", env.regs.cycles.get_full_name()},   "NO_REG_BIT_BASH_TEST", 1, this);
            uvm_resource_db#(bit)::set({"REG::", env.regs.err_info.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
            uvm_resource_db#(bit)::set({"REG::", env.regs.id.get_full_name()},       "NO_REG_BIT_BASH_TEST", 1, this);
            rst_seq.model = env.regs; rst_seq.start(null);
            bash.model = env.regs;    bash.start(null);
            ae.env = env; ae.start(env.apb.sqr);
            run_ops(3);
            `uvm_info("RAL", "hw-reset and bit-bash sequences completed", UVM_NONE)
            phase.drop_objection(this);
        endtask
    endclass

    // Random operations only (used for bug-injection runs).
    class mlp_random_test extends mlp_base_test;
        `uvm_component_utils(mlp_random_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            int n = 100;
            void'($value$plusargs("NUM_OPS=%d", n));
            phase.raise_objection(this);
            run_ops(n);
            phase.drop_objection(this);
        endtask
    endclass

    // Everything in one run: directed corners, random ops, 4 KB-straddling ops, slow memory, errors.
    class mlp_full_test extends mlp_base_test;
        `uvm_component_utils(mlp_full_test)
        function new(string n, uvm_component p); super.new(n, p); endfunction
        task run_phase(uvm_phase phase);
            int n = 100;
            void'($value$plusargs("NUM_OPS=%d", n));
            phase.raise_objection(this);
            run_directed();
            run_ops(n);
            run_ops(n / 5 + 1, 1);
            cfg.p_ready = 25; cfg.p_gap = 60; cfg.lat_min = 10; cfg.lat_max = 30; cfg.b_dly_max = 20;
            run_ops(n / 5 + 1);
            cfg.p_ready = 70; cfg.p_gap = 20; cfg.lat_min = 0; cfg.lat_max = 6; cfg.b_dly_max = 4;
            run_errors();
            phase.drop_objection(this);
        endtask
    endclass
endpackage
