# UVM environment for `mlp_top` (v2)

```
mlp_tb_top
 ├─ apb_if (+SVA) ─────── apb_agent (reused from sa_pkg / v1)
 │                          └─ monitor ─► mlp_reg_predictor ─► RAL mirror
 ├─ mlp_axi_if (+9 SVA) ── mlp_axi_slave  reactive AXI4 memory: random READY/latency, SLVERR injection,
 │                                         WLAST/WSTRB checks, burst coverage
 └─ mlp_env
      ├─ mlp_reg_block (RAL): CTRL STATUS A_ADDR B_ADDR C_ADDR RQ_MULT RQ_SHIFT RQ_ZP CYCLES ERR_INFO ID
      ├─ mlp_reg_adapter      RAL op <-> apb_item, PSLVERR -> UVM_NOT_OK
      └─ mlp_scoreboard       SV reference model (GEMM + requant), covergroups op / output / errors
```
Every operation is programmed through the register model (`regs.a_addr.write(...)`, `regs.status.read(...)`).

Tests:
* `mlp_ral_test`: `uvm_reg_hw_reset_seq` (all reset values) + `uvm_reg_bit_bash_seq` (every RW bit) + RO/unmapped errors
* `mlp_random_test`: `+NUM_OPS=<n>` random operations
* `mlp_full_test`: directed corners, random ops, 4 KB-straddling buffers, slow memory, AXI errors,
  misaligned addresses, config writes while busy — one run reaches full functional coverage

## EDA Playground (Cadence Xcelium 25.03, UVM 1.2)
Design pane: `design.sv` (all v2 RTL). Testbench pane: `testbench.sv`
(`apb_if.sv` + `mlp_axi_if.sv` + `sa_pkg.sv` + `mlp_pkg.sv` + `mlp_tb_top.sv`).
Compile options: `-timescale 1ns/1ps -coverage functional`.
Run options: `+UVM_TESTNAME=mlp_full_test +NUM_OPS=100`.

## Local simulators
```bash
cd uvm
xrun -uvm -sv -f mlp_files.f -top mlp_tb_top +UVM_TESTNAME=mlp_full_test -coverage functional
vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f mlp_files.f -top mlp_tb_top -o simv && ./simv +UVM_TESTNAME=mlp_ral_test
```

## Results (Cadence Xcelium 25.03, UVM 1.2, run on EDA Playground)

| Run | Result |
|---|---|
| `mlp_full_test +NUM_OPS=100` | PASS, `UVM_ERROR: 0`; 152 operations, 2,432 outputs checked, 0 mismatches, 5 error operations; functional coverage op 100%, output 100%, errors 100%; 606 AXI bursts, 144 ending on a 4 KB boundary, 0 protocol violations |
| `mlp_ral_test` | PASS; `uvm_reg_hw_reset_seq` on all 11 registers, `uvm_reg_bit_bash_seq` on every bit of the 6 RW registers |
| `mlp_random_test` with `+define+BUG_WLAST` | FAIL (as intended): 112 `UVM_ERROR` from the WLAST protocol check. The data scoreboard reported 0 mismatches, so only the protocol checker detects this bug |

Logs: `uvm/logs/mlp_*.log`.
