--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_div
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Division of two floating point numbers. The mantissa
--               long-division is delegated to lm_math_int_div; the rounder
--               is lm_math_fpu_rounding. Latency is approximately
--               g_data_mant + a few extra cycles for exponent / sign
--               handling.
--
--   error_o layout (7 bits):
--     Bits 0..5 classify the input operands (driven by proc_errors,
--     one cycle after dv_i); the "IEEE-expected result" column is
--     the IEEE-754 answer for that input class, NOT the value the
--     module actually drives on quotient_o (see below).
--         bit 0 : A finite, B = +-inf     (IEEE result: +-0)
--         bit 1 : A is NaN                 (IEEE result: NaN)
--         bit 2 : B is NaN                 (IEEE result: NaN)
--         bit 3 : +-inf / +-inf            (IEEE result: NaN)
--         bit 4 : +-inf / finite           (IEEE result: +-inf)
--         bit 5 : A finite, B = +-0        (IEEE result: +-inf,
--                                           div-by-zero exception)
--     Bit 6 is independent of the input class: it is the numeric
--     over-range flag produced by proc_final when s_car_res exceeds
--     C_MAX_CAR (the unbiased exponent goes above the normal range).
--     It can be set for inputs that look "normal" if the magnitude
--     of the quotient overflows.
--
--   IEEE conformance contract:
--     When ANY bit of error_o is set, the value driven on
--     quotient_o is computed from the raw mantissa / exponent
--     fields and is NOT IEEE-conformant. The bullets above
--     describe what the IEEE-correct answer would be, not what the
--     module actually outputs. Consumers must read error_o before
--     using quotient_o.
--
--   Subnormal handling (partial):
--     * Denormal operands are accepted: proc_load_numer / proc_load_denom
--       drive the mantissa without an implicit '1', and the
--       proc_adjust_operands shift-left normalizes both sides for
--       the integer divider.
--     * proc_final's "else" branch (s_car_res < 0) shifts the integer
--       result right by -s_car_res to produce a denormal-magnitude
--       output, i.e. a real (not flush-to-zero) subnormal result.
--       lm_math_fpu_sum also produces real subnormal outputs via its
--       own data-path (validated by tb_lm_math_fpu_sum's denormal
--       phase); lm_math_fpu_prod, in contrast, uses FTZ.
--     * error_o is NOT set for either case; subnormal arithmetic is
--       silent. The integration with the rest of the library
--       (which is FTZ-leaning) has not been validated by the TB.
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

entity lm_math_fpu_div is
  generic(
    --* exponent width
    g_data_exp   : natural := 8;
    --* mantissa width
    g_data_mant  : natural := 23;
    --* how many compare-subtract steps per cycle in the integer divider
    g_chunk_size : natural := 4;
    --* rounding mode
    g_round_mode : integer := C_LM_ROUND_NEAREST
  );
  port(
    clk_i      : in  std_logic;
    rst_n_i    : in  std_logic;
    dv_i       : in  std_logic;
    dividend_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    divisor_i  : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    quotient_o : out std_logic_vector(g_data_exp + g_data_mant downto 0);
    dv_o       : out std_logic;
    error_o    : out std_logic_vector(6 downto 0)
  );
end lm_math_fpu_div;

architecture a_rtl of lm_math_fpu_div is

  constant C_BIAS           : natural := 2**(g_data_exp - 1) - 1;
  constant C_MAX_CAR        : integer := 2**g_data_exp - 2;
  constant C_DATA_W         : natural := g_data_mant + 1;
  constant C_LATENCY        : natural := f_div_ceil(C_DATA_W, g_chunk_size);
  constant C_INTDIV_LATENCY : natural := f_div_ceil(C_DATA_W + 1, g_chunk_size);

  type t_scar      is array (0 to C_LATENCY + 3) of signed(g_data_exp downto 0);
  type t_scar_long is array (0 to C_LATENCY + 3) of signed(g_data_exp + 2 downto 0);
  type t_error     is array (0 to C_LATENCY + 15) of std_logic_vector(5 downto 0);

  signal s_error           : t_error;
  signal s_error_x         : std_logic_vector(0 to 10);
  signal s_sign            : std_logic_vector(0 to C_LATENCY + 5);
  signal s_sign_a          : std_logic;
  signal s_sign_b          : std_logic;
  signal s_car_a           : t_scar;
  signal s_mant_a          : unsigned(g_data_mant - 1 downto 0);
  signal s_car_b           : t_scar;
  signal s_mant_b          : unsigned(g_data_mant - 1 downto 0);
  signal s_car_num         : signed(g_data_exp downto 0);
  signal s_car_den         : signed(g_data_exp downto 0);
  signal s_car_res         : t_scar_long;
  signal s_car             : unsigned(g_data_exp - 1 downto 0);
  signal s_mant            : std_logic_vector(g_data_mant + 1 downto 0);
  signal s_delta_num       : unsigned(g_data_exp - 1 downto 0);
  signal s_delta_den       : unsigned(g_data_exp - 1 downto 0);
  signal s_delta_num_d     : unsigned(g_data_exp - 1 downto 0);
  signal s_delta_den_d     : unsigned(g_data_exp - 1 downto 0);
  signal s_numer           : unsigned(g_data_mant downto 0);
  signal s_denom           : unsigned(g_data_mant downto 0);
  signal s_numer_d         : unsigned(g_data_mant downto 0);
  signal s_denom_d         : unsigned(g_data_mant downto 0);
  signal s_dv              : std_logic_vector(0 to C_LATENCY + 10);
  signal s_int_res         : std_logic_vector(g_data_mant + 1 downto 0);
  signal s_int_res_d       : std_logic_vector(g_data_mant + 1 downto 0);

begin

  s_sign(0) <= s_sign_a xor s_sign_b;

  proc_load_data : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if dv_i = '1' then
        s_sign_a   <= dividend_i(dividend_i'left);
        s_sign_b   <= divisor_i(divisor_i'left);
        s_car_a(0) <= signed(std_logic_vector(
                        '0' & unsigned(dividend_i(dividend_i'left - 1
                                                  downto dividend_i'left - g_data_exp))));
        s_car_b(0) <= signed(std_logic_vector(
                        '0' & unsigned(divisor_i(divisor_i'left - 1
                                                 downto divisor_i'left - g_data_exp))));
        s_mant_a   <= unsigned(dividend_i(dividend_i'left - g_data_exp - 1 downto 0));
        s_mant_b   <= unsigned(divisor_i(divisor_i'left - g_data_exp - 1 downto 0));
      end if;
    end if;
  end process proc_load_data;

  proc_load_numer : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_car_a(0) > 0 then
        s_numer <= '1' & s_mant_a;
      else
        s_numer <= s_mant_a & '0';
      end if;
    end if;
  end process proc_load_numer;

  proc_load_denom : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_car_b(0) > 0 then
        s_denom <= '1' & s_mant_b;
      else
        s_denom <= s_mant_b & '0';
      end if;
    end if;
  end process proc_load_denom;

  s_delta_num <= resize(f_count_delta(s_numer), s_delta_num'length);
  s_delta_den <= resize(f_count_delta(s_denom), s_delta_den'length);

  proc_adjust_operands : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_numer_d <= shift_left(s_numer, to_integer(s_delta_num));
      s_denom_d <= shift_left(s_denom, to_integer(s_delta_den));
    end if;
  end process proc_adjust_operands;

  inst_integer_div : entity lm_math_float_lib.lm_math_int_div(a_rtl_compare_short)
    generic map(
      g_data_w        => C_DATA_W,
      g_quotient_size => C_DATA_W + 1,
      g_chunk_size    => g_chunk_size
    )
    port map(
      clk_i      => clk_i,
      dv_i       => s_dv(3),
      dividend_i => std_logic_vector(s_numer_d),
      divisor_i  => std_logic_vector(s_denom_d),
      dv_o       => open,
      quotient_o => s_int_res
    );

  proc_char : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_delta_num_d <= s_delta_num;
      s_delta_den_d <= s_delta_den;
      s_car_num <= s_car_a(1)
                   - signed(std_logic_vector('0' & s_delta_num));
      s_car_den <= s_car_b(1)
                   - signed(std_logic_vector('0' & s_delta_den));
      s_car_res(0) <= resize(s_car_num - s_car_den, s_car_res(0)'length);
      s_car_res(1) <= s_car_res(0) + C_BIAS;
    end if;
  end process proc_char;

  proc_pre_final : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_int_res(s_int_res'left) = '0' then
        s_car_res(C_INTDIV_LATENCY) <= s_car_res(C_INTDIV_LATENCY - 1) - 1;
        s_int_res_d                 <= s_int_res(s_int_res'left - 1 downto 0) & '0';
      else
        s_car_res(C_INTDIV_LATENCY) <= s_car_res(C_INTDIV_LATENCY - 1);
        s_int_res_d                 <= s_int_res;
      end if;
    end if;
  end process proc_pre_final;

  proc_final : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_car        <= (others => '0');
        s_mant       <= (others => '0');
        s_error_x(0) <= '0';
      elsif s_car_res(C_INTDIV_LATENCY) > C_MAX_CAR then
        s_car        <= (others => '1');
        s_mant       <= s_int_res_d(s_int_res_d'left - 1 downto 0) & '0';
        s_error_x(0) <= '1';
      elsif s_car_res(C_INTDIV_LATENCY) > 0 then
        s_car        <= unsigned(std_logic_vector(
                          s_car_res(C_INTDIV_LATENCY)(g_data_exp - 1 downto 0)));
        s_mant       <= s_int_res_d(s_int_res_d'left - 1 downto 0) & '0';
        s_error_x(0) <= '0';
      elsif s_car_res(C_INTDIV_LATENCY) = 0 then
        s_car        <= (others => '0');
        s_mant       <= s_int_res_d;
        s_error_x(0) <= '0';
      else
        s_car        <= (others => '0');
        s_mant       <= std_logic_vector(shift_right(unsigned(s_int_res_d),
                                                     to_integer(-s_car_res(C_INTDIV_LATENCY))));
        s_error_x(0) <= '0';
      end if;
    end if;
  end process proc_final;

  s_dv(0) <= dv_i;

  dv_o    <= s_dv(C_INTDIV_LATENCY + 7);
  -- error_o bit 6 = s_error_x(2): over-range flag, produced by proc_final
  -- (cycle C_INTDIV_LATENCY + 5 from input) and delayed 2 more cycles to
  -- align with dv_o (cycle C_INTDIV_LATENCY + 7).
  -- error_o bits 5..0 = s_error: each bit comes out of proc_errors 2
  -- cycles after the input (load + decode). Indexing at +5 (vs. the
  -- legacy +7) trims those two extra delay stages so the 6 input-class
  -- flags line up with dv_o and with the over-range bit.
  error_o <= s_error_x(2) & s_error(C_INTDIV_LATENCY + 5);

  gen_car_res : for i in 1 to C_INTDIV_LATENCY - 2 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_car_res(i + 1) <= s_car_res(i);
      end if;
    end process;
  end generate gen_car_res;

  gen_dv : for i in 0 to C_LATENCY + 8 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_dv(i + 1) <= s_dv(i);
      end if;
    end process;
  end generate gen_dv;

  gen_car : for i in 0 to C_LATENCY + 2 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_car_a(i + 1) <= s_car_a(i);
        s_car_b(i + 1) <= s_car_b(i);
      end if;
    end process;
  end generate gen_car;

  gen_sign : for i in 0 to C_LATENCY + 4 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign(i + 1) <= s_sign(i);
      end if;
    end process;
  end generate gen_sign;

  gen_error : for i in 0 to s_error'length - 2 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        if rst_n_i = '0' then
          s_error(i + 1) <= (others => '0');
        else
          s_error(i + 1) <= s_error(i);
        end if;
      end if;
    end process;
  end generate gen_error;

  gen_error_x : for i in 0 to s_error_x'length - 2 generate
    process(clk_i)
    begin
      if rising_edge(clk_i) then
        if rst_n_i = '0' then
          s_error_x(i + 1) <= '0';
        else
          s_error_x(i + 1) <= s_error_x(i);
        end if;
      end if;
    end process;
  end generate gen_error_x;

  inst_lm_math_fpu_round : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_data_exp,
      g_din_mant   => g_data_mant,
      g_round_mode => g_round_mode
    )
    port map(
      clk_i      => clk_i,
      sign_i     => s_sign(C_INTDIV_LATENCY + 4),
      mantissa_i => s_mant,
      car_i      => std_logic_vector(s_car),
      dout_o     => quotient_o
    );

  -- error flags on the inputs. Each bit is fully (re)evaluated every cycle
  -- so error_o never latches stale flags between dv_i pulses; the inputs
  -- (s_car_a, s_car_b, s_mant_a, s_mant_b) are themselves only refreshed
  -- on dv_i = '1' via proc_load_data, so the flags effectively describe
  -- "the most recently latched operand pair".
  proc_errors : process(clk_i)
    -- Local views of the per-cycle input class. s_car_a(0) and
    -- s_car_b(0) are signed(g_data_exp downto 0); the bottom g_data_exp
    -- bits hold the raw biased exponent field, and we test them via
    -- f_all_ones / equality to 0.
    variable v_car_a_field : unsigned(g_data_exp - 1 downto 0);
    variable v_car_b_field : unsigned(g_data_exp - 1 downto 0);
    variable v_a_is_inf    : boolean;
    variable v_b_is_inf    : boolean;
    variable v_a_is_nan    : boolean;
    variable v_b_is_nan    : boolean;
    variable v_b_is_zero   : boolean;
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        -- Reset s_error(0) only. gen_error below (one process per
        -- pipeline stage) is responsible for clearing the rest of the
        -- shift register on rst -- driving s_error(1..N) from here
        -- would create multiple drivers on those signals (gen_error
        -- also writes them every cycle) and the std_logic resolution
        -- would turn the whole pipeline into 'X' under reset.
        s_error(0) <= (others => '0');
      else
        v_car_a_field := unsigned(std_logic_vector(
                           s_car_a(0)(g_data_exp - 1 downto 0)));
        v_car_b_field := unsigned(std_logic_vector(
                           s_car_b(0)(g_data_exp - 1 downto 0)));
        v_a_is_inf    := f_all_ones(v_car_a_field) = '1' and s_mant_a = 0;
        v_b_is_inf    := f_all_ones(v_car_b_field) = '1' and s_mant_b = 0;
        v_a_is_nan    := f_all_ones(v_car_a_field) = '1' and s_mant_a > 0;
        v_b_is_nan    := f_all_ones(v_car_b_field) = '1' and s_mant_b > 0;
        v_b_is_zero   := v_car_b_field = 0 and s_mant_b = 0;

        -- bit 0: result is 0 (finite / +-inf)
        if not (v_a_is_inf or v_a_is_nan) and v_b_is_inf then
          s_error(0)(0) <= '1';
        else
          s_error(0)(0) <= '0';
        end if;

        -- bit 1: dividend is NaN
        if v_a_is_nan then s_error(0)(1) <= '1'; else s_error(0)(1) <= '0'; end if;
        -- bit 2: divisor is NaN
        if v_b_is_nan then s_error(0)(2) <= '1'; else s_error(0)(2) <= '0'; end if;

        -- bits 3 and 4: +-inf / +-inf (undetermined) vs +-inf / finite.
        -- Both bits driven on every branch so neither latches.
        if v_a_is_inf and v_b_is_inf then
          s_error(0)(3) <= '1';
          s_error(0)(4) <= '0';
        elsif v_a_is_inf and not (v_b_is_inf or v_b_is_nan) then
          s_error(0)(3) <= '0';
          s_error(0)(4) <= '1';
        else
          s_error(0)(3) <= '0';
          s_error(0)(4) <= '0';
        end if;

        -- bit 5: divide-by-zero (finite / +-0)
        if not (v_a_is_inf or v_a_is_nan) and v_b_is_zero then
          s_error(0)(5) <= '1';
        else
          s_error(0)(5) <= '0';
        end if;
      end if;
    end if;
  end process proc_errors;

end a_rtl;
