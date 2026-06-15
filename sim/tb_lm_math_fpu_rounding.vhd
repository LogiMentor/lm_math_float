--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_rounding
-- Description: Self-checking testbench for lm_math_fpu_rounding. Four DUT
--              instances are exercised in parallel, one per rounding mode:
--                * uut_zero    (C_LM_ROUND_ZERO,    truncate)
--                * uut_nearest (C_LM_ROUND_NEAREST, round half up)
--                * uut_inf     (C_LM_ROUND_INF,     toward +inf)
--                * uut_neginf  (C_LM_ROUND_NEGINF,  toward -inf)
--              All four receive the same (sign, car, mantissa+2-guard-bit)
--              input on every cycle. For each test pattern the TB checks
--              every DUT's dout_o against the per-mode expected output
--              (hard-coded, computed by hand).
--
--              Coverage:
--                * guard bits 00 / 01 / 10 / 11 with car > 0 and both
--                  signs. Negative + guard=11 (vec 10) and negative +
--                  guard=00 (vec 11) complete the (sign, guard) matrix
--                  on the normal path;
--                * vec 6 / vec 7: mantissa = all-ones with guard = 11.
--                  Rounding-up overflows the mantissa and bumps the
--                  exponent via the proc_go_out path in the DUT;
--                * car = 0 with mantissa = all-ones, guard = 11
--                  (vec 8 / vec 9) AND guard = 10 (vec 12 / vec 13).
--                  Vec 12 / 13 verify that the "denormal becoming
--                  normal" leg in proc_go_out fires whenever the
--                  selected mode rounds up, regardless of whether the
--                  guard value is 10 or 11.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_rounding is
  generic(
    g_clk_period : time    := 10 ns;
    g_din_exp    : natural := 8;
    g_din_mant   : natural := 23
  );
end tb_lm_math_fpu_rounding;

architecture tb of tb_lm_math_fpu_rounding is

  constant C_W      : natural := g_din_exp + g_din_mant + 1;
  constant C_LATENCY : natural := 1;  -- one registered stage from input to dout_o

  signal clk_i      : std_logic := '0';
  signal sign_i     : std_logic := '0';
  signal car_i      : std_logic_vector(g_din_exp - 1 downto 0)        := (others => '0');
  signal mantissa_i : std_logic_vector((2 + g_din_mant) - 1 downto 0) := (others => '0');

  signal out_zero    : std_logic_vector(C_W - 1 downto 0);
  signal out_nearest : std_logic_vector(C_W - 1 downto 0);
  signal out_inf     : std_logic_vector(C_W - 1 downto 0);
  signal out_neginf  : std_logic_vector(C_W - 1 downto 0);

  signal s_n_errors : natural := 0;
  signal s_n_checks : natural := 0;
  signal sim_end    : boolean := false;

  --* Helper: build a (1 + g_din_exp + g_din_mant)-bit float pattern
  function f_make(sign : std_logic; car : natural; mant_int : natural)
    return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0);
  begin
    v(C_W - 1)                      := sign;
    v(C_W - 2 downto g_din_mant)    := std_logic_vector(to_unsigned(car, g_din_exp));
    v(g_din_mant - 1 downto 0)      := std_logic_vector(to_unsigned(mant_int, g_din_mant));
    return v;
  end function;

  --* Helper: build a (2 + g_din_mant)-bit mantissa with 2 guard bits.
  --  mant_top is the upper g_din_mant bits, guard is the 2 LSBs.
  function f_make_mant(mant_top : natural; guard : natural)
    return std_logic_vector is
    variable v : std_logic_vector((2 + g_din_mant) - 1 downto 0);
  begin
    v((2 + g_din_mant) - 1 downto 2) :=
      std_logic_vector(to_unsigned(mant_top, g_din_mant));
    v(1 downto 0) := std_logic_vector(to_unsigned(guard, 2));
    return v;
  end function;

  --* Single-bit-equal compare (no tolerance: rounding outputs are
  --  exact bit patterns). Counters are passed as variables so multiple
  --  back-to-back calls in the same delta cycle all accumulate.
  procedure check(dut_name : in string;
                  vec_id   : in integer;
                  actual   : in std_logic_vector;
                  expected : in std_logic_vector;
                  variable nE : inout natural;
                  variable nC : inout natural) is
  begin
    if actual /= expected then
      nE := nE + 1;
      report "rounding(" & dut_name & ") mismatch vec "
             & integer'image(vec_id)
             & " actual="   & to_hstring(actual)
             & " expected=" & to_hstring(expected)
        severity warning;
    end if;
    nC := nC + 1;
  end procedure;

begin

  uut_zero : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_din_exp,
      g_din_mant   => g_din_mant,
      g_round_mode => C_LM_ROUND_ZERO
    )
    port map(
      clk_i      => clk_i,
      sign_i     => sign_i,
      car_i      => car_i,
      mantissa_i => mantissa_i,
      dout_o     => out_zero
    );

  uut_nearest : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_din_exp,
      g_din_mant   => g_din_mant,
      g_round_mode => C_LM_ROUND_NEAREST
    )
    port map(
      clk_i      => clk_i,
      sign_i     => sign_i,
      car_i      => car_i,
      mantissa_i => mantissa_i,
      dout_o     => out_nearest
    );

  uut_inf : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_din_exp,
      g_din_mant   => g_din_mant,
      g_round_mode => C_LM_ROUND_INF
    )
    port map(
      clk_i      => clk_i,
      sign_i     => sign_i,
      car_i      => car_i,
      mantissa_i => mantissa_i,
      dout_o     => out_inf
    );

  uut_neginf : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_din_exp,
      g_din_mant   => g_din_mant,
      g_round_mode => C_LM_ROUND_NEGINF
    )
    port map(
      clk_i      => clk_i,
      sign_i     => sign_i,
      car_i      => car_i,
      mantissa_i => mantissa_i,
      dout_o     => out_neginf
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
    constant C_MANT_ALL_ONES : natural := 2**g_din_mant - 1;

    procedure pulse(sign : in std_logic; car_int : in natural;
                    mant_top : in natural; guard : in natural) is
    begin
      sign_i     <= sign;
      car_i      <= std_logic_vector(to_unsigned(car_int, g_din_exp));
      mantissa_i <= f_make_mant(mant_top, guard);
      wait until rising_edge(clk_i);
    end procedure;

    procedure pulse_zero is
    begin
      sign_i     <= '0';
      car_i      <= (others => '0');
      mantissa_i <= (others => '0');
      wait until rising_edge(clk_i);
    end procedure;

  begin
    --   give the FSM a couple of cycles before driving real data
    pulse_zero;
    pulse_zero;

    -- ===========================================================
    -- vec 0: positive, mant top = 0, guard = "00"  (clean number)
    --   All modes should output the same: 1.0 (sign=0, car=127, mant=0)
    -- ===========================================================
    pulse('0', 127, 0, 0);

    -- vec 1: positive, mant top = 0, guard = "01"
    --   ZERO    : truncate   -> 1.0 (mant=0)
    --   NEAREST : guard MSB=0, truncate -> 1.0
    --   INF     : guard>0 + sign=0 -> round up, mant=1
    --   NEGINF  : guard>0 + sign=1? no, sign=0 -> no round, mant=0
    pulse('0', 127, 0, 1);

    -- vec 2: positive, mant top = 0, guard = "10"
    --   ZERO    : truncate -> mant=0
    --   NEAREST : guard MSB=1 -> round up, mant=1
    --   INF     : guard>0+sign=0 -> mant=1
    --   NEGINF  : no round -> mant=0
    pulse('0', 127, 0, 2);

    -- vec 3: positive, mant top = 0, guard = "11"
    --   ZERO    : truncate -> mant=0
    --   NEAREST : round up -> mant=1
    --   INF     : round up -> mant=1
    --   NEGINF  : no round -> mant=0
    pulse('0', 127, 0, 3);

    -- vec 4: NEGATIVE, mant top = 0, guard = "10"
    --   ZERO    : -> mant=0
    --   NEAREST : -> round up, mant=1
    --   INF     : sign=1, no round -> mant=0
    --   NEGINF  : sign=1, guard>0 -> round up, mant=1
    pulse('1', 127, 0, 2);

    -- vec 5: NEGATIVE, mant top = 0, guard = "01"
    --   ZERO    : -> mant=0
    --   NEAREST : guard MSB=0, no round -> mant=0
    --   INF     : sign=1, no round -> mant=0
    --   NEGINF  : sign=1, guard>0 -> round up, mant=1
    pulse('1', 127, 0, 1);

    -- vec 6: positive, mant top = all-ones, guard = "11" (overflow)
    --   ZERO    : truncate -> mant=all_ones, car=127
    --   NEAREST : round up -> mant=0, car=128 (proc_go_out bumps exp)
    --   INF     : round up -> mant=0, car=128
    --   NEGINF  : no round (sign=0) -> mant=all_ones, car=127
    pulse('0', 127, C_MANT_ALL_ONES, 3);

    -- vec 7: NEGATIVE, mant top = all-ones, guard = "11" (overflow)
    --   ZERO    : -> mant=all_ones, car=127, sign=1
    --   NEAREST : round up -> mant=0, car=128, sign=1
    --   INF     : sign=1 -> no round -> all_ones,127
    --   NEGINF  : sign=1, guard>0 -> round up -> mant=0,car=128
    pulse('1', 127, C_MANT_ALL_ONES, 3);

    -- vec 8: positive, car=0, mant top = all-ones, guard = "11"
    --   exercises the "denormal becoming normal" branch in proc_go_out:
    --   rounding pushes s_number across the implicit-MSB boundary while
    --   s_car_i_d = 0.
    --   ZERO    : truncate -> sign=0, car=0,   mant=all_ones
    --   NEAREST : round up -> sign=0, car=1,   mant=0x400000 (top bit set)
    --   INF     : sign=0+guard>0 round up -> same as NEAREST
    --   NEGINF  : sign=0, no round -> same as ZERO
    pulse('0', 0, C_MANT_ALL_ONES, 3);

    -- vec 9: NEGATIVE, car=0, mant top = all-ones, guard = "11"
    --   ZERO    : sign=1, car=0,   mant=all_ones
    --   NEAREST : sign=1, car=1,   mant=0x400000
    --   INF     : sign=1, no round -> same as ZERO
    --   NEGINF  : sign=1, guard>0 round up -> same as NEAREST
    pulse('1', 0, C_MANT_ALL_ONES, 3);

    -- vec 10: NEGATIVE, mant top = 0, guard = "11" (no overflow).
    --   Complement to vec 3 (positive, guard=11) and vec 4 (negative,
    --   guard=10). Locks down the NEGINF round-up decision on
    --   guard=11 specifically -- vec 4 only covers NEGINF on guard=10.
    --   ZERO    : sign=1, car=127, mant=0
    --   NEAREST : guard MSB=1 -> round up, mant=1
    --   INF     : sign=1, no round -> mant=0
    --   NEGINF  : sign=1, guard>0 -> round up, mant=1
    pulse('1', 127, 0, 3);

    -- vec 11: NEGATIVE, mant top = 0, guard = "00" (no round on any mode).
    --   Complement to vec 0 (positive, guard=00). Verifies that the
    --   sign='1' path produces a pure-truncate output on every mode
    --   when there is no rounding pressure.
    --   All modes -> sign=1, car=127, mant=0
    pulse('1', 127, 0, 0);

    -- vec 12: positive, car=0, mant top = all-ones, guard = "10".
    --   Complement to vec 8 (same but guard=11). Verifies that the
    --   "denormal becoming normal" branch in proc_go_out fires for
    --   NEAREST and INF on guard=10 too, not only on guard=11.
    --   ZERO    : truncate -> sign=0, car=0,   mant=all_ones
    --   NEAREST : guard MSB=1 -> round up -> denormal->normal:
    --             sign=0, car=1, mant=0x400000
    --   INF     : sign=0+guard>0 -> round up -> same as NEAREST
    --   NEGINF  : sign=0, no round -> same as ZERO
    pulse('0', 0, C_MANT_ALL_ONES, 2);

    -- vec 13: NEGATIVE, car=0, mant top = all-ones, guard = "10".
    --   Complement to vec 9 (same but guard=11). Verifies that the
    --   NEGINF denormal->normal branch fires on guard=10 too.
    --   ZERO    : truncate -> sign=1, car=0,   mant=all_ones
    --   NEAREST : guard MSB=1 -> round up -> denormal->normal:
    --             sign=1, car=1, mant=0x400000
    --   INF     : sign=1, no round -> same as ZERO
    --   NEGINF  : sign=1, guard>0 -> round up -> same as NEAREST
    pulse('1', 0, C_MANT_ALL_ONES, 2);

    --   wait the pipeline latency so the LAST output is observed by the
    --   check process before we end simulation
    pulse_zero;
    pulse_zero;
    pulse_zero;

    wait;
  end process;

  proc_check : process
    type t_expected_array is array (0 to 13) of std_logic_vector(C_W - 1 downto 0);
    constant C_MANT_AO  : natural := 2**g_din_mant - 1;        -- all-ones (23 bits)
    constant C_MANT_MSB : natural := 2 ** (g_din_mant - 1);    -- only bit 22 set (0x400000)
    --                                          sign car  mant
    constant C_EXP_ZERO : t_expected_array := (
      f_make('0', 127, 0),         -- vec 0
      f_make('0', 127, 0),         -- vec 1
      f_make('0', 127, 0),         -- vec 2
      f_make('0', 127, 0),         -- vec 3
      f_make('1', 127, 0),         -- vec 4 (negative)
      f_make('1', 127, 0),         -- vec 5 (negative)
      f_make('0', 127, C_MANT_AO), -- vec 6 (overflow, no round)
      f_make('1', 127, C_MANT_AO), -- vec 7 (overflow, no round)
      f_make('0',   0, C_MANT_AO), -- vec 8 (car=0, no round)
      f_make('1',   0, C_MANT_AO), -- vec 9 (car=0, no round)
      f_make('1', 127, 0),         -- vec 10 (NEG, guard=11, no round)
      f_make('1', 127, 0),         -- vec 11 (NEG, guard=00, no round)
      f_make('0',   0, C_MANT_AO), -- vec 12 (car=0, guard=10, no round)
      f_make('1',   0, C_MANT_AO)  -- vec 13 (car=0, NEG, guard=10, no round)
    );
    constant C_EXP_NEAR : t_expected_array := (
      f_make('0', 127, 0),
      f_make('0', 127, 0),         -- guard MSB=0, no round
      f_make('0', 127, 1),         -- guard MSB=1, round up
      f_make('0', 127, 1),
      f_make('1', 127, 1),         -- sign=1, guard MSB=1, round up
      f_make('1', 127, 0),         -- sign=1, guard MSB=0, no round
      f_make('0', 128, 0),         -- overflow -> exp bump
      f_make('1', 128, 0),
      f_make('0',   1, C_MANT_MSB), -- vec 8: denormal->normal (car 0 -> 1)
      f_make('1',   1, C_MANT_MSB), -- vec 9: denormal->normal (car 0 -> 1)
      f_make('1', 127, 1),         -- vec 10: NEG, guard MSB=1, round up
      f_make('1', 127, 0),         -- vec 11: NEG, guard MSB=0, no round
      f_make('0',   1, C_MANT_MSB),-- vec 12: car=0, guard MSB=1, denormal->normal
      f_make('1',   1, C_MANT_MSB) -- vec 13: car=0, NEG, guard MSB=1, denormal->normal
    );
    constant C_EXP_INF : t_expected_array := (
      f_make('0', 127, 0),
      f_make('0', 127, 1),         -- sign=0, guard>0 -> round up
      f_make('0', 127, 1),
      f_make('0', 127, 1),
      f_make('1', 127, 0),         -- sign=1, no round
      f_make('1', 127, 0),
      f_make('0', 128, 0),         -- sign=0, guard>0, overflow -> bump
      f_make('1', 127, C_MANT_AO), -- sign=1, no round (despite guard)
      f_make('0',   1, C_MANT_MSB), -- vec 8: sign=0+guard>0 -> denormal->normal
      f_make('1',   0, C_MANT_AO),  -- vec 9: sign=1, no round
      f_make('1', 127, 0),         -- vec 10: sign=1, no round (despite guard)
      f_make('1', 127, 0),         -- vec 11: sign=1, no round
      f_make('0',   1, C_MANT_MSB),-- vec 12: sign=0+guard>0 -> denormal->normal
      f_make('1',   0, C_MANT_AO)  -- vec 13: sign=1, no round
    );
    constant C_EXP_NINF : t_expected_array := (
      f_make('0', 127, 0),
      f_make('0', 127, 0),         -- sign=0, no round
      f_make('0', 127, 0),
      f_make('0', 127, 0),
      f_make('1', 127, 1),         -- sign=1, guard>0 -> round up
      f_make('1', 127, 1),
      f_make('0', 127, C_MANT_AO), -- sign=0, no round
      f_make('1', 128, 0),         -- sign=1, guard>0, overflow -> bump
      f_make('0',   0, C_MANT_AO), -- vec 8: sign=0, no round
      f_make('1',   1, C_MANT_MSB),-- vec 9: sign=1+guard>0 -> denormal->normal
      f_make('1', 127, 1),         -- vec 10: sign=1+guard>0 -> round up
      f_make('1', 127, 0),         -- vec 11: sign=1, guard=00, no round
      f_make('0',   0, C_MANT_AO), -- vec 12: sign=0, no round
      f_make('1',   1, C_MANT_MSB) -- vec 13: sign=1+guard>0 -> denormal->normal
    );
    variable v_n_errors : natural := 0;
    variable v_n_checks : natural := 0;
  begin
    --   skip the two warm-up pulse_zero cycles + C_LATENCY pipeline
    wait until rising_edge(clk_i);  -- after first warm-up
    wait until rising_edge(clk_i);  -- after second warm-up
    wait until rising_edge(clk_i);  -- vec 0 input is sampled here
    --   from now on every clock cycle's output corresponds to the
    --   vector that was driven C_LATENCY cycles earlier
    for k in 1 to C_LATENCY loop
      wait until rising_edge(clk_i);
    end loop;

    for i in 0 to 13 loop
      wait for 1 ps;
      check("zero",    i, out_zero,    C_EXP_ZERO(i),  v_n_errors, v_n_checks);
      check("nearest", i, out_nearest, C_EXP_NEAR(i),  v_n_errors, v_n_checks);
      check("inf",     i, out_inf,     C_EXP_INF(i),   v_n_errors, v_n_checks);
      check("neginf",  i, out_neginf,  C_EXP_NINF(i),  v_n_errors, v_n_checks);
      wait until rising_edge(clk_i);
    end loop;

    s_n_errors <= v_n_errors;
    s_n_checks <= v_n_checks;
    wait for 5 * g_clk_period;
    assert v_n_errors = 0
      report "TEST FAILED: " & integer'image(v_n_errors) & " / "
             & integer'image(v_n_checks) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(v_n_checks) & " checks OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
