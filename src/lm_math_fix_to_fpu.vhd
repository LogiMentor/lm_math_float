--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fix_to_fpu
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Conversion from fixed point to floating point.
--
--   Fixed-point format conventions:
--     g_fix_length : total bit width of the fixed-point input.
--     g_fix_bpoint : number of fractional bits (position of the
--                    implicit binary point). In the conventional
--                    Qm.n notation used in this repo,
--                    m = g_fix_length - g_fix_bpoint and n =
--                    g_fix_bpoint; for signed formats m INCLUDES
--                    the sign bit at the MSB.
--     g_is_signed  : '1' = two's complement (sign bit at MSB), '0' =
--                    unsigned (fix_in_i is non-negative).
--     Example: g_fix_length=16, g_fix_bpoint=13, g_is_signed='1'
--              -> Q3.13 (16-bit two's complement, 13 fractional
--              bits, 3 integer-side bits including the sign bit at
--              the MSB).
--
--   Latency:
--     * Data-path pipeline stages: 4 (proc_sign_processing +
--       proc_count_delta + proc_test_car + proc_convert).
--     * Interface valid timing: 3 rising clock edges between the
--       edge that samples dv_i = '1' and the edge that asserts
--       dv_o = '1'. The repo convention (see lm_math_fpu_sum) uses
--       the edge count for "Latency", so dv_i -> dv_o = 3 cycles
--       is the figure to use for downstream integration.
--
--   Exponent over-range branch:
--     proc_convert handles s_test_car > C_MAX_CAR by emitting +-inf.
--     For typical Q formats this branch is unreachable because
--     C_BASE_CAR = C_BIAS + g_fix_length - g_fix_bpoint - 1 is much
--     smaller than C_MAX_CAR = 2**g_dout_exp - 2 (e.g. 129 vs 254
--     for Q3.13 / float32). The branch only fires for extreme
--     widths (g_fix_length > C_BIAS + g_fix_bpoint + 1, i.e.
--     impractically wide fixed-point inputs).
--
--   Reset semantics:
--     This module has no rst_n_i port. The data path is purely
--     pipelined (no FSM state that survives across operations) and
--     the dv_i / dv_o handshake makes any stale internal state
--     unobservable: a consumer that respects dv_o never reads
--     float_out_o while it is stale. s_sign_d and s_dv_d are both
--     initialized to (others => '0') at elaboration, so dv_o is
--     '0' at simulation start without needing an explicit reset.
--     Hardware power-up behaviour matches when the synthesis flow
--     honours register initialization (typical FPGA targets like
--     Xilinx / Intel preserve the init; ASIC flows usually do not
--     and would need an external reset to reach the same state).
--     Modules with FSM state (lm_math_fpu_sqrt) or
--     reset-clearable error pipelines (lm_math_fpu_div) do expose
--     rst_n_i; lm_math_fix_to_fpu needs neither.
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Revision History:
-- Date  Version  Author      Description
-- 2026  1.0.0    Logimentor  Initial public release.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity lm_math_fix_to_fpu is
  generic(
    --* exponent width of output
    g_dout_exp   : natural   := 8;
    --* mantissa width of output
    g_dout_mant  : natural   := 23;
    --* fixed point input width
    g_fix_length : natural   := 18;
    --* fixed point binary point position
    g_fix_bpoint : natural   := 9;
    --* sign presence on the fixed point input
    g_is_signed  : std_logic := '1'
  );
  port(
    clk_i       : in  std_logic;
    dv_i        : in  std_logic;
    fix_in_i    : in  std_logic_vector(g_fix_length - 1 downto 0);
    float_out_o : out std_logic_vector(g_dout_exp + g_dout_mant downto 0);
    dv_o        : out std_logic
  );
end lm_math_fix_to_fpu;

architecture a_rtl of lm_math_fix_to_fpu is

  constant C_BIAS      : natural := 2**(g_dout_exp - 1) - 1;
  constant C_MAX_CAR   : natural := 2**g_dout_exp - 2;
  constant C_MAX_SHIFT : natural := f_ceil_log2(g_fix_length);
  constant C_BASE_CAR  : natural := C_BIAS + g_fix_length - g_fix_bpoint - 1;

  signal s_sign_in           : std_logic;
  signal s_sign              : std_logic;
  -- shift registers explicitly initialized to '0' so the pipeline does
  -- not propagate 'U' on the first few cycles after elaboration.
  signal s_sign_d            : std_logic_vector(3 downto 0) := (others => '0');
  signal s_dv_d              : std_logic_vector(3 downto 0) := (others => '0');
  signal s_car               : unsigned(g_dout_exp - 1 downto 0);
  signal s_test_car          : unsigned(g_dout_exp - 1 downto 0);

  signal s_mant              : unsigned(g_dout_mant - 1 downto 0);
  signal s_unsigned_fixed    : unsigned(g_fix_length - 1 downto 0);
  signal s_unsigned_fixed_d  : unsigned(g_fix_length - 1 downto 0);
  signal s_unsigned_fixed_2d : unsigned(g_fix_length - 1 downto 0);
  signal s_delta             : unsigned(C_MAX_SHIFT downto 0);
  signal s_delta_d           : unsigned(C_MAX_SHIFT downto 0);

begin

  gen_no_sign : if g_is_signed = '0' generate
    proc_sign_processing : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_unsigned_fixed <= unsigned(fix_in_i);
      end if;
    end process proc_sign_processing;
  end generate gen_no_sign;

  gen_sign : if g_is_signed = '1' generate
    proc_sign_processing : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if fix_in_i(fix_in_i'left) = '0' then
          s_unsigned_fixed <= unsigned(fix_in_i);
        else
          s_unsigned_fixed <= not(unsigned(fix_in_i)) + 1;
        end if;
      end if;
    end process proc_sign_processing;
  end generate gen_sign;

  proc_count_delta : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_delta            <= resize(f_count_delta(s_unsigned_fixed), s_delta'length);
      s_unsigned_fixed_d <= s_unsigned_fixed;
    end if;
  end process proc_count_delta;

  proc_test_car : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if C_BASE_CAR >= s_delta then
        s_test_car <= to_unsigned(C_BASE_CAR, s_test_car'length) - s_delta;
      else
        s_test_car <= (others => '0');
      end if;
      s_unsigned_fixed_2d <= s_unsigned_fixed_d;
      s_delta_d           <= s_delta;
    end if;
  end process proc_test_car;

  gen_small_fixed : if s_mant'left >= s_unsigned_fixed_2d'length generate
    proc_convert : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_delta_d = g_fix_length then
          s_car  <= (others => '0');
          s_mant <= (others => '0');
        elsif (s_test_car > 0) and (s_test_car <= C_MAX_CAR) then
          s_car <= s_test_car;
          if s_mant'left >= s_unsigned_fixed_2d'length then
            s_mant(s_mant'left downto s_mant'left - s_unsigned_fixed_2d'length + 1)
              <= shift_left(s_unsigned_fixed_2d, to_integer(s_delta_d) + 1);
            s_mant(s_mant'left - s_unsigned_fixed_2d'length downto 0) <= (others => '0');
          else
            s_mant <= shift_left(s_unsigned_fixed_2d, to_integer(s_delta_d) + 1)
                      (s_unsigned_fixed_2d'left
                       downto s_unsigned_fixed_2d'left - s_mant'length + 1);
          end if;
        elsif s_test_car = 0 then
          s_car <= (others => '0');
          if s_mant'left >= s_unsigned_fixed_2d'length then
            s_mant(s_mant'left downto s_mant'left - s_unsigned_fixed_2d'length)
              <= '1' & shift_right(s_unsigned_fixed_2d,
                                   to_integer(s_test_car
                                              - to_unsigned(C_MAX_CAR, s_test_car'length)));
            s_mant(s_mant'left - s_unsigned_fixed_2d'length - 1 downto 0) <= (others => '0');
          else
            s_mant <= '1' & shift_right(s_unsigned_fixed_2d,
                                        to_integer(s_test_car
                                                   - to_unsigned(C_MAX_CAR, s_test_car'length)))
                                       (s_unsigned_fixed_2d'left
                                        downto s_unsigned_fixed_2d'left - s_mant'length);
          end if;
        elsif s_test_car > C_MAX_CAR then
          -- IEEE-754 infinity: all-ones exponent + zero mantissa
          s_car  <= (others => '1');
          s_mant <= (others => '0');
        end if;
      end if;
    end process proc_convert;
  end generate gen_small_fixed;

  gen_large_fixed : if s_mant'left < s_unsigned_fixed_2d'length generate
    proc_convert : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_delta_d = g_fix_length then
          s_car  <= (others => '0');
          s_mant <= (others => '0');
        elsif (s_test_car > 0) and (s_test_car <= C_MAX_CAR) then
          s_car  <= s_test_car;
          s_mant <= shift_left(s_unsigned_fixed_2d, to_integer(s_delta_d) + 1)
                    (s_unsigned_fixed_2d'left
                     downto s_unsigned_fixed_2d'left - s_mant'length + 1);
        elsif s_test_car = 0 then
          s_car  <= (others => '0');
          s_mant <= shift_right(s_unsigned_fixed_2d,
                                to_integer(s_test_car
                                           - to_unsigned(C_MAX_CAR, s_test_car'length)))
                                (s_unsigned_fixed_2d'left
                                 downto s_unsigned_fixed_2d'left - s_mant'length + 1);
        elsif s_test_car > C_MAX_CAR then
          -- IEEE-754 infinity: all-ones exponent + zero mantissa
          s_car  <= (others => '1');
          s_mant <= (others => '0');
        end if;
      end if;
    end process proc_convert;
  end generate gen_large_fixed;

  -- when the fixed input is unsigned, its top bit is a magnitude bit, not a
  -- sign bit: force the float output sign to '0' in that case.
  s_sign_in <= fix_in_i(fix_in_i'left) when g_is_signed = '1' else '0';

  -- inline 4-cycle delays (formerly an external delay primitive with g_delay=4)
  proc_delays : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_sign_d <= s_sign_d(2 downto 0) & s_sign_in;
      s_dv_d   <= s_dv_d(2 downto 0) & dv_i;
    end if;
  end process proc_delays;

  s_sign <= s_sign_d(3);
  dv_o   <= s_dv_d(3);

  float_out_o <= s_sign & std_logic_vector(s_car) & std_logic_vector(s_mant);

end a_rtl;
