<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# lm_math_float

`lm_math_float` is a self-contained VHDL-2008 library of floating-point
arithmetic primitives with parametric exponent and mantissa widths. The
library uses a compact custom encoding compatible with the field convention
used by `ieee.float_pkg`:

```text
[ sign(1) | exponent(g_data_exp) | mantissa(g_data_mant) ]
```

All synthesizable sources compile into `lm_math_float_lib`. Verification
testbenches compile into `work` and are self-checking: each bench reports
`TEST PASSED` on success and raises `severity failure` on mismatch.

## Repository Layout

```text
src/
  lm_math_float_pkg.vhd       constants and helper functions
  lm_math_fi_mult.vhd         pipelined unsigned integer multiplier
  lm_math_int_div.vhd         pipelined unsigned integer divider
  lm_math_fpu_rounding.vhd    rounding block
  lm_math_fpu_sum.vhd         floating-point add/subtract
  lm_math_fpu_prod.vhd        floating-point product
  lm_math_fpu_div.vhd         floating-point division
  lm_math_fpu_div2.vhd        divide by two
  lm_math_fpu_sqrt.vhd        square root
  lm_math_fpu_mult_cmplx.vhd  complex product
  lm_math_fix_to_fpu.vhd      fixed-point to float conversion
  lm_math_fpu_to_fix.vhd      float to fixed-point conversion
  lm_math_fpu_to_fpu.vhd      float format resize

sim/
  tb_lm_math_*.vhd            self-checking VHDL testbenches
  questasim/                  QuestaSim / ModelSim scripts

scripts/
  run_ghdl_tests.py           GHDL compile-and-run regression
  run_synth_reports.py        local FPGA synthesis/timing summaries
  check_repo_hygiene.py       repository hygiene checks

docs/
  USER_GUIDE.md               integration and verification guide
  REGRESSION_COVERAGE.md      module-to-test coverage matrix
  VERIFICATION.md             verification scope and known limits

CHANGELOG.md                  public release history
```

## Modules

| Module | Operation | Latency | Notes |
|---|---|---:|---|
| `lm_math_fpu_sum` | `a + b` or `a - b` | 10 clocks | Select operation with `g_operation`. |
| `lm_math_fpu_prod` | `a * b` | `g_pipe_stages + 8` | Uses the embedded-multiplier path. |
| `lm_math_fpu_div` | `a / b` | about `g_data_mant/g_chunk_size + 8` | Has `rst_n_i`. |
| `lm_math_fpu_div2` | `a / 2` | 3 clocks | Truncating divide-by-two helper. |
| `lm_math_fpu_sqrt` | `sqrt(a)` | `g_data_mant + 2` | FSM-driven, one active input at a time. |
| `lm_math_fpu_mult_cmplx` | complex product | depends on architecture | Supports 3- and 4-multiplier structures. |
| `lm_math_fpu_rounding` | post-normalization rounding | 2 clocks | Four rounding modes. |
| `lm_math_fix_to_fpu` | fixed to float | 4 clocks | Signed or unsigned fixed input. |
| `lm_math_fpu_to_fix` | float to fixed | 4 or 5 clocks | Signed or unsigned fixed output. |
| `lm_math_fpu_to_fpu` | float resize | 2 or 3 clocks | Supports grow/grow or shrink/shrink only. |

## Rounding Modes

The package defines these constants:

| Constant | Value | Behavior |
|---|---:|---|
| `C_LM_ROUND_NEAREST` | 1 | round to nearest, ties up |
| `C_LM_ROUND_INF` | 2 | round toward positive infinity |
| `C_LM_ROUND_NEGINF` | 3 | round toward negative infinity |
| `C_LM_ROUND_ZERO` | 4 | truncate toward zero |

## Quick Start

Add `src/*.vhd` to your simulator or synthesis project in this order:

1. `lm_math_float_pkg.vhd`
2. `lm_math_fi_mult.vhd`
3. `lm_math_int_div.vhd`
4. `lm_math_fpu_rounding.vhd`
5. arithmetic cores and converters

For simulation with GHDL:

```sh
python3 scripts/run_ghdl_tests.py
```

For simulation with QuestaSim or ModelSim:

```sh
cd sim/questasim
vsim -c -do "do run_all.do; quit -f"
```

The GHDL script and GitHub Actions workflow both require every testbench to
emit `TEST PASSED`. A VHDL `severity failure`, a missing pass marker, or a
reported `TEST FAILED` marks the run as failed.

For local FPGA synthesis and timing summaries:

```sh
python3 scripts/run_synth_reports.py --list-tools
python3 scripts/run_synth_reports.py --tools auto
```

The synthesis runner is intentionally not part of CI. It detects installed
Vivado, Quartus, Diamond, and Libero executables, generates vendor scripts
under `build/synth`, and writes `synthesis_summary.md` plus
`synthesis_summary.csv` with Fmax and utilization data when the vendor reports
provide those fields. Edit the configuration block at the top of the script
for local tool paths, operating system, clock period, and target devices.

## Verification Status

The suite contains 15 self-checking testbenches with 693 documented checks.
Coverage includes direct helper regressions, normal arithmetic, selected IEEE
special encodings, subnormal and flush-to-zero behavior, conversion
boundaries, complex-product architectures, and mid-stream reset tests for the
modules that expose `rst_n_i`.

Detailed per-test coverage, tolerances, and known gaps are in
[`TESTPLAN.md`](TESTPLAN.md). The module-to-test matrix is in
[`docs/REGRESSION_COVERAGE.md`](docs/REGRESSION_COVERAGE.md). Integration
details are in [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md). Verification
scope and known limits are summarized in
[`docs/VERIFICATION.md`](docs/VERIFICATION.md).

## Repository Hygiene

Install the optional pre-commit hook with:

```sh
pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
```

The hook runs:

```sh
python3 scripts/check_repo_hygiene.py
```

It checks tracked files for Apache-2.0 headers on source/script files,
expected license metadata, forbidden local-tool path components, common
private development-tool markers, the current branch name, and commit
messages. To run the stricter all-ref check used by CI:

```sh
python3 scripts/check_repo_hygiene.py --all-refs
```

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
