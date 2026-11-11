"""APB3 master bus-functional model for cocotb."""
from cocotb.triggers import RisingEdge, ReadOnly


class ApbMaster:
    def __init__(self, dut, clk, max_wait=16):
        self.dut, self.clk, self.max_wait = dut, clk, max_wait
        self.wait_states_seen = 0
        dut.psel.value = 0
        dut.penable.value = 0
        dut.pwrite.value = 0
        dut.paddr.value = 0
        dut.pwdata.value = 0

    async def _xfer(self, addr, write, data=0):
        d = self.dut
        # SETUP phase
        d.psel.value, d.penable.value = 1, 0
        d.paddr.value, d.pwrite.value = addr, int(write)
        d.pwdata.value = data & 0xFFFFFFFF
        await RisingEdge(self.clk)
        # ACCESS phase
        d.penable.value = 1
        for _ in range(self.max_wait):
            await ReadOnly()
            ready = int(d.pready.value)
            rdata = int(d.prdata.value)
            err = int(d.pslverr.value)
            await RisingEdge(self.clk)
            if ready:
                break
            self.wait_states_seen += 1
        else:
            raise TimeoutError(f"APB: PREADY never asserted for addr 0x{addr:03x}")
        d.psel.value, d.penable.value = 0, 0
        return rdata, err

    async def write(self, addr, data):
        _, err = await self._xfer(addr, True, data)
        return err

    async def read(self, addr):
        return await self._xfer(addr, False)
