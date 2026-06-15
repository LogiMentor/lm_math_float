--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_int_div
-- Description: Self-checking unit test for lm_math_int_div.
--
--              Coverage:
--                * dividend < divisor, dividend = divisor, and
--                  dividend > divisor;
--                * zero dividend;
--                * non-power-of-two divisors;
--                * maximum in-contract ratio below 2.0;
--                * two chunk sizes, including a quotient width that is not an
--                  exact multiple of the chunk size.
--
--              The expected quotient is fixed-point:
--                floor(dividend * 2^(g_quotient_size - 1) / divisor).
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_int_div is
  generic(
    g_clk_period : time := 10 ns
  );
end tb_lm_math_int_div;

architecture tb of tb_lm_math_int_div is

  constant C_DATA_W : natural := 5;
  constant C_Q_W    : natural := 6;
  constant C_N_VEC  : natural := 8;

  type t_nat_array is array (0 to C_N_VEC - 1) of natural;
  constant C_NUM : t_nat_array := ( 0, 16, 20, 15, 31,  1,  7, 17);
  constant C_DEN : t_nat_array := ( 7, 16, 16, 16, 16, 31, 13, 31);

  signal clk_i        : std_logic := '0';
  signal sim_end      : boolean   := false;
  signal dv_i         : std_logic := '0';
  signal dividend_i   : std_logic_vector(C_DATA_W - 1 downto 0) := (others => '0');
  signal divisor_i    : std_logic_vector(C_DATA_W - 1 downto 0) := (others => '0');
  signal dv_chunk1    : std_logic;
  signal dv_chunk4    : std_logic;
  signal q_chunk1     : std_logic_vector(C_Q_W - 1 downto 0);
  signal q_chunk4     : std_logic_vector(C_Q_W - 1 downto 0);

begin

  uut_chunk1 : entity lm_math_float_lib.lm_math_int_div
    generic map(
      g_data_w        => C_DATA_W,
      g_quotient_size => C_Q_W,
      g_chunk_size    => 1
    )
    port map(
      clk_i      => clk_i,
      dv_i       => dv_i,
      dividend_i => dividend_i,
      divisor_i  => divisor_i,
      dv_o       => dv_chunk1,
      quotient_o => q_chunk1
    );

  uut_chunk4 : entity lm_math_float_lib.lm_math_int_div
    generic map(
      g_data_w        => C_DATA_W,
      g_quotient_size => C_Q_W,
      g_chunk_size    => 4
    )
    port map(
      clk_i      => clk_i,
      dv_i       => dv_i,
      dividend_i => dividend_i,
      divisor_i  => divisor_i,
      dv_o       => dv_chunk4,
      quotient_o => q_chunk4
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

    procedure apply_vec(idx : natural; dividend : natural; divisor : natural) is
      variable v_expected    : std_logic_vector(C_Q_W - 1 downto 0);
      variable v_seen_chunk1 : boolean := false;
      variable v_seen_chunk4 : boolean := false;
    begin
      v_expected := std_logic_vector(to_unsigned(
        (dividend * (2 ** (C_Q_W - 1))) / divisor, C_Q_W));

      dividend_i <= std_logic_vector(to_unsigned(dividend, C_DATA_W));
      divisor_i  <= std_logic_vector(to_unsigned(divisor, C_DATA_W));
      dv_i       <= '1';
      wait until rising_edge(clk_i);
      dv_i       <= '0';

      for cycle in 0 to 12 loop
        wait until rising_edge(clk_i);
        wait for 1 ns;

        if dv_chunk4 = '1' and not v_seen_chunk4 then
          check_slv("chunk4 quotient vec " & integer'image(idx),
                    q_chunk4, v_expected);
          v_seen_chunk4 := true;
        end if;

        if dv_chunk1 = '1' and not v_seen_chunk1 then
          check_slv("chunk1 quotient vec " & integer'image(idx),
                    q_chunk1, v_expected);
          v_seen_chunk1 := true;
        end if;

        exit when v_seen_chunk1 and v_seen_chunk4;
      end loop;

      if not v_seen_chunk4 then
        v_n_errors := v_n_errors + 1;
        report "chunk4 dv_o timeout on vec " & integer'image(idx)
          severity warning;
      end if;
      if not v_seen_chunk1 then
        v_n_errors := v_n_errors + 1;
        report "chunk1 dv_o timeout on vec " & integer'image(idx)
          severity warning;
      end if;
    end procedure;
  begin
    wait for 1 ns;
    check_sl("chunk1 dv_o initial", dv_chunk1, '0');
    check_sl("chunk4 dv_o initial", dv_chunk4, '0');

    for i in 0 to C_N_VEC - 1 loop
      apply_vec(i, C_NUM(i), C_DEN(i));
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
