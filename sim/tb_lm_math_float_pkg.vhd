--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_float_pkg
-- Description: Self-checking unit test for lm_math_float_pkg helper functions.
--              This complements the arithmetic testbenches, which exercise the
--              package indirectly through the RTL modules.
--
--              Coverage:
--                * rounding constants;
--                * sizing helpers: f_ceil_log2, f_div_ceil, f_max;
--                * bit helpers: f_all_ones, f_int_to_sl;
--                * shift/count helpers: f_divide_by_two, f_count_delta,
--                  f_count_kernel, f_bump_left, f_bump_right,
--                  f_resize_right.
--
--              Contract-violation assertions are not intentionally triggered
--              here because they are expected to stop simulation.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_float_pkg is
end tb_lm_math_float_pkg;

architecture tb of tb_lm_math_float_pkg is
  constant C_U_1111          : unsigned(3 downto 0)  := "1111";
  constant C_U_1011          : unsigned(3 downto 0)  := "1011";
  constant C_U_0             : unsigned(0 downto 0)  := "0";
  constant C_DELTA_SAMPLE    : unsigned(14 downto 0) := "000101100110100";
  constant C_U_0000          : unsigned(3 downto 0)  := "0000";
  constant C_U_1000          : unsigned(3 downto 0)  := "1000";
  constant C_KERNEL_SINGLE   : unsigned(6 downto 0)  := "0010000";
  constant C_BUMP_SAMPLE     : unsigned(12 downto 0) := "0000110100000";
  constant C_BUMP_LEFT_EXP   : unsigned(12 downto 0) := "1101000000000";
  constant C_BUMP_RIGHT_EXP  : unsigned(12 downto 0) := "0000000001101";
  constant C_U_1010          : unsigned(3 downto 0)  := "1010";
  constant C_RESIZE_IN       : unsigned(5 downto 0)  := "001101";
  constant C_RESIZE_GROW     : unsigned(9 downto 0)  := "0011010000";
  constant C_RESIZE_SHRINK   : unsigned(3 downto 0)  := "0011";
  constant C_U_1             : unsigned(0 downto 0)  := "1";
  constant C_RESIZE_1_TO_3   : unsigned(2 downto 0)  := "100";
begin

  proc_check : process
    variable v_n_checks : natural := 0;
    variable v_n_errors : natural := 0;

    procedure check_int(desc : string; actual : integer; expected : integer) is
    begin
      v_n_checks := v_n_checks + 1;
      if actual /= expected then
        v_n_errors := v_n_errors + 1;
        report desc & ": expected " & integer'image(expected)
               & ", got " & integer'image(actual)
          severity warning;
      end if;
    end procedure;

    procedure check_sl(desc : string; actual : std_logic; expected : std_logic) is
    begin
      v_n_checks := v_n_checks + 1;
      if actual /= expected then
        v_n_errors := v_n_errors + 1;
        report desc & ": expected " & std_logic'image(expected)
               & ", got " & std_logic'image(actual)
          severity warning;
      end if;
    end procedure;

    procedure check_unsigned(desc : string; actual : unsigned; expected : unsigned) is
    begin
      v_n_checks := v_n_checks + 1;
      if actual'length /= expected'length or actual /= expected then
        v_n_errors := v_n_errors + 1;
        report desc & ": expected 0x" & to_hstring(std_logic_vector(expected))
               & " (" & integer'image(expected'length) & " bits), got 0x"
               & to_hstring(std_logic_vector(actual)) & " ("
               & integer'image(actual'length) & " bits)"
          severity warning;
      end if;
    end procedure;
  begin
    check_int("C_LM_ROUND_NEAREST", C_LM_ROUND_NEAREST, 1);
    check_int("C_LM_ROUND_INF", C_LM_ROUND_INF, 2);
    check_int("C_LM_ROUND_NEGINF", C_LM_ROUND_NEGINF, 3);
    check_int("C_LM_ROUND_ZERO", C_LM_ROUND_ZERO, 4);

    check_int("f_ceil_log2(1)", f_ceil_log2(1), 1);
    check_int("f_ceil_log2(2)", f_ceil_log2(2), 1);
    check_int("f_ceil_log2(3)", f_ceil_log2(3), 2);
    check_int("f_ceil_log2(4)", f_ceil_log2(4), 2);
    check_int("f_ceil_log2(5)", f_ceil_log2(5), 3);
    check_int("f_ceil_log2(16)", f_ceil_log2(16), 4);
    check_int("f_ceil_log2(17)", f_ceil_log2(17), 5);

    check_int("f_div_ceil(0,4)", f_div_ceil(0, 4), 0);
    check_int("f_div_ceil(1,4)", f_div_ceil(1, 4), 1);
    check_int("f_div_ceil(4,4)", f_div_ceil(4, 4), 1);
    check_int("f_div_ceil(5,4)", f_div_ceil(5, 4), 2);
    check_int("f_div_ceil(17,8)", f_div_ceil(17, 8), 3);

    check_int("f_max(-1,2)", f_max(-1, 2), 2);
    check_int("f_max(5,5)", f_max(5, 5), 5);
    check_int("f_max(9,3)", f_max(9, 3), 9);

    check_sl("f_all_ones(1111)", f_all_ones(C_U_1111), '1');
    check_sl("f_all_ones(1011)", f_all_ones(C_U_1011), '0');
    check_sl("f_all_ones(0)", f_all_ones(C_U_0), '0');

    check_sl("f_int_to_sl(0)", f_int_to_sl(0), '0');
    check_sl("f_int_to_sl(7)", f_int_to_sl(7), '1');
    check_sl("f_int_to_sl(-1)", f_int_to_sl(-1), '1');

    check_int("f_divide_by_two(10,4)", f_divide_by_two(10, 4), 5);
    check_int("f_divide_by_two(-9,4)", f_divide_by_two(-9, 4), -4);
    check_int("f_divide_by_two(1,1)", f_divide_by_two(1, 1), 0);
    check_int("f_divide_by_two(0,5)", f_divide_by_two(0, 5), 0);

    check_int("f_count_delta(sample)",
              to_integer(f_count_delta(C_DELTA_SAMPLE)), 3);
    check_int("f_count_delta(all zero)",
              to_integer(f_count_delta(C_U_0000)), 4);
    check_int("f_count_delta(msb one)",
              to_integer(f_count_delta(C_U_1000)), 0);

    check_int("f_count_kernel(sample)",
              to_integer(f_count_kernel(C_DELTA_SAMPLE)), 10);
    check_int("f_count_kernel(all zero)",
              to_integer(f_count_kernel(C_U_0000)), 0);
    check_int("f_count_kernel(single one)",
              to_integer(f_count_kernel(C_KERNEL_SINGLE)), 1);

    check_unsigned("f_bump_left(sample)",
                   f_bump_left(C_BUMP_SAMPLE),
                   C_BUMP_LEFT_EXP);
    check_unsigned("f_bump_left(all zero)",
                   f_bump_left(C_U_0000),
                   C_U_0000);
    check_unsigned("f_bump_left(already left)",
                   f_bump_left(C_U_1010),
                   C_U_1010);

    check_unsigned("f_bump_right(sample)",
                   f_bump_right(C_BUMP_SAMPLE),
                   C_BUMP_RIGHT_EXP);
    check_unsigned("f_bump_right(all zero)",
                   f_bump_right(C_U_0000),
                   C_U_0000);
    check_unsigned("f_bump_right(already right)",
                   f_bump_right(C_U_1011),
                   C_U_1011);

    check_unsigned("f_resize_right(grow)",
                   f_resize_right(C_RESIZE_IN, 10),
                   C_RESIZE_GROW);
    check_unsigned("f_resize_right(shrink)",
                   f_resize_right(C_RESIZE_IN, 4),
                   C_RESIZE_SHRINK);
    check_unsigned("f_resize_right(equal)",
                   f_resize_right(C_U_1010, 4),
                   C_U_1010);
    check_unsigned("f_resize_right(one bit grow)",
                   f_resize_right(C_U_1, 3),
                   C_RESIZE_1_TO_3);

    assert v_n_errors = 0
      report "TEST FAILED: " & integer'image(v_n_errors) & " / "
             & integer'image(v_n_checks) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(v_n_checks) & " checks OK"
      severity note;
    wait;
  end process proc_check;

end tb;
