--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_prod
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Multiplication (product) of two floating point numbers.
--               Uses lm_math_fi_mult for the mantissa product and
--               lm_math_fpu_rounding for the output rounding.
--
--   IEEE special inputs:
--     * If either operand is NaN or +-inf the corresponding bit of
--       error_o is set (bits 0..4). The value driven on dout_o for
--       these inputs is computed from the raw mantissa / exponent
--       fields and is NOT IEEE-conformant. Consumers must read
--       error_o before using dout_o.
--     * Bits 5..6 of error_o flag the (zero) * (mantissa /= 0)
--       case: one operand has both car=0 AND mant=0 (a true +-0),
--       and the other operand has mantissa /= 0. Note this is
--       narrower than "zero vs non-zero operand": an operand with
--       car /= 0 and mant = 0 (e.g. exact 2.0 = 0x40000000) does
--       NOT trigger bits 5..6 even when multiplied by a true zero.
--       When the flag does fire, the exponent and mantissa fields
--       of dout_o are 0 and the sign bit is s_sign_a XOR s_sign_b,
--       so the output is +0 or -0 depending on the operand signs.
--       This matches the IEEE result for 0 * finite.
--
--   Subnormal handling (flush-to-zero):
--     proc_final_car_eval saturates s_car_d to 0 when the unbiased
--     result exponent goes negative (s_car < C_BIAS). The mantissa
--     is also forced to 0, but the sign bit (s_sign_a XOR s_sign_b)
--     passes through proc_dly and the rounder unchanged, so a
--     subnormal product retains its computed sign: a negative
--     subnormal becomes -0, a positive one becomes +0. error_o is
--     NOT set for this case. This is a deliberate FTZ
--     implementation, not IEEE-conformant denormal support.
--
--   Reset semantics:
--     This module has no rst_n_i port. The data path is purely
--     pipelined (no FSM state that survives across operations) and
--     the dv_i / dv_o handshake makes any stale internal state
--     unobservable: a consumer that respects dv_o never reads
--     dout_o or error_o while they are stale. s_dv_dly,
--     s_error_dly, s_sign_dly and s_car_sum_dly are initialized to
--     (others => '0') at elaboration, so dv_o and error_o are
--     '0' at simulation start without needing an explicit reset.
--     Hardware power-up behaviour matches when the synthesis flow
--     honours register initialization (typical FPGA targets like
--     Xilinx / Intel preserve the init; ASIC flows usually do not
--     and would need an external reset to reach the same state).
--     Modules with FSM state (lm_math_fpu_sqrt) or
--     reset-clearable error pipelines (lm_math_fpu_div) do expose
--     rst_n_i; lm_math_fpu_prod needs neither.
--
--   s_delta alignment (fixed in 2.0.1):
--     The legacy code registered s_delta inside proc_delta_count,
--     which made it lag s_mult_out by one cycle. proc_car_mant_eval
--     reads s_mult_out / s_car_sum_d / s_delta on the same edge, so
--     with the registered version s_delta belonged to vec N-1 while
--     the other two belonged to vec N. The mismatch was silent on
--     normal*normal products (s_delta = 0 for those: the leading-
--     zero count of the 2*(g_data_mant+1)-bit product is 0 or 1
--     because the product lies in [2^(2*g_data_mant),
--     2^(2*g_data_mant+2)), and the "- 1" in proc_delta_count
--     collapses both cases to 0). A subnormal product preceded by
--     a normal-magnitude one (e.g. 1.0e-40 * 2.0 after NaN*NaN)
--     skipped the FTZ clamp and emitted a corrupted output. The
--     2.0.1 fix makes s_delta and s_biased_delta combinational on
--     s_mult_out so they always correspond to the same vector that
--     proc_car_mant_eval reads.
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

entity lm_math_fpu_prod is
  generic(
    --* exponent width
    g_data_exp      : natural   := 8;
    --* mantissa width
    g_data_mant     : natural   := 23;
    --* rounding mode
    g_round_mode    : integer   := C_LM_ROUND_NEAREST;
    --* DEPRECATED, no-op. The legacy module had two architectures
    --  (embedded multiplier vs. FSM-based logic multiplier) selected
    --  by this generic. The logic-multiplier branch was never finished
    --  and was dropped during the 2.0.0 migration. The generic is kept
    --  here so existing instantiations still analyze; passing any value
    --  other than '1' triggers an elaboration assertion failure.
    g_mult_vs_logic : std_logic := '1';
    --* Pipeline stages of the integer multiplier. Must be >= 2: the
    --  s_car_sum_dly shift register is sized for g_pipe_stages stages
    --  of (g_data_exp + 1) bits, and the downstream alignment math
    --  (C_PIPE_LATENCY etc.) is only defined from that depth upwards.
    --  Lower values are rejected at elaboration.
    g_pipe_stages   : natural   := 5
  );
  port(
    clk_i            : in  std_logic;
    dv_i             : in  std_logic;
    multiplicand_a_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    multiplicand_b_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    dout_o           : out std_logic_vector(g_data_exp + g_data_mant downto 0);
    dv_o             : out std_logic;
    error_o          : out std_logic_vector(6 downto 0)
  );
end lm_math_fpu_prod;

architecture a_rtl of lm_math_fpu_prod is

  constant C_BIAS        : natural := 2**(g_data_exp - 1) - 1;
  constant C_DELTA_WIDTH : integer := f_max(f_ceil_log2(g_data_mant) + 1,
                                            f_ceil_log2(C_BIAS));

  -- Total pipeline latency from the rising_edge that samples dv_i = '1'
  -- to the rising_edge that produces dv_o = '1':
  --   1 (proc_load_data) + g_pipe_stages (mult) + 5 (post-processing
  --   stages + rounding) = g_pipe_stages + 6.
  -- The downstream shift-register depths (s_error_dly, s_dv_dly,
  -- s_sign_dly, s_car_sum_dly) are derived from this single value.
  constant C_PIPE_LATENCY : natural := g_pipe_stages + 6;
  -- s_error: produced at cycle 2 (proc_load_data + proc_errors), so it
  -- needs C_PIPE_LATENCY - 2 stages to align with dv_o.
  constant C_ERROR_DELAY  : natural := C_PIPE_LATENCY - 2;
  -- s_dv_dly: dv_i sampled at cycle 1, dv_o produced at cycle
  -- C_PIPE_LATENCY, so the shift register holds C_PIPE_LATENCY stages
  -- end-to-end (no extra register after the shift).
  constant C_DV_DELAY     : natural := C_PIPE_LATENCY;
  -- s_sign_dly: sign passes from proc_load_data (cycle 1) to the
  -- rounder input (cycle C_PIPE_LATENCY - 2) = g_pipe_stages + 4.
  constant C_SIGN_DELAY   : natural := C_PIPE_LATENCY - 3;

  signal s_sign_a          : std_logic;
  signal s_sign_b          : std_logic;
  signal s_car_a           : unsigned(g_data_exp - 1 downto 0);
  signal s_mant_a          : unsigned(g_data_mant - 1 downto 0);
  signal s_car_b           : unsigned(g_data_exp - 1 downto 0);
  signal s_mant_b          : unsigned(g_data_mant - 1 downto 0);

  signal s_sign            : std_logic;
  signal s_sign_d          : std_logic;
  signal s_car_sum         : unsigned(g_data_exp downto 0);
  signal s_car_sum_d       : std_logic_vector(g_data_exp downto 0);
  signal s_car             : unsigned(g_data_exp downto 0);
  signal s_car_d           : unsigned(g_data_exp downto 0);
  signal s_mant            : unsigned(2 + g_data_mant - 1 downto 0);
  signal s_mant_d          : unsigned(2 + g_data_mant - 1 downto 0);
  signal s_factor_a        : unsigned(g_data_mant downto 0);
  signal s_factor_b        : unsigned(g_data_mant downto 0);

  signal s_delta           : unsigned(C_DELTA_WIDTH + 1 downto 0);
  signal s_biased_delta    : unsigned(C_DELTA_WIDTH + 1 downto 0);

  signal s_error           : std_logic_vector(6 downto 0);
  signal s_error_d         : std_logic_vector(6 downto 0);

  signal s_mult_out        : std_logic_vector(2 * (g_data_mant + 1) - 1 downto 0);
  signal s_mult_out_d      : std_logic_vector(2 * (g_data_mant + 1) - 1 downto 0);

  -- inline shift registers replacing the former external delay primitive.
  -- Initialized to '0' so dv_o / error_o do not propagate 'U' before the
  -- pipeline has filled. Depths are derived from C_PIPE_LATENCY above.
  --
  -- s_car_sum_dly is sized with f_max(g_pipe_stages, 2) so the range
  -- and the proc_dly slice are always well-formed at elaboration even
  -- when g_pipe_stages = 0 or 1; in those cases the assertion above
  -- still fires first with a readable message instead of the analyzer
  -- erroring out on a "-1 downto 0" range.
  signal s_car_sum_dly : std_logic_vector(f_max(g_pipe_stages, 2)
                                            * (g_data_exp + 1) - 1
                                          downto 0)               := (others => '0');
  signal s_sign_dly    : std_logic_vector(C_SIGN_DELAY - 1 downto 0)  := (others => '0');
  signal s_dv_dly      : std_logic_vector(C_DV_DELAY - 1 downto 0)    := (others => '0');
  signal s_error_dly   : std_logic_vector(7 * C_ERROR_DELAY - 1 downto 0)
                         := (others => '0');

begin

  -- Only the embedded-multiplier branch is implemented; the legacy
  -- g_mult_vs_logic = '0' (FSM-based logic multiplier) was dropped during
  -- the migration. Fail at elaboration if instantiated with a different
  -- value.
  assert g_mult_vs_logic = '1'
    report "lm_math_fpu_prod: only g_mult_vs_logic = '1' is supported."
    severity failure;

  -- s_car_sum_dly is sized as g_pipe_stages * (g_data_exp + 1) bits
  -- (one stage per pipeline cycle of lm_math_fi_mult) and shifted by
  -- (g_data_exp + 1) bits per cycle. With g_pipe_stages < 2 the shift
  -- slice "s_car_sum_dly'left - (g_data_exp + 1) downto 0" is invalid
  -- (negative left index). The alignment math elsewhere in the module
  -- also assumes g_pipe_stages >= 2. Reject smaller values at
  -- elaboration so a misconfiguration is caught up front instead of
  -- producing X on dout_o.
  assert g_pipe_stages >= 2
    report "lm_math_fpu_prod: g_pipe_stages must be >= 2"
           & " (the s_car_sum_dly shift register and the C_PIPE_LATENCY"
           & " alignment require it)."
    severity failure;

  -- error flags on the inputs
  proc_errors : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if ((f_all_ones(s_car_a) = '1') and (s_mant_a > 0))
         or ((f_all_ones(s_car_b) = '1') and (s_mant_b > 0)) then
        s_error(0) <= '1';
      else
        s_error(0) <= '0';
      end if;

      -- bits 1 and 2: infty*0 (undetermined) vs infty*n (infinity) on the
      -- A side. Each branch must drive BOTH bits explicitly, otherwise one
      -- of them latches a value from the previous cycle.
      if ((f_all_ones(s_car_a) = '1') and (s_mant_a = 0))
         and ((s_car_b = 0) and (s_mant_b = 0)) then
        s_error(1) <= '1';
        s_error(2) <= '0';
      elsif (f_all_ones(s_car_a) = '1') and (s_mant_a = 0) then
        s_error(1) <= '0';
        s_error(2) <= '1';
      else
        s_error(1) <= '0';
        s_error(2) <= '0';
      end if;

      -- bits 3 and 4: same structure for the B side.
      if ((f_all_ones(s_car_b) = '1') and (s_mant_b = 0))
         and ((s_car_a = 0) and (s_mant_a = 0)) then
        s_error(3) <= '1';
        s_error(4) <= '0';
      elsif (f_all_ones(s_car_b) = '1') and (s_mant_b = 0) then
        s_error(3) <= '0';
        s_error(4) <= '1';
      else
        s_error(3) <= '0';
        s_error(4) <= '0';
      end if;

      if ((s_car_a = 0) and (s_mant_a = 0)) and s_mant_b > 0 then
        s_error(5) <= '1';
      else
        s_error(5) <= '0';
      end if;

      if ((s_car_b = 0) and (s_mant_b = 0)) and s_mant_a > 0 then
        s_error(6) <= '1';
      else
        s_error(6) <= '0';
      end if;
    end if;
  end process proc_errors;

  error_o <= s_error_d;

  proc_load_data : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if dv_i = '1' then
        s_sign_a <= multiplicand_a_i(multiplicand_a_i'left);
        s_car_a  <= unsigned(multiplicand_a_i(multiplicand_a_i'left - 1
                                              downto multiplicand_a_i'left - g_data_exp));
        s_mant_a <= unsigned(multiplicand_a_i(multiplicand_a_i'left - g_data_exp - 1
                                              downto 0));
        s_sign_b <= multiplicand_b_i(multiplicand_b_i'left);
        s_car_b  <= unsigned(multiplicand_b_i(multiplicand_b_i'left - 1
                                              downto multiplicand_b_i'left - g_data_exp));
        s_mant_b <= unsigned(multiplicand_b_i(multiplicand_b_i'left - g_data_exp - 1
                                              downto 0));
      end if;
    end if;
  end process proc_load_data;

  s_sign <= s_sign_a xor s_sign_b;

  s_factor_a <= '1' & s_mant_a when s_car_a > 0 else '0' & s_mant_a;
  s_factor_b <= '1' & s_mant_b when s_car_b > 0 else '0' & s_mant_b;

  inst_mult : entity lm_math_float_lib.lm_math_fi_mult
    generic map(
      g_din_a_w     => g_data_mant + 1,
      g_din_b_w     => g_data_mant + 1,
      g_dout_w      => 2 * (g_data_mant + 1),
      g_pipe_stages => g_pipe_stages
    )
    port map(
      clk_i  => clk_i,
      din1_i => std_logic_vector(s_factor_a),
      din2_i => std_logic_vector(s_factor_b),
      dout_o => s_mult_out
    );

  -- IEEE-754 encodes subnormals with biased exponent = 0 but the
  -- represented value is m * 2^(1 - bias - mant_width), i.e. the
  -- effective biased exponent is 1, not 0. The downstream
  -- normalization in proc_car_mant_eval / proc_final_car_eval is
  -- written assuming car_sum = E_eff_a + E_eff_b, so feeding it the
  -- raw stored 0 for a subnormal operand makes the final result
  -- exponent one bit too small (the dout magnitude is half the IEEE
  -- value). Compensate here by promoting s_car_a / s_car_b to 1
  -- when the operand is a true subnormal (car = 0 AND mant /= 0).
  -- For a true +-0 (car = 0 AND mant = 0) the +1 is NOT applied:
  -- s_mult_out is 0 in that case and proc_final_car_eval's
  -- "s_mult_out_d = 0" leg short-circuits car_d / mant_d to zero, so
  -- the car_sum value is irrelevant. For NaN / inf (car = all-ones)
  -- the +1 is also skipped: error_o flags those inputs and the
  -- module header documents dout as not IEEE-conformant when an
  -- error_o bit is set.
  proc_car_sum : process(clk_i)
    variable v_car_a_eff : unsigned(g_data_exp - 1 downto 0);
    variable v_car_b_eff : unsigned(g_data_exp - 1 downto 0);
  begin
    if rising_edge(clk_i) then
      if (s_car_a = 0) and (s_mant_a /= 0) then
        v_car_a_eff := to_unsigned(1, g_data_exp);
      else
        v_car_a_eff := s_car_a;
      end if;
      if (s_car_b = 0) and (s_mant_b /= 0) then
        v_car_b_eff := to_unsigned(1, g_data_exp);
      else
        v_car_b_eff := s_car_b;
      end if;
      s_car_sum <= resize(v_car_a_eff, s_car_sum'length)
                   + resize(v_car_b_eff, s_car_sum'length);
    end if;
  end process proc_car_sum;

  -- s_delta and s_biased_delta are computed combinationally on
  -- s_mult_out (a leading-zero count plus a constant bias). The
  -- previous implementation registered s_delta inside this process,
  -- which made it lag s_mult_out by one cycle. proc_car_mant_eval
  -- reads s_mult_out / s_car_sum_d / s_delta on the same edge, so
  -- with the registered version s_delta belonged to vec N-1 while
  -- the other two belonged to vec N. The mismatch was silent for
  -- normal * normal products (the LZ count of the product is 0 or
  -- 1, and the "- 1" below collapses both cases to s_delta = 0)
  -- but caused subnormal magnitudes preceded by a normal-magnitude
  -- product (e.g. 1.0e-40 * 2.0 after NaN*NaN) to skip the FTZ
  -- clamp and emit a corrupted output. The 2*(g_data_mant+1)-bit
  -- f_count_delta path (48 bits for the default g_data_mant=23) is
  -- short enough to stay combinational on typical FPGAs; if a
  -- higher-frequency target needs to break it out into its own
  -- pipeline stage, add a register here AND bump s_dv_dly /
  -- s_error_dly / s_sign_dly / s_car_sum_dly by one to maintain the
  -- alignment.
  s_delta        <= resize(f_count_delta(unsigned(s_mult_out)),
                           s_delta'length) - 1
                    when s_mult_out(s_mult_out'left) = '0'
                    else (others => '0');
  s_biased_delta <= s_delta + C_BIAS;

  proc_car_mant_eval : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if s_mult_out(s_mult_out'left) = '1' then
        s_car  <= unsigned(s_car_sum_d) + 1;
        s_mant <= unsigned(s_mult_out(s_mult_out'left - 1
                                      downto s_mult_out'left - (2 + g_data_mant)));
      elsif s_mult_out(s_mult_out'left) = '0'
            and s_mult_out(s_mult_out'left - 1) = '1' then
        s_car <= unsigned(s_car_sum_d);
        if unsigned(s_car_sum_d) > 0 then
          s_mant <= unsigned(s_mult_out(s_mult_out'left - 2
                                        downto s_mult_out'left - (3 + g_data_mant)));
        else
          -- underflow guard: drive s_mant explicitly so synthesis does
          -- not infer a latch (s_car_sum_d = 0 means the exponent has
          -- already underflowed, so 0 mantissa is the right value too).
          s_mant <= (others => '0');
        end if;
      else
        if unsigned(s_car_sum_d) > resize(s_delta, s_car_sum_d'length) then
          s_car  <= unsigned(s_car_sum_d(s_car'left downto 0))
                    - resize(s_delta, s_car'length);
          s_mant <= shift_left(unsigned(s_mult_out), to_integer(s_delta))
                              (s_mult_out'left - 2
                               downto s_mult_out'left - 2 - s_mant'left);
        elsif unsigned(s_car_sum_d) <= resize(s_biased_delta, s_car_sum_d'length) then
          s_car  <= (others => '0');
          s_mant <= shift_left(unsigned(s_mult_out), to_integer(s_delta))
                              (s_mult_out'left - 1
                               downto s_mult_out'left - 1 - s_mant'left);
        else
          s_car  <= (others => '0');
          s_mant <= shift_left(unsigned(s_mult_out),
                               to_integer(unsigned(s_car_sum_d)))
                              (s_mult_out'left - 1
                               downto s_mult_out'left - 1 - s_mant'left);
        end if;
      end if;
      s_mult_out_d <= s_mult_out;
    end if;
  end process proc_car_mant_eval;

  -- Final exponent saturation. The underflow / overflow conditions are
  -- absorbed into s_car_d and s_mant_d directly (0 for underflow, all-1
  -- for overflow); the legacy module also derived dedicated underflow /
  -- overflow flags here but never exposed them. They are not regenerated.
  proc_final_car_eval : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if unsigned(s_mult_out_d) = 0 then
        s_car_d  <= (others => '0');
        s_mant_d <= s_mant;
      elsif (s_car >= C_BIAS) and (s_car < 3 * C_BIAS) then
        s_car_d  <= s_car - C_BIAS;
        s_mant_d <= s_mant;
      elsif s_car < C_BIAS then
        s_car_d  <= (others => '0');
        s_mant_d <= (others => '0');
      else
        s_car_d  <= (others => '1');
        s_mant_d <= (others => '0');
      end if;
    end if;
  end process proc_final_car_eval;

  inst_lm_math_fpu_round : entity lm_math_float_lib.lm_math_fpu_rounding
    generic map(
      g_din_exp    => g_data_exp,
      g_din_mant   => g_data_mant,
      g_round_mode => g_round_mode
    )
    port map(
      clk_i      => clk_i,
      sign_i     => s_sign_d,
      mantissa_i => std_logic_vector(s_mant_d),
      car_i      => std_logic_vector(s_car_d(s_car_d'left - 1 downto 0)),
      dout_o     => dout_o
    );

  --------------------------------------------------------------------------
  -- inline pipeline delays replacing the former external delay primitive
  --------------------------------------------------------------------------
  proc_dly : process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- car_sum: depth g_pipe_stages, width g_data_exp+1
      s_car_sum_dly <= s_car_sum_dly(s_car_sum_dly'left - (g_data_exp + 1)
                                     downto 0)
                       & std_logic_vector(s_car_sum);
      -- sign: depth C_SIGN_DELAY = C_PIPE_LATENCY - 3
      s_sign_dly <= s_sign_dly(s_sign_dly'left - 1 downto 0) & s_sign;
      -- dv: depth C_DV_DELAY = C_PIPE_LATENCY
      s_dv_dly <= s_dv_dly(s_dv_dly'left - 1 downto 0) & dv_i;
      -- error: depth C_ERROR_DELAY = C_PIPE_LATENCY - 2, width 7
      s_error_dly <= s_error_dly(s_error_dly'left - 7 downto 0) & s_error;
    end if;
  end process proc_dly;

  s_car_sum_d <= s_car_sum_dly(s_car_sum_dly'left
                               downto s_car_sum_dly'left - g_data_exp);
  s_sign_d    <= s_sign_dly(s_sign_dly'left);
  dv_o        <= s_dv_dly(s_dv_dly'left);
  s_error_d   <= s_error_dly(s_error_dly'left
                             downto s_error_dly'left - 6);

end a_rtl;
