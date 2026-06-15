--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_to_fix
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Conversion from floating point to fixed point.
--
--   Fixed-point format conventions:
--     g_fix_length : total bit width of the fixed-point output.
--     g_fix_bpoint : number of fractional bits.
--     g_is_signed  : '1' = two's complement, '0' = unsigned (the
--                    float sign is IGNORED, the absolute magnitude
--                    is emitted; this is not a saturate-to-zero
--                    clamp -- negative inputs come out positive).
--
--   Supported generic combinations (covered by the three internal
--   generate branches):
--     A. g_din_mant >= g_fix_bpoint + 3  -> gen_large_mantissa
--     B. g_din_mant  = g_fix_bpoint      -> gen_fixbpoint_equal_mantissa
--     C. g_din_mant  < g_fix_bpoint      -> gen_large_fixbpoint
--   The two gap cases g_din_mant = g_fix_bpoint + 1 and
--   g_din_mant = g_fix_bpoint + 2 are NOT implemented and trigger
--   an elaboration assertion failure via C_SHAPE_OK.
--
--   Latency:
--     The sign pipeline is 3 cycles in every branch. For dv_o,
--     the table below distinguishes the shift-register stage count
--     from the rising_edge-to-rising_edge dv_i -> dv_o delay (the
--     repo convention, see lm_math_fpu_sum):
--                                          stages   dv_i -> dv_o
--       gen_large_mantissa           :       5         4 clocks
--       gen_fixbpoint_equal_mantissa :       4         3 clocks
--       gen_large_fixbpoint          :       5         4 clocks
--
--   IEEE special inputs:
--     The data path treats NaN and +-inf as raw mantissa + exponent
--     bits, so the value driven on fixed_out_o for those inputs is
--     NOT meaningful. All overflow paths funnel into the all-ones
--     saturation (or its signed-negate for negative overflow), so
--     a downstream "saturate or NaN-check" decision must be made
--     by the consumer.
--
--   Reset semantics:
--     This module has no rst_n_i port. The data path is purely
--     pipelined (no FSM state that survives across operations) and
--     the dv_i / dv_o handshake makes any stale internal state
--     unobservable: a consumer that respects dv_o never reads
--     fixed_out_o while it is stale. The three generate branches
--     (gen_large_mantissa, gen_fixbpoint_equal_mantissa,
--     gen_large_fixbpoint, selected by the relation between
--     g_din_mant and g_fix_bpoint -- see the table at the top of
--     this file) each carry their own s_sign_sr and s_dv_sr
--     shift registers, all initialized to (others => '0') at
--     elaboration, so dv_o is '0' at simulation start without
--     needing an explicit reset. Hardware power-up behaviour
--     matches when the synthesis flow honours register
--     initialization (typical FPGA targets like Xilinx / Intel
--     preserve the init; ASIC flows usually do not and would
--     need an external reset to reach the same state). Modules
--     with FSM state (lm_math_fpu_sqrt) or reset-clearable error
--     pipelines (lm_math_fpu_div) do expose rst_n_i;
--     lm_math_fpu_to_fix needs neither.
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

entity lm_math_fpu_to_fix is
  generic(
    --* exponent width of input
    g_din_exp    : natural   := 8;
    --* mantissa width of input
    g_din_mant   : natural   := 23;
    --* fixed point output width
    g_fix_length : natural   := 16;
    --* fixed point binary point position
    g_fix_bpoint : natural   := 13;
    --* sign presence
    g_is_signed  : std_logic := '1'
  );
  port(
    clk_i       : in  std_logic;
    dv_i        : in  std_logic;
    float_in_i  : in  std_logic_vector(g_din_exp + g_din_mant downto 0);
    fixed_out_o : out std_logic_vector(g_fix_length - 1 downto 0);
    dv_o        : out std_logic
  );
end lm_math_fpu_to_fix;

architecture a_rtl of lm_math_fpu_to_fix is

  -- supported configurations (covered by the three generate branches below):
  --   * g_din_mant >= g_fix_bpoint + 3        -> gen_large_mantissa
  --   * g_fix_bpoint  = g_din_mant            -> gen_fixbpoint_equal_mantissa
  --   * g_fix_bpoint  > g_din_mant            -> gen_large_fixbpoint
  -- The gaps (g_fix_bpoint = g_din_mant - 1 and g_fix_bpoint = g_din_mant - 2)
  -- are not implemented and would leave the data path undriven. The boolean
  -- below mirrors the three generate conditions verbatim.
  constant C_SHAPE_OK : boolean :=
    (g_din_mant >= g_fix_bpoint + 3)
    or (g_fix_bpoint = g_din_mant)
    or (g_fix_bpoint > g_din_mant);

  constant C_BIAS      : natural := 2**(g_din_exp - 1) - 1;

  signal s_sign        : std_logic;
  signal s_sign_d      : std_logic;
  signal s_car         : unsigned(g_din_exp - 1 downto 0);
  signal s_mant        : unsigned(g_din_mant - 1 downto 0);
  signal s_exp         : unsigned(g_din_exp - 1 downto 0);
  signal s_num_int     : unsigned(g_din_mant downto 0);
  signal s_num_aux     : unsigned(g_fix_length - g_fix_bpoint + g_din_mant - 1 downto 0);
  signal s_num_aux2    : unsigned(g_fix_length - 1 downto 0);
  signal s_num_true    : unsigned(g_fix_length - g_fix_bpoint + g_din_mant - 1 downto 0);
  signal s_num_true2   : unsigned(g_fix_length - 1 downto 0);
  signal s_shift_lr    : std_logic;
  signal s_shift_lr_d  : std_logic;
  signal s_ovlf        : std_logic;
  signal s_fixed       : unsigned(g_fix_length - 1 downto 0) := (others => '0');
  signal s_sfixed      : unsigned(g_fix_length - 1 downto 0) := (others => '0');
  signal s_cyph        : std_logic;
  signal s_cyph_d      : std_logic;

begin

  assert C_SHAPE_OK
    report "lm_math_fpu_to_fix: unsupported generic combination. "
         & "Allowed: g_din_mant >= g_fix_bpoint + 3, g_din_mant = g_fix_bpoint, "
         & "or g_din_mant < g_fix_bpoint."
    severity failure;

  proc_read_data : process(clk_i)
  begin
    if rising_edge(clk_i) then
      s_sign <= float_in_i(float_in_i'left);
      s_car  <= unsigned(float_in_i(float_in_i'left - 1
                                    downto float_in_i'left - g_din_exp));
      s_mant <= unsigned(float_in_i(float_in_i'left - g_din_exp - 1 downto 0));
    end if;
  end process proc_read_data;

  proc_evaluate_shift : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_car >= C_BIAS then
        s_shift_lr <= '1';
      else
        s_shift_lr <= '0';
      end if;
      s_shift_lr_d <= s_shift_lr;
    end if;
  end process proc_evaluate_shift;

  s_num_int <= '1' & s_mant when s_car > 0 else '0' & s_mant;

  gen_large_mantissa : if s_num_true'left > g_fix_length + 1 generate
    -- inline shift registers replacing the former external delay primitive,
    -- explicitly initialized
    -- so the pipeline does not propagate 'U' from elaboration.
    signal s_sign_sr : std_logic_vector(2 downto 0) := (others => '0');
    signal s_dv_sr   : std_logic_vector(4 downto 0) := (others => '0');
  begin
    proc_load_number : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_num_aux(s_num_aux'left downto g_din_mant + 1) <= (others => '0');
        if s_num_int(s_num_int'left) = '1' then
          s_num_aux(g_din_mant)             <= '1';
          s_num_aux(g_din_mant - 1 downto 0) <= s_mant;
        else
          s_num_aux(g_din_mant)             <= s_num_int(s_num_int'left - 1);
          s_num_aux(g_din_mant - 1 downto 0) <= s_mant(s_mant'left - 1 downto 0) & '0';
        end if;
      end if;
    end process proc_load_number;

    proc_exp_calc : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_car >= C_BIAS then
          s_exp <= s_car - C_BIAS;
        else
          s_exp <= C_BIAS - s_car;
        end if;
      end if;
    end process proc_exp_calc;

    proc_shift_number : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_shift_lr = '1' then
          if s_exp < g_fix_length - g_fix_bpoint then
            s_num_true <= shift_left(s_num_aux, to_integer(s_exp));
            s_ovlf     <= '0';
          else
            s_num_true <= (others => '1');
            s_ovlf     <= '1';
          end if;
        else
          s_num_true <= shift_right(s_num_aux, to_integer(s_exp));
          s_ovlf     <= '0';
        end if;
      end if;
    end process proc_shift_number;

    s_cyph <= s_num_true(s_num_true'left - g_fix_length);

    proc_output : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_ovlf = '1' then
          s_fixed <= (others => '1');
        elsif s_cyph = '1' then
          s_fixed <= s_num_true(s_num_aux'left downto g_din_mant - g_fix_bpoint) + 1;
        else
          s_fixed <= s_num_true(s_num_aux'left downto g_din_mant - g_fix_bpoint);
        end if;
      end if;
    end process proc_output;

    proc_sign_processing : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if g_is_signed = '0' then
          s_sfixed <= s_fixed;
        else
          if s_sign_d = '0' then
            s_sfixed <= s_fixed;
          else
            s_sfixed <= (not s_fixed) + 1;
          end if;
        end if;
      end if;
    end process proc_sign_processing;

    fixed_out_o <= std_logic_vector(s_sfixed);

    -- sign by 3, dv by 5
    proc_delays : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign_sr <= s_sign_sr(1 downto 0) & s_sign;
        s_dv_sr   <= s_dv_sr(3 downto 0) & dv_i;
      end if;
    end process proc_delays;

    s_sign_d <= s_sign_sr(2);
    dv_o     <= s_dv_sr(4);
  end generate gen_large_mantissa;

  gen_fixbpoint_equal_mantissa : if g_fix_bpoint = g_din_mant generate
    signal s_sign_sr : std_logic_vector(2 downto 0) := (others => '0');
    signal s_dv_sr   : std_logic_vector(3 downto 0) := (others => '0');
  begin
    proc_load_number : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_num_aux(s_num_aux'left downto g_din_mant + 1) <= (others => '0');
        if s_num_int(s_num_int'left) = '1' then
          s_num_aux(g_din_mant)             <= '1';
          s_num_aux(g_din_mant - 1 downto 0) <= s_mant;
        else
          s_num_aux(g_din_mant)             <= s_num_int(s_num_int'left - 1);
          s_num_aux(g_din_mant - 1 downto 0) <= s_mant(s_mant'left - 1 downto 0) & '0';
        end if;
      end if;
    end process proc_load_number;

    proc_exp_calc : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_car >= C_BIAS then
          s_exp <= s_car - C_BIAS;
        else
          s_exp <= C_BIAS - s_car;
        end if;
      end if;
    end process proc_exp_calc;

    proc_shift_number : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_shift_lr = '1' then
          if s_exp < g_fix_length - g_fix_bpoint then
            s_num_true <= shift_left(s_num_aux, to_integer(s_exp));
            s_ovlf     <= '0';
          else
            s_num_true <= (others => '1');
            s_ovlf     <= '1';
          end if;
        else
          s_num_true <= shift_right(s_num_aux, to_integer(s_exp));
          s_ovlf     <= '0';
        end if;
      end if;
    end process proc_shift_number;

    -- Pick the round-up cyph bit via a process so the index is only
    -- computed when s_exp > 0; the concurrent "when ... else" form caused
    -- some simulators to evaluate s_num_aux(-1) at the boundary.
    proc_cyph : process(s_shift_lr, s_exp, s_num_aux)
    begin
      s_cyph <= '0';
      if s_shift_lr = '0' and s_exp > 0 then
        s_cyph <= s_num_aux(to_integer(s_exp) - 1);
      end if;
    end process proc_cyph;

    proc_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_cyph_d <= s_cyph;
      end if;
    end process proc_delay;

    proc_output : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_ovlf = '1' then
          s_fixed <= (others => '1');
        elsif s_cyph_d = '1' then
          s_fixed <= s_num_true(s_num_aux'left downto g_din_mant - g_fix_bpoint) + 1;
        else
          s_fixed <= s_num_true(s_num_aux'left downto g_din_mant - g_fix_bpoint);
        end if;
      end if;
    end process proc_output;

    proc_sign_processing : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if g_is_signed = '0' then
          s_sfixed <= s_fixed;
        else
          if s_sign_d = '0' then
            s_sfixed <= s_fixed;
          else
            s_sfixed <= (not s_fixed) + 1;
          end if;
        end if;
      end if;
    end process proc_sign_processing;

    fixed_out_o <= std_logic_vector(s_sfixed);

    -- sign by 3, dv by 4
    proc_delays : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign_sr <= s_sign_sr(1 downto 0) & s_sign;
        s_dv_sr   <= s_dv_sr(2 downto 0) & dv_i;
      end if;
    end process proc_delays;

    s_sign_d <= s_sign_sr(2);
    dv_o     <= s_dv_sr(3);
  end generate gen_fixbpoint_equal_mantissa;

  gen_large_fixbpoint : if g_fix_bpoint > g_din_mant generate
    signal s_sign_sr : std_logic_vector(2 downto 0) := (others => '0');
    signal s_dv_sr   : std_logic_vector(4 downto 0) := (others => '0');
  begin
    proc_load_number : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_num_aux2(s_num_aux2'left downto g_fix_bpoint + 1) <= (others => '0');
        if s_num_int(s_num_int'left) = '1' then
          s_num_aux2(g_fix_bpoint) <= '1';
        else
          s_num_aux2(g_fix_bpoint) <= s_num_int(s_num_int'left - 1);
        end if;
        s_num_aux2(g_fix_bpoint - 1 downto g_fix_bpoint - 1 - s_mant'left) <= s_mant;
        s_num_aux2(g_fix_bpoint - 1 - s_mant'left - 1 downto 0)            <= (others => '0');
      end if;
    end process proc_load_number;

    proc_exp_calc : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_car >= C_BIAS then
          s_exp <= s_car - C_BIAS;
        else
          s_exp <= C_BIAS - s_car;
        end if;
      end if;
    end process proc_exp_calc;

    proc_shift_number : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_shift_lr = '1' then
          if s_exp < g_fix_length - g_fix_bpoint then
            s_num_true2 <= shift_left(s_num_aux2, to_integer(s_exp));
            s_ovlf      <= '0';
          else
            s_num_true2 <= (others => '1');
            s_ovlf      <= '1';
          end if;
        else
          s_num_true2 <= shift_right(s_num_aux2, to_integer(s_exp));
          s_ovlf      <= '0';
        end if;
      end if;
    end process proc_shift_number;

    -- guarded s_cyph indexing (see comment in gen_fixbpoint_equal_mantissa)
    proc_cyph : process(s_shift_lr, s_exp, s_num_aux2)
    begin
      s_cyph <= '0';
      if s_shift_lr = '0' and s_exp > 0 then
        s_cyph <= s_num_aux2(to_integer(s_exp) - 1);
      end if;
    end process proc_cyph;

    proc_delay : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_cyph_d <= s_cyph;
      end if;
    end process proc_delay;

    proc_output : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if s_ovlf = '1' then
          s_fixed <= (others => '1');
        elsif s_cyph_d = '1' then
          s_fixed <= s_num_true2 + 1;
        else
          s_fixed <= s_num_true2;
        end if;
      end if;
    end process proc_output;

    proc_sign_processing : process(clk_i)
    begin
      if rising_edge(clk_i) then
        if g_is_signed = '0' then
          s_sfixed <= s_fixed;
        else
          if s_sign_d = '0' then
            s_sfixed <= s_fixed;
          else
            s_sfixed <= (not s_fixed) + 1;
          end if;
        end if;
      end if;
    end process proc_sign_processing;

    fixed_out_o <= std_logic_vector(s_sfixed);

    -- sign by 3, dv by 5
    proc_delays : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_sign_sr <= s_sign_sr(1 downto 0) & s_sign;
        s_dv_sr   <= s_dv_sr(3 downto 0) & dv_i;
      end if;
    end process proc_delays;

    s_sign_d <= s_sign_sr(2);
    dv_o     <= s_dv_sr(4);
  end generate gen_large_fixbpoint;

end a_rtl;
