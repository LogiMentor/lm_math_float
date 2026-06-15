<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# lm_math_float — Test plan

Status of the simulation-level verification for every module in the library.
The matrix below is the contract: every entry that says **PASS** must terminate
with `** Note: TEST PASSED: N ...` and any deviation aborts the run with
`severity failure`.

To re-run everything with GHDL:

```
python3 scripts/run_ghdl_tests.py
```

To re-run everything from `sim/questasim/`:

```
vsim -c -do "do run_all.do; quit -f"
```

Each TB also has its own `run_tb_<name>.do` for focused debug.

## Matrix

| TB | Status | Checks | DUTs | Coverage summary |
|---|:---:|---:|:---:|---|
| `tb_lm_math_float_pkg`      | PASS | 45 | n/a | Direct package-helper regression: rounding constants, sizing helpers, bit helpers, count/shift helpers, and resize-right behavior on explicit `downto` vectors |
| `tb_lm_math_fi_mult`        | PASS | 14 | 2 (full + truncated) | Direct unsigned multiplier regression: zero/one/max/asymmetric operands, full product, right-aligned truncation, `g_pipe_stages=0` and `g_pipe_stages=2` |
| `tb_lm_math_int_div`        | PASS | 18 | 2 (chunk 1 + chunk 4) | Direct integer-divider regression: zero dividend, `<`, `=`, and `>` divisor ratios under the FPU in-contract ratio range, non-power-of-two divisors, non-even chunking |
| `tb_lm_math_fpu_sum`        | PASS | 120 | 2 (add + sub) | 18 normals × 4 (incl. add-side exact cancellation 1.0 + -1.0 and alignment-shift saturation 1e+30 + 1e-30), 10 special × 2 (every `error_o` bit on both signs: -inf-A on bit 2, -NaN-A on bit 0, -NaN-B on bit 1, -inf-B on bit 3 — all sign='1' — plus +inf + -inf where both inf flags fire), 7 denormal-arithmetic × 4 (incl. negative-denormal sign propagation), `dv_pre_o`→`dv_o` invariant |
| `tb_lm_math_fpu_prod`       | PASS | 59 | 1 | 16 normals + 9 special (NaN/inf/0×inf) + 6 FTZ (subnormal product → ±0, incl. the denormal×normal cases that pin the 2.0.1 s_delta-alignment fix) + 3 subnormal-input rescue (subnormal×normal → normal-magnitude product, pin the 2.0.2 effective-biased-exp fix), 7-bit `error_o` decoder |
| `tb_lm_math_fpu_div`        | PASS | 63 | 1 | 16 normals + 15 special (÷0, inf/0, NaN, over-range, all error_o bits 0/1/2/4/5 on both signs) + 9 denormal/boundary (denormal÷normal, normal÷denormal, denormal÷denormal, subnormal-magnitude result via proc_final's else branch on both signs, overflow→+inf, negative variants) |
| `tb_lm_math_fpu_div_rst`    | PASS |  5 | 1 | mid-stream rst pulse: sanity over-range + clean-vec-after-rst proves `s_error` / `s_error_x` / `proc_final` rst paths clear stale `error_o(6)` |
| `tb_lm_math_fpu_div2`       | PASS | 20 | 1 | 12 normals (incl. exact smallest-normal 2^-126 on the car=1 path) + 4 exponent-boundary + 3 denormal-magnitude (pin the proc_mant_result denormal fix; one negative variant locks down sign propagation on car=0) + 1 raw -0.0 bit pattern (sign preservation on zero) |
| `tb_lm_math_fpu_sqrt`       | PASS | 44 | 1 | 16 normals incl. exponent boundaries, identity 1.0 and small power-of-2 0.0625; 16 back-to-back; 12 special cases (±0, +∞, sNaN ±, qNaN ±, negative finite, smallest +denormal, largest +denormal, negative denormal) |
| `tb_lm_math_fpu_sqrt_rst`   | PASS |  5 | 1 | mid-stream rst pulse: sanity `sqrt(4)` + interrupted `sqrt(16)` + clean `sqrt(9)` proves the FSM lands back in `s_idle` and clears `s_q`/`s_r`/`s_x`/`s_error` |
| `tb_lm_math_fpu_mult_cmplx` | PASS | 88 | 2 (arch 0 + arch 1) | 10 normals × 2 (incl. pure-imaginary and high-mag integer-valued) + 7 special complex (NaN/inf in every operand position, both signs) + 9 denormal/boundary × 2 (FTZ propagated from prod on subnormal-magnitude components, overflow→inf [`error_o` only, no dout check], negative-denormal sign propagation through FTZ, all-four-denormal flush corner, end-to-end lock of the prod 2.0.2 subnormal-input rescue) |
| `tb_lm_math_fix_to_fpu`     | PASS | 58 | 2 (signed + unsigned) | 29 codes × 2: corner patterns, full leading-zero ladder on BOTH DUTs (every LZ count from 0 to 17, where signed DUT counts on `abs(code)` and unsigned DUT counts on the raw pattern), alternating bit patterns; unsigned never produces sign='1' |
| `tb_lm_math_fpu_to_fix`     | PASS | 60 | 2 (Q3.13 signed + UQ3.13) | 14 in-range × 2 (±2 LSB, incl. ±2.0, ±3.99), 4 overflow exact match, 7 sub-LSB / denormal exact match (0.4·LSB and 0.6·LSB bracket the RTN decision), 4 overflow-path specials (+inf / -inf / +NaN / -NaN) and 1 sign-zero raw pattern (-0.0 driven as slv since VHDL `real` collapses it to +0.0) |
| `tb_lm_math_fpu_to_fpu`     | PASS | 38 | 2 (l2s + s2l) | 10 l2s normals + 3 boundary + 6 s2l-denormal × 2 + 3 special, 10 s2l normals + 6 s2l-denormal (single denormal → double normal, exercises gen_small_to_large's shift-and-rebias + ±0 zero-detect leg) |
| `tb_lm_math_fpu_rounding`   | PASS | 56 | 4 (one per mode) | 14 vectors × 4 modes (ZERO / NEAREST / INF / NEGINF). Full (sign × guard) matrix on the normal path, mantissa-overflow exponent bump on both signs, denormal-becoming-normal on guard=11 and guard=10 for both signs |
| **Total**                   | **PASS** | **693** | — | — |

## How to read the table

* **Status** — `PASS` means the TB is self-checking and terminates with
  `TEST PASSED`. There are no smoke-only TBs left in the library.
* **Checks** — number of independent equality assertions per run. Each
  assertion compares one DUT output (typically `dout_o`, `error_o`, or
  `dv_o`) against a value computed in the TB.
* **DUTs** — how many instances of the module are exercised in parallel.
  Multiple DUTs mean a generic variant is being swept (add vs sub, signed
  vs unsigned, arch 0 vs 1, etc.) with the same stimulus stream.

## Tolerances

* **±1 ULP** on the mantissa is the default reference (most TBs).
* **±2 ULP** for `mult_cmplx`, `fpu_to_fpu`, `fix_to_fpu` (longer
  rounding chain or format-resize loss).
* **One-sided 1 ULP floor** for `fpu_sqrt`: the DUT truncates (computes
  `floor(sqrt(X))` on the scaled mantissa) while `ieee.float_pkg.sqrt`
  rounds to nearest, so the DUT result must equal the rounded reference
  or be one ULP below it. Results one ULP **above** the reference are
  rejected as bugs.
* **Exact** for `rounding` (4 DUTs vs. hand-computed expected) and for
  the overflow paths of `fpu_to_fix` (exact legacy clamp values).
* **Exact** for the direct package, integer-multiplier, and integer-divider
  helper regressions.

## Per-TB notes

### `tb_lm_math_float_pkg`
Direct package regression. It checks 45 helper-level cases: the four rounding
mode constants, `f_ceil_log2`, `f_div_ceil`, `f_max`, `f_all_ones`,
`f_int_to_sl`, `f_divide_by_two`, `f_count_delta`, `f_count_kernel`,
`f_bump_left`, `f_bump_right`, and `f_resize_right`.

The test uses explicit `downto` vectors because the helpers are used by RTL
signals with descending ranges. Contract-violation assertions (empty vectors,
zero sizes, negative divider inputs) are not intentionally fired in the main
regression because they are expected to stop simulation.

### `tb_lm_math_fi_mult`
Direct helper regression for `lm_math_fi_mult`. Two DUTs run against the same
stimulus:

* full-width output with `g_pipe_stages = 0`;
* truncated output with `g_pipe_stages = 2`.

The 7 vectors cover zero, one, asymmetric operands, maximum product, and
right-aligned truncation. The invalid generic case `g_dout_w >
g_din_a_w + g_din_b_w` is guarded by an elaboration assertion and is not
included in the normal pass suite.

### `tb_lm_math_int_div`
Direct helper regression for `lm_math_int_div`. Two DUTs use the same
`g_data_w=5` / `g_quotient_size=6` shape with different chunk sizes:

* `g_chunk_size = 1`;
* `g_chunk_size = 4`, intentionally not an even divisor of the quotient
  width.

The 8 vectors cover zero dividend, dividend less than / equal to / greater
than divisor, non-power-of-two divisors, and the maximum in-contract ratio
below 2.0. Expected quotient is
`floor(dividend * 2^(g_quotient_size - 1) / divisor)`.

### `tb_lm_math_fpu_sum`
Dual-DUT: `uut_add` (`g_operation='1'`) + `uut_sub` (`g_operation='0'`)
share the same `a_i`/`b_i`. Three phases:

* 18 normals checked on both `dout` (±1 ULP vs. `ieee.float_pkg`)
  and `error_o = "0000"`. On top of the original 16-vec mix, the
  set adds:
  - vec 16: `1.0 + -1.0` — exact cancellation on the add DUT
    (sub gives 2.0). The previous set covered sub-side
    cancellation (vec 2: `-3.75 - -3.75 = 0`) but never made
    the add path land on zero.
  - vec 17: `1e+30 + 1e-30` — alignment-shift saturation. The
    two operands differ by ~199 exponent bits, so the smaller
    one shifts out entirely and the result equals the larger.
    Locks down the alignment shifter on a magnitude gap that
    the previous set did not approach.
* 10 special vectors with hard-coded expected `error_o`. `dout` is
  NOT checked — module header documents it as not IEEE-conformant
  when `error_o /= 0`, and consumers must read `error_o` first.
  - vec 0: +NaN-A (bit 0, sign='0')
  - vec 1: +NaN-B (bit 1, sign='0')
  - vec 2: +inf-A (bit 2, sign='0')
  - vec 3: +inf-B (bit 3, sign='0')
  - vec 4: +NaN + +inf (NaN-A | inf-B)
  - vec 5: `-inf + finite` — sign='1' on bit 2 (inf-A).
  - vec 6: `+inf + -inf` — both inputs are inf so both inf
    flags fire (`error_o = "1100"`). The IEEE result is NaN
    but the module flags INPUTS, not outputs.
  - vec 7: `-NaN + finite` — sign='1' on bit 0 (NaN-A).
  - vec 8: `finite + -NaN` — sign='1' on bit 1 (NaN-B).
  - vec 9: `finite + -inf` — sign='1' on bit 3 (inf-B).
    Vecs 5/7/8/9 together complete the "every `error_o` bit
    on both signs of the special input" coverage claim.
* 7 denormal vectors exercising every branch of the subnormal code
  path: denormal+denormal (stays denormal), denormal+denormal
  crossing into normal, denormal−denormal (zero result, exact),
  denormal−denormal (stays denormal), normal+denormal (absorbed),
  denormal+0, negative-denormal + negative-denormal (locks down
  sign propagation: add stays subnormal with sign='1', sub flips
  to opposite-sign subnormal). All checked ±1 ULP vs.
  `ieee.float_pkg` with `error_o = "0000"`.

A continuous-time `proc_dv_pre_invariant` verifies the
`dv_pre_o` → `dv_o` pipeline relationship throughout; its counter
is separated from the main one to avoid the VHDL multi-driver issue.

### `tb_lm_math_fpu_prod`
Single DUT. Four phases:

* 16 normals (full mantissa range), ±1 ULP vs. `ieee.float_pkg "*"`,
  per-vector `error_o` decode via the `f_expected_err` helper that
  mirrors `proc_errors` (7 bits).
* 9 special vectors hitting every `error_o` bit: `NaN×f`, `f×NaN`,
  `±inf×f`, `f×±inf`, `±inf×0`, `0×±inf`, `±inf×±inf`, `NaN×±inf`,
  `NaN×NaN`. `dout` is NOT checked — the module header documents it
  as not IEEE-conformant for these inputs.
* 6 FTZ vectors that exercise the documented flush-to-zero
  behavior of `proc_final_car_eval`: a subnormal product (input or
  computed) clamps the exponent and mantissa to 0 and the sign bit
  (`s_sign_a XOR s_sign_b`) passes through, so the output is `±0`
  with `error_o = "0000000"`. The six vectors all have positive
  operands so we compare against `+0` exactly; a TB note documents
  the sign-preservation contract for any future negative case.
  Vectors 0–1 (denormal × normal and normal × denormal) are
  placed FIRST in the FTZ phase on purpose: the phase runs
  immediately after `NaN×NaN` (the last special vector), so vec 0
  is preceded by `NaN×NaN` (s_delta = 0) — the exact stimulus
  ordering that exposed the 2.0.1 `s_delta`-alignment bug. The
  legacy registered `proc_delta_count` made `s_delta` lag
  `s_mult_out` by one cycle, so vec 0 used to inherit `NaN×NaN`'s
  `s_delta = 0`, skip the FTZ clamp, and emit a corrupted output.
  They now pass.
* 3 subnormal-input rescue vectors: a subnormal operand multiplied
  by a normal operand whose IEEE product lands BACK in the normal
  range (no FTZ). Compared against `ieee.float_pkg "*"` within
  ±1 ULP and `error_o = "0000000"`.
  - vec 0: `+1e-40 * +1e+30 = +1e-10` — A subnormal, sign='0'.
  - vec 1: `-1e-40 * +1e+30 = -1e-10` — A subnormal, sign='1';
    locks down sign propagation through the rescue path.
  - vec 2: `+1e+30 * +1e-40 = +1e-10` — B subnormal; locks down
    the symmetric (B-side) compensation in `proc_car_sum`.
  Pre-2.0.2 the DUT produced half the correct value because the
  stored 0 biased exponent of a subnormal operand was used raw in
  `s_car_sum` instead of being promoted to the IEEE-effective
  value 1. This phase was added during the 2.0.2 PR after the bug
  was surfaced by extending `tb_lm_math_fpu_mult_cmplx`.

### `tb_lm_math_fpu_div`
Three phases on a single DUT:

* 16 normals (`error_o = "0000000"`), `dout` vs `ieee.float_pkg "/"`
  within ±1 ULP.
* 15 special vectors covering every `error_o` bit AND every
  individual bit on both signs of the special input. `dout` is
  not IEEE-conformant for these (the data path doesn't detect
  specials), so only `error_o` is checked.
  - vec 0..9: original sign='0' coverage of bits 0..6
    (NaN-A, NaN-B, +inf/fin, fin/+inf, +inf/+inf, fin/+0,
    +0/fin, NaN/NaN, +inf/+0, huge/tiny overflow).
  - vec 10: `fin / -inf` — bit 0 with sign='1'.
  - vec 11: `-NaN / fin` — bit 1 with sign='1'.
  - vec 12: `fin / -NaN` — bit 2 with sign='1'.
  - vec 13: `-inf / fin` — bit 4 with sign='1'.
  - vec 14: `fin / -0` — bit 5 with sign='1' (driven as a raw
    bit pattern via `f_neg_zero` because VHDL `real` collapses
    `-0.0` to `+0.0`; `proc_errors` decodes both +0 and -0
    identically, so bit 6 fires alongside bit 5 same as vec 5).
  Bit 3 (`inf/inf`) is excluded from the sign='1' sweep because
  both inputs are inf and "sign" does not pick a single operand.
* 9 denormal / exponent-boundary vectors:
  - `1e-40 / 2.0` — denormal dividend / normal divisor → denormal
    result;
  - `2.0 / 1e-40` — normal / denormal → overflow to +inf (bit 6);
  - `1e-40 / 1e-40` — denormal / denormal → result ~ 1.0,
    compared against `float_pkg "/"` within ±1 ULP like the
    other in-range vectors;
  - `1e-20 / 1e+20` — normal / normal where the quotient lands in
    the subnormal range; exercises `proc_final`'s `else` branch
    (`shift_right(s_int_res_d, -s_car_res)`) with sign='0';
  - `1e+30 / 1e-10` — overflow to +inf (bit 6);
  - `-1.0 / 2.0`, `1.0 / -2.0`, `-1e-40 / 2.0` — sign-propagation
    sanity through the full data path;
  - `-1e-20 / 1e+20` — exercises `proc_final`'s `else` branch
    with sign='1', complement to vec 3. Result `-1e-40` is
    compared against `float_pkg "/"` within ±1 ULP.

  All in-range denormal vectors pass against `float_pkg "/"`
  within ±1 ULP with `error_o` matching the per-vector expected
  pattern. For the two over-range cases `dout` is documented as
  not IEEE-conformant and is not checked.

The DUT's `error_o` bits 0–5 come from a reset-aware pipeline;
bit 6 (over-range) also has rst behavior (the original shift
register was un-reset and could leave stale data after `rst_n_i`).

### `tb_lm_math_fpu_div2`
Three paths in `proc_mant_result` depending on the input class:

* Normal input (car > 1) — exponent decremented by 1, mantissa
  passed through unchanged.
* Smallest normal (car = 1) — output lands in the denormal range,
  the implicit '1' becomes the explicit MSB of the output mantissa,
  car_out = 0.
* Denormal input (car = 0) — exponent stays at 0, mantissa is
  shifted right by one in the bit field; smallest denormal
  truncates to ±0 (sign preserved).

Coverage breakdown (20 checks total):

* 12 normals across the value range, including the exact smallest
  single-precision normal `2.0**(-126)` — that input produces a
  denormal output via the `car = 1` branch, a path that the
  previous set never hit (`2.35e-38 ≈ 2^-125` sits at car=2, one
  bit above).
* 4 exponent-boundary normals (2.35e-38, 8.5e+37, 2.0, 4.0).
* 3 denormal-magnitude vectors. Vec 16 (`2.0e-40`) and vec 17
  (`5.0e-40`) pin the 2.0.1 fix to the `car = 0` branch. Vec 18
  (`-2.0e-40`) locks down sign propagation on the same branch.
* 1 raw `-0.0` bit pattern driven via `f_neg_zero` (VHDL `real`
  does not preserve a distinct -0, so `to_float(-0.0)` collapses
  to +0). The DUT must produce the same `-0` bit pattern
  exactly — sign-bit passthrough.

Does **not** cover NaN / inf — the module has no special-case
path for those.

The legacy `car = 0` code did `shift_left(s_mant_den, 1)` which
dropped the implicit '1' and made the output equal to the INPUT
rather than input/2; the 2.0.1 fix replaces it with a right-shift
on the denormal mantissa.

### `tb_lm_math_fpu_sqrt`
Comprehensive. Three phases:

* Phase 1: 16 positive normals with reset between every vector.
  Mix of perfect squares, irrational sqrts, and exponent boundaries
  (close to the small-denormal and large-finite edges), plus the
  identity 1.0 and a small power-of-2 0.0625 to round out the
  exponent ladder. Compared against `ieee.float_pkg.sqrt` with
  the one-sided 1 ULP floor tolerance (DUT may equal or be one ULP
  below the rounded reference; one ULP above is rejected as a bug).
* Phase 2: same 16 vectors back-to-back without resets. Exercises
  the FSM's `s_done → s_idle` transition on `enable_i = '0'`.
* Phase 3: 12 special bit-pattern cases:
  - `+0` → `+0`, no error;
  - `-0` → `+0`, no error (sign cleared);
  - `+inf` → `+inf`, no error;
  - `-inf` → canonical NaN, error;
  - `+sNaN` / `-sNaN` passthrough (mantissa MSB=0 + distinctive
    LSB) — sign and full payload preserved;
  - `+qNaN` / `-qNaN` passthrough (mantissa MSB=1 + distinctive
    LSB) — verifies that the NaN detection accepts the quiet
    convention too, not only the signaling pattern;
  - negative finite (-4.0) → canonical NaN, error;
  - smallest positive denormal (mantissa = LSB only) → `+0`, error;
  - largest positive denormal (mantissa all-ones) → `+0`, error
    (verifies that the denormal-detection branch fires on any
    positive denormal mantissa, not just the LSB-only case);
  - negative denormal → canonical NaN, error (verifies that the
    negative-non-zero branch fires before the positive-denormal
    branch).

The DUT implements digit-by-digit binary sqrt; reference for
phases 1-2 is `ieee.float_pkg.sqrt`. Special-case outputs (phase
3) are exact bit-pattern comparisons.

### `tb_lm_math_fpu_mult_cmplx`
Dual-arch: `uut_arch1` (`g_architecture='1'`, 4 multipliers + 2 adders,
straightforward `ac-bd, ad+bc`) and `uut_arch0` (`g_architecture='0'`,
3 multipliers + 5 adders, Gauss/Karatsuba) get the same complex
inputs. Three phases on each DUT:

* 10 normals checked on both components (±2 ULP vs.
  `ieee.float_pkg`) and `error_o = "00"`. On top of the original
  8-vec mix, the set adds a pure-imaginary pair (a = 0 + 1j,
  b = 0 + 1j → -1 + 0j; exercises the path where two of the four
  internal products are zero) and an integer-valued high-magnitude
  vector (a = 10 + 20j, b = 30 + 40j → -500 + 1000j; exact in
  float32 on both arches' intermediate sums).
* 7 special bit-pattern vectors (NaN / +-inf in one of the four
  input components) with `error_o /= "00"`. The 4-vec original set
  only covered the (a_re, a_im, {b_re + b_im}) operand positions
  with sign='0' specials. The 3 new vectors close the gaps: vec 4
  isolates +inf in b_im, vec 5 puts -inf in a_re (first sign='1'
  special, exercises the negative-sign special-detection path),
  and vec 6 isolates +NaN in b_re.
* 9 denormal / boundary vectors:
  - denormal A * normal B and normal A * denormal B with
    subnormal-magnitude result;
  - normal A * normal B that underflows to subnormal;
  - both components denormal;
  - negative signed variant;
  - overflow case (`1e30 * 1e30`; the IEEE/reference result is
    `+inf`, but the module documents `dout` as not
    IEEE-conformant when `error_o /= "00"`, so the TB only
    asserts `error_o = "10"` and does not check the data outputs
    in this case);
  - negative-denormal × small-normal with subnormal-magnitude
    product (`-1e-40 * 2.0 = -2e-40` → FTZ to -0). Locks down
    sign propagation through prod's FTZ on negative subnormal
    products. arch=1 and arch=0 legitimately differ on the
    `v_re` sign-zero (arch=1: -0 from `-0 - +0`; arch=0: +0 from
    `-0 - (-0)`); both are IEEE-correct and `f_check_component`
    compares the per-arch sign;
  - all-four-denormal (`1e-40` in every component). Every
    internal product flushes to +0 on both arches; result is
    exactly `(+0, +0)`. Closes the "everything flushes" corner
    that the previous denormal set did not cover;
  - negative-subnormal-input × large-normal-input with the
    product BACK in the normal range (`-1e-40 × 1e+30 = -1e-10`).
    End-to-end lock of the prod 2.0.2 fix (`proc_car_sum`
    promoting the stored 0 biased exp of a subnormal operand to
    its effective value 1). Both arches give `(-1e-10, +0)`:
    arch=0's `v_im` benefits from exact cancellation
    (`f + h = -1e-10 + 1e-10 = +0`); arch=1's `v_im` comes from
    the inner FTZ products (`-0 + +0 = +0`). This vector locks the
    cmplx-side behavior end-to-end for the prod-side subnormal-input
    exponent fix.

  The reference for each in-range vector is built by applying
  `lm_math_fpu_prod`'s FTZ rule at each `lm_math_fpu_prod`
  instance output, then doing the downstream sums via
  `float_pkg`. The set of internal products differs per
  architecture, so the TB uses two separate reference paths:

  - **arch=1 (4-mult)**: FTZ at `ac`, `bd`, `ad`, `bc`; then
    `re = ac - bd`, `im = ad + bc`.
  - **arch=0 (3-mult Gauss/Karatsuba)**: precompute the three
    intermediate sums `c = b_re + b_im`, `d = a_im + a_re`,
    `e = a_im - a_re` in full subnormal arithmetic; then FTZ at
    the three products `f = a_re * c`, `g = b_im * d`,
    `h = b_re * e`; then `re = f - g`, `im = f + h`.

  This mirrors what `mult_cmplx` actually computes in each
  architecture: prod is FTZ on subnormal-magnitude internal
  products, the downstream sums operate on the flushed terms, and
  cancellation of two normal-magnitude products can legitimately
  produce a non-zero subnormal final component (which the DUT
  must then emit, not flush again). The per-component check:
  - expects FTZ (zero magnitude with the reference's sign) when
    the (post-FTZ) reference component is zero-magnitude;
  - compares within ±2 ULP otherwise.
  Documented in the `mult_cmplx` header.

Per-DUT counters merged at end-of-sim.

### `tb_lm_math_fix_to_fpu`
Dual-DUT: signed (`g_is_signed='1'`) and unsigned. 29 codes × 2
comparisons spanning:

* corner codes — max-positive (`0x1FFFF`), min-signed-negative
  (`0x20000`), min+1 (`0x20001`), all-ones (`0x3FFFF`, encoded
  as `-1`), all-zeros (`0x00000`), `0x3FFFE` (`-2` / unsigned
  near-max);
* the full leading-zero ladder on BOTH DUTs — at least one code
  per LZ count from 0 to 17. `proc_count_delta`'s input differs
  between the two DUTs: the signed DUT sees `abs(fix_in_i)`
  (post-two's-complement), the unsigned DUT sees the raw
  pattern. The C_FIX list is constructed so that, between
  positives and negatives, every LZ count is hit on BOTH paths
  (e.g. LZ=16 on signed via `-2` (abs `0x00002`) and on unsigned
  via the new positive `2` (raw `0x00002`));
* two alternating-bit patterns (`0x15555` and `0x2AAAA`) that
  stress the sign+absolute-value path with non-trivial mantissa
  content.

Explicit invariant: the unsigned DUT must never output
`sign='1'`, even when the fixed-point input has its MSB set
(locked down by the round-2 `s_sign_in <= '0' when g_is_signed = '0'` fix).

### `tb_lm_math_fpu_to_fix`
Dual-DUT Q3.13 signed and unsigned. Five phases:

* 14 in-range vectors (±2 LSB on the fixed code). On top of the
  original 10-vector mix, the set adds ±2.0 (exact powers of two,
  exp_unbiased = 1 shift amount that the original set did not
  hit) and ±3.99 (just-inside the signed-DUT range, |x| < 4.0,
  max-representable signed is 2^2·(1 - 2^-13) ≈ 3.9999).

  The sign-zero corner (-0.0) is intentionally NOT in this group:
  VHDL `real` arithmetic does not preserve a distinct negative
  zero, so a real literal `-0.0` collapses to `+0.0` on
  `to_float()` and would duplicate the existing `0.0` vector
  without exercising the sign='1', magnitude=0 path. The
  dedicated -0.0 check is driven later as a raw IEEE-754 bit
  pattern (sign=1, exp=0, mant=0) via `f_negzero`; both DUTs must
  produce 0x0000 (signed must not negate magnitude 0 into -1;
  unsigned must drop the sign).
* 4 overflow vectors (exact match against the legacy clamp
  constants: `0xFFFF` for positive overflow, `0x0001` for negative
  signed overflow after the 2's-complement negate; documented in
  the TB).
* 7 sub-LSB / denormal vectors (exact match): positive denormal
  (1e-40), negative denormal (-1e-40), another denormal example
  (5e-39; not the maximum subnormal, which is ~1.175e-38),
  very small normal (1e-30, below the LSB), `0.4·LSB` (just below
  the half-LSB RTN threshold, rounds DOWN to 0), `0.6·LSB` (just
  above the half-LSB threshold, rounds UP to 0x0001), and 1.0e-4
  which for the default Q3.13 generics is between 0.5 and 1.0 LSB
  and rounds UP to 0x0001. The 0.4/0.6·LSB pair brackets the
  round-to-nearest decision boundary without relying on a specific
  tie-breaking convention. The DUT path is
  `shift_right(s_num_aux, s_exp)` with `s_exp = C_BIAS - s_car`,
  which shifts denormals out by ~bias positions and yields 0.
* 4 special bit-patterns (`+inf`, `-inf`, `+NaN`, `-NaN`) which all
  funnel into the overflow path. The sign bit of the input drives
  the clamp-then-negate path on the signed DUT, so +inf / +NaN
  give 0xFFFF and -inf / -NaN give 0x0001; the unsigned DUT
  always gives 0xFFFF.
* 1 -0.0 raw bit pattern. This goes through the regular data
  path (not the overflow path -- the input exponent is 0, well
  below the overflow threshold) and both DUTs must produce
  0x0000.

Known coverage gap (deliberately not exercised here): the band
|x| in [2^(g_fix_length-g_fix_bpoint-1), 2^(g_fix_length-g_fix_bpoint))
— e.g. [4.0, 8.0) for default Q3.13. The DUT's overflow detector
trips at `exp_unbiased >= g_fix_length-g_fix_bpoint`, but the
signed fixed format saturates one bit earlier, so values in this
band would expose a latent wrap-around on the signed DUT. Out of
scope for a pure-coverage PR; tracked separately.

### `tb_lm_math_fpu_to_fpu`
Dual-direction: `uut_l2s` (large→small: 11/52 → 8/23) and `uut_s2l`
(small→large: 8/23 → 11/52). Four phases per direction:

* 10 mid-range normals on both DUTs (±2 ULP vs `float_pkg.resize()`).
* 3 boundary vectors (1e+300, 1e-300, -1e+300) — only the l2s
  direction is checked here; s2l skips them because they can't be
  encoded as single in the first place.
* 6 s2l-denormal vectors covering single-precision denormals
  (1e-40, -1e-40, 5e-39, smallest denormal 2^-149), `+0`
  (exercises the 2.0.1 zero-detect leg), and min normal single
  (2^-126, boundary case where car=1 so the denormal-
  normalization branch is NOT engaged). Each is checked on both
  DUTs: s2l uses `gen_small_to_large`'s shift-and-rebias path
  to turn the input denormal into a double-precision normal,
  l2s round-trips the double-encoded copy back down. Both
  compared against `float_pkg.resize()` within ±2 ULP.
* 3 special bit-patterns (+inf, -inf, +NaN) — only the l2s
  direction is checked (the legacy s2l path adds C_DELTA_BIAS
  to s_car_in without detecting all-ones, so a single +inf is
  rewritten as a large finite normal instead of producing a
  double +inf; documented limitation).

The s2l direction uncovered the pipeline alignment fix in 2.0.1
(`s_car_in_d1` register + explicit zero-detect leg in
`gen_small_to_large`).

### `tb_lm_math_fpu_rounding`
Four DUTs in parallel, one per rounding mode (ZERO / NEAREST / INF /
NEGINF). Same `(sign, car, mantissa+2-guard-bit)` stimulus is driven
to all of them. 14 vectors × 4 modes:

* guard `00` / `01` / `10` / `11` with both signs — vec 0..5 cover
  the positive normal path, vec 10 / 11 complete the (sign, guard)
  matrix on the negative normal path with `guard=11` and `guard=00`.
* mantissa all-ones + round-up — vec 6 / 7 (positive and negative)
  exercise the mantissa-overflow exponent bump (proc_go_out path).
* `car=0` with mantissa all-ones — vec 8 / 9 (guard=11) and vec
  12 / 13 (guard=10) exercise the "denormal becoming normal" leg
  in proc_go_out. The guard=10 pair verifies that the branch
  fires for any rounding-mode + sign combination that decides to
  round up, not only for guard=11.

Each expected output is hard-coded from manual analysis (not derived
from the DUT), so the TB is a real independent reference, not a
self-comparison.

### `tb_lm_math_fpu_div_rst`
Mid-stream `rst_n_i` pulse on `lm_math_fpu_div`. Two phases:

* Phase A — sanity. Drives an over-range pair (`1.0e30 / 1.0e-10`)
  and waits the full latency, confirming `error_o(6) = '1'` arrives
  at `dv_o` time. Proves the over-range detection works in normal
  operation.
* Phase B — rst test. Drives the same over-range pair, asserts
  `rst_n_i = '0'` for 5 cycles BEFORE the bit-6 `'1'` reaches the
  output, lets the pipeline flush, then drives a clean `2.0 / 1.0`
  and waits the latency. Verifies `dv_o = '1'` with
  `error_o = "0000000"` and `quotient_o ≈ 2.0` within 1 ULP. Without
  the rst additions on `s_error` / `s_error_x` / `proc_final` (PR
  #3), the stale bit-6 `'1'` would still be present in the
  shift register and would surface as `error_o(6) = '1'` on the
  clean vector.

### `tb_lm_math_fpu_sqrt_rst`
Mid-stream `rst_n_i` pulse on `lm_math_fpu_sqrt`. Two phases:

* Phase A — sanity. `sqrt(4.0) = 2.0` within 1 ULP.
* Phase B — rst test. Starts `sqrt(16.0)`, waits 5 cycles so the
  FSM is in `s_busy` with non-zero `s_q`/`s_r`/`s_x`, then pulses
  `rst_n_i = '0'` for 5 cycles. After rst, drops `enable_i` to
  guarantee the FSM is in `s_idle`, then issues `sqrt(9.0)`. Verifies
  `done_o = '1'` arrives within `2 * (K+1)` cycles and that
  `dout_o ≈ 3.0` within 1 ULP with `error_o = '0'`. Without the
  rst handling, the FSM would resume from a stale `s_busy` and
  either hang or produce a corrupted dout.

## Modules without `rst_n_i`

Only `lm_math_fpu_div` and `lm_math_fpu_sqrt` expose a reset port.
The other modules rely on signal initialization at elaboration and
on `dv_i = '0'` to drain their pipelines naturally. Adding rst to
them is a possible future enhancement but is not yet scoped.

## Coverage gaps

These are known not-tested behaviors. They are not bugs; they are
intentional limits of the current sim plan.

* Mid-stream rst is now covered for `div` and `sqrt`. `prod`, `sum`,
  `mult_cmplx`, `rounding`, the format converters, and `div2` have
  no reset port, so this remains untested for those modules.
* `s_dv` shift registers (in `div`) and other data-path shift
  registers throughout the library do NOT have rst. Stale dv pulses
  can surface as spurious `dv_o = '1'` during/after rst. The TBs
  flush this by ignoring any output until a deterministic
  post-latency window after the next driven `dv_i = '1'`. Adding
  data-path rst is a scope decision, not currently planned.
* Denormal arithmetic in `sum` is now covered (6 vectors crossing
  every branch of the subnormal code path). `prod` and `div`
  remain untested for denormal inputs; their behavior is undefined
  per their module headers.
* Multi-clock-domain behavior: the library is single-clock by design.
  No CDC checks are run.
* Synthesis-time warnings (latches, multi-drivers in elaborated
  netlists) are not part of the TB suite — they belong to the
  synthesis flow.
