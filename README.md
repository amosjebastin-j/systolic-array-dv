# Systolic-Array Matrix Multiplier: Design & Verification

An **N×N INT8 output-stationary systolic array** (the compute core of ML inference accelerators)
with an **APB3** control interface, verified with a **cocotb constrained-random testbench**,
a **UVM environment with SVA**, functional coverage, and a **bug-injection campaign**.

![regression](../../actions/workflows/regression.yml/badge.svg)

## Architecture
```
            APB3                 ┌──────────────── sa_apb_top ─────────────────┐
  PSEL/PENABLE/PADDR ──────────► │ reg file   A[N][N]  B[N][N]  CTRL/STATUS    │
  PWDATA/PRDATA/PREADY/PSLVERR ◄─│     │          │                            │
                                 │     ▼ skew     ▼ skew        FSM            │
                                 │   B[k][0] B[k][1] ...  IDLE→CLR→RUN(3N-2)   │
                                 │      ↓       ↓                              │
                                 │ A[0][k]→ PE ─→ PE ─→ ...   acc += a·b       │
                                 │ A[1][k]→ PE ─→ PE ─→ ...   (int32)          │
                                 │      ↓       ↓                              │
                                 │   C[i][j] = acc(i,j)  → read mux (1 wait)   │
                                 └─────────────────────────────────────────────┘
```
* Each PE does `acc += a_in * b_in` and forwards `a` right and `b` down.
* `A[i][k]` enters row *i* at cycle `i+k`; `B[k][j]` enters column *j* at cycle `k+j`; they meet at PE(i,j) at cycle `i+j+k`.
* Latency: 1 clear cycle + **3N−2** compute cycles (10 cycles for 4×4).

### Register map
| Offset | Name | Access | Description |
|---|---|---|---|
| 0x000 | CTRL | W | bit0 START (ignored while BUSY) |
| 0x004 | STATUS | R | bit0 BUSY, bit1 DONE |
| 0x008 | CYCLES | R | compute cycles of last operation |
| 0x00C | ID | R | `0x5A0000NN` |
| 0x100+4·(iN+j) | A[i][j] | RW | int8 |
| 0x200+4·(iN+j) | B[i][j] | RW | int8 |
| 0x300+4·(iN+j) | C[i][j] | R | int32, 1 wait state |

`PSLVERR` on: unmapped address, write to read-only register, write to A/B while BUSY.

## Verification environment
| | cocotb (`tb/`) | UVM (`uvm/`) |
|---|---|---|
| Driver | `ApbMaster` BFM (handles PREADY) | `apb_driver` via clocking block |
| Checker | Python golden model, all N² outputs | `sa_scoreboard` (shadow regs + SV model) |
| Protocol | — | 6 SVA assertions + 3 cover properties in `apb_if` |
| Coverage | 27 bins (`tb/coverage.py`) | 3 covergroups with a cross |
| Tests | reset, directed corners (49 combos), random, back-to-back, errors | `sa_random_test`, `sa_error_test` |

Full plan: [`docs/testplan.md`](docs/testplan.md).

## Results
Regression: 10 random seeds × 200 random operations, plus directed tests (~2,700 matrix multiplies, ~43,000 checked outputs):

| Metric | Result |
|---|---|
| Tests | 50/50 pass |
| Functional coverage | **27/27 bins (100%)** |
| Injected bugs caught | **5/5** |

| Injected bug | Caught by |
|---|---|
| `BUG_SIGN`: B treated as unsigned | directed, random, back-to-back, errors |
| `BUG_NOCLR`: accumulator not cleared | directed, random, back-to-back |
| `BUG_SKEW`: last row mis-timed | directed, random, back-to-back, errors |
| `BUG_PSLVERR`: no busy write-protect | errors |
| `BUG_CTRANSPOSE`: C read transposed | directed, random, back-to-back, errors |

## Run it
```bash
sudo apt install -y iverilog python3-pip make
pip install -r requirements.txt

make                                   # all cocotb tests, 4x4
make N=8 NUM_ITERS=50                  # 8x8 array
make SEED=1234                         # reproduce a seed
make DEFINES=BUG_SKEW                  # inject a bug -> tests must FAIL
python3 scripts/run_regression.py --seeds 10 --iters 200 --bugs   # full regression + report
cat results/regression_report.md
```
UVM flow (Xcelium / VCS / Questa / EDA Playground): see [`uvm/README.md`](uvm/README.md).

## Structure
```
rtl/       sa_pe.v  systolic_array.v  sa_apb_top.v
tb/        test_systolic.py  apb_master.py  model.py  coverage.py
uvm/       apb_if.sv (SVA)  sa_pkg.sv (agent/scoreboard/coverage/seqs/tests)  tb_top.sv
scripts/   run_regression.py
docs/      testplan.md
```

## Next steps
- AXI-Stream operand interface with back-pressure
- Weight-stationary variant and comparison of PE utilisation
- Saturating INT8 output mode with requantisation
- FPGA bring-up on PYNQ-Z2 driven from Python
