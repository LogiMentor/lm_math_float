<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# User Guide

This guide explains how to integrate, simulate, and verify `lm_math_float`
in an FPGA-oriented VHDL project.

## Floating-Point Format

Every floating-point data port uses:

```text
[ sign | exponent | mantissa ]
```

The total width is:

```text
1 + g_data_exp + g_data_mant
```

For IEEE single-precision-like datapaths use `g_data_exp = 8` and
`g_data_mant = 23`. For double-precision-like datapaths use
`g_data_exp = 11` and `g_data_mant = 52`, subject to the resource and
latency impact of the selected module.

## Handshake Convention

Most modules use a simple valid pipeline:

```text
dv_i = '1' on an input clock edge
dv_o = '1' on the matching output clock edge
```

The data and error outputs are meaningful when `dv_o = '1'`. Modules without
an explicit reset rely on initialized pipeline-valid registers so `dv_o`
starts at `'0'` in simulation and on FPGA flows that preserve register
initialization.

`lm_math_fpu_div` and `lm_math_fpu_sqrt` expose `rst_n_i` because they contain
state that must be explicitly cleared during operation.

## Error Outputs and Special Encodings

Several modules expose an `error_o` port. The exact bit layout is documented
in each module header and exercised by the matching testbench.

Important rule for users: when a module documents `dout_o` as not
IEEE-conformant for flagged special inputs, downstream logic must check
`error_o` before consuming `dout_o`.

The library intentionally documents per-module behavior rather than claiming
full IEEE-754 compliance across every special case. This keeps the RTL small
and makes unsupported cases visible at the interface.

## Subnormal Behavior

Subnormal handling is module-specific:

| Module | Behavior |
|---|---|
| `lm_math_fpu_sum` | Handles subnormal arithmetic in the data path. |
| `lm_math_fpu_div2` | Handles denormal input to denormal output for covered cases. |
| `lm_math_fpu_div` | Includes tested denormal and boundary division cases. |
| `lm_math_fpu_prod` | Flushes subnormal-magnitude products to signed zero, while selected subnormal-input normal-result cases are supported. |
| `lm_math_fpu_sqrt` | Positive denormal input returns `+0` and flags `error_o`. |
| converters and composite modules | Behavior is documented in the module and testbench headers. |

Use the module header plus `TESTPLAN.md` as the contract for edge cases.

## Compile Order

Use this order for both simulation and synthesis:

```text
lm_math_float_pkg.vhd
lm_math_fi_mult.vhd
lm_math_int_div.vhd
lm_math_fpu_rounding.vhd
lm_math_fpu_sum.vhd
lm_math_fpu_prod.vhd
lm_math_fpu_div.vhd
lm_math_fpu_div2.vhd
lm_math_fpu_sqrt.vhd
lm_math_fix_to_fpu.vhd
lm_math_fpu_to_fix.vhd
lm_math_fpu_to_fpu.vhd
lm_math_fpu_mult_cmplx.vhd
```

All files should be analyzed as VHDL-2008 into `lm_math_float_lib`.

## GHDL Regression

Run:

```sh
python3 scripts/run_ghdl_tests.py
```

The script:

1. Creates `build/ghdl`.
2. Analyzes all sources into `lm_math_float_lib`.
3. Analyzes, elaborates, and runs every testbench.
4. Requires a `TEST PASSED` marker from every bench.

Useful options:

```sh
python3 scripts/run_ghdl_tests.py --stop-time 500us
python3 scripts/run_ghdl_tests.py --ghdl /path/to/ghdl
python3 scripts/run_ghdl_tests.py --keep-build
```

The testbenches finish with a passive `wait`, so the runner uses a stop time
and checks the pass marker in the simulator output.

The regression matrix covers every public source module directly. See
[`REGRESSION_COVERAGE.md`](REGRESSION_COVERAGE.md) for the module-to-test
mapping and the non-exhaustive edge cases that remain outside the pass suite.

## QuestaSim / ModelSim Regression

Run the full suite:

```sh
cd sim/questasim
vsim -c -do "do run_all.do; quit -f"
```

Run one bench:

```sh
cd sim/questasim
vsim -c -do "do run_tb_lm_math_fpu_sum.do; quit -f"
```

Each `run_tb_*.do` script sources `compile_lib.do`, compiles the matching
testbench, runs to completion, and relies on the self-checking assertions.

## Local FPGA Synthesis Reports

The repository includes a local synthesis/timing runner for workstation use:

```sh
python3 scripts/run_synth_reports.py --list-tools
python3 scripts/run_synth_reports.py --tools auto
```

The script supports Vivado, Quartus, Diamond, and Libero when their command
line tools are installed on the local machine. It generates one vendor script
per module and writes:

```text
build/synth/synthesis_summary.md
build/synth/synthesis_summary.csv
build/synth/<tool>/<module>/
```

Edit the configuration block at the top of
`scripts/run_synth_reports.py` before collecting release numbers. The key
settings are:

| Setting | Purpose |
|---|---|
| `HOST_PLATFORM` | `auto`, `windows`, or `linux`. |
| `CLOCK_PERIOD_NS` | Clock constraint used for the generated builds. |
| `TOOL_COMMANDS` | Local executable names or absolute paths. |
| `VIVADO_PART` | Xilinx part for Vivado runs. |
| `QUARTUS_FAMILY`, `QUARTUS_DEVICE` | Intel target for Quartus runs. |
| `DIAMOND_DEVICE`, `DIAMOND_SYNTH` | Lattice target and synthesis engine. |
| `LIBERO_*` | Microchip family, die, package, and speed grade. |

Useful commands:

```sh
python3 scripts/run_synth_reports.py --emit-only --tools vivado,quartus
python3 scripts/run_synth_reports.py --module lm_math_fpu_prod
python3 scripts/run_synth_reports.py --clock-period 5.0
python3 scripts/run_synth_reports.py --vivado /path/to/vivado
```

Fmax is taken from vendor timing reports when present. When only requested
clock period and slack are available, the script reports an approximate Fmax
derived from those values. Utilization parsing is best effort because report
formats differ across tool versions; keep the raw reports under
`build/synth/<tool>/<module>/` with any published result.

## CI

The GitHub Actions workflow runs two jobs:

| Job | Purpose |
|---|---|
| `repo-hygiene` | Verifies license/header/content/history hygiene. |
| `ghdl-regression` | Installs GHDL and runs all self-checking benches. |

The CI is intentionally simulator-open-source-first. QuestaSim scripts remain
available for local or licensed runs.

## Integration Checklist

Before using a module in production logic:

1. Pick the exponent and mantissa width.
2. Confirm the module supports that shape through its generic assertions.
3. Budget the documented `dv_i` to `dv_o` latency.
4. Gate output consumption with `dv_o`.
5. Gate special-input behavior with `error_o` when present.
6. Decide whether the documented subnormal behavior is acceptable.
7. Run the matching testbench after any local modification.

## Public Release Checklist

Before publishing from a local working copy:

1. Run `python3 scripts/check_repo_hygiene.py`.
2. Run `python3 scripts/check_repo_hygiene.py --all-refs` on the public
   mirror or a clone that only contains refs intended for publication.
3. Install local hooks with
   `pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push`.
4. Run `python3 scripts/run_ghdl_tests.py` on a machine with GHDL.
5. Run `vsim -c -do "do run_all.do; quit -f"` when QuestaSim is available.
6. Publish only the reviewed public branch. Do not push local archive,
   experiment, or mirror refs to the public repository.
