<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# Release Code Review

This review focuses on public-release readiness, verification risk, and
integration hazards.

## Findings

### High: Publish only reviewed public refs

The public source snapshot is intended to be published from a reviewed clean
root-commit branch. Publishing all refs or pushing unrelated branch history can
expose process metadata even if the latest checkout is clean.

Recommended release path: publish only the clean root-commit branch, and avoid
`--all` or mirror pushes unless every ref has passed the same public sanity
checks.

### Low: GHDL regression is locally proven

The full GHDL regression has been run locally with GHDL 6.0.0. All 15
self-checking testbenches pass, covering the documented 693 checks. The CI
job remains useful as an independent portability gate on Linux.

Recommended follow-up: keep any future GHDL analysis, elaboration, or runtime
failure visible in CI as a regression failure rather than as a Python crash.

### Medium: reset policy is FPGA-friendly but not universal

Several modules rely on initialized pipeline-valid registers instead of an
explicit reset input. That is a reasonable FPGA-oriented design choice when
the target synthesis flow preserves register initialization. It is not a
portable ASIC reset strategy.

Recommended user-facing contract: consumers must treat this as an FPGA RTL
library unless they add or wrap reset behavior for flows that require it.

### Medium: special-input data outputs are not uniformly IEEE-conformant

Some modules flag NaN or infinity inputs but still drive `dout_o` from raw
field arithmetic. That is documented and tested, but it is easy for an
integrator to misuse.

Recommended contract: `error_o` must be checked before consuming `dout_o` for
flagged inputs.

### Medium: subnormal behavior is intentionally per-module

The library does not implement one global subnormal policy. Some modules
support selected subnormal paths, some flush subnormal-magnitude results, and
some document limited behavior.

Recommended contract: module headers and `TESTPLAN.md` define the edge-case
contract; do not market the library as fully IEEE-754 compliant.

### Low: QuestaSim logs contain startup metavalue warnings

The latest QuestaSim transcript shows numeric_std metavalue warnings at time
zero or before pipeline-valid output data is consumed. The self-checking
benches pass, and the valid handshake prevents stale data from being used, but
warning-heavy logs can reduce confidence in public CI.

Recommended follow-up: add internal default initializers where that does not
change the intended reset semantics, or suppress only known-benign startup
warnings in simulator-specific scripts.

## Positive Observations

The testbenches are self-checking and broad enough to be useful as a public
regression suite. They now cover every public source module directly,
including package helpers, the unsigned multiplier helper, and the integer
divider helper. Arithmetic coverage includes normal operations, selected
special encodings, subnormal and boundary cases, conversion behavior,
complex-product variants, and mid-stream reset paths for stateful modules.

The RTL headers already describe latency, reset behavior, and special-case
handling in unusual detail for a small hardware library. That is worth keeping:
it turns many edge cases from tribal knowledge into a user contract.

## Release Recommendation

The current clean-history branch is suitable for a public source snapshot
after the sanity checks, GHDL regression, and QuestaSim regression pass.
Publish only refs intended for the public repository.
