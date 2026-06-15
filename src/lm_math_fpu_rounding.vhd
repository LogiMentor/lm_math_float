--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_rounding
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : FPU rounding block. Four modes are supported, selected by
--               the g_round_mode generic:
--                 C_LM_ROUND_NEAREST  round to nearest, ties up
--                 C_LM_ROUND_INF      round toward positive infinity
--                 C_LM_ROUND_NEGINF   round toward negative infinity
--                 C_LM_ROUND_ZERO     truncate (round toward zero)
--               Latency: 2 clock cycles (sign and car internally delayed).
--
--   Reset semantics:
--     This module has no rst_n_i port and no dv_i / dv_o handshake.
--     It is a stateless building block (no FSM state, only the
--     internal pipeline registers s_sign_d / s_number /
--     s_car / s_mantissa) consumed by lm_math_fpu_prod,
--     lm_math_fpu_sum and lm_math_fpu_div directly, and by
--     lm_math_fpu_mult_cmplx transitively (via its internal
--     prod / sum instances). The enclosing module manages the
--     dv handshake at its own level, so stale internal state
--     here is unobservable to the user because the enclosing
--     module's dv_o never asserts on stale data. The pipeline
--     regs are 'U' at sim start but reach a defined value
--     after the latency documented above (2 edge-to-edge from
--     a stable input to dout_o); the enclosing module's dv
--     shift register absorbs that warm-up window. Modules with
--     FSM state (lm_math_fpu_sqrt) or reset-clearable error
--     pipelines (lm_math_fpu_div) do expose rst_n_i.
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

entity lm_math_fpu_rounding is
  generic(
    --* exponent width
    g_din_exp    : natural := 8;
    --* mantissa width
    g_din_mant   : natural := 23;
    --* rounding mode (see C_LM_ROUND_* constants)
    g_round_mode : integer := C_LM_ROUND_NEAREST
  );
  port(
    clk_i      : in  std_logic;
    sign_i     : in  std_logic;
    car_i      : in  std_logic_vector(g_din_exp - 1 downto 0);
    mantissa_i : in  std_logic_vector((2 + g_din_mant) - 1 downto 0);
    dout_o     : out std_logic_vector((1 + g_din_exp + g_din_mant) - 1 downto 0)
  );
end lm_math_fpu_rounding;

architecture a_rtl of lm_math_fpu_rounding is

  type t_rounding_mode is (round_near_s, round_tr_s, round_pinf_s, round_ninf_s);

  constant C_MAX_CAR : natural := 2**g_din_exp - 2;  -- max representable exponent

  -- compile-time decode of the mode generic
  function f_mode_state(m : integer) return t_rounding_mode is
  begin
    case m is
      when C_LM_ROUND_NEAREST => return round_near_s;
      when C_LM_ROUND_INF     => return round_pinf_s;
      when C_LM_ROUND_NEGINF  => return round_ninf_s;
      when C_LM_ROUND_ZERO    => return round_tr_s;
      when others =>
        assert false
          report "lm_math_fpu_rounding: unsupported g_round_mode value, using NEAREST"
          severity warning;
        return round_near_s;
    end case;
  end function;

  constant C_STATE : t_rounding_mode := f_mode_state(g_round_mode);

  signal s_number_in : unsigned((4 + g_din_mant) - 1 downto 0);
  signal s_number    : unsigned((2 + g_din_mant) - 1 downto 0);
  signal s_car_i_d   : unsigned(g_din_exp - 1 downto 0);
  signal s_car       : unsigned(g_din_exp - 1 downto 0);
  signal s_mantissa  : unsigned(g_din_mant - 1 downto 0);
  signal s_sign_d    : std_logic_vector(1 downto 0);  -- 2-cycle delay line for sign

begin

  -- restore the implicit MSB of the mantissa, with one extra '0' guard bit on top
  s_number_in <= '0' & '1' & unsigned(mantissa_i) when unsigned(car_i) > 0
                 else '0' & '0' & unsigned(mantissa_i);

  -- rounding step
  proc_rounding : process(clk_i)
  begin
    if rising_edge(clk_i) then
      case C_STATE is

        when round_tr_s =>
          s_number <= s_number_in(s_number_in'left downto 2);

        when round_near_s =>
          if s_number_in(1) = '0' then
            s_number <= s_number_in(s_number_in'left downto 2);
          else
            s_number <= s_number_in(s_number_in'left downto 2) + 1;
          end if;

        when round_pinf_s =>
          if s_number_in(1 downto 0) > 0 and sign_i = '0' then
            s_number <= s_number_in(s_number_in'left downto 2) + 1;
          else
            s_number <= s_number_in(s_number_in'left downto 2);
          end if;

        when round_ninf_s =>
          if s_number_in(1 downto 0) > 0 and sign_i = '1' then
            s_number <= s_number_in(s_number_in'left downto 2) + 1;
          else
            s_number <= s_number_in(s_number_in'left downto 2);
          end if;

      end case;
    end if;
  end process proc_rounding;

  -- overflow check after rounding: bump exponent if the rounding produced a
  -- carry out of the mantissa.
  -- Note: C_MAX_CAR = 2**g_din_exp - 2 is the largest finite exponent code.
  -- When s_car_i_d already holds C_MAX_CAR and the rounding overflows, the
  -- +1 below pushes the exponent to 2**g_din_exp - 1 (all-ones, the IEEE-754
  -- reserved encoding for infinity) and the mantissa is forced to zero --
  -- producing the canonical infinity representation, not an off-by-one.
  proc_go_out : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (s_number(s_number'left) = '1') and (s_car_i_d > 0) then
        -- overflow on a normalized number
        if s_car_i_d = C_MAX_CAR then
          s_mantissa <= (others => '0');             -- infinity
        else
          s_mantissa <= s_number(s_number'left - 1 downto 1);
        end if;
        s_car <= s_car_i_d + 1;
      elsif (s_number(s_number'left - 1) = '1') and (s_car_i_d = 0) then
        -- overflow on a denormalized number that just normalized
        s_car      <= s_car_i_d + 1;
        s_mantissa <= s_number(s_number'left - 1 downto 1);
      else
        s_car      <= s_car_i_d;
        s_mantissa <= s_number(s_number'left - 2 downto 0);
      end if;
    end if;
  end process proc_go_out;

  -- 2-cycle delay line for the sign, inlined (formerly an external delay primitive)
  proc_dly_sign : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_sign_d <= s_sign_d(0) & sign_i;
    end if;
  end process proc_dly_sign;

  -- 1-cycle delay on the exponent in
  proc_delay_car : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_car_i_d <= unsigned(car_i);
    end if;
  end process proc_delay_car;

  dout_o <= s_sign_d(1) & std_logic_vector(s_car) & std_logic_vector(s_mantissa);

end a_rtl;
