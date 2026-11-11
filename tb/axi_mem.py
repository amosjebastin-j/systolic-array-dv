"""Reactive AXI4 slave memory for cocotb (32-bit data).

* random AR/AW/W ready, random read latency and R gaps, random B delay
* checks every request: ARSIZE/AWSIZE = 4 bytes, INCR burst, no 4 KB crossing,
  WLAST exactly on the last beat, WSTRB = 0xF
* error injection: address ranges that answer SLVERR on read or write
"""
import random
from collections import deque

from cocotb.triggers import ReadOnly, RisingEdge


class AxiMem:
    def __init__(self, dut, clk):
        self.dut, self.clk = dut, clk
        self.mem = {}
        self.p_ready = 70          # % chance AR/AW/W ready is high in a cycle
        self.p_gap = 20            # % chance of an idle cycle between R beats
        self.lat = (0, 6)          # read latency range (cycles) after AR
        self.b_delay = (0, 4)
        self.rd_err = []           # [(lo, hi)] address ranges answering SLVERR on read
        self.wr_err = []
        self.violations = []
        self.rd_bursts, self.wr_bursts = [], []   # (addr, beats)
        self.cycle = 0
        d = dut
        d.m_axi_arready.value = 0
        d.m_axi_rvalid.value = 0
        d.m_axi_rdata.value = 0
        d.m_axi_rresp.value = 0
        d.m_axi_rlast.value = 0
        d.m_axi_awready.value = 0
        d.m_axi_wready.value = 0
        d.m_axi_bvalid.value = 0
        d.m_axi_bresp.value = 0

    # ---------------------------------------------------------------- helpers
    def write_bytes(self, addr, data):
        for i, v in enumerate(data):
            self.mem[addr + i] = v & 0xFF

    def read_bytes(self, addr, n):
        return [self.mem.get(addr + i, 0) for i in range(n)]

    def _in(self, ranges, addr):
        return any(lo <= addr < hi for lo, hi in ranges)

    def _check_req(self, kind, addr, alen, size, burst):
        beats = alen + 1
        if size != 2:
            self.violations.append(f"{kind}: size {size} != 2 (4 bytes)")
        if burst != 1:
            self.violations.append(f"{kind}: burst type {burst} != INCR")
        if addr & 3:
            self.violations.append(f"{kind}: unaligned address 0x{addr:08x}")
        if beats > 16:
            self.violations.append(f"{kind}: {beats} beats > 16")
        if (addr & 0xFFF) + 4 * beats > 0x1000:
            self.violations.append(f"{kind}: burst 0x{addr:08x}+{4*beats} crosses a 4 KB boundary")

    def start(self):
        import cocotb
        cocotb.start_soon(self._read_proc())
        cocotb.start_soon(self._write_proc())

    # ---------------------------------------------------------------- read side
    async def _read_proc(self):
        d = self.dut
        q = deque()                  # [addr, beats, sent, ready_at, err]
        rvalid = 0
        while True:
            await ReadOnly()
            ar_hs = int(d.m_axi_arvalid.value) and int(d.m_axi_arready.value)
            if ar_hs:
                addr, alen = int(d.m_axi_araddr.value), int(d.m_axi_arlen.value)
                self._check_req("AR", addr, alen, int(d.m_axi_arsize.value), int(d.m_axi_arburst.value))
                q.append([addr, alen + 1, 0, self.cycle + random.randint(*self.lat),
                          self._in(self.rd_err, addr)])
                self.rd_bursts.append((addr, alen + 1))
            r_hs = rvalid and int(d.m_axi_rready.value)
            await RisingEdge(self.clk)
            self.cycle += 1
            if r_hs:
                q[0][2] += 1
                if q[0][2] == q[0][1]:
                    q.popleft()
                rvalid = 0
            d.m_axi_arready.value = int(random.randint(0, 99) < self.p_ready)
            if not rvalid and q and q[0][3] <= self.cycle and random.randint(0, 99) >= self.p_gap:
                b = q[0]
                a = b[0] + 4 * b[2]
                data = self.read_bytes(a, 4)
                d.m_axi_rdata.value = data[0] | data[1] << 8 | data[2] << 16 | data[3] << 24
                d.m_axi_rresp.value = 2 if b[4] else 0
                d.m_axi_rlast.value = int(b[2] == b[1] - 1)
                rvalid = 1
            d.m_axi_rvalid.value = rvalid

    # ---------------------------------------------------------------- write side
    async def _write_proc(self):
        d = self.dut
        aw = deque()                 # [addr, beats, received, err]
        bq = deque()                 # [due_cycle, resp]
        bvalid = 0
        while True:
            await ReadOnly()
            if int(d.m_axi_awvalid.value) and int(d.m_axi_awready.value):
                addr, alen = int(d.m_axi_awaddr.value), int(d.m_axi_awlen.value)
                self._check_req("AW", addr, alen, int(d.m_axi_awsize.value), int(d.m_axi_awburst.value))
                aw.append([addr, alen + 1, 0, self._in(self.wr_err, addr)])
                self.wr_bursts.append((addr, alen + 1))
            if int(d.m_axi_wvalid.value) and int(d.m_axi_wready.value):
                if not aw:
                    self.violations.append("W beat with no outstanding AW")
                else:
                    b = aw[0]
                    data, strb, last = int(d.m_axi_wdata.value), int(d.m_axi_wstrb.value), int(d.m_axi_wlast.value)
                    if strb != 0xF:
                        self.violations.append(f"WSTRB 0x{strb:x} != 0xF")
                    exp_last = int(b[2] == b[1] - 1)
                    if last != exp_last:
                        self.violations.append(f"WLAST={last} on beat {b[2]} of {b[1]} (burst 0x{b[0]:08x})")
                    if not b[3]:
                        self.write_bytes(b[0] + 4 * b[2], [(data >> (8 * i)) & 0xFF for i in range(4)])
                    b[2] += 1
                    if b[2] == b[1]:
                        bq.append([self.cycle + random.randint(*self.b_delay), 2 if b[3] else 0])
                        aw.popleft()
            b_hs = bvalid and int(d.m_axi_bready.value)
            await RisingEdge(self.clk)
            if b_hs:
                bq.popleft()
                bvalid = 0
            d.m_axi_awready.value = int(random.randint(0, 99) < self.p_ready)
            d.m_axi_wready.value = int(random.randint(0, 99) < self.p_ready)
            if not bvalid and bq and bq[0][0] <= self.cycle:
                d.m_axi_bresp.value = bq[0][1]
                bvalid = 1
            d.m_axi_bvalid.value = bvalid
