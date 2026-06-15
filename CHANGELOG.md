<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# Changelog

All notable changes to `lm_math_float` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026

Initial public release of the self-contained VHDL-2008 floating-point
arithmetic library.

### Added

- Parametric floating-point cores in `lm_math_float_lib` (configurable
  exponent and mantissa widths):
  - `lm_math_fpu_sum` - add / subtract
  - `lm_math_fpu_prod` - product
  - `lm_math_fpu_div` - division
  - `lm_math_fpu_div2` - divide by two
  - `lm_math_fpu_sqrt` - square root
  - `lm_math_fpu_mult_cmplx` - complex product (3- and 4-multiplier structures)
  - `lm_math_fpu_rounding` - post-normalization rounding (four modes)
  - `lm_math_fix_to_fpu` / `lm_math_fpu_to_fix` - fixed/float conversion
  - `lm_math_fpu_to_fpu` - float format resize
  - `lm_math_fi_mult` - pipelined unsigned integer multiplier
  - `lm_math_int_div` - pipelined unsigned integer divider
  - `lm_math_float_pkg` - constants and helper functions
- 15 self-checking testbenches (693 documented checks) validating each
  core against an `ieee.float_pkg` golden reference, including normal
  arithmetic, IEEE special encodings, subnormal / flush-to-zero
  behavior, conversion boundaries, and mid-stream reset.
- GHDL regression runner (`scripts/run_ghdl_tests.py`) and QuestaSim /
  ModelSim scripts (`sim/questasim/`).
- GitHub Actions CI: public-content sanity checks and the GHDL
  self-checking regression.
- Documentation: `README.md`, `docs/USER_GUIDE.md`,
  `docs/REGRESSION_COVERAGE.md`, `docs/CODE_REVIEW.md`, and `TESTPLAN.md`.
- Apache-2.0 license with SPDX headers across all source and script files.

[1.0.0]: https://github.com/logimentor/lm_math_float/releases/tag/v1.0.0
