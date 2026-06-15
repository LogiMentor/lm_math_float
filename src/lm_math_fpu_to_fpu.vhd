--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_to_fpu
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Conversion between two floating point sizes (different
--               exponent and/or mantissa width).
--
--   Supported generic combinations (covered by the two internal
--   generate branches):
--     A. gen_small_to_large : g_din_exp < g_dout_exp AND
--                             g_din_mant < g_dout_mant.
--                             Both fields strictly grow.
--     B. gen_large_to_small : g_din_exp > g_dout_exp AND
--                             g_din_mant >= g_dout_mant + 2.
--                             Both fields strictly shrink, mantissa
--                             by at least 2 bits (the branch needs
--                             s_mant_in(g_din_mant - g_dout_mant - 2)
--                             for rounding).
--   Equal sizes and mixed cases (one field grows while the other
--   shrinks) are NOT implemented and trigger an elaboration
--   assertion failure via C_SHAPE_OK.
--
--   Subnormal handling (gen_small_to_large):
--     A denormal input is shifted left until the leading 1 reaches
--     the implicit-MSB position and the exponent is decreased by
--     the shift count; the result is a normal-encoded small-to-
--     large equivalent of the original denormal value. An exact
--     +-0 input is detected before that step by an explicit
--     zero-detect leg, so it does not "normalize" into a tiny
--     non-zero value.
--
--   IEEE special inputs (NOT preserved):
--     NaN and +-inf are processed by the same arithmetic data path
--     as normals and lose their IEEE classification:
--       * gen_small_to_large: the exponent is bias-shifted by
--         proc_make_char (s_car_test_1 = s_car_in + C_DELTA_BIAS),
--         so an all-ones input exponent does NOT come out all-ones
--         in the output -- the input infinity / NaN becomes a
--         very-large finite number.
--       * gen_large_to_small: the overflow guard in
--         proc_make_mantissa_test forces the output mantissa to 0
--         when s_car_in exceeds the representable range, so an
--         input NaN (large car, non-zero mantissa) collapses to
--         +-infinity (large car, zero mantissa) in the output.
--     No error_o is exposed. Consumers needing IEEE-strict
--     special-case handling must check for NaN / +-inf BEFORE
--     feeding the value to this module.
--
--   Latency:
--     The table below lists both the data-path pipeline stage count
--     and the rising_edge-to-rising_edge dv_i -> dv_o delay (the
--     repo convention used by lm_math_fpu_sum's "Latency: 10
--     clocks"):
--                          stages   dv_i -> dv_o
--       gen_small_to_large :   2         1 clock
--       gen_large_to_small :   3         2 clocks
--                              (includes the mantissa-rounding
--                               stage)
--
--   Reset semantics:
--     This module has no rst_n_i port. The data path is purely
--     pipelined (no FSM state that survives across operations) and
--     the dv_i / dv_o handshake makes any stale internal state
--     unobservable: a consumer that respects dv_o never reads
--     dout_o while it is stale. Both generate branches carry their
--     own dv pipeline. gen_small_to_large registers dv_i through
--     s_dv -> s_dv_o (both init '0') and drives dv_o via a
--     concurrent assignment from s_dv_o; gen_large_to_small uses
--     s_dv_sr (init (others => '0')) and drives dv_o concurrently
--     from its rightmost stage. Both paths therefore present dv_o
--     = '0' at simulation start without needing an explicit reset
--     (gen_small_to_large registers dv_o through the initialized
--     s_dv_o for this reason). Hardware
--     power-up behaviour matches when the synthesis flow honours
--     register initialization (typical FPGA targets like Xilinx /
--     Intel preserve the init; ASIC flows usually do not and
--     would need an external reset to reach the same state).
--     Modules with FSM state (lm_math_fpu_sqrt) or
--     reset-clearable error pipelines (lm_math_fpu_div) do expose
--     rst_n_i; lm_math_fpu_to_fpu needs neither.
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

entity lm_math_fpu_to_fpu is
  generic(
    --* exponent width of input
    g_din_exp   : natural := 10;
    --* mantissa width of input
    g_din_mant  : natural := 30;
    --* exponent width of output
    g_dout_exp  : natural := 8;
    --* mantissa width of output
    g_dout_mant : natural := 23
  );
  port(
    clk_i       : in  std_logic;
    dv_i        : in  std_logic;
    float_in_i  : in  std_logic_vector(g_din_exp + g_din_mant downto 0);
    float_out_o : out std_logic_vector(g_dout_exp + g_dout_mant downto 0);
    dv_o        : out std_logic
  );
end lm_math_fpu_to_fpu;

architecture a_rtl of lm_math_fpu_to_fpu is

  -- supported configurations: both input fields strictly grow, or both
  -- strictly shrink. The large-to-small path additionally indexes
  -- s_mant_in(g_din_mant - g_dout_mant - 2), so the mantissa must shrink
  -- by at least 2 bits. Equal sizes and mixed cases (one grows, the
  -- other shrinks) are NOT implemented and would leave the data path
  -- undriven.
  constant C_SHAPE_OK : boolean :=
    (g_din_exp < g_dout_exp and g_din_mant < g_dout_mant)
    or (g_din_exp > g_dout_exp and g_din_mant >= g_dout_mant + 2);

  constant C_BIAS_IN     : natural := 2**(g_din_exp - 1) - 1;
  constant C_BIAS_OUT    : natural := 2**(g_dout_exp - 1) - 1;
  constant C_DELTA_BIAS  : integer := C_BIAS_OUT - C_BIAS_IN;
  constant C_MAX_CAR_OUT : integer := 2**g_dout_exp - 2;

  signal s_sign_in    : std_logic;
  signal s_car_in     : unsigned(g_din_exp - 1 downto 0);
  signal s_car_in_d   : unsigned(g_din_exp - 1 downto 0);
  signal s_mant_in    : unsigned(g_din_mant - 1 downto 0);
  signal s_sign_out   : std_logic;
  signal s_sign_d     : std_logic;
  signal s_car_out    : unsigned(g_dout_exp - 1 downto 0);
  signal s_mant_test  : unsigned(g_dout_mant - 1 downto 0);
  signal s_mant_out   : unsigned(g_dout_mant - 1 downto 0);
  signal s_car_test_2 : unsigned(g_din_exp - 1 downto 0);
  signal s_car_test_1 : unsigned(g_dout_exp - 1 downto 0);
  signal s_delta      : unsigned(g_din_exp - 1 downto 0);
  signal s_shift      : unsigned(6 downto 0);

begin

  assert C_SHAPE_OK
    report "lm_math_fpu_to_fpu: unsupported generic combination. "
         & "Either both g_din_exp / g_din_mant must grow, or g_din_exp "
         & "must shrink AND g_din_mant must shrink by at least 2 bits. "
         & "Equal sizes and mixed cases are not implemented."
    severity failure;

  proc_load_data : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if dv_i = '1' then
        s_sign_in <= float_in_i(float_in_i'left);
        s_car_in  <= unsigned(float_in_i(float_in_i'left - 1
                                         downto float_in_i'left - g_din_exp));
        s_mant_in <= unsigned(float_in_i(float_in_i'left - g_din_exp - 1 downto 0));
      end if;
    end if;
  end process proc_load_data;

  gen_small_to_large : if (g_din_exp < g_dout_exp and g_din_mant < g_dout_mant) generate
    --* Pipelined copy of s_car_in aligned with s_car_test_1 / s_mant_test.
    --  proc_make_char / proc_make_mantissa each register their results so
    --  s_car_test_1 and s_mant_test reflect the input from one cycle ago.
    --  The "is this a denormal input" check must use the same vintage of
    --  s_car_in, otherwise a normal sample N is misclassified when the
    --  following sample N+1 happens to be a denormal/zero.
    signal s_car_in_d1 : unsigned(g_din_exp - 1 downto 0)
                         := (others => '0');
    signal s_dv        : std_logic := '0';
    --* registered dv_o output, initialized so the port reads '0'
    --  at sim start (before the first rising_edge of clk_i). Same
    --  pattern used by lm_math_fpu_sum.
    signal s_dv_o      : std_logic := '0';
  begin
    proc_align_car_in : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_car_in_d1 <= s_car_in;
      end if;
    end process proc_align_car_in;

    proc_make_char : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_car_test_1 <= resize(s_car_in, s_car_test_1'length) + C_DELTA_BIAS;
      end if;
    end process proc_make_char;

    proc_make_mantissa : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_mant_test <= f_resize_right(s_mant_in, s_mant_test'length);
      end if;
    end process proc_make_mantissa;

    s_shift <= f_count_delta(s_mant_test);

    --* Three output cases:
    --    1) input is +/-0          -> output +0 (both fields zero)
    --    2) input is denormal      -> shift mantissa left to normalize and
    --                                 subtract the shift count from the
    --                                 (already bias-corrected) exponent
    --    3) input is a normal      -> straight bias correction
    --  The denormal-normalization path used to "normalize" an all-zero
    --  input too, producing a tiny but non-zero result for +/-0; the
    --  zero-detect leg below guards against that.
    s_car_out  <= (others => '0')
                  when (s_car_in_d1 = 0) and (s_mant_test = 0)
                  else s_car_test_1 - s_shift
                  when s_car_in_d1 = 0
                  else s_car_test_1;
    s_mant_out <= (others => '0')
                  when (s_car_in_d1 = 0) and (s_mant_test = 0)
                  else resize(shift_left(s_mant_test, to_integer(s_shift) + 1),
                              g_dout_mant)
                  when s_car_in_d1 = 0
                  else s_mant_test;

    proc_sign_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign_out <= s_sign_in;
      end if;
    end process proc_sign_delay;

    proc_dv_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_dv   <= dv_i;
        s_dv_o <= s_dv;
      end if;
    end process proc_dv_delay;

    dv_o <= s_dv_o;
  end generate gen_small_to_large;

  gen_large_to_small : if (g_din_exp > g_dout_exp and g_din_mant >= g_dout_mant + 2) generate
    -- in this branch the input bias is larger than the output bias, so the
    -- bias-correction term -C_DELTA_BIAS = C_BIAS_IN - C_BIAS_OUT is a strictly
    -- positive natural and can be used directly with unsigned arithmetic.
    constant C_BIAS_DOWN : natural := C_BIAS_IN - C_BIAS_OUT;
    -- 3-cycle dv shift register, initialized to avoid 'U' propagation
    signal s_dv_sr : std_logic_vector(2 downto 0) := (others => '0');
  begin
    proc_make_char_test : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if to_integer(s_car_in) > C_MAX_CAR_OUT + C_BIAS_DOWN then
          -- overflow: s_delta is not consumed in this case, but drive it
          -- explicitly so synthesis does not infer a latch.
          s_car_test_2 <= (others => '1');
          s_delta      <= (others => '0');
        elsif C_BIAS_DOWN < to_integer(s_car_in) then
          s_car_test_2 <= s_car_in - C_BIAS_DOWN;
          s_delta      <= (others => '0');
        else
          s_car_test_2 <= (others => '0');
          s_delta      <= resize(to_unsigned(C_BIAS_DOWN, g_din_exp) - s_car_in,
                                 s_delta'length);
        end if;
      end if;
    end process proc_make_char_test;

    proc_make_mantissa_test : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if to_integer(s_car_in) > C_MAX_CAR_OUT + C_BIAS_IN - C_BIAS_OUT then
          s_mant_test <= (others => '0');
        elsif -C_DELTA_BIAS < to_integer(s_car_in) then
          if s_mant_in(g_din_mant - g_dout_mant - 2) = '0' then
            s_mant_test <= f_resize_right(s_mant_in, g_dout_mant);
          else
            s_mant_test <= f_resize_right(s_mant_in, g_dout_mant) + 1;
          end if;
        else
          s_mant_test <= f_resize_right(s_mant_in, g_dout_mant);
        end if;
      end if;
    end process proc_make_mantissa_test;

    proc_make_out : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign_out <= s_sign_d;
        s_car_out  <= resize(s_car_test_2, g_dout_exp);
        if -C_DELTA_BIAS < to_integer(s_car_in_d) then
          s_mant_out <= s_mant_test;
        elsif to_integer(s_delta) < g_dout_mant then
          if s_mant_test(0) = '0' then
            s_mant_out <= shift_right('1' & s_mant_test(g_dout_mant - 1 downto 1),
                                      to_integer(s_delta));
          else
            s_mant_out <= shift_right('1' & s_mant_test(g_dout_mant - 1 downto 1),
                                      to_integer(s_delta)) + 1;
          end if;
        else
          s_mant_out <= (others => '0');
        end if;
      end if;
    end process proc_make_out;

    proc_sign_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign_d <= s_sign_in;
      end if;
    end process proc_sign_delay;

    proc_car_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_car_in_d <= s_car_in;
      end if;
    end process proc_car_delay;

    -- inline 3-cycle delay for dv (formerly an external delay primitive with g_delay=3)
    proc_dv_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_dv_sr <= s_dv_sr(1 downto 0) & dv_i;
      end if;
    end process proc_dv_delay;

    dv_o <= s_dv_sr(2);
  end generate gen_large_to_small;

  float_out_o <= std_logic_vector(s_sign_out & s_car_out & s_mant_out);

end a_rtl;
