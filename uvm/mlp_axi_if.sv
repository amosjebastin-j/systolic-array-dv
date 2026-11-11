`timescale 1ns/1ps
// AXI4 interface (32-bit data, single ID) between mlp_top (master) and the UVM memory responder (slave).
interface mlp_axi_if (input logic clk, input logic rst_n);
    logic        arvalid, arready, rvalid, rready, rlast;
    logic [31:0] araddr, rdata;
    logic [7:0]  arlen;
    logic [2:0]  arsize;
    logic [1:0]  arburst, rresp;
    logic        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    logic [31:0] awaddr, wdata;
    logic [7:0]  awlen;
    logic [2:0]  awsize;
    logic [1:0]  awburst, bresp;
    logic [3:0]  wstrb;

    clocking slv_cb @(posedge clk);
        default input #1step output #1;
        input  arvalid, araddr, arlen, arsize, arburst, rready;
        output arready, rvalid, rdata, rresp, rlast;
        input  awvalid, awaddr, awlen, awsize, awburst, wvalid, wdata, wstrb, wlast, bready;
        output awready, wready, bvalid, bresp;
    endclocking

    // ---------------- master-side protocol checks (SVA)
    a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
        arvalid && !arready |=> arvalid && $stable({araddr, arlen, arsize, arburst}))
        else $error("AXI: AR changed while waiting for ARREADY");
    a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
        awvalid && !awready |=> awvalid && $stable({awaddr, awlen, awsize, awburst}))
        else $error("AXI: AW changed while waiting for AWREADY");
    a_w_stable:  assert property (@(posedge clk) disable iff (!rst_n)
        wvalid && !wready |=> wvalid && $stable({wdata, wstrb, wlast}))
        else $error("AXI: W changed while waiting for WREADY");
    a_ar_4k:     assert property (@(posedge clk) disable iff (!rst_n)
        arvalid |-> ({1'b0, araddr[11:0]} + ((13'(arlen) + 13'd1) << 2)) <= 13'h1000)
        else $error("AXI: read burst crosses a 4 KB boundary");
    a_aw_4k:     assert property (@(posedge clk) disable iff (!rst_n)
        awvalid |-> ({1'b0, awaddr[11:0]} + ((13'(awlen) + 13'd1) << 2)) <= 13'h1000)
        else $error("AXI: write burst crosses a 4 KB boundary");
    a_ar_fmt:    assert property (@(posedge clk) disable iff (!rst_n)
        arvalid |-> arsize == 3'd2 && arburst == 2'b01 && araddr[1:0] == 2'b00 && arlen < 8'd16)
        else $error("AXI: bad AR size/burst/alignment/length");
    a_aw_fmt:    assert property (@(posedge clk) disable iff (!rst_n)
        awvalid |-> awsize == 3'd2 && awburst == 2'b01 && awaddr[1:0] == 2'b00 && awlen < 8'd16)
        else $error("AXI: bad AW size/burst/alignment/length");
    // ---------------- slave-side checks (catch testbench mistakes)
    a_r_stable:  assert property (@(posedge clk) disable iff (!rst_n)
        rvalid && !rready |=> rvalid && $stable({rdata, rresp, rlast}))
        else $error("AXI: R changed while waiting for RREADY");
    a_b_stable:  assert property (@(posedge clk) disable iff (!rst_n)
        bvalid && !bready |=> bvalid && $stable(bresp))
        else $error("AXI: B changed while waiting for BREADY");

    c_ar_wait:   cover property (@(posedge clk) arvalid && !arready);
    c_w_wait:    cover property (@(posedge clk) wvalid && !wready);
    c_r_burst16: cover property (@(posedge clk) arvalid && arready && arlen == 8'd15);
endinterface
