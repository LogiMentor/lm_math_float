--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_float_pkg
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Self-contained support package for the floating point
--               arithmetic library. Provides:
--                 * rounding mode constants
--                 * f_ceil_log2 / f_div_ceil / f_max  (sizing helpers)
--                 * f_all_ones, f_int_to_sl, f_divide_by_two
--                 * f_count_delta, f_count_kernel,
--                   f_bump_left, f_bump_right, f_resize_right
--                   (bit-counting / shifting helpers used by the FPU cores)
--
--               Only symbols actually used by the FPU modules are kept.
--               No external library dependencies.
--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Revision History:
-- Date  Version  Author      Description
-- 2026  1.0.0    Logimentor  Initial public release.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package lm_math_float_pkg is

  -----------------------------------------------------------------------------
  -- Rounding mode constants
  -----------------------------------------------------------------------------
  --* Default: round to nearest (ties up)
  constant C_LM_ROUND_NEAREST : integer := 1;
  --* Round toward +infinity
  constant C_LM_ROUND_INF     : integer := 2;
  --* Round toward -infinity
  constant C_LM_ROUND_NEGINF  : integer := 3;
  --* Round toward zero (simple truncation)
  constant C_LM_ROUND_ZERO    : integer := 4;

  -----------------------------------------------------------------------------
  -- Sizing helpers
  -----------------------------------------------------------------------------
  --* Ceiling of log2(n). f_ceil_log2(1)=1, f_ceil_log2(2)=1, f_ceil_log2(3)=2,
  --  f_ceil_log2(4)=2, f_ceil_log2(5)=3, ...
  function f_ceil_log2(n : natural) return natural;

  --* Ceiling of a/b. Contract: a >= 0 (non-negative dividend),
  --  b > 0 (positive divisor). a = 0 is allowed and returns 0
  --  for any valid b. Earlier documentation said "positive
  --  integers" but this was confirmed: the formula is correct
  --  on non-negative a (and zero-dividend has a well-defined result),
  --  so 0 is admitted explicitly.
  function f_div_ceil(a : integer; b : integer) return integer;

  --* Maximum of two integers
  function f_max(l, r : integer) return integer;

  -----------------------------------------------------------------------------
  -- Bit-pattern helpers
  -----------------------------------------------------------------------------
  --* Returns '1' when all the bits of the vector are '1', '0' otherwise
  function f_all_ones(vector_i : unsigned) return std_logic;

  --* Converts an integer to '0' (when zero) or '1' (when non-zero)
  function f_int_to_sl(in_num : integer) return std_logic;

  --* Truncating integer division by 2^depth_i (sign-preserving)
  function f_divide_by_two(number_i : integer; depth_i : natural) return integer;

  -----------------------------------------------------------------------------
  -- Counting / shifting helpers used by the FPU normalization paths
  -----------------------------------------------------------------------------
  --* Counts the leading zeros (from the left): "000101100110100" -> 3
  function f_count_delta(vector_i : unsigned) return unsigned;

  --* Distance between the leftmost and rightmost '1' bits (inclusive):
  --  "000101100110100" -> 10
  function f_count_kernel(vector_i : unsigned) return unsigned;

  --* Shift left until the most significant '1' hits the left border:
  --  "0000110100000" -> "1101000000000"
  function f_bump_left(in_vector : unsigned) return unsigned;

  --* Shift right until the least significant '1' hits the right border:
  --  "0000110100000" -> "0000000001101"
  function f_bump_right(in_vector : unsigned) return unsigned;

  --* Like numeric_std.resize, but the zero padding is applied on the right
  --  instead of on the left: "001101" -> "0010100000"
  function f_resize_right(vector_in : unsigned; length_out : natural) return unsigned;

end package lm_math_float_pkg;


package body lm_math_float_pkg is

  -----------------------------------------------------------------------------
  -- Sizing helpers
  -----------------------------------------------------------------------------
  function f_ceil_log2(n : natural) return natural is
    variable v_i, v_bitcount : natural;
  begin
    assert n >= 1
      report "lm_math_float_pkg.f_ceil_log2: n must be >= 1 (log2(0) is "
             & "undefined)."
      severity failure;
    if n = 1 then
      return 1;
    end if;
    v_i        := n - 1;
    v_bitcount := 0;
    while (v_i > 0) loop
      v_bitcount := v_bitcount + 1;
      v_i        := to_integer(shift_right(to_unsigned(v_i, 32), 1));
    end loop;
    return v_bitcount;
  end function;

  function f_div_ceil(a : integer; b : integer) return integer is
    variable v_div_res : integer := 0;
    variable v_div_mod : integer := 0;
  begin
    --   Contract (see the function declaration comment): a >= 0 and
    --   b > 0. a = 0 is allowed and returns 0 for any valid b. The
    --   ceiling formula below is correct on non-negative dividends
    --   thanks to VHDL `mod` semantics; a negative dividend would
    --   silently return mathematically-wrong results. b = 0 is
    --   undefined; b < 0 would flip the ceiling direction.
    assert a >= 0
      report "lm_math_float_pkg.f_div_ceil: dividend a must be >= 0, got "
             & integer'image(a) & "."
      severity failure;
    assert b > 0
      report "lm_math_float_pkg.f_div_ceil: divisor b must be > 0, got "
             & integer'image(b) & "."
      severity failure;
    v_div_res := a / b;
    v_div_mod := a mod b;
    if v_div_mod = 0 then
      return v_div_res;
    else
      return v_div_res + 1;
    end if;
  end function;

  function f_max(l, r : integer) return integer is
  begin
    if l > r then
      return l;
    else
      return r;
    end if;
  end function;

  -----------------------------------------------------------------------------
  -- Bit-pattern helpers
  -----------------------------------------------------------------------------
  function f_all_ones(vector_i : unsigned) return std_logic is
    constant C_ALL_ONES : unsigned(vector_i'range) := (others => '1');
  begin
    if vector_i = C_ALL_ONES then
      return '1';
    else
      return '0';
    end if;
  end function;

  function f_int_to_sl(in_num : integer) return std_logic is
  begin
    if in_num = 0 then
      return '0';
    else
      return '1';
    end if;
  end function;

  function f_divide_by_two(number_i : integer; depth_i : natural) return integer is
    --   sizing uses f_max(depth_i, 1) so the variable declaration is
    --   always valid; the assert below catches the real precondition
    --   violation and aborts before any logic that depends on depth_i.
    constant C_SAFE_DEPTH : natural := f_max(depth_i, 1);
    variable v_number : unsigned(C_SAFE_DEPTH - 1 downto 0);
  begin
    assert depth_i >= 1
      report "lm_math_float_pkg.f_divide_by_two: depth_i must be >= 1 "
             & "(the internal working vector would have an invalid range)."
      severity failure;
    if number_i >= 0 then
      v_number := '0' & to_unsigned(number_i, depth_i)(v_number'left downto 1);
      return to_integer(v_number);
    else
      v_number := '0' & to_unsigned(-number_i, depth_i)(v_number'left downto 1);
      return -to_integer(v_number);
    end if;
  end function;

  -----------------------------------------------------------------------------
  -- Counting / shifting helpers
  -----------------------------------------------------------------------------
  function f_count_delta(vector_i : unsigned) return unsigned is
    --   declarative-region sizes use f_max(..., 1) so f_ceil_log2 is
    --   never called with 0 (which would fire f_ceil_log2's own assert
    --   first and mask the more specific f_count_delta diagnostic
    --   below).
    constant C_SAFE_LEN  : natural := f_max(vector_i'length, 1);
    constant C_BITS      : natural := f_ceil_log2(C_SAFE_LEN);
    variable v_vector : unsigned(f_max(vector_i'left, 0) downto 0);
    variable v_delta  : unsigned(C_BITS downto 0)
                        := to_unsigned(C_SAFE_LEN, C_BITS + 1);
  begin
    assert vector_i'length >= 1
      report "lm_math_float_pkg.f_count_delta: input vector must be "
             & "non-empty."
      severity failure;
    v_vector := vector_i;
    for i in 0 to v_vector'left loop
      if v_vector(v_vector'left - i) = '1' then
        v_delta := to_unsigned(i, v_delta'length);
        exit;
      end if;
    end loop;
    return v_delta;
  end function;

  function f_count_kernel(vector_i : unsigned) return unsigned is
    --   declarative-region sizes use f_max(..., 1) so f_ceil_log2 is
    --   never called with 0 (which would fire f_ceil_log2's own
    --   assert first and mask the more specific f_count_kernel
    --   diagnostic below).
    constant C_SAFE_LEN  : natural := f_max(vector_i'length, 1);
    constant C_BITS      : natural := f_ceil_log2(C_SAFE_LEN);
    variable v_vector : unsigned(f_max(vector_i'left, 0) downto 0);
    variable v_kernel : unsigned(C_BITS downto 0) := (others => '0');
    variable v_i      : unsigned(C_BITS downto 0);
  begin
    assert vector_i'length >= 1
      report "lm_math_float_pkg.f_count_kernel: input vector must be "
             & "non-empty."
      severity failure;
    v_vector := vector_i;
    if v_vector > 0 then
      for i in 0 to v_vector'left loop
        if v_vector(v_vector'left - i) = '1' then
          v_i := to_unsigned(i, v_i'length);
          exit;
        end if;
      end loop;
      for j in 0 to v_vector'left loop
        if v_vector(j) = '1' then
          v_kernel := to_unsigned(v_vector'length, v_i'length)
                      - v_i - to_unsigned(j, v_i'length);
          exit;
        end if;
      end loop;
    end if;
    return v_kernel;
  end function;

  function f_bump_left(in_vector : unsigned) return unsigned is
    --   sizing uses f_max(in_vector'left, 0) so the declaration is
    --   always valid; the assert below catches the real precondition.
    variable v_vector : unsigned(f_max(in_vector'left, 0) downto 0);
  begin
    assert in_vector'length >= 1
      report "lm_math_float_pkg.f_bump_left: input vector must be non-empty."
      severity failure;
    v_vector := in_vector;
    for i in 0 to v_vector'left loop
      if v_vector(v_vector'left - i) = '1' then
        v_vector := shift_left(v_vector, i);
        exit;
      end if;
    end loop;
    return v_vector;
  end function;

  function f_bump_right(in_vector : unsigned) return unsigned is
    --   sizing uses f_max(in_vector'left, 0) so the declaration is
    --   always valid; the assert below catches the real precondition.
    variable v_vector : unsigned(f_max(in_vector'left, 0) downto 0);
  begin
    assert in_vector'length >= 1
      report "lm_math_float_pkg.f_bump_right: input vector must be non-empty."
      severity failure;
    v_vector := in_vector;
    for i in 0 to v_vector'left loop
      if v_vector(i) = '1' then
        v_vector := (i - 1 downto 0 => '0') & v_vector(v_vector'left downto i);
        exit;
      end if;
    end loop;
    return v_vector;
  end function;

  function f_resize_right(vector_in : unsigned; length_out : natural) return unsigned is
    --   sizing uses f_max(length_out, 1) so the declaration is always
    --   valid; the assert below catches the real precondition.
    constant C_SAFE_LEN_OUT : natural := f_max(length_out, 1);
    variable v_vector_out : unsigned(C_SAFE_LEN_OUT - 1 downto 0);
  begin
    assert length_out >= 1
      report "lm_math_float_pkg.f_resize_right: length_out must be >= 1 "
             & "(the output vector range would be invalid otherwise)."
      severity failure;
    assert vector_in'length >= 1
      report "lm_math_float_pkg.f_resize_right: vector_in must be "
             & "non-empty."
      severity failure;
    if vector_in'length <= length_out then
      for i in 0 to vector_in'left loop
        v_vector_out(v_vector_out'left - i) := vector_in(vector_in'left - i);
      end loop;
      v_vector_out(v_vector_out'left - vector_in'length downto 0) := (others => '0');
    else
      v_vector_out(v_vector_out'left downto 0) :=
        vector_in(vector_in'left downto vector_in'left - v_vector_out'left);
    end if;
    return v_vector_out;
  end function;

end package body lm_math_float_pkg;
