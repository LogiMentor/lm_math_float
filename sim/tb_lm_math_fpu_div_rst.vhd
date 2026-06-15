--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_div_rst
-- Description: Validates the rst_n_i pipelines of lm_math_fpu_div under
--              mid-stream reset.
--
--              The test covers the module's reset-clearable paths:
--                * proc_errors    -> s_error(0)
--                * gen_error      -> s_error(1..N)         (entire pipeline)
--                * proc_final     -> s_car / s_mant / s_error_x(0)
--                * gen_error_x    -> s_error_x(1..M)       (entire pipeline)
--
--              Strategy:
--                Phase A (sanity)
--                  Drive an over-range pair (1.0e30 / 1.0e-10) so the
--                  module raises error_o(6) at the head of its 7-bit
--                  error_o vector. Wait the full latency, confirm
--                  error_o(6) = '1' on dv_o.
--                Phase B (rst test)
--                  Drive the same over-range pair again, but assert
--                  rst_n_i = '0' just BEFORE the over-range bit reaches
--                  the output. Hold rst for 5 cycles, deassert. Drive a
--                  clean pair (2.0 / 1.0) and wait the latency. Confirm
--                  dv_o pulses with error_o = "0000000". Without the
--                  rst additions on s_error / s_error_x / proc_final,
--                  the stale bit-6 '1' would still propagate out as
--                  error_o(6) on the clean vector.
--
--              Latency: dv_o = s_dv(C_INTDIV_LATENCY + 7). With
--              g_data_mant = 23 and g_chunk_size = 4, C_INTDIV_LATENCY
--              = ceil(25/4) = 7, so dv_i -> dv_o is 14 clocks.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_div_rst is
  generic(
    g_clk_period : time    := 10 ns;
    g_data_exp   : natural := 8;
    g_data_mant  : natural := 23;
    g_chunk_size : natural := 4;
    g_round_mode : integer := C_LM_ROUND_NEAREST
  );
end tb_lm_math_fpu_div_rst;

architecture tb of tb_lm_math_fpu_div_rst is

  constant C_W       : natural := g_data_exp + g_data_mant + 1;
  --   dv_o latency from a dv_i pulse: gen_dv shifts s_dv(0) -> s_dv(C_INTDIV_LATENCY+7)
  constant C_LATENCY : natural := ((g_data_mant + 2 + g_chunk_size - 1)
                                   / g_chunk_size) + 7;

  signal clk_i      : std_logic := '0';
  signal rst_n_i    : std_logic := '0';
  signal dv_i       : std_logic := '0';
  signal dividend_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal divisor_i  : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal quotient_o : std_logic_vector(C_W - 1 downto 0);
  signal dv_o       : std_logic;
  signal error_o    : std_logic_vector(6 downto 0);

  signal sim_end    : boolean   := false;

  function f_normal(x : real) return std_logic_vector is
  begin
    return to_slv(to_float(x, g_data_exp, g_data_mant));
  end function;

  --* Symmetric +/-1 ULP compare. Works at any C_W (no to_integer
  --  conversion, so it does not depend on the simulator's integer
  --  range -- safe if the generics are widened to 11/52).
  function f_within_1ulp(a, b : std_logic_vector) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= 1;
  end function;

begin

  uut : entity lm_math_float_lib.lm_math_fpu_div
    generic map(
      g_data_exp   => g_data_exp,
      g_data_mant  => g_data_mant,
      g_chunk_size => g_chunk_size,
      g_round_mode => g_round_mode
    )
    port map(
      clk_i      => clk_i,
      rst_n_i    => rst_n_i,
      dv_i       => dv_i,
      dividend_i => dividend_i,
      divisor_i  => divisor_i,
      quotient_o => quotient_o,
      dv_o       => dv_o,
      error_o    => error_o
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
    rst_n_i <= '0';
    dv_i    <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk_i); end loop;
    rst_n_i <= '1';
    wait until rising_edge(clk_i);

    -- ===================================================================
    -- Phase A: sanity. Drive over-range, wait full latency, check
    -- error_o(6) = '1' at dv_o time.
    -- ===================================================================
    dividend_i <= f_normal(1.0e30);
    divisor_i  <= f_normal(1.0e-10);
    dv_i       <= '1';
    wait until rising_edge(clk_i);
    dv_i       <= '0';

    --   wait for dv_o, bounded -- a regression in latency / rst logic
    --   must not hang the TB. The inner "wait for 1 ps" lets dv_o
    --   settle after each clock edge before the loop re-evaluates.
    v_timeout := 0;
    loop
      wait until rising_edge(clk_i);
      wait for 1 ps;
      exit when dv_o = '1';
      v_timeout := v_timeout + 1;
      exit when v_timeout > 2 * C_LATENCY;
    end loop;

    v_n_checks := v_n_checks + 1;
    if dv_o /= '1' then
      v_n_errors := v_n_errors + 1;
      report "Phase A: dv_o never asserted within "
             & integer'image(2 * C_LATENCY) & " cycles"
        severity warning;
    end if;

    v_n_checks := v_n_checks + 1;
    if error_o(6) /= '1' then
      v_n_errors := v_n_errors + 1;
      report "Phase A: over-range vec did not raise error_o(6). error_o="
             & to_string(error_o)
        severity warning;
    end if;

    --   let any residual pulses drain
    for i in 1 to C_LATENCY + 5 loop wait until rising_edge(clk_i); end loop;

    -- ===================================================================
    -- Phase B: mid-stream rst. Drive over-range, then assert rst before
    -- the bit-6 '1' has propagated out, then drive a clean vec and check
    -- the clean output has error_o = "0000000".
    -- ===================================================================
    dividend_i <= f_normal(1.0e30);
    divisor_i  <= f_normal(1.0e-10);
    dv_i       <= '1';
    wait until rising_edge(clk_i);
    dv_i       <= '0';

    --   wait a few cycles so the over-range pair has entered the pipeline
    --   but its dv_o has not yet fired
    for i in 1 to C_LATENCY - 3 loop wait until rising_edge(clk_i); end loop;

    --   pulse rst MID-PIPELINE
    rst_n_i <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk_i); end loop;
    rst_n_i <= '1';

    --   flush window: any stale s_dv pulses from Phase A or the
    --   over-range vec will surface here. s_dv has no rst, so we drop
    --   anything that comes out during the flush.
    for i in 1 to 2 * C_LATENCY loop wait until rising_edge(clk_i); end loop;

    --   drive the clean vector
    dividend_i <= f_normal(2.0);
    divisor_i  <= f_normal(1.0);
    dv_i       <= '1';
    wait until rising_edge(clk_i);
    dv_i       <= '0';

    --   The dv_i sampling edge above counts as cycle 1 of the dv_i ->
    --   dv_o pipeline. We wait C_LATENCY - 1 more rising edges to land
    --   on the C_LATENCY-th edge (the one where the DUT's gen_dv
    --   produces dv_o = '1' for this vector).
    for i in 1 to C_LATENCY - 1 loop wait until rising_edge(clk_i); end loop;
    wait for 1 ps;

    v_n_checks := v_n_checks + 1;
    if dv_o /= '1' then
      v_n_errors := v_n_errors + 1;
      report "Phase B: dv_o not '1' at expected clean-vec latency"
        severity warning;
    end if;

    v_n_checks := v_n_checks + 1;
    if error_o /= "0000000" then
      v_n_errors := v_n_errors + 1;
      report "Phase B: clean vec produced non-zero error_o after rst. "
             & "error_o=" & to_string(error_o)
             & " (the rst_n_i additions to s_error / s_error_x / "
             & "proc_final are supposed to clear this on rst)"
        severity warning;
    end if;

    --   value check: 2.0 / 1.0 = 2.0 within 1 ULP. Unsigned-vector
    --   compare so it stays valid even if the generics are widened to
    --   double precision (no to_integer overflow).
    v_n_checks := v_n_checks + 1;
    if not f_within_1ulp(quotient_o, f_normal(2.0)) then
      v_n_errors := v_n_errors + 1;
      report "Phase B: clean vec quotient_o not within 1 ULP of 2.0. "
             & "quotient_o=" & to_hstring(quotient_o)
        severity warning;
    end if;

    --   ===================================================================
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
