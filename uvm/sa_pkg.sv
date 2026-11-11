`timescale 1ns/1ps
`ifndef SA_N
`define SA_N 4
`endif
package sa_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int N = `SA_N;
    localparam bit [11:0] CTRL = 12'h000, STATUS = 12'h004, CYCLES = 12'h008, ID = 12'h00C;
    localparam bit [11:0] A_BASE = 12'h100, B_BASE = 12'h200, C_BASE = 12'h300;

    // =========================================================== item
    class apb_item extends uvm_sequence_item;
        rand bit [11:0] addr;
        rand bit        write;
        rand bit [31:0] data;
        bit      [31:0] rdata;
        bit             slverr;
        constraint c_align { addr[1:0] == 2'b00; }
        `uvm_object_utils_begin(apb_item)
            `uvm_field_int(addr, UVM_ALL_ON)
            `uvm_field_int(write, UVM_ALL_ON)
            `uvm_field_int(data, UVM_ALL_ON)
            `uvm_field_int(rdata, UVM_ALL_ON)
            `uvm_field_int(slverr, UVM_ALL_ON)
        `uvm_object_utils_end
        function new(string name = "apb_item"); super.new(name); endfunction
        function string convert2string();
            return $sformatf("%s addr=0x%03h %s=0x%08h slverr=%0b", write ? "WR" : "RD",
                             addr, write ? "wdata" : "rdata", write ? data : rdata, slverr);
        endfunction
    endclass

    typedef uvm_sequencer #(apb_item) apb_sequencer;

    // =========================================================== driver
    class apb_driver extends uvm_driver #(apb_item);
        `uvm_component_utils(apb_driver)
        virtual apb_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "apb_if not set")
        endfunction
        task run_phase(uvm_phase phase);
            vif.drv_cb.psel    <= 0;
            vif.drv_cb.penable <= 0;
            @(posedge vif.presetn);
            forever begin
                seq_item_port.get_next_item(req);
                drive(req);
                seq_item_port.item_done();
            end
        endtask
        task drive(apb_item t);
            @(vif.drv_cb);
            vif.drv_cb.psel    <= 1;      // SETUP
            vif.drv_cb.penable <= 0;
            vif.drv_cb.paddr   <= t.addr;
            vif.drv_cb.pwrite  <= t.write;
            vif.drv_cb.pwdata  <= t.write ? t.data : 32'h0;
            @(vif.drv_cb);
            vif.drv_cb.penable <= 1;      // ACCESS
            do @(vif.drv_cb); while (!vif.drv_cb.pready);
            t.rdata  = vif.drv_cb.prdata;
            t.slverr = vif.drv_cb.pslverr;
            vif.drv_cb.psel    <= 0;
            vif.drv_cb.penable <= 0;
        endtask
    endclass

    // =========================================================== monitor
    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)
        virtual apb_if vif;
        uvm_analysis_port #(apb_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "apb_if not set")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.mon_cb.psel && vif.mon_cb.penable && vif.mon_cb.pready) begin
                    apb_item t = apb_item::type_id::create("t");
                    t.addr   = vif.mon_cb.paddr;
                    t.write  = vif.mon_cb.pwrite;
                    t.data   = vif.mon_cb.pwdata;
                    t.rdata  = vif.mon_cb.prdata;
                    t.slverr = vif.mon_cb.pslverr;
                    `uvm_info("MON", t.convert2string(), UVM_HIGH)
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================== agent
    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)
        apb_sequencer sqr;
        apb_driver    drv;
        apb_monitor   mon;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            mon = apb_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = apb_sequencer::type_id::create("sqr", this);
                drv = apb_driver::type_id::create("drv", this);
            end
        endfunction
        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================== scoreboard
    // Shadows A/B from observed writes, predicts C = A x B at START, and checks
    // every C / CYCLES / ID read and every address-based PSLVERR.
    class sa_scoreboard extends uvm_subscriber #(apb_item);
        `uvm_component_utils(sa_scoreboard)
        byte         a_sh[N*N], b_sh[N*N];
        int          c_exp[N*N];
        bit          started, results_valid;
        int unsigned n_checked, n_errors_checked, n_ops;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function bit is_mapped(bit [11:0] a);
            if (a inside {CTRL, STATUS, CYCLES, ID}) return 1;
            if (a[11:10] == 0 && a[9:8] != 0 && a[7:2] < N*N) return 1;
            return 0;
        endfunction
        function bit is_ro(bit [11:0] a);
            return (a inside {STATUS, CYCLES, ID}) || (a[9:8] == 2'd3 && is_mapped(a));
        endfunction

        function void predict();
            foreach (c_exp[e]) begin
                int i = e / N, j = e % N;
                c_exp[e] = 0;
                for (int k = 0; k < N; k++) c_exp[e] += int'(a_sh[i*N+k]) * int'(b_sh[k*N+j]);
            end
        endfunction

        function void write(apb_item t);
            bit exp_err = !is_mapped(t.addr) || (t.write && is_ro(t.addr));
            int el = t.addr[7:2];
            if (exp_err) begin
                n_errors_checked++;
                if (!t.slverr) `uvm_error("SB", {"missing PSLVERR: ", t.convert2string()})
                return;
            end
            if (t.slverr) begin
                // only legal reason left: A/B write while an operation may be in flight
                if (!(t.write && t.addr[9:8] inside {1, 2} && started && !results_valid))
                    `uvm_error("SB", {"unexpected PSLVERR: ", t.convert2string()})
                return;
            end
            if (t.write) begin
                case (t.addr[9:8])
                    2'd1: if (t.addr[11:10] == 0) a_sh[el] = t.data[7:0];
                    2'd2: if (t.addr[11:10] == 0) b_sh[el] = t.data[7:0];
                    default: if (t.addr == CTRL && t.data[0]) begin
                        predict();
                        if (!started || results_valid) n_ops++;
                        started = 1; results_valid = 0;
                    end
                endcase
                return;
            end
            // ---- reads
            if (t.addr == STATUS && t.rdata[1] && !t.rdata[0]) results_valid = started;
            else if (t.addr == ID) begin
                if (t.rdata !== {8'h5A, 16'h0, 8'(N)}) `uvm_error("SB", $sformatf("ID=0x%08h", t.rdata))
            end else if (t.addr == CYCLES && results_valid) begin
                if (t.rdata != 3*N-2) `uvm_error("SB", $sformatf("CYCLES=%0d exp %0d", t.rdata, 3*N-2))
            end else if (t.addr[9:8] == 2'd1 && t.addr[11:10] == 0) begin
                if (t.rdata != 32'($signed(a_sh[el]))) `uvm_error("SB", {"A readback: ", t.convert2string()})
            end else if (t.addr[9:8] == 2'd2 && t.addr[11:10] == 0) begin
                if (t.rdata != 32'($signed(b_sh[el]))) `uvm_error("SB", {"B readback: ", t.convert2string()})
            end else if (t.addr[9:8] == 2'd3 && results_valid) begin
                n_checked++;
                if ($signed(t.rdata) != c_exp[el])
                    `uvm_error("SB", $sformatf("C[%0d][%0d] exp %0d got %0d", el / N, el % N,
                                               c_exp[el], $signed(t.rdata)))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("operations=%0d  C values checked=%0d  error responses checked=%0d",
                                      n_ops, n_checked, n_errors_checked), UVM_NONE)
            if (n_checked == 0) `uvm_error("SB", "no C results were checked")
        endfunction
    endclass

    // =========================================================== coverage
    class sa_coverage extends uvm_subscriber #(apb_item);
        `uvm_component_utils(sa_coverage)
        apb_item t;
        covergroup cg_bus;
            option.per_instance = 1;
            option.name = "bus";
            cp_region: coverpoint t.addr[11:8] {
                bins regs = {0}; bins a = {1}; bins b = {2}; bins c = {3}; bins unmapped = {[4:15]};
            }
            cp_dir:    coverpoint t.write;
            cp_err:    coverpoint t.slverr;
            x_reg_dir_err: cross cp_region, cp_dir, cp_err {
                ignore_bins rd_err_mapped = binsof(cp_region) intersect {[1:3]} &&
                                            binsof(cp_dir) intersect {0} && binsof(cp_err) intersect {1};
                ignore_bins unmapped_ok   = binsof(cp_region.unmapped) && binsof(cp_err) intersect {0};
                ignore_bins c_wr_ok       = binsof(cp_region.c) && binsof(cp_dir) intersect {1} &&
                                            binsof(cp_err) intersect {0};
            }
        endgroup
        covergroup cg_operand;
            option.per_instance = 1;
            option.name = "operand";
            cp_val: coverpoint $signed(t.data[7:0]) {
                bins min = {-128}; bins neg = {[-127:-2]}; bins m1 = {-1}; bins zero = {0};
                bins one = {1}; bins pos = {[2:126]}; bins max = {127};
            }
        endgroup
        covergroup cg_result;
            option.per_instance = 1;
            option.name = "result";
            cp_c: coverpoint $signed(t.rdata) {
                bins max_neg = {-128*127*N}; bins neg_large = {[-128*127*N+1:-32769]};
                bins neg = {[-32768:-1]}; bins zero = {0}; bins pos = {[1:32768]};
                bins pos_large = {[32769:128*128*N-1]}; bins max_pos = {128*128*N};
            }
        endgroup
        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_bus = new(); cg_operand = new(); cg_result = new();
        endfunction
        int unsigned hits[string];     // per-combination hit table, printed at the end
        function void write(apb_item t);
            string rn = (t.addr[11:8] == 0) ? "regs" : (t.addr[11:8] == 1) ? "A" :
                        (t.addr[11:8] == 2) ? "B" : (t.addr[11:8] == 3) ? "C" : "unmapped";
            string key = $sformatf("%-8s %s err=%0d", rn, t.write ? "WR" : "RD", t.slverr);
            hits[key]++;
            this.t = t;
            cg_bus.sample();
            if (t.write && !t.slverr && t.addr[9:8] inside {1, 2}) cg_operand.sample();
            if (!t.write && !t.slverr && t.addr[9:8] == 3) cg_result.sample();
        endfunction
        function void report_phase(uvm_phase phase);
            foreach (hits[k]) `uvm_info("COV", $sformatf("  bus combo  %-22s hits=%0d", k, hits[k]), UVM_NONE)
            `uvm_info("COV", $sformatf("bus=%.1f%%  operands=%.1f%%  results=%.1f%%",
                cg_bus.get_coverage(), cg_operand.get_coverage(), cg_result.get_coverage()), UVM_NONE)
        endfunction
    endclass

    // =========================================================== env
    class sa_env extends uvm_env;
        `uvm_component_utils(sa_env)
        apb_agent     agt;
        sa_scoreboard sb;
        sa_coverage   cov;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            agt = apb_agent::type_id::create("agt", this);
            sb  = sa_scoreboard::type_id::create("sb", this);
            cov = sa_coverage::type_id::create("cov", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agt.mon.ap.connect(sb.analysis_export);
            agt.mon.ap.connect(cov.analysis_export);
        endfunction
    endclass

    // =========================================================== sequences
    class sa_base_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(sa_base_seq)
        function new(string name = "sa_base_seq"); super.new(name); endfunction
        task wr(bit [11:0] a, bit [31:0] d, output bit err);
            apb_item t = apb_item::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { addr == a; write == 1; data == d; }) `uvm_fatal("RND", "wr")
            finish_item(t);
            err = t.slverr;
        endtask
        task rd(bit [11:0] a, output bit [31:0] d, output bit err);
            apb_item t = apb_item::type_id::create("t");
            start_item(t);
            if (!t.randomize() with { addr == a; write == 0; }) `uvm_fatal("RND", "rd")
            finish_item(t);
            d = t.rdata; err = t.slverr;
        endtask
        task poll_done();
            bit [31:0] st; bit e;
            repeat (100) begin
                rd(STATUS, st, e);
                if (st[1] && !st[0]) return;
            end
            `uvm_error("SEQ", "timeout waiting for DONE")
        endtask
    endclass

    // One full matrix multiply with corner-weighted random operands
    class sa_matmul_seq extends sa_base_seq;
        `uvm_object_utils(sa_matmul_seq)
        rand byte a[N*N], b[N*N];
        constraint c_dist {
            foreach (a[i]) a[i] dist { -128 := 10, 127 := 10, 0 := 10, [-127:126] :/ 70 };
            foreach (b[i]) b[i] dist { -128 := 10, 127 := 10, 0 := 10, [-127:126] :/ 70 };
        }
        function new(string name = "sa_matmul_seq"); super.new(name); endfunction
        task body();
            bit e; bit [31:0] d;
            foreach (a[i]) wr(A_BASE + 12'(4*i), 32'(a[i]), e);
            foreach (b[i]) wr(B_BASE + 12'(4*i), 32'(b[i]), e);
            wr(CTRL, 1, e);
            poll_done();
            rd(CYCLES, d, e);
            for (int i = 0; i < N*N; i++) rd(C_BASE + 12'(4*i), d, e);
        endtask
    endclass

    // Error responses and busy-time behaviour
    class sa_error_seq extends sa_base_seq;
        `uvm_object_utils(sa_error_seq)
        function new(string name = "sa_error_seq"); super.new(name); endfunction
        task body();
            bit e; bit [31:0] d;
            bit [11:0] unmapped[] = '{12'h010, 12'h0FC, 12'h400, 12'h800, 12'hFFC};
            foreach (unmapped[i]) begin rd(unmapped[i], d, e); wr(unmapped[i], 0, e); end
            wr(STATUS, 32'hFFFF_FFFF, e); wr(CYCLES, 1, e); wr(ID, 1, e); wr(C_BASE, 1, e);
            rd(ID, d, e);
            // start an op, then poke it while busy
            wr(CTRL, 1, e);
            wr(A_BASE, 32'h7F, e);
            if (!e) `uvm_error("SEQ", "write to A while BUSY was accepted")
            wr(B_BASE, 32'h80, e);
            if (!e) `uvm_error("SEQ", "write to B while BUSY was accepted")
            wr(CTRL, 1, e);              // START while busy: ignored
            rd(C_BASE, d, e);            // legal partial read
            poll_done();
            rd(CYCLES, d, e);
            // operand read-back (scoreboard compares against its shadow copy; the failed busy-time writes must not have changed it)
            rd(A_BASE, d, e);
            rd(A_BASE + 12'(4*(N*N-1)), d, e);
            rd(B_BASE, d, e);
            rd(B_BASE + 12'(4*(N*N-1)), d, e);
        endtask
    endclass

    // =========================================================== tests
    class sa_base_test extends uvm_test;
        `uvm_component_utils(sa_base_test)
        sa_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); env = sa_env::type_id::create("env", this); endfunction
        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
                `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
            else
                `uvm_info("TEST", "*** TEST FAILED ***", UVM_NONE)
        endfunction
    endclass

    class sa_random_test extends sa_base_test;
        `uvm_component_utils(sa_random_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            int num_ops = 200;
            void'($value$plusargs("NUM_OPS=%d", num_ops));
            phase.raise_objection(this);
            // directed extremes first: min x min, min x max, zero x random
            for (int k = 0; k < 3; k++) begin
                sa_matmul_seq s = sa_matmul_seq::type_id::create("s_dir");
                if (!s.randomize() with {
                        foreach (a[i]) a[i] == ((k == 2) ? 0 : -128);
                        foreach (b[i]) (k == 0) -> b[i] == -128;
                        foreach (b[i]) (k == 1) -> b[i] == 127; }) `uvm_fatal("RND", "directed")
                s.start(env.agt.sqr);
            end
            repeat (num_ops) begin
                sa_matmul_seq s = sa_matmul_seq::type_id::create("s");
                if (!s.randomize()) `uvm_fatal("RND", "matmul seq")
                s.start(env.agt.sqr);
            end
            // finish with the error/busy-behaviour sequence so one run closes the bus coverage
            begin
                sa_error_seq es = sa_error_seq::type_id::create("es_end");
                es.start(env.agt.sqr);
            end
            phase.drop_objection(this);
        endtask
    endclass

    class sa_error_test extends sa_base_test;
        `uvm_component_utils(sa_error_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            sa_error_seq es = sa_error_seq::type_id::create("es");
            sa_matmul_seq ms = sa_matmul_seq::type_id::create("ms");
            phase.raise_objection(this);
            if (!ms.randomize()) `uvm_fatal("RND", "matmul seq")
            ms.start(env.agt.sqr);
            es.start(env.agt.sqr);
            if (!ms.randomize()) `uvm_fatal("RND", "matmul seq")
            ms.start(env.agt.sqr);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
