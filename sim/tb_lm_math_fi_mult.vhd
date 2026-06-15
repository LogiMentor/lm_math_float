--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fi_mult
-- Description: Self-checking unit test for lm_math_fi_mult.
--
--              Coverage:
--                * zero operands;
--                * one operands;
--                * asymmetric widths;
--                * maximum product;
--                * right-aligned truncation;
--                * g_pipe_stages = 0 and g_pipe_stages = 2.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lm_math_float_lib;

entity tb_lm_math_fi_mult is
  generic(
    g_clk_period : time := 10 ns
  );
end tb_lm_math_fi_mult;

architecture tb of tb_lm_math_fi_mult is

  constant C_A_W        : natural := 4;
  constant C_B_W        : natural := 3;
  constant C_FULL_W     : natural := C_A_W + C_B_W;
  constant C_TRUNC_W    : natural := 5;
  constant C_TRUNC_PIPE : natural := 2;
  constant C_N_VEC      : natural := 7;

  type t_nat_array is array (0 to C_N_VEC - 1) of natural;
  constant C_A : t_nat_array := (0, 1, 3, 7, 15, 12, 9);
  constant C_B : t_nat_array := (0, 1, 5, 6,  7,  7, 3);

  signal clk_i       : std_logic := '0';
  signal sim_end     : boolean   := false;
  signal din1_i      : std_logic_vector(C_A_W - 1 downto 0) := (others => '0');
  signal din2_i      : std_logic_vector(C_B_W - 1 downto 0) := (others => '0');
  signal dout_full   : std_logic_vector(C_FULL_W - 1 downto 0);
  signal dout_trunc  : std_logic_vector(C_TRUNC_W - 1 downto 0);

begin

  uut_full : entity lm_math_float_lib.lm_math_fi_mult
    generic map(
      g_din_a_w     => C_A_W,
      g_din_b_w     => C_B_W,
      g_dout_w      => C_FULL_W,
      g_pipe_stages => 0
    )
    port map(
      clk_i  => clk_i,
      din1_i => din1_i,
      din2_i => din2_i,
      dout_o => dout_full
    );

  uut_trunc : entity lm_math_float_lib.lm_math_fi_mult
    generic map(
      g_din_a_w     => C_A_W,
      g_din_b_w     => C_B_W,
      g_dout_w      => C_TRUNC_W,
      g_pipe_stages => C_TRUNC_PIPE
    )
    port map(
      clk_i  => clk_i,
      din1_i => din1_i,
      din2_i => din2_i,
      dout_o => dout_trunc
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
  end process proc_clk;

  proc_stim : process
    variable v_n_checks : natural := 0;
    variable v_n_errors : natural := 0;

    procedure check_slv(desc : string; actual : std_logic_vector;
                        expected : std_logic_vector) is
    begin
      v_n_checks := v_n_checks + 1;
      if actual /= expected then
        v_n_errors := v_n_errors + 1;
        report desc & ": expected 0x" & to_hstring(expected)
               & ", got 0x" & to_hstring(actual)
          severity warning;
      end if;
    end procedure;

    procedure apply_vec(idx : natural; a : natural; b : natural) is
      variable v_product : natural;
    begin
      v_product := a * b;
      din1_i    <= std_logic_vector(to_unsigned(a, C_A_W));
      din2_i    <= std_logic_vector(to_unsigned(b, C_B_W));

      wait until rising_edge(clk_i);
      wait for 1 ns;
      check_slv("full product vec " & integer'image(idx),
                dout_full,
                std_logic_vector(to_unsigned(v_product, C_FULL_W)));

      for i in 1 to C_TRUNC_PIPE loop
        wait until rising_edge(clk_i);
      end loop;
      wait for 1 ns;
      check_slv("truncated product vec " & integer'image(idx),
                dout_trunc,
                std_logic_vector(to_unsigned(v_product mod (2 ** C_TRUNC_W),
                                             C_TRUNC_W)));
    end procedure;
  begin
    for i in 0 to C_N_VEC - 1 loop
      apply_vec(i, C_A(i), C_B(i));
    end loop;

    assert v_n_errors = 0
      report "TEST FAILED: " & integer'image(v_n_errors) & " / "
             & integer'image(v_n_checks) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(v_n_checks) & " checks OK"
      severity note;
    sim_end <= true;
    wait;
  end process proc_stim;

end tb;
