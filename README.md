# DLRM MLP Accelerator: INT8 Systolic Array with AXI4 DMA — Design & Verification

[![regression](https://github.com/amosjebastin-j/systolic-array-dv/actions/workflows/regression.yml/badge.svg)](https://github.com/amosjebastin-j/systolic-array-dv/actions)

The MLP (fully-connected) layers of Meta's **DLRM** recommendation model are INT8 matrix multiplies
followed by requantization. This repo builds that layer engine in RTL and verifies it:

* **v2 `mlp_top`** (current): an N×N INT8 **systolic array** fed by an **AXI4 DMA master**
  (reads A and B from memory, writes C back), with per-output **INT8 requantization**
  (multiplier, rounding shift, zero-point, optional ReLU) and an **APB3** register file.
  Verified with cocotb (Python golden model + reactive AXI4 memory) and **UVM with a RAL register model**.
* **v1 `sa_apb_top`**: the original APB-mapped array (operands and int32 results through registers),
  kept with its own cocotb + UVM verification.

## v2 architecture (`mlp_top`)
```
          APB3 (config)                           AXI4 master (32-bit, INCR, ≤16 beats, never crosses 4 KB)
 CPU ──► CTRL STATUS A_ADDR B_ADDR C_ADDR        ┌──────────────────────────────────────────────────┐
         RQ_MULT RQ_SHIFT RQ_ZP CYCLES ERR_INFO  │  DMA FSM: AR/R (A) → AR/R (B) → compute →          │
                                                 │           AW/W/B (C)          split at 4 KB        │
                                                 │      A buf ─┐                                       │
                                                 │      B buf ─┴─► sa_core (N×N systolic array, int32) │
                                                 │                  └─► N² × mlp_requant ─► int8 C    │
                                                 └──────────────────────────────────────────────────┘
```
Requantization (same as TFLite / PyTorch quantized inference), per output element:
`y = clamp( ((acc · MULT) + 2^(SHIFT−1)) >>> SHIFT + ZP, lo, 127 )`, `lo = ZP` if ReLU else −128.

| Offset | Register | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | RW | bit0 START (reads 0), bit1 RELU_EN |
| 0x04 | STATUS | RO | bit0 BUSY, bit1 DONE, bit2 ERR (cleared by START) |
| 0x08 / 0x0C / 0x10 | A_ADDR / B_ADDR / C_ADDR | RW | buffer addresses, 4-byte aligned |
| 0x14 | RQ_MULT | RW | [15:0] signed multiplier (reset 1) |
| 0x18 | RQ_SHIFT | RW | [4:0] rounding right-shift |
| 0x1C | RQ_ZP | RW | [7:0] signed output zero-point |
| 0x20 | CYCLES | RO | cycles of the last operation |
| 0x24 | ERR_INFO | RO | bit0 AXI read error, bit1 AXI write error, bit2 misaligned address |
| 0x28 | ID | RO | `0x4D4C01NN` |

`PSLVERR`: unmapped address, write to a read-only register, any configuration write while BUSY.

## v2 verification
| | cocotb (`tb/test_mlp.py`) | UVM (`uvm/mlp_pkg.sv`) |
|---|---|---|
| Register access | APB BFM | **RAL model** (`mlp_reg_block`) + adapter + predictor; hw-reset and bit-bash sequences |
| Memory side | reactive AXI4 slave (`tb/axi_mem.py`): random ready/latency, SLVERR injection | `mlp_axi_slave` with the same behaviour |
| Checking | Python golden model (`tb/mlp_model.py`), every output byte | operation-level scoreboard with SV reference model |
| Protocol | burst size/type, 4 KB rule, WLAST position, WSTRB | same checks + 9 SVA assertions in `mlp_axi_if` |
| Coverage | 29 bins: ReLU, shift range, multiplier class, saturation / ReLU clamp / rounding, burst split, errors | covergroups `op`, `output` (with cross), `errors`, `burst` |
| Tests | registers, directed corners, random, 4 KB boundary, AXI errors, config-while-busy, slow memory | `mlp_ral_test`, `mlp_random_test`, `mlp_full_test` |

Injected bugs (each must make the tests fail):

| Define | Fault |
|---|---|
| `BUG_4K` | DMA bursts cross a 4 KB boundary |
| `BUG_ROUND` | requantization truncates instead of rounding |
| `BUG_RELU_ZP` | ReLU clamps at 0 instead of the zero-point |
| `BUG_WLAST` | WLAST asserted one beat early |
| `BUG_SIGN` | B operand treated as unsigned (shared PE) |

### v2 results (cocotb, Icarus Verilog)
| Metric | Result |
|---|---|
| Regression | 7 tests × 10 random seeds (100 random ops per seed + directed): all pass, every output byte checked |
| Functional coverage | **29/29 bins (100%)** merged |
| Injected bugs caught | **5/5** (`BUG_4K` caught only by the 4 KB protocol check, `BUG_WLAST` only by the WLAST check) |
| Array sizes | N=4 (4-beat bursts) and N=8 (16-beat bursts) |

Plan: [`docs/testplan.md`](docs/testplan.md). UVM details and how to run on Xcelium / EDA Playground:
[`uvm/README_mlp.md`](uvm/README_mlp.md).

## v1 (`sa_apb_top`)
### v1 architecture: APB-mapped array (`sa_apb_top`)
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

#### Register map
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

### Verification environment
| | cocotb (`tb/`) | UVM (`uvm/`) |
|---|---|---|
| Driver | `ApbMaster` BFM (handles PREADY) | `apb_driver` via clocking block |
| Checker | Python golden model, all N² outputs | `sa_scoreboard` (shadow regs + SV model) |
| Protocol | — | 6 SVA assertions + 3 cover properties in `apb_if` |
| Coverage | 27 bins (`tb/coverage.py`) | 3 covergroups with a cross |
| Tests | reset, directed corners (49 combos), random, back-to-back, errors | `sa_random_test`, `sa_error_test` |

Full plan: [`docs/testplan.md`](docs/testplan.md).

### Results
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

make mlp                                   # v2 MLP engine: 7 cocotb tests
make mlp N=8 NUM_ITERS=50                  # 8x8 array (16-beat bursts)
make mlp DEFINES=BUG_4K                    # inject a v2 bug -> tests must FAIL
make                                       # v1 APB array: 5 cocotb tests
python3 scripts/run_regression.py --seeds 10 --iters 200 --bugs   # both tops, all bugs, report
cat results/regression_report.md
```

## Structure
```
rtl/       sa_pe.v  systolic_array.v                 shared PE and array
           sa_apb_top.v                             v1 top
           sa_core.v  mlp_requant.v  mlp_top.v      v2 top (DMA + requant)
tb/        test_mlp.py  axi_mem.py  mlp_model.py    v2 cocotb
           test_systolic.py  apb_master.py  model.py  coverage.py
uvm/       mlp_axi_if.sv  mlp_pkg.sv  mlp_tb_top.sv  mlp_files.f    v2 UVM (RAL)
           apb_if.sv  sa_pkg.sv  tb_top.sv  files.f                 v1 UVM
scripts/   run_regression.py
docs/      testplan.md
```
