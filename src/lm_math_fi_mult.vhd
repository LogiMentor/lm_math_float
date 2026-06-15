--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fi_mult
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Pipelined unsigned integer multiplier used by lm_math_fpu_prod
--               for the mantissa multiplication. The full product
--               (g_din_a_w + g_din_b_w bits) is truncated/right-aligned to
--               g_dout_w bits at the output.
--
--               A slim integer multiplier that keeps only the unsigned
--               path: only unsigned*unsigned with simple truncation is
--               kept, since this is the only configuration actually
--               instantiated by the FPU sources. The signed and rounding
--               logic is intentionally dropped.
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

entity lm_math_fi_mult is
  generic(
    --* input a width
    g_din_a_w     : natural := 24;
    --* input b width
    g_din_b_w     : natural := 24;
    --* output width (must be <= g_din_a_w + g_din_b_w)
    g_dout_w      : natural := 48;
    --* number of pipeline registers after the multiplier (>= 0)
    g_pipe_stages : natural := 3
  );
  port(
    clk_i  : in  std_logic;
    din1_i : in  std_logic_vector(g_din_a_w - 1 downto 0);
    din2_i : in  std_logic_vector(g_din_b_w - 1 downto 0);
    dout_o : out std_logic_vector(g_dout_w - 1 downto 0)
  );
end lm_math_fi_mult;

architecture a_rtl of lm_math_fi_mult is
  constant C_FULL_W : natural := g_din_a_w + g_din_b_w;
  type t_pipe is array (0 to g_pipe_stages) of unsigned(C_FULL_W - 1 downto 0);
  signal s_pipe : t_pipe := (others => (others => '0'));
begin

  proc_mult : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_pipe(0) <= unsigned(din1_i) * unsigned(din2_i);
      for i in 1 to g_pipe_stages loop
        s_pipe(i) <= s_pipe(i - 1);
      end loop;
    end if;
  end process proc_mult;

  -- g_dout_w is sliced out of the (g_din_a_w + g_din_b_w)-bit full
  -- product. Values above C_FULL_W make the slice range invalid (left
  -- index past the unsigned vector's left), which is an elaboration-
  -- time error in most simulators / synthesis tools -- the analyzer
  -- gives up before any concurrent assertion gets a chance to run.
  -- Guard the slice with a static if-generate so the invalid branch
  -- is never elaborated at all; the else branch carries an
  -- assert-false plus a safe default driver to keep dout_o defined.
  gen_dout : if g_dout_w <= C_FULL_W generate
    -- right-aligned truncation: keep the g_dout_w least significant bits
    dout_o <= std_logic_vector(s_pipe(g_pipe_stages)(g_dout_w - 1 downto 0));
  else generate
    assert false
      report "lm_math_fi_mult: g_dout_w (" & integer'image(g_dout_w)
             & ") must be <= g_din_a_w + g_din_b_w ("
             & integer'image(C_FULL_W) & ")."
      severity failure;
    dout_o <= (others => '0');
  end generate;

end a_rtl;
