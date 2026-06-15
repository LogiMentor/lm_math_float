<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# Verification

This document summarizes the verification scope, quality gates, and known
integration limits for `lm_math_float`.

## Regression Suite

The repository includes 15 self-checking VHDL testbenches with 693 documented
checks. The testbenches are expected to print `TEST PASSED` and to stop with
`severity failure` on mismatches.

The regression covers:

- package helper functions;
- unsigned multiplier and integer divider helper blocks;
- normal add, subtract, multiply, divide, square root, and conversion cases;
- selected NaN, infinity, zero, and raw `-0.0` encodings;
- subnormal and flush-to-zero behavior where documented by each module;
- complex-product architectures;
- mid-stream reset behavior for modules that expose `rst_n_i`.

Detailed per-test coverage and tolerances are in `TESTPLAN.md`. The
module-to-test matrix is in `docs/REGRESSION_COVERAGE.md`.

## Tooling

The primary open-source regression entry point is:

```sh
python3 scripts/run_ghdl_tests.py
```

The runner analyzes sources, analyzes and elaborates each testbench, runs the
simulation, and reports a failed testbench instead of surfacing a Python
traceback when a GHDL phase fails.

QuestaSim / ModelSim scripts are also provided under `sim/questasim/`:

```sh
cd sim/questasim
vsim -c -do "do run_all.do; quit -f"
```

## Continuous Checks

The CI workflow runs two jobs:

- repository hygiene checks for license metadata, SPDX headers, forbidden
  local path markers, branch names, and commit messages;
- the full GHDL self-checking regression.

The same hygiene script is available locally:

```sh
python3 scripts/check_repo_hygiene.py
python3 scripts/check_repo_hygiene.py --all-refs
```

## Known Limits

The library should not be marketed as a fully IEEE-754 compliant
implementation. It uses a compact field layout compatible with the convention
used by `ieee.float_pkg`, but special-input data outputs and subnormal behavior
are intentionally per-module contracts. Consumers must check `error_o` before
using `dout_o` for flagged inputs.

Several modules rely on initialized pipeline-valid registers instead of an
explicit reset input. This is appropriate for FPGA flows that preserve register
initial values, but ASIC flows or flows that require reset on every register
may need wrappers or local reset extensions.

Simulator startup logs may include numeric_std metavalue warnings before valid
pipeline data is consumed. The self-checking benches gate comparisons with the
documented valid signals.
