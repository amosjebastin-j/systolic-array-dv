# UVM environment

```
tb_top ── apb_if (+SVA) ── sa_apb_top (DUT)
  └─ sa_env
       ├─ apb_agent (sequencer, driver, monitor)
       ├─ sa_scoreboard   shadow A/B → predict C at START → check C/CYCLES/ID reads + PSLVERR
       └─ sa_coverage     address×dir×error cross, operand values, result ranges
```
Tests: `sa_random_test` (directed extremes + `+NUM_OPS=` random multiplies), `sa_error_test`.

## Run
**Cadence Xcelium (college lab):**
```bash
cd uvm
xrun -uvm -sv -f files.f +UVM_TESTNAME=sa_random_test +NUM_OPS=200 -coverage functional -access +r
xrun -uvm -sv -f files.f +UVM_TESTNAME=sa_error_test
```
**Synopsys VCS:**
```bash
cd uvm
vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -f files.f -o simv && ./simv +UVM_TESTNAME=sa_random_test
```
**Siemens Questa:** `qrun -uvm -f files.f +UVM_TESTNAME=sa_random_test`

**EDA Playground (free, browser):** Testbench pane = `tb_top.sv`, add tabs `sa_pkg.sv`, `apb_if.sv`;
Design pane = the three files in `../rtl/`. Tools & Simulators → *UVM 1.2* + *Cadence Xcelium* or *Synopsys VCS*.
Add `-timescale 1ns/1ps` to compile options and put `` `include "apb_if.sv" `` and `` `include "sa_pkg.sv" ``
at the top of `tb_top.sv` (EDA Playground compiles only the first file of each pane by default).
Run options: `+UVM_TESTNAME=sa_random_test`.

Pass criterion: `*** TEST PASSED ***` and `UVM_ERROR : 0` in the report summary.
Inject a bug with `+define+BUG_SIGN` (Xcelium/VCS) and confirm the scoreboard flags it.
