`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import sa_pkg::*;
    logic pclk = 0, presetn = 0;
    always #5 pclk = ~pclk;
    initial begin repeat (5) @(posedge pclk); presetn <= 1; end

    apb_if bus (.pclk(pclk), .presetn(presetn));

    sa_apb_top #(.N(sa_pkg::N)) dut (
        .pclk(pclk), .presetn(presetn),
        .psel(bus.psel), .penable(bus.penable), .pwrite(bus.pwrite),
        .paddr(bus.paddr), .pwdata(bus.pwdata), .prdata(bus.prdata),
        .pready(bus.pready), .pslverr(bus.pslverr), .irq()
    );

    initial begin
        uvm_config_db#(virtual apb_if)::set(null, "*", "vif", bus);
        run_test("sa_random_test");
    end
endmodule
