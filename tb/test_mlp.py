"""cocotb tests for mlp_top: DLRM MLP layer = INT8 GEMM (systolic array) + AXI4 DMA + requantization."""
import math
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from apb_master import ApbMaster
from axi_mem import AxiMem
from coverage import Coverage
from mlp_model import mlp_layer
from model import to_s8

CTRL, STATUS, A_ADDR, B_ADDR, C_ADDR = 0x00, 0x04, 0x08, 0x0C, 0x10
RQ_MULT, RQ_SHIFT, RQ_ZP, CYCLES, ERR_INFO, ID = 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28
ITERS = int(os.environ.get("NUM_ITERS", "100"))
COV_FILE = os.environ.get("COV_FILE", "results/coverage_mlp.json")

cov = Coverage()
cov.define("mlp_relu", ["off", "on"])
cov.define("mlp_shift", ["zero", "1_7", "8_15", "16_23", "24_31"])
cov.define("mlp_mult", ["positive", "negative", "one", "max_pos", "max_neg"])
cov.define("mlp_output", ["in_range", "sat_hi", "sat_lo", "relu_clamp", "rounded_up"])
cov.define("mlp_burst", ["single_beat", "split_part", "full_length"])   # full_length = min(16, N*N/4) beats
cov.define("mlp_dma", ["split_at_4k", "back_to_back", "slow_memory"])
cov.define("mlp_error", ["axi_read_slverr", "axi_write_slverr", "misaligned_addr",
                         "apb_unmapped", "apb_ro_write", "apb_cfg_while_busy"])
STATS = {"ops": 0, "outputs": 0}


# ---------------------------------------------------------------- helpers
async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    apb = ApbMaster(dut, dut.clk)
    mem = AxiMem(dut, dut.clk)
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    mem.start()
    rd, err = await apb.read(ID)
    assert err == 0 and rd >> 16 == 0x4D4C, f"bad ID 0x{rd:08x}"
    return apb, mem, rd & 0xFF


def finish(dut, tag, mem):
    assert not mem.violations, f"AXI protocol violations: {mem.violations[:5]}"
    hit, tot = cov.summary()
    dut._log.info(f"[{tag}] ops={STATS['ops']} outputs checked={STATS['outputs']} coverage={hit}/{tot}")
    cov.dump(COV_FILE)


def rand_matrix(n, kind="random"):
    r = random.randint
    if kind == "identity":
        return [[1 if i == j else 0 for j in range(n)] for i in range(n)]
    if kind == "max":
        return [[127] * n for _ in range(n)]
    if kind == "min":
        return [[-128] * n for _ in range(n)]
    if kind == "corner":
        return [[random.choice([-128, -1, 0, 1, 127]) for _ in range(n)] for _ in range(n)]
    return [[r(-128, 127) for _ in range(n)] for _ in range(n)]


def rand_quant(n):
    """Mostly realistic scales (outputs land in int8 range), some extremes."""
    relu = random.random() < 0.5
    zp = random.choice([0, 0, random.randint(-20, 20), random.randint(-128, 127)])
    k = random.random()
    if k < 0.08:
        return random.choice([1, 32767, -32768, -1]), random.randint(0, 31), zp, relu
    mult = random.randint(1, 32767) * (-1 if random.random() < 0.2 else 1)
    typical = 128 * 128 * n / 4            # rough |acc| scale
    shift = round(math.log2(abs(mult) * typical / 64)) + random.randint(-2, 2)
    return mult, max(0, min(31, shift)), zp, relu


def place(n, near_4k=False, pages=None):
    """Three non-overlapping 4-byte-aligned regions (A, B, C); optionally straddling 4 KB boundaries."""
    size = n * n
    pages = pages or random.sample(range(1, 200, 2), 3)
    out = []
    for p in pages:
        base = p * 0x1000
        if near_4k:
            off = 0x1000 - 4 * random.randint(1, max(1, size // 4 - 1))
        else:
            off = 4 * random.randint(0, (0x1000 - size) // 4)
        out.append(base + off)
    return out


def sample(c, mult, shift, zp, relu):
    cov.hit("mlp_relu", "on" if relu else "off")
    cov.hit("mlp_shift", "zero" if shift == 0 else "1_7" if shift < 8 else "8_15" if shift < 16
            else "16_23" if shift < 24 else "24_31")
    cov.hit("mlp_mult", {1: "one", 32767: "max_pos", -32768: "max_neg"}.get(
        mult, "positive" if mult > 0 else "negative"))
    for row in c:
        for acc in row:
            p = acc * mult
            rounded = (p + (1 << (shift - 1))) >> shift if shift else p
            y = rounded + zp
            if y > 127:
                cov.hit("mlp_output", "sat_hi")
            elif relu and y < zp:
                cov.hit("mlp_output", "relu_clamp")
            elif not relu and y < -128:
                cov.hit("mlp_output", "sat_lo")
            else:
                cov.hit("mlp_output", "in_range")
            if shift and rounded != p >> shift and -128 <= y <= 127:
                cov.hit("mlp_output", "rounded_up")


def sample_bursts(mem, first, n):
    full = min(16, n * n // 4)
    for addr, beats in mem.rd_bursts[first[0]:] + mem.wr_bursts[first[1]:]:
        if beats == 1:
            cov.hit("mlp_burst", "single_beat")
        cov.hit("mlp_burst", "full_length" if beats == full else "split_part")
        if ((addr + 4 * beats) & 0xFFF) == 0:
            cov.hit("mlp_dma", "split_at_4k")


async def configure(apb, addrs, mult, shift, zp):
    for reg, val in zip((A_ADDR, B_ADDR, C_ADDR, RQ_MULT, RQ_SHIFT, RQ_ZP),
                        (*addrs, mult & 0xFFFF, shift, zp & 0xFF)):
        assert await apb.write(reg, val) == 0, f"config write 0x{reg:02x} failed"


async def wait_done(apb, timeout=5000):
    for _ in range(timeout):
        st, _ = await apb.read(STATUS)
        if st & 2 and not st & 1:
            return st
    raise TimeoutError("DONE never set")


async def run_op(apb, mem, n, a, b, mult, shift, zp, relu, addrs=None, near_4k=False, expect_err=0):
    addrs = addrs or place(n, near_4k)
    mem.write_bytes(addrs[0], [v for row in a for v in row])
    mem.write_bytes(addrs[1], [v for row in b for v in row])
    mem.write_bytes(addrs[2], [0x5A] * (n * n))                 # poison destination
    first = (len(mem.rd_bursts), len(mem.wr_bursts))
    await configure(apb, addrs, mult, shift, zp)
    assert await apb.write(CTRL, 1 | (int(relu) << 1)) == 0
    st = await wait_done(apb)
    einfo, _ = await apb.read(ERR_INFO)
    assert einfo == expect_err, f"ERR_INFO 0x{einfo:x}, expected 0x{expect_err:x}"
    assert bool(st & 4) == bool(expect_err), f"STATUS.ERR={st >> 2 & 1}, expected {int(bool(expect_err))}"
    if expect_err:
        return
    c, exp = mlp_layer(a, b, mult, shift, zp, relu)
    got_flat = [to_s8(v) for v in mem.read_bytes(addrs[2], n * n)]
    got = [got_flat[i * n:(i + 1) * n] for i in range(n)]
    for i in range(n):
        for j in range(n):
            assert got[i][j] == exp[i][j], (
                f"C[{i}][{j}]: acc={c[i][j]} mult={mult} shift={shift} zp={zp} relu={relu} "
                f"expected {exp[i][j]} got {got[i][j]}")
    sample(c, mult, shift, zp, relu)
    sample_bursts(mem, first, n)
    cyc, _ = await apb.read(CYCLES)
    assert cyc > 3 * n - 2, f"CYCLES={cyc} too small"
    STATS["ops"] += 1
    STATS["outputs"] += n * n


# ---------------------------------------------------------------- tests
@cocotb.test()
async def test_mlp_registers(dut):
    """Reset values, read/write of every config register with field masks, APB error responses."""
    apb, mem, n = await setup(dut)
    for reg, exp in ((CTRL, 0), (STATUS, 0), (A_ADDR, 0), (B_ADDR, 0), (C_ADDR, 0), (RQ_MULT, 1),
                     (RQ_SHIFT, 0), (RQ_ZP, 0), (CYCLES, 0), (ERR_INFO, 0)):
        rd, err = await apb.read(reg)
        assert err == 0 and rd == exp, f"reset 0x{reg:02x}: 0x{rd:08x} != 0x{exp:x}"
    masks = {A_ADDR: 0xFFFFFFFF, B_ADDR: 0xFFFFFFFF, C_ADDR: 0xFFFFFFFF, RQ_MULT: 0xFFFF,
             RQ_SHIFT: 0x1F, RQ_ZP: 0xFF}
    for _ in range(20):
        for reg, m in masks.items():
            v = random.getrandbits(32)
            assert await apb.write(reg, v) == 0
            rd, _ = await apb.read(reg)
            assert rd == v & m, f"0x{reg:02x}: wrote 0x{v:08x} read 0x{rd:08x}"
    assert await apb.write(CTRL, 2) == 0
    assert (await apb.read(CTRL))[0] == 2, "RELU_EN not readable, START must read 0"
    for reg in (STATUS, CYCLES, ERR_INFO, ID):
        assert await apb.write(reg, 0xFFFFFFFF) == 1, f"write to RO 0x{reg:02x} not rejected"
        cov.hit("mlp_error", "apb_ro_write")
    for addr in (0x02C, 0x030, 0x100, 0xFFC):
        _, err = await apb.read(addr)
        assert err == 1, f"unmapped 0x{addr:03x} not rejected"
        cov.hit("mlp_error", "apb_unmapped")
    finish(dut, "registers", mem)


@cocotb.test()
async def test_mlp_directed(dut):
    """Corner cases: pass-through, saturation both ways, ReLU with zero-point, rounding ties, extreme scales."""
    apb, mem, n = await setup(dut)
    I = rand_matrix(n, "identity")
    ramp = [[(i * n + j) * 7 % 256 - 128 for j in range(n)] for i in range(n)]
    cases = [
        (I, ramp, 1, 0, 0, False),                     # C = B passes straight through
        (rand_matrix(n, "max"), rand_matrix(n, "max"), 1, 0, 0, False),      # saturate high
        (rand_matrix(n, "max"), rand_matrix(n, "min"), 1, 0, 0, False),      # saturate low
        (rand_matrix(n, "corner"), rand_matrix(n, "corner"), 1, 8, -5, True),  # ReLU at zp=-5
        (I, [[(-1) ** j * (2 * ((i * n + j) % 60) + 1) for j in range(n)] for i in range(n)], 1, 1, 0, False),
        (I, ramp, 3, 2, 10, False),                    # ties at .5 -> round half up
        (rand_matrix(n), rand_matrix(n), 32767, 31, 0, False),
        (rand_matrix(n), rand_matrix(n), -32768, 20, 3, True),
        (rand_matrix(n), rand_matrix(n), -1, 0, 0, False),
        (rand_matrix(n, "min"), rand_matrix(n, "min"), 1, 31, 127, True),
    ]
    for a, b, mult, shift, zp, relu in cases:
        await run_op(apb, mem, n, a, b, mult, shift, zp, relu)
    finish(dut, "directed", mem)


@cocotb.test()
async def test_mlp_random(dut):
    """Constrained-random matrices, quantization parameters and buffer placement; back-to-back operations."""
    apb, mem, n = await setup(dut)
    for k in range(ITERS):
        mult, shift, zp, relu = rand_quant(n)
        kind = random.choice(["random"] * 6 + ["corner", "max", "min", "identity"])
        await run_op(apb, mem, n, rand_matrix(n, kind), rand_matrix(n), mult, shift, zp, relu,
                     near_4k=random.random() < 0.2)
        if k:
            cov.hit("mlp_dma", "back_to_back")
    finish(dut, "random", mem)


@cocotb.test()
async def test_mlp_4k_boundary(dut):
    """Every buffer straddles a 4 KB boundary: each transfer must be split into two bursts."""
    apb, mem, n = await setup(dut)
    for _ in range(max(10, ITERS // 5)):
        nb = len(mem.rd_bursts) + len(mem.wr_bursts)
        mult, shift, zp, relu = rand_quant(n)
        await run_op(apb, mem, n, rand_matrix(n), rand_matrix(n), mult, shift, zp, relu, near_4k=True)
        if n * n >= 8:
            assert len(mem.rd_bursts) + len(mem.wr_bursts) - nb == 6, \
                "each of A, B, C straddles 4 KB, so there must be 2 bursts each"
    finish(dut, "4k", mem)


@cocotb.test()
async def test_mlp_axi_errors(dut):
    """SLVERR on read and on write sets ERR; misaligned address is rejected with no bus traffic; recovery."""
    apb, mem, n = await setup(dut)
    a, b = rand_matrix(n), rand_matrix(n)
    addrs = place(n)
    mem.rd_err = [(addrs[1], addrs[1] + n * n)]
    await run_op(apb, mem, n, a, b, 1, 4, 0, False, addrs=addrs, expect_err=1)
    cov.hit("mlp_error", "axi_read_slverr")
    mem.rd_err = []
    addrs = place(n)
    mem.wr_err = [(addrs[2], addrs[2] + n * n)]
    await run_op(apb, mem, n, a, b, 1, 4, 0, False, addrs=addrs, expect_err=2)
    cov.hit("mlp_error", "axi_write_slverr")
    mem.wr_err = []
    for bad in range(3):
        addrs = place(n)
        addrs[bad] += random.randint(1, 3)
        before = (len(mem.rd_bursts), len(mem.wr_bursts))
        await run_op(apb, mem, n, a, b, 1, 4, 0, False, addrs=addrs, expect_err=4)
        assert (len(mem.rd_bursts), len(mem.wr_bursts)) == before, "misaligned op generated AXI traffic"
        cov.hit("mlp_error", "misaligned_addr")
    await run_op(apb, mem, n, a, b, 1, 4, 0, False)              # clean op after errors
    finish(dut, "axi-errors", mem)


@cocotb.test()
async def test_mlp_cfg_while_busy(dut):
    """Config writes and START while BUSY get PSLVERR and change nothing; the running op completes correctly."""
    apb, mem, n = await setup(dut)
    mem.lat = (20, 40)
    a, b = rand_matrix(n), rand_matrix(n)
    addrs = place(n)
    mem.write_bytes(addrs[0], [v for r in a for v in r])
    mem.write_bytes(addrs[1], [v for r in b for v in r])
    await configure(apb, addrs, 5, 6, -3)
    assert await apb.write(CTRL, 1) == 0
    st, _ = await apb.read(STATUS)
    assert st & 1, "not BUSY after START"
    for reg in (CTRL, A_ADDR, B_ADDR, C_ADDR, RQ_MULT, RQ_SHIFT, RQ_ZP):
        assert await apb.write(reg, 0x12345678) == 1, f"write 0x{reg:02x} while BUSY not rejected"
        cov.hit("mlp_error", "apb_cfg_while_busy")
    await wait_done(apb)
    for reg, exp in ((A_ADDR, addrs[0]), (RQ_MULT, 5), (RQ_SHIFT, 6), (RQ_ZP, 0xFD), (CTRL, 0)):
        assert (await apb.read(reg))[0] == exp, f"0x{reg:02x} changed while BUSY"
    _, exp = mlp_layer(a, b, 5, 6, -3, False)
    got = [to_s8(v) for v in mem.read_bytes(addrs[2], n * n)]
    assert got == [v for r in exp for v in r], "result corrupted by writes while BUSY"
    finish(dut, "cfg-busy", mem)


@cocotb.test()
async def test_mlp_slow_memory(dut):
    """Long read latency, sparse READY and slow write responses."""
    apb, mem, n = await setup(dut)
    mem.p_ready, mem.p_gap, mem.lat, mem.b_delay = 25, 60, (10, 30), (5, 20)
    for _ in range(max(10, ITERS // 5)):
        mult, shift, zp, relu = rand_quant(n)
        await run_op(apb, mem, n, rand_matrix(n), rand_matrix(n), mult, shift, zp, relu,
                     near_4k=random.random() < 0.3)
        cov.hit("mlp_dma", "slow_memory")
    finish(dut, "slow-memory", mem)
