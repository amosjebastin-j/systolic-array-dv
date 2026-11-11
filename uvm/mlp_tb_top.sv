`timescale 1ns/1ps
module mlp_tb_top;
    import uvm_pkg::*;
    import mlp_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    initial begin repeat (5) @(posedge clk); rst_n <= 1; end

    apb_if     apb (.pclk(clk), .presetn(rst_n));
    mlp_axi_if axi (.clk(clk), .rst_n(rst_n));

    mlp_top #(.N(mlp_pkg::N)) dut (
        .clk(clk), .rst_n(rst_n),
        .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite), .paddr(apb.paddr),
        .pwdata(apb.pwdata), .prdata(apb.prdata), .pready(apb.pready), .pslverr(apb.pslverr), .irq(),
        .m_axi_arvalid(axi.arvalid), .m_axi_arready(axi.arready), .m_axi_araddr(axi.araddr),
        .m_axi_arlen(axi.arlen), .m_axi_arsize(axi.arsize), .m_axi_arburst(axi.arburst),
        .m_axi_rvalid(axi.rvalid), .m_axi_rready(axi.rready), .m_axi_rdata(axi.rdata),
        .m_axi_rresp(axi.rresp), .m_axi_rlast(axi.rlast),
        .m_axi_awvalid(axi.awvalid), .m_axi_awready(axi.awready), .m_axi_awaddr(axi.awaddr),
        .m_axi_awlen(axi.awlen), .m_axi_awsize(axi.awsize), .m_axi_awburst(axi.awburst),
        .m_axi_wvalid(axi.wvalid), .m_axi_wready(axi.wready), .m_axi_wdata(axi.wdata),
        .m_axi_wstrb(axi.wstrb), .m_axi_wlast(axi.wlast),
        .m_axi_bvalid(axi.bvalid), .m_axi_bready(axi.bready), .m_axi_bresp(axi.bresp)
    );

    initial begin
        uvm_config_db#(virtual apb_if)::set(null, "*", "vif", apb);
        uvm_config_db#(virtual mlp_axi_if)::set(null, "*", "axi_vif", axi);
        run_test("mlp_full_test");
    end
endmodule
