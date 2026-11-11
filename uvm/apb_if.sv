`timescale 1ns/1ps
// APB3 interface with protocol assertions (SVA)
interface apb_if (input logic pclk, input logic presetn);
    logic        psel, penable, pwrite;
    logic [11:0] paddr;
    logic [31:0] pwdata, prdata;
    logic        pready, pslverr;

    clocking drv_cb @(posedge pclk);
        default input #1step output #1;
        output psel, penable, pwrite, paddr, pwdata;
        input  prdata, pready, pslverr;
    endclocking

    clocking mon_cb @(posedge pclk);
        default input #1step;
        input psel, penable, pwrite, paddr, pwdata, prdata, pready, pslverr;
    endclocking

    // ---------------- protocol checks ----------------
    // SETUP is always followed by ACCESS
    a_setup_access: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && !penable) |=> (psel && penable))
        else $error("APB: SETUP not followed by ACCESS");
    // Address/control/data stable while waiting
    a_stable: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && penable && !pready) |=> (psel && penable && $stable(paddr) &&
                                          $stable(pwrite) && $stable(pwdata)))
        else $error("APB: signals changed during wait state");
    // PENABLE drops after the transfer completes
    a_penable_drop: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && penable && pready) |=> !penable)
        else $error("APB: PENABLE held after completed transfer");
    // No X on control when selected
    a_no_x: assert property (@(posedge pclk) disable iff (!presetn)
        psel |-> !$isunknown({penable, pwrite, paddr}))
        else $error("APB: X on control signals");
    // Slave: PSLVERR only valid in the last cycle of a transfer
    a_slverr_qual: assert property (@(posedge pclk) disable iff (!presetn)
        pslverr |-> (psel && penable && pready))
        else $error("APB: PSLVERR outside a completing transfer");
    // Slave: bounded wait states (liveness)
    a_ready_bounded: assert property (@(posedge pclk) disable iff (!presetn)
        (psel && penable) |-> ##[0:4] pready)
        else $error("APB: PREADY not asserted within 4 cycles");

    c_wait_state: cover property (@(posedge pclk) psel && penable && !pready);
    c_error_resp: cover property (@(posedge pclk) psel && penable && pready && pslverr);
    c_back2back:  cover property (@(posedge pclk) (psel && penable && pready) ##1 (psel && !penable));
endinterface
