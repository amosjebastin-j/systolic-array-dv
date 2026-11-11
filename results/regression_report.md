# Regression report

Array size N=4, 200 random ops per seed (v1 APB array) / half that for the v2 MLP engine

## Seeds

| top | seed | tests | failures | time (s) |
|---|---|---|---|---|
| sa_apb_top | 2050569861 | 5 | 0 | 4.3 |
| mlp_top | 2050569861 | 7 | 0 | 3.5 |
| sa_apb_top | 1649700815 | 5 | 0 | 4.1 |
| mlp_top | 1649700815 | 7 | 0 | 3.9 |
| sa_apb_top | 386619994 | 5 | 0 | 4.1 |
| mlp_top | 386619994 | 7 | 0 | 3.8 |
| sa_apb_top | 1327189919 | 5 | 0 | 4.1 |
| mlp_top | 1327189919 | 7 | 0 | 3.5 |
| sa_apb_top | 224908345 | 5 | 0 | 3.8 |
| mlp_top | 224908345 | 7 | 0 | 3.2 |
| sa_apb_top | 1072740278 | 5 | 0 | 3.6 |
| mlp_top | 1072740278 | 7 | 0 | 3.8 |
| sa_apb_top | 1666141439 | 5 | 0 | 4.3 |
| mlp_top | 1666141439 | 7 | 0 | 3.6 |
| sa_apb_top | 730827688 | 5 | 0 | 3.6 |
| mlp_top | 730827688 | 7 | 0 | 3.1 |
| sa_apb_top | 722144145 | 5 | 0 | 3.5 |
| mlp_top | 722144145 | 7 | 0 | 3.1 |
| sa_apb_top | 1058059955 | 5 | 0 | 3.5 |
| mlp_top | 1058059955 | 7 | 0 | 3.0 |

## Functional coverage (merged)

**56/56 bins hit (100.0%)**

| coverpoint | bin | hits |
|---|---|---|
| matrix_kind | random | 2820 |
| matrix_kind | zero | 140 |
| matrix_kind | identity | 140 |
| matrix_kind | all_max | 140 |
| matrix_kind | all_min | 341 |
| matrix_kind | alt_sign | 316 |
| matrix_kind | sparse | 531 |
| matrix_kind | corner_mix | 552 |
| c_value | neg_large | 330 |
| c_value | neg | 17615 |
| c_value | zero | 6081 |
| c_value | pos | 17887 |
| c_value | pos_large | 583 |
| c_value | max_pos | 256 |
| c_value | max_neg | 448 |
| operand_pair | min_x_min | 3072 |
| operand_pair | min_x_max | 4977 |
| operand_pair | max_x_max | 2157 |
| operand_pair | zero_x_any | 44565 |
| apb_error | unmapped | 50 |
| apb_error | ro_write | 40 |
| apb_error | write_A_busy | 10 |
| apb_error | write_B_busy | 10 |
| sequencing | start_while_busy | 10 |
| sequencing | back_to_back | 190 |
| sequencing | read_C_while_busy | 10 |
| sequencing | read_C_wait_state | 2690 |
| mlp_relu | off | 780 |
| mlp_relu | on | 730 |
| mlp_shift | zero | 44 |
| mlp_shift | 1_7 | 54 |
| mlp_shift | 8_15 | 49 |
| mlp_shift | 16_23 | 1083 |
| mlp_shift | 24_31 | 280 |
| mlp_mult | positive | 1029 |
| mlp_mult | negative | 303 |
| mlp_mult | one | 109 |
| mlp_mult | max_pos | 35 |
| mlp_mult | max_neg | 34 |
| mlp_output | in_range | 15556 |
| mlp_output | sat_hi | 2176 |
| mlp_output | sat_lo | 1281 |
| mlp_output | relu_clamp | 5147 |
| mlp_output | rounded_up | 9817 |
| mlp_burst | single_beat | 883 |
| mlp_burst | split_part | 2700 |
| mlp_burst | full_length | 3180 |
| mlp_dma | split_at_4k | 1353 |
| mlp_dma | back_to_back | 990 |
| mlp_dma | slow_memory | 200 |
| mlp_error | axi_read_slverr | 10 |
| mlp_error | axi_write_slverr | 10 |
| mlp_error | misaligned_addr | 30 |
| mlp_error | apb_unmapped | 40 |
| mlp_error | apb_ro_write | 40 |
| mlp_error | apb_cfg_while_busy | 70 |

## Bug-injection campaign

Each bug is compiled in with `+define+`; the testbench must FAIL.

| top | bug | description | result | failing tests |
|---|---|---|---|---|
| sa_apb_top | `BUG_SIGN` | B operand multiplied as unsigned | CAUGHT | test_directed_corners, test_random, test_back_to_back, test_apb_errors |
| sa_apb_top | `BUG_NOCLR` | accumulators not cleared on START | CAUGHT | test_directed_corners, test_random, test_back_to_back |
| sa_apb_top | `BUG_SKEW` | last row of A fed one cycle late | CAUGHT | test_directed_corners, test_random, test_back_to_back, test_apb_errors |
| sa_apb_top | `BUG_PSLVERR` | no write protection while BUSY | CAUGHT | test_apb_errors |
| sa_apb_top | `BUG_CTRANSPOSE` | C read-back address transposed | CAUGHT | test_directed_corners, test_random, test_back_to_back, test_apb_errors |
| mlp_top | `BUG_4K` | DMA burst crosses a 4 KB boundary | CAUGHT | test_mlp_random, test_mlp_4k_boundary, test_mlp_slow_memory |
| mlp_top | `BUG_ROUND` | requantization truncates instead of rounding | CAUGHT | test_mlp_directed, test_mlp_random, test_mlp_4k_boundary, test_mlp_axi_errors, test_mlp_cfg_while_busy, test_mlp_slow_memory |
| mlp_top | `BUG_RELU_ZP` | ReLU clamps at 0 instead of the zero-point | CAUGHT | test_mlp_directed, test_mlp_random, test_mlp_4k_boundary, test_mlp_slow_memory |
| mlp_top | `BUG_WLAST` | WLAST asserted one beat early | CAUGHT | test_mlp_directed, test_mlp_random, test_mlp_4k_boundary, test_mlp_axi_errors, test_mlp_cfg_while_busy, test_mlp_slow_memory |
| mlp_top | `BUG_SIGN` | B operand multiplied as unsigned (shared PE) | CAUGHT | test_mlp_directed, test_mlp_random, test_mlp_4k_boundary, test_mlp_axi_errors, test_mlp_cfg_while_busy, test_mlp_slow_memory |
