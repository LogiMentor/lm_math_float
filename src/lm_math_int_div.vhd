--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_int_div
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Pipelined unsigned integer long-division. Computes
--                 quotient_o = floor( dividend_i * 2^(g_quotient_size - 1) /
--                                     divisor_i )
--               truncated to g_quotient_size bits. The pipeline has
--               ceil(g_quotient_size / g_chunk_size) stages, each performing
--               g_chunk_size compare-subtract steps combinatorially.
--
--               This module is used by lm_math_fpu_div to divide the
--               mantissas (both pre-normalized to MSB = '1'). Under that
--               assumption the quotient fits in g_data_w + 1 bits.
--
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

entity lm_math_int_div is
  generic(
    --* dividend and divisor width
    g_data_w        : natural := 24;
    --* quotient width (typically g_data_w + 1 for FPU use)
    g_quotient_size : natural := 25;
    --* number of bit-steps performed in a single pipeline stage
    g_chunk_size    : natural := 4
  );
  port(
    clk_i      : in  std_logic;
    dv_i       : in  std_logic;
    dividend_i : in  std_logic_vector(g_data_w - 1 downto 0);
    divisor_i  : in  std_logic_vector(g_data_w - 1 downto 0);
    dv_o       : out std_logic;
    quotient_o : out std_logic_vector(g_quotient_size - 1 downto 0)
  );
end lm_math_int_div;

architecture a_rtl_compare_short of lm_math_int_div is

  constant C_STAGES : natural := f_div_ceil(g_quotient_size, g_chunk_size);

  subtype t_rem is unsigned(g_data_w downto 0);  -- 1 extra bit for compare/sub

  type t_rem_pipe is array (0 to C_STAGES) of t_rem;
  type t_q_pipe   is array (0 to C_STAGES) of unsigned(g_quotient_size - 1 downto 0);
  type t_div_pipe is array (0 to C_STAGES) of unsigned(g_data_w - 1 downto 0);

  -- Pipeline signals initialized to all-zeros so dv_o starts at '0'
  -- at simulation start instead of propagating 'U' through the shift
  -- register for the first C_STAGES cycles. The data pipeline
  -- (s_rem / s_q / s_div) is consumed only when dv_o = '1', so its
  -- initial value is functionally irrelevant; initializing it
  -- silences spurious 'U' propagation in waveform inspection /
  -- assertion-based monitors.
  signal s_rem : t_rem_pipe              := (others => (others => '0'));
  signal s_q   : t_q_pipe                := (others => (others => '0'));
  signal s_div : t_div_pipe              := (others => (others => '0'));
  signal s_dv  : std_logic_vector(0 to C_STAGES) := (others => '0');

begin

  -- Generic constraints. g_data_w = 0 collapses the dividend / divisor
  -- range to (-1 downto 0) which is invalid; g_quotient_size = 0
  -- collapses the quotient range likewise; g_chunk_size = 0 makes the
  -- per-stage compare-subtract loop iterate zero times so the pipeline
  -- registers garbage. Reject the violations at elaboration with a
  -- readable message.
  assert g_data_w >= 1
    report "lm_math_int_div: g_data_w must be >= 1, got "
           & integer'image(g_data_w) & "."
    severity failure;
  assert g_quotient_size >= 1
    report "lm_math_int_div: g_quotient_size must be >= 1, got "
           & integer'image(g_quotient_size) & "."
    severity failure;
  assert g_chunk_size >= 1
    report "lm_math_int_div: g_chunk_size must be >= 1, got "
           & integer'image(g_chunk_size) & "."
    severity failure;

  -- combinational input to the first stage; stage 0 registers it
  s_rem(0) <= '0' & unsigned(dividend_i);
  s_q(0)   <= (others => '0');
  s_div(0) <= unsigned(divisor_i);
  s_dv(0)  <= dv_i;

  gen_stages : for s in 0 to C_STAGES - 1 generate
    process(clk_i)
      variable v_rem : t_rem;
      variable v_q   : unsigned(g_quotient_size - 1 downto 0);
      variable v_div : t_rem;
      variable v_idx : integer;
    begin
      if rising_edge(clk_i) then
        v_rem := s_rem(s);
        v_q   := s_q(s);
        v_div := '0' & s_div(s);
        for k in 0 to g_chunk_size - 1 loop
          v_idx := g_quotient_size - 1 - (s * g_chunk_size + k);
          if v_idx >= 0 then
            -- the very first compare uses the un-shifted dividend so that
            -- the MSB of the quotient flags the case "dividend >= divisor".
            -- All later iterations shift left before the compare.
            if not (s = 0 and k = 0) then
              v_rem := v_rem(v_rem'left - 1 downto 0) & '0';
            end if;
            if v_rem >= v_div then
              v_rem      := v_rem - v_div;
              v_q(v_idx) := '1';
            else
              v_q(v_idx) := '0';
            end if;
          end if;
        end loop;
        s_rem(s + 1) <= v_rem;
        s_q(s + 1)   <= v_q;
        s_div(s + 1) <= s_div(s);
        s_dv(s + 1)  <= s_dv(s);
      end if;
    end process;
  end generate gen_stages;

  quotient_o <= std_logic_vector(s_q(C_STAGES));
  dv_o       <= s_dv(C_STAGES);

end a_rtl_compare_short;
