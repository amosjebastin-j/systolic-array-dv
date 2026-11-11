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
