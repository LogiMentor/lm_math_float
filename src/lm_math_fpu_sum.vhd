--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_sum
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Sum (or subtraction) of two floating point numbers.
--               The inputs are treated as signed; depending on g_operation
--               the module computes A+B (g_operation=1) or A-B (g_operation=0).
--               Latency: 10 clock cycles (rounding included).
--
--   IEEE special inputs:
--     * If either operand is NaN, +-inf, or sets any bit of error_o, the
--       value driven on dout_o is computed from the raw mantissa /
--       exponent fields and is NOT IEEE-conformant (it is not necessarily
--       NaN or +-inf). Downstream consumers must read error_o before
--       using dout_o for these cases.
--     * Subnormal (denormal) inputs ARE handled by the data path: the
--       implicit-1 bit is suppressed via s_*_is_denorm, the alignment
--       shift in proc_augend_addend_align uses delta - 1 for the
--       normal+denormal pair, and proc_car_mant_extraction promotes the
--       result to a normal when the sum mantissa crosses the
--       2^g_data_mant boundary. error_o is left at "0000" for
--       denormal inputs.
--
--   Reset semantics:
--     This module has no rst_n_i port. The data path is purely
--     pipelined (no FSM state that survives across operations) and
--     the dv_i / dv_o handshake makes any stale internal state
--     unobservable: a consumer that respects dv_o never reads
--     dout_o or error_o while they are stale. s_dv_dly,
--     s_error_dly, s_sign_dly, s_car_large_dly and
--     s_large_denorm_dd_dly are initialized to (others => '0') at
--     elaboration, so dv_o, dv_pre_o and error_o are '0' at
--     simulation start without needing an explicit reset. Hardware
--     power-up behaviour matches when the synthesis flow honours
--     register initialization (typical FPGA targets like Xilinx /
--     Intel preserve the init; ASIC flows usually do not and
--     would need an external reset to reach the same state).
--     Modules with FSM state (lm_math_fpu_sqrt) or
--     reset-clearable error pipelines (lm_math_fpu_div) do expose
--     rst_n_i; lm_math_fpu_sum needs neither.
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

entity lm_math_fpu_sum is
  generic(
    --* exponent width
    g_data_exp   : natural := 8;
    --* mantissa width
    g_data_mant  : natural := 23;
    --* output rounding mode
    g_round_mode : integer := C_LM_ROUND_NEAREST;
    --* operation: 1 = SUM, 0 = SUBTRACTION
    g_operation  : natural := 1
  );
  port(
    clk_i    : in  std_logic;
    dv_i     : in  std_logic;
    din_a_i  : in  std_logic_vector((g_data_exp + g_data_mant + 1) - 1 downto 0);
    din_b_i  : in  std_logic_vector((g_data_exp + g_data_mant + 1) - 1 downto 0);
    dout_o   : out std_logic_vector((g_data_exp + g_data_mant + 1) - 1 downto 0);
    --* anticipates dv_o of one clock
    dv_pre_o : out std_logic;
    dv_o     : out std_logic;
    error_o  : out std_logic_vector(3 downto 0)
  );
end lm_math_fpu_sum;

architecture a_rtl of lm_math_fpu_sum is

  constant C_CAR     : natural := g_data_exp;
  constant C_MANT    : natural := g_data_mant;
  constant C_MAX_CAR : natural := 2**g_data_exp - 2;

  -- Total pipeline latency from the rising_edge that samples dv_i = '1'
  -- to the rising_edge that produces dv_o = '1'. All other alignment
  -- delays in this architecture are derived from this single value.
  constant C_PIPE_LATENCY : natural := 10;
  -- s_error: produced at cycle 2 (proc_load_data + proc_errors), so it
  -- needs C_PIPE_LATENCY - 2 stages of shift register to land at the
  -- output together with dv_o.
  constant C_ERROR_DELAY  : natural := C_PIPE_LATENCY - 2;
  -- s_dv_dly: dv_i runs through C_PIPE_LATENCY - 1 shift-register
  -- stages, then proc_delay_dv provides the final stage.
  constant C_DV_DELAY     : natural := C_PIPE_LATENCY - 1;

  signal s_dv_pre             : std_logic;
  --* registered dv_o output, initialized so the port reads '0'
  --  at sim start (before the first rising_edge of clk_i).
  signal s_dv_o               : std_logic := '0';
  signal s_sign_a             : std_logic;
  signal s_sign_b             : std_logic;
  signal s_sign_l             : std_logic;
  signal s_sign_s             : std_logic;
  signal s_car_a              : unsigned(g_data_exp - 1 downto 0);
  signal s_car_b              : unsigned(g_data_exp - 1 downto 0);
  signal s_mantissa_a         : unsigned(g_data_mant - 1 downto 0);
  signal s_mantissa_b         : unsigned(g_data_mant - 1 downto 0);
  signal s_car_small          : unsigned(C_CAR - 1 downto 0);
  signal s_car_large          : unsigned(C_CAR - 1 downto 0);
  signal s_car_large_d        : std_logic_vector(C_CAR - 1 downto 0);
  signal s_car_large_dd       : std_logic_vector(C_CAR - 1 downto 0);
  signal s_mantissa_small     : unsigned(C_MANT - 1 downto 0);
  signal s_mantissa_large     : unsigned(C_MANT - 1 downto 0);
  signal s_small_is_denorm    : std_logic;
  signal s_large_is_denorm    : std_logic;
  signal s_small_is_denorm_d  : std_logic;
  signal s_large_is_denorm_d  : std_logic;
  signal s_large_is_denorm_dd : std_logic;
  signal s_mantissa           : unsigned(2 + g_data_mant - 1 downto 0);
  signal s_sign               : std_logic;
  signal s_signs              : std_logic_vector(1 downto 0);
  signal s_equals             : std_logic;
  signal s_sign_d             : std_logic;
  signal s_car                : unsigned(g_data_exp - 1 downto 0);
  signal s_car_test           : unsigned(C_CAR - 1 downto 0);
  signal s_factor_s           : unsigned(2 + C_MANT + 1 downto 0);
  signal s_factor_s_d         : unsigned(2 + C_MANT + 1 downto 0);
  signal s_factor_l           : unsigned(2 + C_MANT + 1 downto 0);
  signal s_factor_l_d         : unsigned(2 + C_MANT + 1 downto 0);
  signal s_result             : unsigned(2 + C_MANT + 1 downto 0);
  signal s_result_d           : unsigned(2 + C_MANT + 1 downto 0);
  signal s_result_dd          : unsigned(2 + C_MANT + 1 downto 0);
  signal s_a_is_denorm        : std_logic;
  signal s_b_is_denorm        : std_logic;
  signal s_delta              : unsigned(C_CAR - 1 downto 0);
  signal s_res_shift          : unsigned(C_CAR - 1 downto 0);
  signal s_res_shift_d        : unsigned(C_CAR - 1 downto 0);
  signal s_testcar            : std_logic_vector(1 downto 0);
  signal s_go_to_sum          : std_logic;
  signal s_go_to_sum_d        : std_logic;
  signal s_error              : std_logic_vector(3 downto 0);
  signal s_error_d            : std_logic_vector(3 downto 0);

  -- inline shift registers replacing the former external delay primitive.
  -- All initialized to '0' so error_o / dv_pre_o / dv_o do not propagate
  -- 'U' during the first few cycles after elaboration.
  signal s_error_dly           : std_logic_vector(4 * C_ERROR_DELAY - 1 downto 0)
                                 := (others => '0');
  signal s_sign_dly            : std_logic_vector(4 downto 0) := (others => '0');  -- delay 5
  signal s_large_denorm_dd_dly : std_logic_vector(4 downto 0) := (others => '0');  -- delay 5
  signal s_car_large_dly       : std_logic_vector(4 * C_CAR - 1 downto 0)
                                 := (others => '0');                                -- delay 4 of C_CAR bits
  signal s_dv_dly              : std_logic_vector(C_DV_DELAY - 1 downto 0)
                                 := (others => '0');

begin

  -- error flags on the input
  proc_errors : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (f_all_ones(s_car_a) = '1') and (s_mantissa_a > 0) then
        s_error(0) <= '1';
      else
        s_error(0) <= '0';
      end if;
      if (f_all_ones(s_car_b) = '1') and (s_mantissa_b > 0) then
        s_error(1) <= '1';
      else
        s_error(1) <= '0';
      end if;
      if (f_all_ones(s_car_a) = '1') and (s_mantissa_a = 0) then
        s_error(2) <= '1';
      else
        s_error(2) <= '0';
      end if;
      if (f_all_ones(s_car_b) = '1') and (s_mantissa_b = 0) then
        s_error(3) <= '1';
      else
        s_error(3) <= '0';
      end if;
    end if;
  end process proc_errors;

  -- inline delay of error by C_ERROR_DELAY = 8 cycles, 4 bits wide
  proc_dly_error : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_error_dly <= s_error_dly(s_error_dly'left - 4 downto 0) & s_error;
    end if;
  end process proc_dly_error;
  s_error_d <= s_error_dly(s_error_dly'left downto s_error_dly'left - 3);
  error_o   <= s_error_d;

  proc_load_data : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if dv_i = '1' then
        s_sign_a <= din_a_i(din_a_i'left);
        if g_operation = 1 then
          s_sign_b <= din_b_i(din_b_i'left);
        else
          s_sign_b <= not din_b_i(din_b_i'left);
        end if;
        s_car_a      <= unsigned(din_a_i(din_a_i'left - 1
                                         downto din_a_i'left - g_data_exp));
        s_car_b      <= unsigned(din_b_i(din_b_i'left - 1
                                         downto din_b_i'left - g_data_exp));
        s_mantissa_a <= unsigned(din_a_i(din_a_i'left - g_data_exp - 1 downto 0));
        s_mantissa_b <= unsigned(din_b_i(din_b_i'left - g_data_exp - 1 downto 0));
        if unsigned(din_a_i(din_a_i'left - 1
                            downto din_a_i'left - g_data_exp)) > 0 then
          s_a_is_denorm <= '0';
        else
          s_a_is_denorm <= '1';
        end if;
        if unsigned(din_b_i(din_b_i'left - 1
                            downto din_b_i'left - g_data_exp)) > 0 then
          s_b_is_denorm <= '0';
        else
          s_b_is_denorm <= '1';
        end if;
      end if;
    end if;
  end process proc_load_data;

  -- Pick the operand with the larger magnitude as "large" and the other
  -- as "small". Tie on exponent is broken by mantissa (strict greater).
  -- When both are fully equal (s_equals = '1') the choice is irrelevant:
  -- the result is either 2*|A| (same signs) or 0 (opposite signs).
  proc_ordering : process(clk_i)
    variable v_a_is_large : boolean;
  begin
    if rising_edge(clk_i) then
      v_a_is_large := (s_car_a > s_car_b)
                   or ((s_car_a = s_car_b) and (s_mantissa_a > s_mantissa_b));
      if v_a_is_large then
        s_sign_l          <= s_sign_a;
        s_sign_s          <= s_sign_b;
        s_car_large       <= s_car_a;
        s_car_small       <= s_car_b;
        s_mantissa_large  <= s_mantissa_a;
        s_mantissa_small  <= s_mantissa_b;
        s_large_is_denorm <= s_a_is_denorm;
        s_small_is_denorm <= s_b_is_denorm;
      else
        s_sign_l          <= s_sign_b;
        s_sign_s          <= s_sign_a;
        s_car_large       <= s_car_b;
        s_car_small       <= s_car_a;
        s_mantissa_large  <= s_mantissa_b;
        s_mantissa_small  <= s_mantissa_a;
        s_large_is_denorm <= s_b_is_denorm;
        s_small_is_denorm <= s_a_is_denorm;
      end if;
      if (s_car_a = s_car_b) and (s_mantissa_a = s_mantissa_b) then
        s_equals <= '1';
      else
        s_equals <= '0';
      end if;
    end if;
  end process proc_ordering;

  s_signs <= s_sign_l & s_sign_s;

  proc_set_sum_diff : process(clk_i)
  begin
    if rising_edge(clk_i) then
      case s_signs is
        when "00" =>
          s_go_to_sum <= '1';
          s_sign      <= '0';
        when "11" =>
          s_go_to_sum <= '1';
          s_sign      <= '1';
        when "01" =>
          s_go_to_sum <= '0';
          s_sign      <= '0';
        when "10" =>
          s_go_to_sum <= '0';
          if s_equals = '1' then
            s_sign <= '0';
          else
            s_sign <= '1';
          end if;
        when others =>
          s_go_to_sum <= '1';
          s_sign      <= '0';
      end case;
    end if;
  end process proc_set_sum_diff;

  proc_delta : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_delta <= s_car_large - s_car_small;
    end if;
  end process proc_delta;

  proc_add_trailing : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_large_is_denorm = '0' then
        s_factor_l <= resize('1' & s_mantissa_large & "00", s_result'length);
      else
        s_factor_l <= resize('0' & s_mantissa_large & "00", s_result'length);
      end if;
      if s_small_is_denorm = '0' then
        s_factor_s <= resize('1' & s_mantissa_small & "00", s_result'length);
      else
        s_factor_s <= resize('0' & s_mantissa_small & "00", s_result'length);
      end if;
    end if;
  end process proc_add_trailing;

  -- proc_ordering guarantees that the operand with the larger exponent is
  -- selected as the 'large' one, so a denormal 'large' implies a denormal
  -- 'small'. The (large_denorm='1', small_denorm='0') combination is thus
  -- unreachable; we handle it defensively by treating it as the both-denorm
  -- case to avoid latched flip-flops on s_factor_l_d / s_factor_s_d.
  proc_augend_addend_align : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_large_is_denorm_d = '0' and s_small_is_denorm_d = '0' then
        s_factor_l_d <= s_factor_l;
        s_factor_s_d <= shift_right(s_factor_s, to_integer(s_delta));
      elsif s_large_is_denorm_d = '0' and s_small_is_denorm_d = '1' then
        s_factor_l_d <= s_factor_l;
        s_factor_s_d <= shift_right(s_factor_s, to_integer(s_delta) - 1);
      else  -- both denormal, or the unreachable (large denorm, small normal)
        s_factor_l_d <= s_factor_l;
        s_factor_s_d <= s_factor_s;
      end if;
    end if;
  end process proc_augend_addend_align;

  proc_sum_integer : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_go_to_sum_d = '1' then
        s_result <= s_factor_l_d + s_factor_s_d;
      else
        s_result <= s_factor_l_d - s_factor_s_d;
      end if;
    end if;
  end process proc_sum_integer;

  proc_result_shift_measure : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_result(s_result'left) = '0' then
        s_res_shift <= resize(f_count_delta(s_result), s_res_shift'length) - 1;
      else
        s_res_shift <= (others => '0');
      end if;
      s_res_shift_d <= s_res_shift;
      s_result_d    <= s_result;
      s_result_dd   <= s_result_d;
    end if;
  end process proc_result_shift_measure;

  proc_result_shift : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if unsigned(s_car_large_d) > s_res_shift then
        s_car_test <= unsigned(s_car_large_d) - s_res_shift;
        s_testcar  <= "11";
      elsif unsigned(s_car_large_d) = s_res_shift then
        s_car_test <= (others => '0');
        s_testcar  <= "01";
      else
        s_car_test <= (others => '0');
        s_testcar  <= "00";
      end if;
    end if;
  end process proc_result_shift;

  proc_car_mant_extraction : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_result_dd = 0 then
        s_car      <= (others => '0');
        s_mantissa <= (others => '0');
      elsif s_car_test = C_MAX_CAR + 1 then
        s_car      <= s_car_test;
        s_mantissa <= (others => '0');
      elsif (s_car_test = C_MAX_CAR) and (s_result_dd(s_result_dd'left) = '1') then
        s_car      <= s_car_test + 1;
        s_mantissa <= (others => '0');
      elsif s_result_dd(s_result_dd'left) = '1' then
        s_car      <= s_car_test + 1;
        s_mantissa <= s_result_dd(s_result_dd'left - 1 downto 1);
      elsif (s_result_dd(s_result_dd'left) = '0')
            and (s_result_dd(s_result_dd'left - 1) = '1') then
        if s_large_is_denorm_dd = '0' then
          s_car <= s_car_test;
        else
          s_car <= s_car_test + 1;
        end if;
        s_mantissa <= s_result_dd(s_result_dd'left - 2 downto 0);
      else
        if s_testcar = "11" then
          s_car      <= s_car_test;
          s_mantissa <= shift_left(s_result_dd, to_integer(s_res_shift_d) + 2)
                                  (s_result_dd'left downto 2);
        elsif s_testcar = "01" then
          s_car      <= (others => '0');
          s_mantissa <= shift_left(s_result_dd, to_integer(s_res_shift_d) + 2)
                                  (s_result_dd'left downto 2);
        else
          s_car <= (others => '0');
          if unsigned(s_car_large_dd) = 0 then
            s_mantissa <= shift_left(s_result_dd,
                                     to_integer(unsigned(s_car_large_dd)) + 2)
                                    (s_result_dd'left downto 2);
          else
            s_mantissa <= shift_left(s_result_dd,
                                     to_integer(unsigned(s_car_large_dd)) + 1)
                                    (s_result_dd'left downto 2);
          end if;
        end if;
      end if;
    end if;
  end process proc_car_mant_extraction;

  ----------------------------------------------------------------------------
  -- inline pipeline delays (replacing the former external delay primitives)
  ----------------------------------------------------------------------------
  proc_dly_misc : process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- sign delayed by 5
      s_sign_dly <= s_sign_dly(3 downto 0) & s_sign;
      -- large_is_denorm delayed by 1 (was inst_delay_large_denorm_trig)
      s_large_is_denorm_d <= s_large_is_denorm;
      -- large_is_denorm delayed by 5 (was inst_delay_large_denorm_car_use)
      s_large_denorm_dd_dly <= s_large_denorm_dd_dly(3 downto 0) & s_large_is_denorm;
      -- small_is_denorm delayed by 1 (was inst_delay_small_denorm_trig)
      s_small_is_denorm_d <= s_small_is_denorm;
      -- go_to_sum delayed by 1
      s_go_to_sum_d <= s_go_to_sum;
      -- car_large delayed by 4 (multi-bit shift register)
      s_car_large_dly <= s_car_large_dly(s_car_large_dly'left - C_CAR downto 0)
                         & std_logic_vector(s_car_large);
      -- car_large delayed by 5 total = 4 + 1
      s_car_large_dd <= s_car_large_d;
      -- dv delayed by C_DV_DELAY = 9; proc_delay_dv adds the final stage
      s_dv_dly <= s_dv_dly(s_dv_dly'left - 1 downto 0) & dv_i;
    end if;
  end process proc_dly_misc;

  s_sign_d             <= s_sign_dly(4);
  s_large_is_denorm_dd <= s_large_denorm_dd_dly(4);
  s_car_large_d        <= s_car_large_dly(s_car_large_dly'left
                                          downto s_car_large_dly'left - C_CAR + 1);
  s_dv_pre             <= s_dv_dly(s_dv_dly'left);
  dv_pre_o             <= s_dv_pre;

  -- dv_o is registered through an initialized internal signal so the
  -- port has a defined '0' value at sim start, before the first
  -- rising_edge. Without the init the port would propagate 'U' for
  -- one cycle and contaminate downstream consumers that watch dv_o
  -- combinationally (handshake monitors, assertions, etc.).
  proc_delay_dv : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_dv_o <= s_dv_pre;
    end if;
  end process proc_delay_dv;

  dv_o <= s_dv_o;

  ----------------------------------------------------------------------------

  inst_lm_math_fpu_round : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_data_exp,
      g_din_mant   => g_data_mant,
      g_round_mode => g_round_mode
    )
    port map(
      clk_i      => clk_i,
      sign_i     => s_sign_d,
      mantissa_i => std_logic_vector(s_mantissa),
      car_i      => std_logic_vector(s_car),
      dout_o     => dout_o
    );

end a_rtl;
