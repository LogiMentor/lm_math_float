--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Module Name : lm_math_fpu_mult_cmplx
-- Library     : lm_math_float_lib
-- Project     : LM MATH FLOAT
-- Company     : Logimentor
-- Author      : Logimentor
-------------------------------------------------------------------------------
-- Description : Complex multiplication (product) of two floating point
--               complex numbers. Two architectures:
--                 g_architecture = '1' : 4 multipliers, 2 adders
--                                        (straightforward ac-bd, ad+bc)
--                 g_architecture = '0' : 3 multipliers, 5 adders
--                                        (Gauss / Karatsuba)
--
--   Latency (dv_i sample -> dv_o assert, edge count):
--     gen_4_mult_struct : lm_math_fpu_prod (g_pipe_stages + 6) +
--                         lm_math_fpu_sum  (10)
--                         = g_pipe_stages + 16 cycles
--     gen_3_mult_struct : lm_math_fpu_sum  (10) +
--                         lm_math_fpu_prod (g_pipe_stages + 6) +
--                         lm_math_fpu_sum  (10)
--                         = g_pipe_stages + 26 cycles
--     The two architectures have DIFFERENT latencies, so a caller
--     that switches g_architecture must re-synchronize against dv_o
--     and not assume a fixed offset from dv_i.
--
--   IEEE special inputs:
--     error_o is derived ONLY from the two final output-stage sums,
--     not from the internal multipliers or earlier sums:
--       g_architecture = '1' : OR of s_g_err / s_h_err
--                              (= inst_first_sum / inst_second_sum)
--       g_architecture = '0' : OR of s_i_err / s_l_err
--                              (= inst_fourth_sum / inst_fifth_sum)
--     Collapsed into 2 module-level bits:
--       bit 0 : any NaN flagged by either final sum
--               (bits 0..1 of the sum's error_o)
--       bit 1 : any +-inf flagged by either final sum
--               (bits 2..3 of the sum's error_o)
--     A NaN or +-inf in an intermediate multiplier or earlier sum
--     will usually still surface here because NaN / inf propagate
--     through arithmetic, but the reduction is not exhaustive:
--     pathological cases (e.g. an internal NaN multiplied by 0 that
--     cancels later) can leave error_o = "00" with a non-IEEE
--     dout. Consumers needing per-operand classification must
--     pre-check the four real/imag inputs.
--     dout_re_o / dout_im_o are not IEEE-conformant when error_o /=
--     "00" (the data path treats NaN / inf as raw arithmetic).
--
--   Subnormal handling (inherited FTZ from lm_math_fpu_prod):
--     This module uses lm_math_fpu_prod internally for the four
--     (g_architecture='1') or three (g_architecture='0') mantissa-
--     level multiplications. Each lm_math_fpu_prod instance flushes
--     any subnormal-magnitude product AT ITS OWN OUTPUT to +-0
--     with the sign preserved (per its documented FTZ behavior).
--     The downstream sums then receive these signed zeros and
--     operate normally with full subnormal support.
--
--     The set of internal products differs by architecture:
--       g_architecture = '1' : the four products ac, bd, ad, bc
--                              (straightforward "ac - bd, ad + bc").
--       g_architecture = '0' : the three Karatsuba intermediates
--                              f = a_re * (b_re + b_im),
--                              g = b_im * (a_im + a_re),
--                              h = b_re * (a_im - a_re).
--     FTZ applies at each of those prod outputs, NOT at the final
--     re / im components.
--
--     Consequence: subnormal outputs from mult_cmplx can arise in
--     two ways:
--       (a) an IEEE-correct internal product is itself subnormal
--           -- e.g. (1e-40 + 0j) * (2.0 + 0j): under arch='1' the
--           ac = 2e-40 prod flushes to +-0; under arch='0' the
--           f = a_re * (b_re + b_im) = 1e-40 * 2 = 2e-40 prod also
--           flushes. Final re = 0 in both archs.
--       (b) two normal-magnitude internal products cancel into a
--           subnormal final component. prod does NOT flush here
--           (its inputs and outputs are normal), so the downstream
--           sum can legitimately emit a non-zero subnormal.
--     The TB models both cases by applying FTZ per-prod-output in
--     the reference (helper f_prod_ftz), with arch-specific
--     reference paths.
--     If full subnormal support inside prod is needed in the
--     complex domain, prod must be upgraded first (this is a
--     library-wide scope decision).
--
--   Reset semantics:
--     This module has no rst_n_i port. It composes pure-pipeline
--     instances of lm_math_fpu_prod and lm_math_fpu_sum (neither
--     of which has rst either) plus a few operand-alignment shift
--     registers (s_a_re_dly, s_b_re_dly, s_b_im_dly, all
--     initialized to (others => '0') at elaboration -- a_im is
--     consumed directly without a delay line). The
--     dv_i / dv_o handshake of each internal prod/sum makes stale
--     internal state unobservable to the cmplx consumer: dv_o
--     is '0' at simulation start because every shift register and
--     every downstream dv_dly inside prod/sum is initialized to
--     '0'. Hardware power-up behaviour matches when the synthesis
--     flow honours register initialization (typical FPGA targets
--     like Xilinx / Intel preserve the init; ASIC flows usually
--     do not and would need an external reset to reach the same
--     state). Modules with FSM state (lm_math_fpu_sqrt) or
--     reset-clearable error pipelines (lm_math_fpu_div) do expose
--     rst_n_i; lm_math_fpu_mult_cmplx needs neither.
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

entity lm_math_fpu_mult_cmplx is
  generic(
    --* exponent width
    g_data_exp     : natural   := 8;
    --* mantissa width
    g_data_mant    : natural   := 23;
    --* rounding mode
    g_round_mode   : integer   := C_LM_ROUND_NEAREST;
    --* architecture: '1' = 4 multipliers, '0' = 3 multipliers
    g_architecture : std_logic := '1';
    --* pipeline stages of the integer multiplier
    g_pipe_stages  : natural   := 3
  );
  port(
    clk_i       : in  std_logic;
    dv_i        : in  std_logic;
    data_a_re_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    data_a_im_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    data_b_re_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    data_b_im_i : in  std_logic_vector(g_data_exp + g_data_mant downto 0);
    dout_re_o   : out std_logic_vector(g_data_exp + g_data_mant downto 0);
    dout_im_o   : out std_logic_vector(g_data_exp + g_data_mant downto 0);
    dv_o        : out std_logic;
    error_o     : out std_logic_vector(1 downto 0)
  );
end lm_math_fpu_mult_cmplx;

architecture a_rtl of lm_math_fpu_mult_cmplx is

  constant C_OP_W : natural := g_data_exp + g_data_mant + 1;

  signal s_data_a_m_re : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_data_a_re_d : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_data_b_im_d : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_data_b_re_d : std_logic_vector(g_data_exp + g_data_mant downto 0);

  signal s_c_err  : std_logic_vector(6 downto 0);
  signal s_c_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_c_dv_o : std_logic;

  signal s_d_err    : std_logic_vector(6 downto 0);
  signal s_d_data   : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_d_m_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_d_dv_o   : std_logic;

  signal s_e_err  : std_logic_vector(6 downto 0);
  signal s_e_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_e_dv_o : std_logic;

  signal s_f_err  : std_logic_vector(6 downto 0);
  signal s_f_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_f_dv_o : std_logic;

  signal s_g_err    : std_logic_vector(6 downto 0);
  signal s_g_data   : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_g_m_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_g_dv_o   : std_logic;

  signal s_h_err  : std_logic_vector(6 downto 0);
  signal s_h_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_h_dv_o : std_logic;

  signal s_i_err  : std_logic_vector(6 downto 0);
  signal s_i_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_i_dv_o : std_logic;

  signal s_l_err  : std_logic_vector(6 downto 0);
  signal s_l_data : std_logic_vector(g_data_exp + g_data_mant downto 0);
  signal s_l_dv_o : std_logic;

  --* In the 3-multiplier architecture each multiplier consumes one
  --  direct operand and one output from the parallel sums. The sums
  --  take C_SUM_LATENCY cycles, so the direct operands must be
  --  delayed by exactly that many cycles to arrive in step.
  --  The legacy code used g_pipe_stages here (the integer-multiplier
  --  pipeline depth), which is unrelated and produced misaligned
  --  data for any g_pipe_stages /= C_SUM_LATENCY -- effectively
  --  garbage output for the default generics.
  constant C_SUM_LATENCY : natural := 10;
  -- Initialized to '0' (matches every other inline shift register in
  -- the library) so the per-operand outputs do not propagate 'U'
  -- during the first C_SUM_LATENCY post-elaboration cycles.
  signal s_a_re_dly : std_logic_vector(C_SUM_LATENCY * C_OP_W - 1 downto 0)
                      := (others => '0');
  signal s_b_im_dly : std_logic_vector(C_SUM_LATENCY * C_OP_W - 1 downto 0)
                      := (others => '0');
  signal s_b_re_dly : std_logic_vector(C_SUM_LATENCY * C_OP_W - 1 downto 0)
                      := (others => '0');

begin

  assert (g_architecture = '0' or g_architecture = '1')
    report "g_architecture can only be '0' (3 mult) or '1' (4 mult)"
    severity failure;

  gen_4_mult_struct : if g_architecture = '1' generate
    -- x(re) = a(re)*b(re) - a(im)*b(im)
    -- x(im) = a(re)*b(im) + a(im)*b(re)

    inst_first_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => dv_i,
        multiplicand_a_i => data_a_re_i,
        multiplicand_b_i => data_b_re_i,
        dout_o           => s_c_data,
        dv_o             => s_c_dv_o,
        error_o          => s_c_err
      );

    inst_second_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => dv_i,
        multiplicand_a_i => data_a_im_i,
        multiplicand_b_i => data_b_im_i,
        dout_o           => s_d_data,
        dv_o             => s_d_dv_o,
        error_o          => s_d_err
      );

    inst_third_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => dv_i,
        multiplicand_a_i => data_a_re_i,
        multiplicand_b_i => data_b_im_i,
        dout_o           => s_e_data,
        dv_o             => s_e_dv_o,
        error_o          => s_e_err
      );

    inst_fourth_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => dv_i,
        multiplicand_a_i => data_a_im_i,
        multiplicand_b_i => data_b_re_i,
        dout_o           => s_f_data,
        dv_o             => s_f_dv_o,
        error_o          => s_f_err
      );

    -- x(re) = c + (-d)
    s_d_m_data(s_d_m_data'left)               <= not s_d_data(s_d_data'left);
    s_d_m_data(s_d_m_data'left - 1 downto 0)  <= s_d_data(s_d_data'left - 1 downto 0);

    inst_first_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => s_c_dv_o,
        din_a_i  => s_c_data,
        din_b_i  => s_d_m_data,
        dout_o   => s_g_data,
        dv_pre_o => open,
        dv_o     => s_g_dv_o,
        error_o  => s_g_err(3 downto 0)
      );

    -- x(im) = e + f
    inst_second_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => s_e_dv_o,
        din_a_i  => s_e_data,
        din_b_i  => s_f_data,
        dout_o   => s_h_data,
        dv_pre_o => open,
        dv_o     => s_h_dv_o,
        error_o  => s_h_err(3 downto 0)
      );

    dout_re_o  <= s_g_data;
    dout_im_o  <= s_h_data;
    dv_o       <= s_h_dv_o;
    error_o(0) <= s_g_err(0) or s_g_err(1) or s_h_err(0) or s_h_err(1);
    error_o(1) <= s_g_err(2) or s_g_err(3) or s_h_err(2) or s_h_err(3);
  end generate gen_4_mult_struct;

  gen_3_mult_struct : if g_architecture = '0' generate
    -- x(re) = a(re)*(b(re)+b(im)) - (a(im)+a(re))*b(im)
    -- x(im) = a(re)*(b(re)+b(im)) + (a(im)-a(re))*b(re)

    -- c = b(re) + b(im)
    inst_first_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => dv_i,
        din_a_i  => data_b_re_i,
        din_b_i  => data_b_im_i,
        dout_o   => s_c_data,
        dv_pre_o => open,
        dv_o     => s_c_dv_o,
        error_o  => s_c_err(3 downto 0)
      );

    -- d = a(im) + a(re)
    inst_second_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => dv_i,
        din_a_i  => data_a_re_i,
        din_b_i  => data_a_im_i,
        dout_o   => s_d_data,
        dv_pre_o => open,
        dv_o     => s_d_dv_o,
        error_o  => s_d_err(3 downto 0)
      );

    -- e = a(im) - a(re)
    s_data_a_m_re(s_data_a_m_re'left)              <= not data_a_re_i(data_a_re_i'left);
    s_data_a_m_re(s_data_a_m_re'left - 1 downto 0) <= data_a_re_i(data_a_re_i'left - 1
                                                                  downto 0);

    inst_third_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => dv_i,
        din_a_i  => data_a_im_i,
        din_b_i  => s_data_a_m_re,
        dout_o   => s_e_data,
        dv_pre_o => open,
        dv_o     => s_e_dv_o,
        error_o  => s_e_err(3 downto 0)
      );

    -- inline operand delays (formerly 3 external delay primitives)
    proc_op_delays : process(clk_i)
    begin
      if rising_edge(clk_i) then
        s_a_re_dly <= s_a_re_dly(s_a_re_dly'left - C_OP_W downto 0) & data_a_re_i;
        s_b_im_dly <= s_b_im_dly(s_b_im_dly'left - C_OP_W downto 0) & data_b_im_i;
        s_b_re_dly <= s_b_re_dly(s_b_re_dly'left - C_OP_W downto 0) & data_b_re_i;
      end if;
    end process proc_op_delays;

    s_data_a_re_d <= s_a_re_dly(s_a_re_dly'left
                                downto s_a_re_dly'left - C_OP_W + 1);
    s_data_b_im_d <= s_b_im_dly(s_b_im_dly'left
                                downto s_b_im_dly'left - C_OP_W + 1);
    s_data_b_re_d <= s_b_re_dly(s_b_re_dly'left
                                downto s_b_re_dly'left - C_OP_W + 1);

    -- f = a(re) * c. Triggered by the first_sum's dv_o so the multiplier
    -- samples only when its B operand (= c) is valid; s_data_a_re_d has
    -- already been delayed by C_SUM_LATENCY to arrive at the same cycle.
    inst_first_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => s_c_dv_o,
        multiplicand_a_i => s_data_a_re_d,
        multiplicand_b_i => s_c_data,
        dout_o           => s_f_data,
        dv_o             => s_f_dv_o,
        error_o          => s_f_err
      );

    -- g = d * b(im)
    inst_second_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => s_d_dv_o,
        multiplicand_a_i => s_data_b_im_d,
        multiplicand_b_i => s_d_data,
        dout_o           => s_g_data,
        dv_o             => s_g_dv_o,
        error_o          => s_g_err
      );

    -- h = e * b(re)
    inst_third_mult : entity lm_math_float_lib.lm_math_fpu_prod
      generic map(
        g_data_exp      => g_data_exp,
        g_data_mant     => g_data_mant,
        g_round_mode    => g_round_mode,
        g_mult_vs_logic => '1',
        g_pipe_stages   => g_pipe_stages
      )
      port map(
        clk_i            => clk_i,
        dv_i             => s_e_dv_o,
        multiplicand_a_i => s_data_b_re_d,
        multiplicand_b_i => s_e_data,
        dout_o           => s_h_data,
        dv_o             => s_h_dv_o,
        error_o          => s_h_err
      );

    -- i = f - g  -> x(re)
    s_g_m_data(s_g_m_data'left)               <= not s_g_data(s_g_data'left);
    s_g_m_data(s_g_m_data'left - 1 downto 0)  <= s_g_data(s_g_data'left - 1 downto 0);

    inst_fourth_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => s_f_dv_o,
        din_a_i  => s_f_data,
        din_b_i  => s_g_m_data,
        dout_o   => s_i_data,
        dv_pre_o => open,
        dv_o     => s_i_dv_o,
        error_o  => s_i_err(3 downto 0)
      );

    -- l = f + h  -> x(im)
    inst_fifth_sum : entity lm_math_float_lib.lm_math_fpu_sum
      generic map(
        g_data_exp   => g_data_exp,
        g_data_mant  => g_data_mant,
        g_round_mode => g_round_mode,
        g_operation  => 1
      )
      port map(
        clk_i    => clk_i,
        dv_i     => s_f_dv_o,
        din_a_i  => s_f_data,
        din_b_i  => s_h_data,
        dout_o   => s_l_data,
        dv_pre_o => open,
        dv_o     => s_l_dv_o,
        error_o  => s_l_err(3 downto 0)
      );

    dout_re_o  <= s_i_data;
    dout_im_o  <= s_l_data;
    dv_o       <= s_l_dv_o;
    error_o(0) <= s_i_err(0) or s_i_err(1) or s_l_err(0) or s_l_err(1);
    error_o(1) <= s_i_err(2) or s_i_err(3) or s_l_err(2) or s_l_err(3);
  end generate gen_3_mult_struct;

end a_rtl;
