--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_sqrt
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Square root of a floating point input.
--
--   value = (-1)^sign * 1.M * 2^E
--   sqrt(value) = sqrt(1.M) * 2^(E/2)
--
--   If E is even: significand stays in [1, 2), result exponent = E/2.
--   If E is odd : significand becomes sqrt(2*1.M) in [sqrt(2), 2),
--                 result exponent = (E-1)/2.
--
--   Implementation: classic binary digit-by-digit square root. A 2K-bit
--   scaled mantissa X is fed to a K-cycle compare-subtract loop that
--   produces the K most significant bits of sqrt(X). K = g_data_mant + 1.
--
--   Latency from enable_i = '1' to done_o = '1' is approximately K + 1
--   clock cycles. The result is held on dout_o while done_o = '1';
--   pulling enable_i back to '0' returns the FSM to idle, ready for a
--   new conversion (no reset is required between conversions).
--
--   Special cases handled:
--     * +0 / -0 -> +0,          done_o='1', error_o='0'
--     * +inf    -> +inf,        done_o='1', error_o='0'
--     * NaN     -> NaN passthrough (sign + payload preserved), error_o='1'
--     * negative non-zero (incl. -inf, negative finite, negative denormal)
--                -> canonical quiet NaN (sign='0', mant MSB='1'), error_o='1'
--     * positive denormal input -> +0, error_o='1'
--                (denormal support not implemented)
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

entity lm_math_fpu_sqrt is
  generic(
    --* exponent width of input
    g_data_exp         : natural := 11;
    --* mantissa width of input
    g_data_mant        : natural := 52;
    --* DEPRECATED, no-op. The 2.0.0 release gated this entity behind
    --  g_acknowledge_todo because the FSM was a known TODO. The 3.0.0
    --  rewrite removed the gate but the generic is kept here as a
    --  no-op so any existing instantiations that set
    --  `g_acknowledge_todo => true` still analyze. New code should not
    --  reference this generic.
    g_acknowledge_todo : boolean := false
  );
  port(
    clk_i    : in  std_logic;
    rst_n_i  : in  std_logic;
    enable_i : in  std_logic;
    number_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    dout_o   : out std_logic_vector(g_data_exp + g_data_mant downto 0);
    done_o   : out std_logic;
    error_o  : out std_logic
  );
end lm_math_fpu_sqrt;

architecture a_rtl of lm_math_fpu_sqrt is

  constant C_BIAS : natural := 2**(g_data_exp - 1) - 1;
  --* number of significand bits (mantissa + implicit 1)
  constant K      : natural := g_data_mant + 1;

  type t_state is (s_idle, s_busy, s_done);

  signal s_state    : t_state := s_idle;
  --* iteration counter: counts K, K-1, ..., 1 during s_busy
  signal s_cnt      : natural range 0 to K := 0;

  --* radicand: mantissa scaled to a 2K-bit value, fed to the
  --  digit-by-digit sqrt loop. It is not generally a perfect square --
  --  for irrational results the loop produces floor(sqrt(s_x)).
  signal s_x        : unsigned(2 * K - 1 downto 0) := (others => '0');
  --* partial result accumulator (K bits, MSB = implicit '1' of result)
  signal s_q        : unsigned(K - 1 downto 0) := (others => '0');
  --* running remainder; needs K+2 bits to hold "(R<<2) | pair"
  signal s_r        : unsigned(K + 1 downto 0) := (others => '0');

  --* full output word, latched on completion (normal or special)
  signal s_dout_reg : std_logic_vector(g_data_exp + g_data_mant downto 0)
                      := (others => '0');
  signal s_error    : std_logic := '0';

begin

  proc_fsm : process(clk_i)
    variable v_sign       : std_logic;
    variable v_car        : unsigned(g_data_exp - 1 downto 0);
    variable v_mant       : unsigned(g_data_mant - 1 downto 0);
    variable v_m_int      : unsigned(K - 1 downto 0);
    variable v_all_ones   : unsigned(g_data_exp - 1 downto 0);
    variable v_car_sum    : unsigned(g_data_exp downto 0);
    variable v_car_out    : unsigned(g_data_exp - 1 downto 0);
    variable v_pair       : unsigned(1 downto 0);
    variable v_r_shift    : unsigned(K + 1 downto 0);
    variable v_t          : unsigned(K + 1 downto 0);
    variable v_q_next     : unsigned(K - 1 downto 0);
  begin
    if rising_edge(clk_i) then
      v_all_ones := (others => '1');

      if rst_n_i = '0' then
        s_state    <= s_idle;
        s_cnt      <= 0;
        s_q        <= (others => '0');
        s_r        <= (others => '0');
        s_x        <= (others => '0');
        s_dout_reg <= (others => '0');
        s_error    <= '0';
      else
        case s_state is

          --------------------------------------------------------------------
          when s_idle =>
            if enable_i = '1' then
              v_sign := number_i(number_i'left);
              v_car  := unsigned(number_i(number_i'left - 1
                                          downto number_i'left - g_data_exp));
              v_mant := unsigned(number_i(number_i'left - g_data_exp - 1 downto 0));

              -- significand with implicit 1 for normals (M_int has K bits)
              if v_car > 0 then
                v_m_int := '1' & v_mant;
              else
                v_m_int := '0' & v_mant;
              end if;

              -- result exponent (only used by the normal path):
              -- car_out = floor((car_in + bias) / 2). Works for both even
              -- and odd unbiased exponents because C_BIAS is odd.
              v_car_sum := resize(v_car, g_data_exp + 1)
                           + to_unsigned(C_BIAS, g_data_exp + 1);
              v_car_out := v_car_sum(g_data_exp downto 1);

              -- ---- special-case dispatch -----------------------------
              -- NaN must be checked BEFORE the negative branch, otherwise
              -- a negative NaN (sign='1', car=all-ones, mant /= 0) would
              -- be misclassified as a generic negative input and lose
              -- its payload.
              if v_car = v_all_ones and v_mant /= 0 then
                -- NaN (any sign) -> NaN passthrough: preserve sign and
                -- mantissa payload, set error_o.
                s_dout_reg <= v_sign
                              & std_logic_vector(v_all_ones)
                              & std_logic_vector(v_mant);
                s_error    <= '1';
                s_state    <= s_done;
              elsif v_sign = '1' and (v_car /= 0 or v_mant /= 0) then
                -- negative non-zero (finite or -inf): NaN, error
                s_dout_reg <= '0'
                              & std_logic_vector(v_all_ones)
                              & '1' & std_logic_vector(to_unsigned(0, g_data_mant - 1));
                s_error    <= '1';
                s_state    <= s_done;
              elsif v_car = 0 and v_mant = 0 then
                -- +/-0 -> +0
                s_dout_reg <= (others => '0');
                s_error    <= '0';
                s_state    <= s_done;
              elsif v_car = v_all_ones then
                -- +inf -> +inf (negatives, NaNs already caught above)
                s_dout_reg <= '0'
                              & std_logic_vector(v_all_ones)
                              & std_logic_vector(to_unsigned(0, g_data_mant));
                s_error    <= '0';
                s_state    <= s_done;
              elsif v_car = 0 then
                -- denormal: not implemented, return zero with error
                s_dout_reg <= (others => '0');
                s_error    <= '1';
                s_state    <= s_done;
              else
                -- normal positive input: run the algorithm
                s_error <= '0';

                -- Prepare X as the 2K-bit scaled radicand for the
                -- compare-subtract square-root iteration (not generally
                -- a perfect square: floor(sqrt(X)) is what the loop
                -- produces).
                -- Bias is odd, so:
                --   E_in even <-> car_in odd  -> X = M_int << (K-1) (1 pad bit at top)
                --   E_in odd  <-> car_in even -> X = M_int <<  K    (no padding)
                if v_car(0) = '1' then  -- E_in even
                  s_x <= shift_left(resize(v_m_int, 2 * K), K - 1);
                else                     -- E_in odd
                  s_x <= shift_left(resize(v_m_int, 2 * K), K);
                end if;

                s_q   <= (others => '0');
                s_r   <= (others => '0');
                s_cnt <= K;

                -- preload the result exponent / sign for use at completion
                s_dout_reg <= '0'
                              & std_logic_vector(v_car_out)
                              & std_logic_vector(to_unsigned(0, g_data_mant));

                s_state <= s_busy;
              end if;
            end if;

          --------------------------------------------------------------------
          when s_busy =>
            -- One digit-by-digit step of binary sqrt:
            --   pair  = next 2 bits of X (MSB first)
            --   R     = (R << 2) | pair
            --   T     = (Q << 2) | 1     -- == 4Q + 1
            --   if R >= T: Q := (Q << 1) | 1, R := R - T
            --   else:       Q := (Q << 1)
            v_pair    := s_x(2 * s_cnt - 1 downto 2 * s_cnt - 2);
            v_r_shift := s_r(K - 1 downto 0) & v_pair;
            v_t       := s_q & "01";

            if v_r_shift >= v_t then
              v_q_next := s_q(K - 2 downto 0) & '1';
              s_q <= v_q_next;
              s_r <= v_r_shift - v_t;
            else
              v_q_next := s_q(K - 2 downto 0) & '0';
              s_q <= v_q_next;
              s_r <= v_r_shift;
            end if;

            if s_cnt = 1 then
              -- last iteration: drop the implicit '1' (MSB of Q) and pack
              -- the K-1 low bits into the mantissa field of the output.
              s_dout_reg(g_data_mant - 1 downto 0)
                <= std_logic_vector(v_q_next(K - 2 downto 0));
              s_state <= s_done;
            else
              s_cnt <= s_cnt - 1;
            end if;

          --------------------------------------------------------------------
          when s_done =>
            -- hold output, return to idle when the caller releases enable_i
            if enable_i = '0' then
              s_state <= s_idle;
              s_error <= '0';
            end if;

        end case;
      end if;
    end if;
  end process proc_fsm;

  done_o  <= '1' when s_state = s_done else '0';
  dout_o  <= s_dout_reg;
  error_o <= s_error;

end a_rtl;
