"""cocotb test suite for sa_apb_top (systolic-array matrix multiplier)."""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from apb_master import ApbMaster
from coverage import cov
from model import matmul, to_s8, to_s32

CTRL, STATUS, CYCLES, ID = 0x000, 0x004, 0x008, 0x00C
A_BASE, B_BASE, C_BASE = 0x100, 0x200, 0x300
ITERS = int(os.environ.get("NUM_ITERS", "100"))
COV_FILE = os.environ.get("COV_FILE", "results/coverage.json")


# ----------------------------------------------------------------- helpers
async def setup(dut):
    cocotb.start_soon(Clock(dut.pclk, 10, unit="ns").start())
    apb = ApbMaster(dut, dut.pclk)
    dut.presetn.value = 0
    for _ in range(3):
        await RisingEdge(dut.pclk)
    dut.presetn.value = 1
    await RisingEdge(dut.pclk)
    rd, _ = await apb.read(ID)
    n = rd & 0xFF
    assert rd >> 24 == 0x5A, f"bad ID 0x{rd:08x}"
    return apb, n


def gen_matrix(n, kind):
    r = random.randint
    if kind == "zero":
        return [[0] * n for _ in range(n)]
    if kind == "identity":
        return [[1 if i == j else 0 for j in range(n)] for i in range(n)]
    if kind == "all_max":
        return [[127] * n for _ in range(n)]
    if kind == "all_min":
        return [[-128] * n for _ in range(n)]
    if kind == "alt_sign":
        return [[(127 if (i + j) % 2 else -128) for j in range(n)] for i in range(n)]
    if kind == "sparse":
        return [[(r(-128, 127) if random.random() < 0.2 else 0) for _ in range(n)] for _ in range(n)]
    if kind == "corner_mix":
        return [[random.choice([-128, -1, 0, 1, 127]) for _ in range(n)] for _ in range(n)]
    return [[r(-128, 127) for _ in range(n)] for _ in range(n)]


async def load(apb, n, a, b):
    for i in range(n):
        for j in range(n):
            assert await apb.write(A_BASE + 4 * (i * n + j), a[i][j] & 0xFF) == 0
            assert await apb.write(B_BASE + 4 * (i * n + j), b[i][j] & 0xFF) == 0


async def wait_done(apb, timeout=200):
    for _ in range(timeout):
        st, _ = await apb.read(STATUS)
        if st & 2 and not st & 1:
            return
    raise TimeoutError("DONE never set")


async def read_c(apb, n):
    c = [[0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            rd, err = await apb.read(C_BASE + 4 * (i * n + j))
            assert err == 0
            c[i][j] = to_s32(rd)
    return c


def sample_values(a, b, c):
    n = len(a)
    for i in range(n):
        for k in range(n):
            for j in range(n):
                x, y = a[i][k], b[k][j]
                if x == -128 and y == -128:
                    cov.hit("operand_pair", "min_x_min")
                elif {x, y} == {-128, 127}:
                    cov.hit("operand_pair", "min_x_max")
                elif x == 127 and y == 127:
                    cov.hit("operand_pair", "max_x_max")
                elif x == 0 or y == 0:
                    cov.hit("operand_pair", "zero_x_any")
    for row in c:
        for v in row:
            if v == 128 * 128 * n:
                cov.hit("c_value", "max_pos")
            elif v == -128 * 127 * n:
                cov.hit("c_value", "max_neg")
            elif v < -32768:
                cov.hit("c_value", "neg_large")
            elif v < 0:
                cov.hit("c_value", "neg")
            elif v == 0:
                cov.hit("c_value", "zero")
            elif v > 32768:
                cov.hit("c_value", "pos_large")
            else:
                cov.hit("c_value", "pos")


def check(a, b, c, tag):
    exp = matmul(a, b)
    for i, (er, gr) in enumerate(zip(exp, c)):
        for j, (e, g) in enumerate(zip(er, gr)):
            assert e == g, f"[{tag}] C[{i}][{j}] mismatch: expected {e}, got {g}\nA={a}\nB={b}"
    sample_values(a, b, c)


async def run_op(apb, n, a, b, tag):
    await load(apb, n, a, b)
    assert await apb.write(CTRL, 1) == 0
    await wait_done(apb)
    cyc, _ = await apb.read(CYCLES)
    assert cyc == 3 * n - 2, f"CYCLES={cyc}, expected {3 * n - 2}"
    c = await read_c(apb, n)
    check(a, b, c, tag)
    if apb.wait_states_seen:
        cov.hit("sequencing", "read_C_wait_state")


# ------------------------------------------------------------------- tests
@cocotb.test()
async def test_reset_values(dut):
    """Registers hold their documented reset values."""
    apb, n = await setup(dut)
    st, _ = await apb.read(STATUS)
    assert st == 0, f"STATUS after reset = {st}"
    for i in range(n * n):
        for base in (A_BASE, B_BASE, C_BASE):
            rd, err = await apb.read(base + 4 * i)
            assert err == 0 and rd == 0, f"reg 0x{base + 4 * i:03x} = {rd} after reset"
    cov.dump(COV_FILE)


@cocotb.test()
async def test_directed_corners(dut):
    """Directed corner cases: zero, identity, saturating extremes, sign mixes."""
    apb, n = await setup(dut)
    kinds = ["zero", "identity", "all_max", "all_min", "alt_sign", "sparse", "corner_mix"]
    for ka in kinds:
        for kb in kinds:
            a, b = gen_matrix(n, ka), gen_matrix(n, kb)
            await run_op(apb, n, a, b, f"{ka}x{kb}")
            cov.hit("matrix_kind", ka)
            cov.hit("matrix_kind", kb)
    cov.dump(COV_FILE)


@cocotb.test()
async def test_random(dut):
    """Constrained-random matrices (30% corner-weighted)."""
    apb, n = await setup(dut)
    weights = {"random": 70, "corner_mix": 10, "sparse": 10, "alt_sign": 5, "all_min": 5}
    for it in range(ITERS):
        ka = random.choices(list(weights), list(weights.values()))[0]
        kb = random.choices(list(weights), list(weights.values()))[0]
        a, b = gen_matrix(n, ka), gen_matrix(n, kb)
        await run_op(apb, n, a, b, f"rand{it}")
        cov.hit("matrix_kind", ka)
        cov.hit("matrix_kind", kb)
    dut._log.info(f"{ITERS} random matrix multiplies passed")
    cov.dump(COV_FILE)


@cocotb.test()
async def test_back_to_back(dut):
    """Consecutive operations must not leak accumulator state."""
    apb, n = await setup(dut)
    for it in range(20):
        a, b = gen_matrix(n, "random"), gen_matrix(n, "random")
        await run_op(apb, n, a, b, f"b2b{it}")
        if it:
            cov.hit("sequencing", "back_to_back")
    cov.dump(COV_FILE)


@cocotb.test()
async def test_apb_errors(dut):
    """PSLVERR rules, START-while-busy, and write protection while BUSY."""
    apb, n = await setup(dut)
    # unmapped addresses
    unmapped = [0x010, 0x0FC, 0x400, 0xFFC] + ([A_BASE + 4 * n * n] if n * n < 64 else [])
    for addr in unmapped:
        _, err = await apb.read(addr)
        assert err == 1, f"no PSLVERR on unmapped read 0x{addr:03x}"
        cov.hit("apb_error", "unmapped")
    # writes to read-only registers
    for addr in (STATUS, CYCLES, ID, C_BASE):
        assert await apb.write(addr, 0xDEADBEEF) == 1, f"no PSLVERR on RO write 0x{addr:03x}"
        cov.hit("apb_error", "ro_write")

    a, b = gen_matrix(n, "random"), gen_matrix(n, "random")
    await load(apb, n, a, b)
    assert await apb.write(CTRL, 1) == 0
    st, _ = await apb.read(STATUS)
    assert st & 1, "BUSY not set after START"
    # writes while busy must error and must not modify the operand
    assert await apb.write(A_BASE, 0x55) == 1, "no PSLVERR writing A while BUSY"
    cov.hit("apb_error", "write_A_busy")
    assert await apb.write(B_BASE, 0x55) == 1, "no PSLVERR writing B while BUSY"
    cov.hit("apb_error", "write_B_busy")
    # START while busy is ignored, not an error
    assert await apb.write(CTRL, 1) == 0
    cov.hit("sequencing", "start_while_busy")
    # reading C while busy is legal
    _, err = await apb.read(C_BASE)
    assert err == 0
    cov.hit("sequencing", "read_C_while_busy")
    await wait_done(apb)
    rd, _ = await apb.read(A_BASE)
    assert to_s8(rd) == a[0][0], "A[0][0] was modified by a write while BUSY"
    check(a, b, await read_c(apb, n), "errors")
    cyc, _ = await apb.read(CYCLES)
    assert cyc == 3 * n - 2, "START while busy restarted the engine"
    hit, total = cov.summary()
    dut._log.info(f"functional coverage (this run): {hit}/{total} bins")
    cov.dump(COV_FILE)
