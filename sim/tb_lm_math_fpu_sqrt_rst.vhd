--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_sqrt_rst
-- Description: Validates the rst_n_i behavior of lm_math_fpu_sqrt under
--              mid-stream reset.
--
--              The sqrt FSM (proc_fsm) clears on rst:
--                * s_state -> s_idle
--                * s_cnt   -> 0
--                * s_q, s_r, s_x, s_dout_reg -> 0
--                * s_error -> '0'
--
--              Strategy:
--                Phase A (sanity)
--                  sqrt(4.0). Enable, wait for done_o, check dout = 2.0
--                  within one ULP.
--                Phase B (rst test)
--                  Start sqrt(16.0). After ~5 cycles (so the FSM is in
--                  s_busy with partial state in s_q / s_r / s_x), pulse
--                  rst_n_i = '0' for 5 cycles. After rst, drop enable_i
--                  for one cycle to ensure the FSM is in idle, then start
--                  a clean sqrt(9.0). Wait for done_o, check dout = 3.0.
--                  Without the FSM rst handling, s_state would still be
--                  s_busy with the old s_cnt / s_q / s_r, and the FSM
--                  would either hang or produce a corrupted result.
--
--              Latency: from enable_i = '1' to done_o = '1' is
--              approximately K + 1 = g_data_mant + 2 clock cycles for
--              normal numbers (special cases complete in one cycle).
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_sqrt_rst is
  generic(
    g_clk_period : time    := 10 ns;
    g_data_exp   : natural := 11;
    g_data_mant  : natural := 52
  );
end tb_lm_math_fpu_sqrt_rst;

architecture tb of tb_lm_math_fpu_sqrt_rst is

  constant C_W       : natural := g_data_exp + g_data_mant + 1;
  --   FSM latency from enable_i = '1' (in s_idle) to done_o = '1':
  --   one cycle to dispatch the request + K iterations in s_busy.
  --   s_done is reached on the last iteration edge (no extra cycle),
  --   so the normal-path latency is K + 1 = g_data_mant + 2.
  constant C_LATENCY : natural := g_data_mant + 2;

  signal clk_i    : std_logic := '0';
  signal rst_n_i  : std_logic := '0';
  signal enable_i : std_logic := '0';
  signal number_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal dout_o   : std_logic_vector(C_W - 1 downto 0);
  signal done_o   : std_logic;
  signal error_o  : std_logic;

  signal sim_end  : boolean   := false;

  function f_normal(x : real) return std_logic_vector is
  begin
    return to_slv(to_float(x, g_data_exp, g_data_mant));
  end function;

  --* One-sided 1 ULP floor: DUT result is always <= rounded reference,
  --  no more than 1 ULP below (positive normals only).
  function f_floor_within_1ulp(dut, ref : std_logic_vector) return boolean is
    variable vd : unsigned(dut'length - 1 downto 0);
    variable vr : unsigned(ref'length - 1 downto 0);
  begin
    vd := unsigned(dut);
    vr := unsigned(ref);
    if vd > vr then
      return false;
    end if;
    return (vr - vd) <= 1;
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

  proc_main : process
    variable v_n_errors : natural := 0;
    variable v_n_checks : natural := 0;
    variable v_timeout  : natural;
  begin
    -- ===================================================================
    -- Initial reset
    -- ===================================================================
    rst_n_i  <= '0';
    enable_i <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk_i); end loop;
    rst_n_i  <= '1';
    wait until rising_edge(clk_i);

    -- ===================================================================
    -- Phase A: sanity. sqrt(4.0) = 2.0
    -- ===================================================================
    number_i <= f_normal(4.0);
    enable_i <= '1';

    --   bounded wait for done_o; the inner "wait for 1 ps" lets the
    --   FSM update propagate before the loop re-evaluates
    v_timeout := 0;
    loop
      wait until rising_edge(clk_i);
      wait for 1 ps;
      exit when done_o = '1';
      v_timeout := v_timeout + 1;
      exit when v_timeout > 2 * C_LATENCY;
    end loop;

    v_n_checks := v_n_checks + 1;
    if done_o /= '1' then
      v_n_errors := v_n_errors + 1;
      report "Phase A: done_o never asserted within "
             & integer'image(2 * C_LATENCY) & " cycles for sqrt(4.0)"
        severity warning;
    end if;

    v_n_checks := v_n_checks + 1;
    if not f_floor_within_1ulp(dout_o, f_normal(2.0)) then
      v_n_errors := v_n_errors + 1;
      report "Phase A: sqrt(4.0) /= 2.0 within 1 ULP"
        severity warning;
    end if;

    --   release enable_i; FSM should fall back to idle
    enable_i <= '0';
    for i in 1 to 3 loop wait until rising_edge(clk_i); end loop;

    -- ===================================================================
    -- Phase B: mid-stream rst. Start sqrt(16.0), pulse rst before
    -- completion, then start sqrt(9.0) and verify the FSM completes
    -- cleanly.
    -- ===================================================================
    number_i <= f_normal(16.0);
    enable_i <= '1';

    --   let the FSM enter s_busy and complete a few iterations
    for i in 1 to 5 loop wait until rising_edge(clk_i); end loop;

    --   pulse rst MID-OPERATION
    rst_n_i  <= '0';
    enable_i <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk_i); end loop;
    rst_n_i  <= '1';

    --   two quiet cycles with enable_i = '0' so the FSM has settled
    --   in s_idle before we drive the next enable
    for i in 1 to 2 loop wait until rising_edge(clk_i); end loop;

    --   now drive sqrt(9.0). If the rst handling is correct, the FSM is
    --   in s_idle and starts a fresh K+1-cycle conversion.
    number_i <= f_normal(9.0);
    enable_i <= '1';

    v_timeout := 0;
    loop
      wait until rising_edge(clk_i);
      wait for 1 ps;
      exit when done_o = '1';
      v_timeout := v_timeout + 1;
      exit when v_timeout > 2 * C_LATENCY;
    end loop;

    v_n_checks := v_n_checks + 1;
    if done_o /= '1' then
      v_n_errors := v_n_errors + 1;
      report "Phase B: done_o never asserted within "
             & integer'image(2 * C_LATENCY) & " cycles -- FSM may be "
             & "stuck in a stale state after rst"
        severity warning;
    end if;

    v_n_checks := v_n_checks + 1;
    if not f_floor_within_1ulp(dout_o, f_normal(3.0)) then
      v_n_errors := v_n_errors + 1;
      report "Phase B: sqrt(9.0) after rst /= 3.0 within 1 ULP"
        severity warning;
    end if;

    v_n_checks := v_n_checks + 1;
    if error_o /= '0' then
      v_n_errors := v_n_errors + 1;
      report "Phase B: error_o set after rst on a clean sqrt(9.0)"
        severity warning;
    end if;

    --   ===================================================================
    enable_i <= '0';
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
