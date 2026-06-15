--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_sqrt
-- Description: Self-checking testbench for lm_math_fpu_sqrt. Three phases:
--                1. positive normals (mid-range + exponent boundaries +
--                   identity 1.0 and small power-of-2 0.0625),
--                   compared against ieee.float_pkg.sqrt on a float
--                   operand using a one-sided 1 ULP floor tolerance: the
--                   DUT result must equal the rounded reference or the
--                   next lower representable value; a result one ULP
--                   above the reference is rejected. A reset is issued
--                   between every vector;
--                2. same vectors back-to-back without resetting (covers the
--                   FSM's idle-return path on enable_i = '0');
--                3. special bit-pattern cases: +/-0, +/-inf, signaling
--                   and quiet NaN with both signs (sign + mantissa
--                   payload preserved on passthrough), negative finite,
--                   smallest and largest positive denormals, negative
--                   denormal -- checked against expected outputs and
--                   the error_o flag.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_sqrt is
  generic(
    g_clk_period : time    := 10 ns;
    g_data_exp   : natural := 11;
    g_data_mant  : natural := 52
  );
end tb_lm_math_fpu_sqrt;

architecture tb of tb_lm_math_fpu_sqrt is

  constant C_W      : natural := g_data_exp + g_data_mant + 1;
  constant C_N_TEST : natural := 16;

  type t_real_array is array (0 to C_N_TEST - 1) of real;
  --* Mix of perfect squares, irrational sqrts, and exponent-boundary
  --  values so that the (car_in + bias) / 2 path is exercised at both
  --  extremes of the normal range, not just mid-range. With the default
  --  double-precision generics the boundary literals are ~ 2^(-996)
  --  through 2^(+997), well inside the normal range.
  --    * 1.0       : trivial identity, sqrt(1)=1 exact; sanity check
  --                  that the FSM does not perturb the mantissa.
  --    * 0.0625    : small power-of-2 (1/16 = 2^-4) -- fills the gap
  --                  between the existing 0.25 (2^-2) and the very
  --                  small 1e-100 / 1e-300 boundary values.
  constant C_X : t_real_array := (
    --   mid-range
    4.0, 2.0, 9.0, 16.0, 100.0, 0.25, 1.0e10, 3.14159,
    --   exponent-boundary
    1.0e-300, 1.0e-100, 1.0e+100, 1.0e+300,
    --   misc
    0.5, 1.5, 1.0, 0.0625
  );

  signal clk_i    : std_logic := '0';
  signal rst_n_i  : std_logic := '0';
  signal enable_i : std_logic := '0';
  signal number_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal dout_o   : std_logic_vector(C_W - 1 downto 0);
  signal done_o   : std_logic;
  signal error_o  : std_logic;

  signal s_n_errors : natural := 0;
  signal s_n_checks : natural := 0;
  signal sim_end    : boolean := false;

  --* One-sided 1 ULP comparison: the DUT truncates (computes integer
  --  floor(sqrt(X))) and the reference rounds to nearest, so for
  --  positive normals the DUT result is always equal to or one ULP
  --  below the reference. A result one ULP above the reference is a
  --  bug and must be flagged. For positive normals, the IEEE-754 bit
  --  pattern interpreted as unsigned is monotonic in magnitude, so a
  --  raw unsigned compare on the two SLV outputs is correct.
  function f_floor_within_1ulp(dut, ref : std_logic_vector) return boolean is
    variable vd : unsigned(dut'length - 1 downto 0);
    variable vr : unsigned(ref'length - 1 downto 0);
  begin
    vd := unsigned(dut);
    vr := unsigned(ref);
    if vd > vr then
      return false;  -- DUT must never exceed the rounded reference
    end if;
    return (vr - vd) <= 1;
  end function;

  --* bit-pattern helpers (synthesizable-style construction)
  function f_zero return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    return v;
  end function;

  function f_inf(sign : std_logic) return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0);
  begin
    v(C_W - 1)                                       := sign;
    v(C_W - 2 downto g_data_mant)                    := (others => '1');
    v(g_data_mant - 1 downto 0)                      := (others => '0');
    return v;
  end function;

  --* the canonical "quiet NaN" emitted by the DUT for negative non-NaN
  --  inputs: sign=0, exponent=all-ones, mantissa MSB=1, rest=0.
  function f_dut_nan return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    v(C_W - 2 downto g_data_mant) := (others => '1');
    v(g_data_mant - 1)            := '1';
    return v;
  end function;

  --* an arbitrary input NaN with a distinctive payload. The
  --  `quiet` argument controls the mantissa MSB:
  --    * quiet='0' -> signaling-NaN payload (mantissa MSB=0, LSB=1).
  --    * quiet='1' -> quiet-NaN payload (mantissa MSB=1, LSB=1).
  --  Both kinds must take the NaN passthrough path: the DUT preserves
  --  sign + full mantissa (so the qNaN/sNaN bit is preserved, not
  --  forced to one canonical form). The LSB=1 is always set so the
  --  passthrough check is sensitive to payload corruption, not just
  --  to the qNaN/sNaN bit.
  function f_input_nan(sign : std_logic; quiet : std_logic := '0')
    return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    v(C_W - 1)                    := sign;
    v(C_W - 2 downto g_data_mant) := (others => '1');
    v(g_data_mant - 1)            := quiet;
    v(0)                          := '1';
    return v;
  end function;

  --* expected NaN from the passthrough path: exact bit-for-bit copy of
  --  the input (sign and mantissa payload both preserved).
  function f_passthrough_nan_out(input_nan : std_logic_vector)
    return std_logic_vector is
  begin
    return input_nan;
  end function;

  --* the smallest positive denormal: sign=0, exp=0, mant=1
  function f_denormal return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    v(0) := '1';
    return v;
  end function;

  --* the largest positive denormal: sign=0, exp=0, mantissa all-ones
  --  (one ULP below the smallest normal). Exercises the denormal
  --  detection path with a mantissa value that is NOT just the LSB,
  --  to verify the DUT classifies the input as denormal regardless
  --  of how much mantissa is set.
  function f_large_denormal return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    v(g_data_mant - 1 downto 0) := (others => '1');
    return v;
  end function;

begin

  uut : entity lm_math_float_lib.lm_math_fpu_sqrt
    generic map(
      g_data_exp  => g_data_exp,
      g_data_mant => g_data_mant
    )
    port map(
      clk_i    => clk_i,
      rst_n_i  => rst_n_i,
      enable_i => enable_i,
      number_i => number_i,
      dout_o   => dout_o,
      done_o   => done_o,
      error_o  => error_o
    );

  proc_clk : process
  begin
    while not sim_end loop
      clk_i <= '0';
      wait for g_clk_period / 2;
      clk_i <= '1';
      wait for g_clk_period / 2;
    end loop;
    wait;
  end process;

  proc_drive : process
    variable v_minus_zero   : std_logic_vector(C_W - 1 downto 0);
    variable v_pos_nan      : std_logic_vector(C_W - 1 downto 0);
    variable v_neg_nan      : std_logic_vector(C_W - 1 downto 0);
    variable v_pos_qnan     : std_logic_vector(C_W - 1 downto 0);
    variable v_neg_qnan     : std_logic_vector(C_W - 1 downto 0);
    variable v_neg_denorm   : std_logic_vector(C_W - 1 downto 0);

    procedure p_pulse_reset is
    begin
      rst_n_i  <= '0';
      enable_i <= '0';
      wait for 3 * g_clk_period;
      rst_n_i  <= '1';
      wait for 2 * g_clk_period;
    end procedure;

    procedure p_apply(slv_in : in std_logic_vector; desc : in string) is
    begin
      wait until rising_edge(clk_i);
      number_i <= slv_in;
      enable_i <= '1';
      wait until done_o = '1' for 5000 * g_clk_period;
      assert done_o = '1'
        report "sqrt timeout on " & desc
        severity failure;
      wait until rising_edge(clk_i);
    end procedure;

    procedure p_release is
    begin
      enable_i <= '0';
      wait for 2 * g_clk_period;
    end procedure;

    --* compare against a float reference (used in phases 1 and 2). Also
    --  verifies error_o = '0', since the normal path must NOT raise the
    --  error flag.
    --  The reference is the float-domain sqrt of the SAME float value
    --  that is driven into the DUT (i.e. the rounded input). Computing
    --  sqrt() on the real literal first and then rounding would compare
    --  sqrt(rounded_input) (DUT) against sqrt(true_input) rounded
    --  (reference), which can disagree at the ULP near rounding
    --  boundaries when this TB is instantiated with non-default
    --  exponent/mantissa widths.
    procedure p_check_real(desc : in string; i : in integer) is
      variable v_in  : float(g_data_exp downto -g_data_mant);
      variable v_ref : float(g_data_exp downto -g_data_mant);
    begin
      v_in  := to_float(C_X(i), g_data_exp, g_data_mant);
      v_ref := sqrt(v_in);
      if (not f_floor_within_1ulp(dout_o, to_slv(v_ref))) or error_o /= '0' then
        s_n_errors <= s_n_errors + 1;
        report "sqrt mismatch on " & desc severity warning;
      end if;
      s_n_checks <= s_n_checks + 1;
    end procedure;

    --* compare against an explicit expected bit pattern + error flag
    procedure p_check_pattern(
      desc        : in string;
      expect_out  : in std_logic_vector;
      expect_err  : in std_logic
    ) is
    begin
      if dout_o /= expect_out or error_o /= expect_err then
        s_n_errors <= s_n_errors + 1;
        report "sqrt mismatch on " & desc severity warning;
      end if;
      s_n_checks <= s_n_checks + 1;
    end procedure;

  begin
    -- ====================================================================
    -- Phase 1: positive normals, reset before every vector
    -- ====================================================================
    for i in 0 to C_N_TEST - 1 loop
      p_pulse_reset;
      p_apply(to_slv(to_float(C_X(i), g_data_exp, g_data_mant)),
              "phase 1 vector " & integer'image(i));
      p_check_real("phase 1 vector " & integer'image(i), i);
      p_release;
    end loop;

    -- ====================================================================
    -- Phase 2: same vectors back-to-back, single reset at the start
    --          (covers the FSM s_done -> s_idle path on enable_i = '0')
    -- ====================================================================
    p_pulse_reset;
    for i in 0 to C_N_TEST - 1 loop
      p_apply(to_slv(to_float(C_X(i), g_data_exp, g_data_mant)),
              "phase 2 vector " & integer'image(i));
      p_check_real("phase 2 vector " & integer'image(i), i);
      p_release;
    end loop;

    -- ====================================================================
    -- Phase 3: special bit-pattern cases
    -- ====================================================================
    p_pulse_reset;

    -- 3a: +0 -> +0, no error
    p_apply(f_zero, "+0");
    p_check_pattern("+0", f_zero, '0');
    p_release;

    -- 3b: -0 -> +0, no error (sign cleared)
    v_minus_zero := (others => '0');
    v_minus_zero(C_W - 1) := '1';
    p_apply(v_minus_zero, "-0");
    p_check_pattern("-0", f_zero, '0');
    p_release;

    -- 3c: +inf -> +inf, no error
    p_apply(f_inf('0'), "+inf");
    p_check_pattern("+inf", f_inf('0'), '0');
    p_release;

    -- 3d: -inf -> NaN, error (sqrt of negative -> NaN per IEEE)
    p_apply(f_inf('1'), "-inf");
    p_check_pattern("-inf", f_dut_nan, '1');
    p_release;

    -- 3e: +sNaN -> NaN passthrough (sign + payload preserved), error
    v_pos_nan := f_input_nan('0', '0');
    p_apply(v_pos_nan, "+sNaN passthrough");
    p_check_pattern("+sNaN passthrough", f_passthrough_nan_out(v_pos_nan), '1');
    p_release;

    -- 3f: -sNaN -> NaN passthrough (sign + payload preserved), error.
    --     Must take the NaN passthrough path even though sign='1'.
    v_neg_nan := f_input_nan('1', '0');
    p_apply(v_neg_nan, "-sNaN passthrough");
    p_check_pattern("-sNaN passthrough", f_passthrough_nan_out(v_neg_nan), '1');
    p_release;

    -- 3g: +qNaN -> NaN passthrough. Mantissa MSB=1 (quiet) plus LSB=1
    --     payload. Verifies that the DUT detects the NaN class on the
    --     quiet-NaN mantissa convention too (not just the signaling
    --     pattern of 3e/3f).
    v_pos_qnan := f_input_nan('0', '1');
    p_apply(v_pos_qnan, "+qNaN passthrough");
    p_check_pattern("+qNaN passthrough", f_passthrough_nan_out(v_pos_qnan), '1');
    p_release;

    -- 3h: -qNaN -> NaN passthrough. Combines sign='1' with the quiet
    --     mantissa MSB convention; both must be preserved on output.
    v_neg_qnan := f_input_nan('1', '1');
    p_apply(v_neg_qnan, "-qNaN passthrough");
    p_check_pattern("-qNaN passthrough", f_passthrough_nan_out(v_neg_qnan), '1');
    p_release;

    -- 3i: negative finite (-4.0) -> canonical quiet NaN, error
    p_apply(to_slv(to_float(-4.0, g_data_exp, g_data_mant)), "-4.0");
    p_check_pattern("-4.0", f_dut_nan, '1');
    p_release;

    -- 3j: smallest positive denormal -> +0, error
    p_apply(f_denormal, "+denormal (smallest)");
    p_check_pattern("+denormal (smallest)", f_zero, '1');
    p_release;

    -- 3k: largest positive denormal (mantissa all-ones) -> +0, error.
    --     Verifies that the denormal-detection branch fires on any
    --     positive denormal, not just the mantissa-LSB-only case
    --     of 3j.
    p_apply(f_large_denormal, "+denormal (largest)");
    p_check_pattern("+denormal (largest)", f_zero, '1');
    p_release;

    -- 3l: negative denormal -> canonical NaN, error.
    --     Verifies that the negative-non-zero branch fires BEFORE the
    --     v_car = 0 (positive-denormal) branch.
    v_neg_denorm := f_denormal;
    v_neg_denorm(C_W - 1) := '1';
    p_apply(v_neg_denorm, "-denormal");
    p_check_pattern("-denormal", f_dut_nan, '1');
    p_release;

    -- ====================================================================
    -- Done
    -- ====================================================================
    wait for 5 * g_clk_period;
    assert s_n_errors = 0
      report "TEST FAILED: " & integer'image(s_n_errors) & " / "
             & integer'image(s_n_checks) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(s_n_checks) & " vectors OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
