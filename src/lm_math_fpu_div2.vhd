--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_div2
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Division of a floating point number by 2.
--               Latency: 2 clock cycles. No rounding is performed (mantissa
--               is shifted exactly; the rounder, if needed, can be appended
--               externally).
--
--   Subnormal handling:
--     Normal input (car > 1): exponent decremented, mantissa
--       unchanged.
--     Normal input at the lower boundary (car = 1): output lands in
--       the denormal range; the implicit '1' becomes the explicit MSB
--       of the output mantissa field, car_out = 0.
--     Denormal input (car = 0): the mantissa is shifted right by one
--       in the bit field; the smallest denormal (mant_field = 1)
--       truncates to mant_field_out = 0, i.e. flush-to-zero on
--       the smallest representable input.
--
--   IEEE special inputs (NOT handled):
--     NaN / +-inf inputs are not detected: the module just decrements
--     the exponent, which corrupts the IEEE classification (e.g. an
--     all-ones car becomes all-ones - 1, no longer infinity). The TB
--     does not cover these cases.
--               Input/output signal timing:
--                     _____
--                  __|     |____________________________ dv_i
--                 ---|A|B|C|---------------------------- dividend_i
--                         _____
--                 _______|     |________________________ dv_o
--                 -------|G|H|I|------------------------ quotient_o
--
--   Reset semantics:
--     This module has no rst_n_i port. The data path is purely
--     pipelined (no FSM state that survives across operations) and
--     the dv_i / dv_o handshake makes any stale internal state
--     unobservable: a consumer that respects dv_o never reads
--     quotient_o while it is stale. s_dv is initialized to
--     (others => '0') at elaboration, so dv_o is '0' at
--     simulation start without needing an explicit reset.
--     Hardware power-up
--     behaviour matches when the synthesis flow honours
--     register initialization (typical FPGA targets like
--     Xilinx / Intel preserve the init; ASIC flows usually do
--     not and would need an external reset to reach the same
--     state). Modules with FSM state (lm_math_fpu_sqrt) or
--     reset-clearable error pipelines (lm_math_fpu_div) do
--     expose rst_n_i; lm_math_fpu_div2 needs neither.
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

entity lm_math_fpu_div2 is
  generic(
    --* exponent width of input
    g_data_exp   : natural := 8;
    --* mantissa width of input
    g_data_mant  : natural := 23;
    --* how many combinatory steps in the integer division (legacy generic,
    --  used to size the internal dv shift register)
    g_chunk_size : natural := 25;
    --* rounding mode (kept for API symmetry; current implementation truncates)
    g_round_mode : integer := C_LM_ROUND_NEAREST
  );
  port(
    clk_i      : in  std_logic;
    dv_i       : in  std_logic;
    dividend_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    quotient_o : out std_logic_vector(g_data_exp + g_data_mant downto 0);
    dv_o       : out std_logic
  );
end lm_math_fpu_div2;

architecture a_rtl of lm_math_fpu_div2 is

  -- output appears 2 cycles after dv_i, so the dv shift register only needs
  -- 2 stages and the sign one stage of alignment. g_chunk_size is kept as a
  -- generic for API symmetry with lm_math_fpu_div but does not affect this
  -- module's latency.
  constant C_DV_DEPTH : natural := 2;

  signal s_sign     : std_logic_vector(0 to 1);
  signal s_sign_i   : std_logic;
  signal s_car      : unsigned(g_data_exp - 1 downto 0);
  signal s_mant     : unsigned(g_data_mant + 1 downto 0);
  signal s_mant_den : unsigned(g_data_mant + 1 downto 0);
  signal s_car_i    : unsigned(g_data_exp - 1 downto 0);
  signal s_mant_i   : unsigned(g_data_mant - 1 downto 0);
  signal s_dv       : std_logic_vector(0 to C_DV_DEPTH) := (others => '0');

begin

  s_sign(0) <= s_sign_i;
  s_dv(0)   <= dv_i;

  proc_load_data : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if dv_i = '1' then
        s_sign_i <= dividend_i(dividend_i'left);
        s_car_i  <= unsigned(dividend_i(dividend_i'left - 1
                                        downto dividend_i'left - g_data_exp));
        s_mant_i <= unsigned(dividend_i(dividend_i'left - g_data_exp - 1 downto 0));
      end if;
    end if;
  end process proc_load_data;

  proc_car_result : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_car_i > 1 then
        s_car <= s_car_i - 1;
      else
        s_car <= (others => '0');
      end if;
    end if;
  end process proc_car_result;

  s_mant_den <= '1' & s_mant_i & '0';

  proc_mant_result : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_car_i > 1 then
        --   Normal input, normal output: exponent decremented, mantissa
        --   passes through unchanged.
        s_mant <= s_mant_i & "00";
      elsif s_car_i = 1 then
        --   Normal input with smallest normal exponent. Halving makes
        --   it land in the denormal range: keep the implicit '1' bit
        --   inside the mantissa and emit car=0.
        s_mant <= s_mant_den;
      else
        --   Denormal input: value = mant_i * 2^(1 - bias - g_data_mant);
        --   halving means mant_field_out = mant_i / 2 (truncated; the
        --   smallest denormal flushes to +-0 via this truncation -- the
        --   sign bit is preserved through the s_sign(1) path, so a
        --   negative smallest denormal halves to -0). Built as
        --   shift_right(s_mant_i, 1) (a g_data_mant-bit unsigned with
        --   the zero shifted in at the top) concatenated with "00" in
        --   the LSB slot the output slice ignores. shift_right is used
        --   instead of an explicit slice "s_mant_i(g_data_mant-1 downto
        --   1)" so the code stays well-formed when g_data_mant = 1
        --   (where the slice would be a null range).
        s_mant <= shift_right(s_mant_i, 1) & "00";
      end if;
    end if;
  end process proc_mant_result;

  gen_dv : for i in 0 to C_DV_DEPTH - 1 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_dv(i + 1) <= s_dv(i);
      end if;
    end process;
  end generate gen_dv;

  process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_sign(1) <= s_sign(0);
    end if;
  end process;

  quotient_o <= std_logic_vector(s_sign(1) & s_car & s_mant(s_mant'left downto 2));
  dv_o       <= s_dv(C_DV_DEPTH);

end a_rtl;
