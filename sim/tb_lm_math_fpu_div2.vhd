--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_div2
-- Description: Self-checking testbench for lm_math_fpu_div2 (divide by 2).
--              The reference is built with ieee.float_pkg by dividing the
--              input by 2.0. ±1 ULP tolerance on the mantissa.
--
--              Coverage:
--                * mid-range normals (perfect halves, irrationals, signed);
--                * exponent boundaries: smallest normal (exactly 2^-126,
--                  which exercises the proc_mant_result car=1 branch
--                  where the output crosses into the denormal range);
--                  largest finite (~2^+126 .. 2^+127 in single
--                  precision); plus a one-bit-above-min vec at
--                  2.35e-38 (~2^-125, car=2);
--                * zero input (real-derived +0.0; the DUT preserves
--                  the sign bit through proc_mant_result so the path
--                  is symmetric);
--                * raw -0.0 bit pattern: VHDL `real` does not
--                  preserve a distinct -0, so to_float(-0.0)
--                  collapses to +0. -0.0 is driven explicitly via
--                  an slv constant (f_neg_zero) and the DUT output
--                  must match the same -0 bit pattern exactly;
--                * 3 denormal-magnitude inputs (2.0e-40, 5.0e-40,
--                  -2.0e-40). The first two pin the 2.0.1 fix; the
--                  third locks down sign propagation through the
--                  proc_mant_result car=0 branch.
--
--              NOT covered by design:
--                * NaN / +-inf inputs. The module has no special-case
--                  path for those, so feeding them yields incorrect
--                  IEEE-754 semantics.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_div2 is
  generic(
    g_clk_period : time    := 10 ns;
    g_data_exp   : natural := 8;
    g_data_mant  : natural := 23;
    g_chunk_size : natural := 25
  );
end tb_lm_math_fpu_div2;

architecture tb of tb_lm_math_fpu_div2 is

  constant C_W           : natural := g_data_exp + g_data_mant + 1;
  --* Number of real-derived stimulus vectors (driven through C_X and
  --  to_float in proc_stim).
  constant C_N_REAL_VECS : natural := 19;
  --* Number of raw bit-pattern stimuli driven after the real-derived
  --  phase. Currently a single -0.0 vector; bump this if more raw
  --  patterns are added.
  constant C_N_RAW_VECS  : natural := 1;
  --* Total checks the proc_check process emits (one per stimulus,
  --  real-derived + raw). Used in the TEST PASSED report so the
  --  number printed always matches what was actually compared.
  constant C_N_CHECKS    : natural := C_N_REAL_VECS + C_N_RAW_VECS;

  type t_real_array is array (0 to C_N_REAL_VECS - 1) of real;
  -- Coverage: normal-range values, zero, exponent-boundary normals
  -- (including the exact smallest-normal that exercises the car=1
  -- "normal becoming denormal" branch of proc_mant_result -- the
  -- smallest single-precision normal input is halved into the
  -- denormal range, so the implicit '1' becomes the explicit MSB
  -- of the output mantissa), and three denormal-magnitude vectors
  -- -- two positive that pin the 2.0.1 fix and one negative that
  -- locks down sign propagation on the same car=0 branch. NaN and
  -- +-inf are intentionally NOT tested because the module has no
  -- special-case path for them (see the file header).
  --
  -- Vec 8 was previously a duplicate of vec 3 (both 1.5e-30); it now
  -- carries the smallest single-precision normal (2^-126 ~= 1.175e-38).
  -- That input exponent-decrements into the denormal range, which
  -- exercises the proc_mant_result car=1 branch (a path that the
  -- previous set never hit -- 2.35e-38 sits at car=2, one bit above).
  constant C_X : t_real_array := (
    --   existing mid-range values (vec 0..11)
    1.0, -2.0, 0.5, 1.5e-30, 1.0e20,
    -7.125, 3.14159, 0.0, 2.0**(-126), 1.0e38,
    100.0, -0.0625,
    --   exponent-boundary normals (vec 12..15):
    --     2.35e-38 ~ 2^-125 (car=2), 8.5e+37 ~ 2^+126 (near max finite),
    --     2.0 and 4.0 (exact halving boundaries on small integers).
    2.35e-38, 8.5e37, 2.0, 4.0,
    --   denormal-magnitude regression cases (below min normal 1.18e-38)
    --   vec 16/17: positive denormals, pin the 2.0.1 fix.
    --   vec 18:    negative denormal -- sign='1' on the car=0 path.
    2.0e-40, 5.0e-40, -2.0e-40
  );

  signal clk_i      : std_logic := '0';
  signal dv_i       : std_logic := '0';
  signal dividend_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal quotient_o : std_logic_vector(C_W - 1 downto 0);
  signal dv_o       : std_logic;

  signal s_n_errors : natural := 0;
  signal s_n_checks : natural := 0;
  signal sim_end    : boolean := false;

  function f_within_1ulp(a, b : std_logic_vector) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= 1;
  end function;

  --* Negative zero IEEE-754 bit pattern (sign=1, exp=0, mant=0).
  --  Driven explicitly because VHDL `real` does not preserve a
  --  distinct -0; `to_float(-0.0)` collapses to +0. The DUT must
  --  preserve the sign on zero -- the path is sign-bit passthrough
  --  on the input slv directly, so -0/2 = -0.
  function f_neg_zero return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    v(C_W - 1) := '1';
    return v;
  end function;

begin

  uut : entity lm_math_float_lib.lm_math_fpu_div2
    generic map(
      g_data_exp   => g_data_exp,
      g_data_mant  => g_data_mant,
      g_chunk_size => g_chunk_size
    )
    port map(
      clk_i      => clk_i,
      dv_i       => dv_i,
      dividend_i => dividend_i,
      quotient_o => quotient_o,
      dv_o       => dv_o
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

  proc_stim : process
  begin
    wait for 5 * g_clk_period;
    wait until rising_edge(clk_i);
    dv_i <= '1';
    --   real-derived phase
    for i in 0 to C_N_REAL_VECS - 1 loop
      dividend_i <= to_slv(to_float(C_X(i), g_data_exp, g_data_mant));
      wait until rising_edge(clk_i);
    end loop;
    --   raw bit-pattern phase: -0.0 (real cannot carry sign='1' on zero)
    dividend_i <= f_neg_zero;
    wait until rising_edge(clk_i);
    dv_i <= '0';
    wait;
  end process;

  proc_check : process
    variable v_x, v_ref : float(g_data_exp downto -g_data_mant);
    variable v_ref_slv  : std_logic_vector(C_W - 1 downto 0);
  begin
    wait until dv_o = '1';
    --   real-derived phase
    for i in 0 to C_N_REAL_VECS - 1 loop
      v_x       := to_float(C_X(i), g_data_exp, g_data_mant);
      v_ref     := v_x / to_float(2.0, g_data_exp, g_data_mant);
      v_ref_slv := to_slv(v_ref);
      wait for 1 ps;
      if not f_within_1ulp(quotient_o, v_ref_slv) then
        s_n_errors <= s_n_errors + 1;
        report "div2 mismatch on vector " & integer'image(i) severity warning;
      end if;
      s_n_checks <= s_n_checks + 1;
      wait until rising_edge(clk_i);
    end loop;
    --   raw -0.0 check: -0 / 2 = -0 exactly. Exact bit-pattern
    --   compare against the same f_neg_zero we drove.
    wait for 1 ps;
    if quotient_o /= f_neg_zero then
      s_n_errors <= s_n_errors + 1;
      report "div2 mismatch on -0.0: expected " & to_hstring(f_neg_zero)
           & " got " & to_hstring(quotient_o)
        severity warning;
    end if;
    s_n_checks <= s_n_checks + 1;
    wait for 5 * g_clk_period;
    --   Sanity: the runtime counter must equal the static total
    --   (C_N_REAL_VECS + C_N_RAW_VECS). If a future edit adds a
    --   stimulus but forgets the matching s_n_checks increment, or
    --   vice versa, this assert catches it immediately.
    assert s_n_checks = C_N_CHECKS
      report "TB error: s_n_checks (" & integer'image(s_n_checks)
             & ") /= C_N_CHECKS (" & integer'image(C_N_CHECKS) & ")"
      severity failure;
    assert s_n_errors = 0
      report "TEST FAILED: " & integer'image(s_n_errors) & " / "
             & integer'image(C_N_CHECKS) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(C_N_CHECKS) & " vectors OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
