# Verification Test Plan: Systolic-Array Matrix Multiplier (`sa_apb_top`)

## 1. DUT summary
An N×N (default 4×4) output-stationary INT8 systolic array computing **C = A × B**
(int8 inputs, int32 accumulation), controlled through an APB3 slave.
Latency: one clear cycle + `3N-2` compute cycles.

## 2. Verification strategy
| Layer | Method |
|---|---|
| Stimulus | Directed corner matrices + constrained-random matrices (corner-weighted) |
| Checking | Python golden model (cocotb) / SV reference model in UVM scoreboard; every C element checked |
| Protocol | SVA on APB (setup→access, stability during wait, PSLVERR qualification, bounded PREADY) |
| Coverage | Functional coverpoints on operand values, result ranges, error responses, sequencing |
| Quality of TB | Bug injection via `+define+BUG_*`: every injected bug must be caught |

## 3. Features → tests → checks → coverage
| ID | Feature | Test(s) | Checker | Coverage |
|---|---|---|---|---|
| F1 | Reset values (STATUS, A, B, C = 0; ID = 0x5A0000NN) | `test_reset_values` | direct compare | — |
| F2 | Matrix multiply correctness, signed int8 | `test_directed_corners`, `test_random` | golden model, all N² outputs | `matrix_kind`, `operand_pair`, `c_value` |
| F3 | Extremes: −128×−128, −128×127, 127×127, zeros | `test_directed_corners` | golden model | `operand_pair.*`, `c_value.max_pos/max_neg` |
| F4 | Accumulators cleared between operations | `test_back_to_back` | golden model on op k+1 | `sequencing.back_to_back` |
| F5 | CYCLES register = 3N−2 | all ops | direct compare | — |
| F6 | PSLVERR: unmapped address | `test_apb_errors` | expect err=1 | `apb_error.unmapped` |
| F7 | PSLVERR: write to read-only (STATUS/CYCLES/ID/C) | `test_apb_errors` | expect err=1 | `apb_error.ro_write` |
| F8 | PSLVERR + no update: A/B write while BUSY | `test_apb_errors` | err=1 and value unchanged | `apb_error.write_A_busy/B_busy` |
| F9 | START while BUSY ignored (no restart) | `test_apb_errors` | CYCLES and result unchanged | `sequencing.start_while_busy` |
| F10 | C read while BUSY is legal | `test_apb_errors` | err=0 | `sequencing.read_C_while_busy` |
| F11 | One wait state on C reads | all C reads | APB BFM handles PREADY; SVA bounded wait | `sequencing.read_C_wait_state` |
| F12 | Parameterisation N = 2..8 | `make N=8` | same tests | — |

## 4. Bug-injection campaign
| Define | Injected fault | Expected detection |
|---|---|---|
| `BUG_SIGN` | B multiplied as unsigned | any negative B |
| `BUG_NOCLR` | accumulators not cleared on START | 2nd operation |
| `BUG_SKEW` | last row of A mis-timed | any non-zero last row |
| `BUG_PSLVERR` | no write protection while BUSY | F8 |
| `BUG_CTRANSPOSE` | C read-back transposed | any non-symmetric result |

## 5. Exit criteria
* 0 failures over ≥10 random seeds × 200 operations
* 100% of functional coverage bins hit (merged)
* All injected bugs CAUGHT
* No SVA failures (UVM flow)

---

# v2 Test Plan: DLRM MLP layer engine (`mlp_top`)

## 1. DUT summary
INT8 GEMM `C = A × B` on the same systolic array, but operands are fetched from memory by an
**AXI4 DMA master** and every int32 result is **requantized to int8** before being written back.

## 2. Features → tests → checks → coverage
| ID | Feature | cocotb test | UVM | Check | Coverage |
|---|---|---|---|---|---|
| M1 | Register reset values, field widths, RO/unmapped errors | `test_mlp_registers` | `mlp_ral_test` (hw-reset + bit-bash) | direct / RAL mirror | `mlp_error.apb_*` |
| M2 | GEMM + requant correctness | `test_mlp_directed`, `test_mlp_random` | `mlp_full_test`, `mlp_random_test` | golden model, all N² bytes | `mlp_output.*`, `mlp_shift`, `mlp_mult` |
| M3 | Round-half-up, shift 0 (no rounding), shift 31 | directed | directed | golden model | `mlp_output.rounded_up`, `mlp_shift.zero/24_31` |
| M4 | Saturation high/low, ReLU clamps at zero-point | directed + random | directed + random | golden model | `sat_hi`, `sat_lo`, `relu_clamp` |
| M5 | Bursts ≤ 16 beats, INCR, 4-byte size | all | all | memory model + SVA `a_ar_fmt/a_aw_fmt` | `mlp_burst.*` |
| M6 | No burst crosses 4 KB; transfers split correctly | `test_mlp_4k_boundary` (+20% random) | `mlp_full_test` | memory model + SVA `a_ar_4k/a_aw_4k` | `mlp_dma.split_at_4k` |
| M7 | WLAST on exactly the last beat, WSTRB = F | all | all | memory model | — |
| M8 | AXI read / write SLVERR → STATUS.ERR, ERR_INFO bit, op still completes | `test_mlp_axi_errors` | `run_errors` | ERR_INFO compare | `mlp_error.axi_*` |
| M9 | Misaligned address rejected with no bus traffic | `test_mlp_axi_errors` | `run_errors` | burst count unchanged | `mlp_error.misaligned_addr` |
| M10 | Config writes / START while BUSY → PSLVERR, no effect | `test_mlp_cfg_while_busy` | `mlp_busy_seq` | registers + result unchanged | `apb_cfg_while_busy` |
| M11 | Back-pressure: slow READY, long latency, slow B | `test_mlp_slow_memory` | `mlp_full_test` slow phase | golden model | `mlp_dma.slow_memory` |

## 3. Bug-injection campaign
| Define | Fault | Detected by |
|---|---|---|
| `BUG_4K` | burst crosses 4 KB | 4 KB protocol check (data is still correct, so only a protocol checker can catch it) |
| `BUG_ROUND` | truncation instead of rounding | golden model |
| `BUG_RELU_ZP` | ReLU floor at 0 instead of ZP | golden model when ZP ≠ 0 |
| `BUG_WLAST` | WLAST one beat early | WLAST check |
| `BUG_SIGN` | B treated as unsigned | golden model |

## 4. Exit criteria
0 failures over ≥10 seeds, 100% functional coverage, every injected bug detected, UVM `UVM_ERROR: 0`.
