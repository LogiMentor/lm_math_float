<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Logimentor -->

# Regression Coverage

This matrix maps every public source module to a self-checking regression.
The suite is intended to cover every documented module contract and edge-case
class, not every possible input bit pattern.

| Source module | Direct regression | Additional exercised through | Covered classes |
|---|---|---|---|
| `lm_math_float_pkg` | `tb_lm_math_float_pkg` | all RTL modules | Rounding constants, sizing helpers, bit helpers, count/shift helpers, resize-right behavior on explicit `downto` vectors. |
| `lm_math_fi_mult` | `tb_lm_math_fi_mult` | `lm_math_fpu_prod`, `lm_math_fpu_mult_cmplx` | Zero/one/max/asymmetric operands, full product, right-aligned truncation, `g_pipe_stages=0` and `g_pipe_stages=2`. |
| `lm_math_int_div` | `tb_lm_math_int_div` | `lm_math_fpu_div` | Zero dividend, dividend less/equal/greater than divisor, non-power-of-two divisors, non-even chunking, chunk sizes 1 and 4. |
| `lm_math_fpu_rounding` | `tb_lm_math_fpu_rounding` | sum/product/division paths | Four rounding modes, sign x guard matrix, mantissa overflow exponent bump, denormal becoming normal. |
| `lm_math_fpu_sum` | `tb_lm_math_fpu_sum` | `lm_math_fpu_mult_cmplx` | Add/subtract, normal vectors, exact cancellation, alignment saturation, special-input error bits, denormal arithmetic, `dv_pre_o` invariant. |
| `lm_math_fpu_prod` | `tb_lm_math_fpu_prod` | `lm_math_fpu_mult_cmplx` | Normal product, special-input error bits, FTZ products, subnormal-input normal-result rescue cases. |
| `lm_math_fpu_div` | `tb_lm_math_fpu_div`, `tb_lm_math_fpu_div_rst` | none | Normal division, special-input error bits, divide-by-zero, over-range, denormal/boundary paths, mid-stream reset clearing. |
| `lm_math_fpu_div2` | `tb_lm_math_fpu_div2` | none | Normal divide-by-two, exponent boundaries, denormal-magnitude cases, negative denormal sign propagation, raw negative zero pattern. |
| `lm_math_fpu_sqrt` | `tb_lm_math_fpu_sqrt`, `tb_lm_math_fpu_sqrt_rst` | none | Normal square root, back-to-back operation, zero/infinity/NaN/negative/denormal special cases, mid-stream reset recovery. |
| `lm_math_fpu_mult_cmplx` | `tb_lm_math_fpu_mult_cmplx` | none | 3- and 4-multiplier architectures, normal complex products, special operands in every component position, denormal/boundary behavior. |
| `lm_math_fix_to_fpu` | `tb_lm_math_fix_to_fpu` | none | Signed and unsigned fixed input, corner patterns, leading-zero ladder, alternating patterns, unsigned sign invariant. |
| `lm_math_fpu_to_fix` | `tb_lm_math_fpu_to_fix` | none | Signed and unsigned fixed output, in-range values, overflow clamps, sub-LSB rounding bracket, special overflow paths, raw negative zero. |
| `lm_math_fpu_to_fpu` | `tb_lm_math_fpu_to_fpu` | none | Large-to-small and small-to-large resize, mid-range normals, boundaries, special l2s bit patterns, s2l denormal normalization. |

## What "All Cases" Means Here

The pass suite covers every documented behavior class in the module headers
and `TESTPLAN.md`: normal paths, selected special encodings, boundary values,
documented subnormal behavior, reset behavior where reset exists, and generic
variants that the library exposes as supported.

It is not exhaustive over the full input space. In particular, the suite does
not intentionally run:

* invalid generic configurations that are expected to fail elaboration;
* helper-function contract violations that are expected to raise
  `severity failure`;
* all possible NaN payloads or every possible mantissa/exponent bit pattern;
* synthesis, timing, CDC, or formal equivalence checks.

Those are separate verification jobs. The current regression is a
self-checking simulation regression for the documented public contract.
