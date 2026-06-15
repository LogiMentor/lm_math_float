--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_mult_cmplx
-- Description: Self-checking testbench for lm_math_fpu_mult_cmplx.
--              Two DUT instances are exercised in parallel, one per
--              supported architecture:
--                * uut_arch1 (g_architecture = '1') -> 4 mults + 2 sums
--                * uut_arch0 (g_architecture = '0') -> 3 mults + 5 sums
--              Both receive the same operands. The pipelines have
--              different latencies, so each has its own dv_o and its
--              own proc_check process. Per-DUT counters are merged in
--              proc_finish.
--
--              Coverage:
--                * 10 normal complex vectors verified for
--                  dout_re_o / dout_im_o vs. ieee.float_pkg (+-2 ULP)
--                  and for error_o = "00". Includes pure-imaginary
--                  inputs (vec 8) and integer-valued high-magnitude
--                  inputs (vec 9, exact in float32);
--                * 7 special bit-pattern vectors with NaN or inf in
--                  one of the four input components: the resulting
--                  error_o must have at least one bit set. Covers
--                  every (operand, sign) combination of the special
--                  inputs that the previous 4-vec set left out:
--                  inf in b_im alone, -inf in a_re (first sign='1'
--                  special), NaN in b_re alone;
--                * 9 denormal / boundary vectors exercising the
--                  internal prod + sum data path on subnormal
--                  magnitudes, denormal complex inputs, negative
--                  variants, an overflow case (vec 5), a negative
--                  denormal whose product remains subnormal-magnitude
--                  and FTZs to -0 (vec 6, locks down sign propagation
--                  through prod's FTZ path), the all-four-denormal
--                  corner where every internal product flushes to +0
--                  (vec 7), and a negative-subnormal-input * large-
--                  normal-input case whose product is BACK in the
--                  normal range (vec 8: -1e-40 * 1e+30 = -1e-10).
--                  Vec 8 locks the prod-side subnormal-input exponent
--                  fix end-to-end from the cmplx consumer side.
--                  Composition of prod (FTZ) + sum (full subnormal)
--                  is verified end-to-end on both architectures.
--
--              error_o layout (per lm_math_fpu_mult_cmplx):
--                bit 0 : any internal sum's NaN-A or NaN-B flag fired
--                        (some operand of the final stage was NaN)
--                bit 1 : any internal sum's inf-A or inf-B flag fired
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_mult_cmplx is
  generic(
    g_clk_period  : time    := 10 ns;
    g_data_exp    : natural := 8;
    g_data_mant   : natural := 23;
    g_round_mode  : integer := C_LM_ROUND_NEAREST;
    g_pipe_stages : natural := 3
  );
end tb_lm_math_fpu_mult_cmplx;

architecture tb of tb_lm_math_fpu_mult_cmplx is

  constant C_W      : natural := g_data_exp + g_data_mant + 1;
  constant C_N_NORM : natural := 10;
  constant C_N_SPEC : natural := 7;
  constant C_N_DENO : natural := 9;
  constant C_TOL    : natural := 2;

  --* Normal-phase complex operands.
  --    vec 8  : pure imaginary inputs (a_re = b_re = 0) -- exercises
  --             the path where two of the four internal products are
  --             zero (and one becomes the only contributor to v_re via
  --             cancellation: 0 - 1 = -1).
  --    vec 9  : higher-magnitude integer-valued operands so the
  --             cancellation product (300 - 800 = -500) and the
  --             sum-product (400 + 600 = 1000) are exact in float32
  --             and round-trip through both arch=1 and arch=0
  --             intermediate sums without ULP loss.
  type t_real_array is array (0 to C_N_NORM - 1) of real;
  constant C_A_RE : t_real_array :=
    ( 1.0, 0.5,  3.0, -2.0,  1.0,  0.0,  5.0,  1.0e-3,  0.0, 10.0);
  constant C_A_IM : t_real_array :=
    ( 2.0, 1.5, -1.0,  2.5, -1.0,  1.0, 12.0,  2.0e-3,  1.0, 20.0);
  constant C_B_RE : t_real_array :=
    ( 3.0, 2.0,  4.0,  1.0,  1.0,  1.0,  1.0,  1.0e3,   0.0, 30.0);
  constant C_B_IM : t_real_array :=
    (-1.0, 0.5,  2.0, -1.0,  0.0, -1.0,  0.0,  0.0,     1.0, 40.0);

  --* Denormal / boundary phase. The complex product is
  --    re = a_re*b_re - a_im*b_im
  --    im = a_re*b_im + a_im*b_re
  --  so any denormal magnitude on either side propagates through
  --  both prod (FTZ) and sum (full subnormal). Each vector below
  --  has an expected error_o pattern; vec 5 (overflow) is the only
  --  one that should raise an error bit.
  type t_real_array_d is array (0 to C_N_DENO - 1) of real;
  --   vec 6: negative denormal in a_re paired with a small normal
  --          b_re. The prod a_re*b_re = -1e-40 * 2.0 = -2e-40 stays
  --          in subnormal-magnitude territory, so prod FTZs to -0
  --          with sign='1'. This exercises the negative-sign FTZ
  --          path of prod (existing denormal vec 0 has positive
  --          a_re; vec 4 uses negative normal, not denormal). The
  --          two architectures legitimately differ on the v_re
  --          sign-zero: arch=1 computes -0 - +0 = -0; arch=0
  --          computes -0 - (-0) = +0 because its sister product
  --          g = b_im * d picks up sign='1' from d = -1e-40. Both
  --          are IEEE-correct; the f_check_component helper handles
  --          per-arch sign-zero comparison.
  --   vec 7: all four components subnormal-magnitude (1e-40). Every
  --          internal product is subnormal and gets FTZ'd to +0 on
  --          both arches. Result is exact (+0, +0). Locks down the
  --          "everything flushes" corner that the previous denormal
  --          set did not cover (only single or two-component
  --          denormals were tested).
  --   vec 8: negative subnormal A * large normal B with product
  --          BACK in the normal range (-1e-40 * 1e+30 = -1e-10).
  --          End-to-end lock of the prod 2.0.2 fix (effective-
  --          biased-exp promotion of subnormal inputs in
  --          proc_car_sum). This vector proves that the cmplx
  --          datapath composes correctly after the prod-side fix:
  --          both arches give (-1e-10, +0).
  --          arch=0's v_im benefits from exact cancellation
  --          (f + h = -1e-10 + 1e-10 = +0); arch=1's v_im comes
  --          from the inner FTZ products (-0 + +0 = +0). Either
  --          way the sign-zero on v_im is +0.
  --                                       vec0     vec1    vec2     vec3      vec4    vec5     vec6     vec7     vec8
  constant C_AD_RE : t_real_array_d := (1.0e-40, 2.0,    1.0e-20, 1.0e-40,  -1.0,   1.0e+30, -1.0e-40, 1.0e-40, -1.0e-40);
  constant C_AD_IM : t_real_array_d := (0.0,     0.0,    0.0,     2.0e-40,   2.0,   0.0,      0.0,     1.0e-40,  0.0);
  constant C_BD_RE : t_real_array_d := (2.0,     1.0e-40, 1.0e-20, 1.0,      3.0,   1.0e+30,  2.0,     1.0e-40,  1.0e+30);
  constant C_BD_IM : t_real_array_d := (0.0,     0.0,    0.0,     0.0,      -1.0,  0.0,      0.0,     1.0e-40,  0.0);
  --   Per-vector expected error_o. Only the overflow vec 5 should set
  --   a bit (the prod's overflow propagates an inf into the final
  --   sum, which raises its inf flag); the others are denormal-only,
  --   no special-input flags fire on the final sums.
  type t_err_array_d is array (0 to C_N_DENO - 1) of std_logic_vector(1 downto 0);
  constant C_DENO_ERR : t_err_array_d := (
    0 => "00", 1 => "00", 2 => "00", 3 => "00",
    4 => "00", 5 => "10", 6 => "00", 7 => "00",
    8 => "00"
  );

  function f_inf(sign : std_logic) return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0);
  begin
    v(C_W - 1)                    := sign;
    v(C_W - 2 downto g_data_mant) := (others => '1');
    v(g_data_mant - 1 downto 0)   := (others => '0');
    return v;
  end function;

  function f_nan(sign : std_logic) return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0);
  begin
    v                                  := (others => '0');
    v(C_W - 1)                         := sign;
    v(C_W - 2 downto g_data_mant)      := (others => '1');
    v(g_data_mant - 1)                 := '1';
    return v;
  end function;

  function f_normal(x : real) return std_logic_vector is
  begin
    return to_slv(to_float(x, g_data_exp, g_data_mant));
  end function;

  type t_slv_w is array (natural range <>) of std_logic_vector(C_W - 1 downto 0);

  --* Special-case operands; one component is NaN or inf, the others
  --  are normal. Expected error_o must be non-zero for each.
  signal C_SPEC_A_RE : t_slv_w(0 to C_N_SPEC - 1);
  signal C_SPEC_A_IM : t_slv_w(0 to C_N_SPEC - 1);
  signal C_SPEC_B_RE : t_slv_w(0 to C_N_SPEC - 1);
  signal C_SPEC_B_IM : t_slv_w(0 to C_N_SPEC - 1);

  signal clk_i       : std_logic := '0';
  signal dv_i        : std_logic := '0';
  signal data_a_re_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal data_a_im_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal data_b_re_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal data_b_im_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');

  signal dout_re_a1  : std_logic_vector(C_W - 1 downto 0);
  signal dout_im_a1  : std_logic_vector(C_W - 1 downto 0);
  signal dv_a1       : std_logic;
  signal err_a1      : std_logic_vector(1 downto 0);

  signal dout_re_a0  : std_logic_vector(C_W - 1 downto 0);
  signal dout_im_a0  : std_logic_vector(C_W - 1 downto 0);
  signal dv_a0       : std_logic;
  signal err_a0      : std_logic_vector(1 downto 0);

  signal s_n_errors_a1 : natural := 0;
  signal s_n_checks_a1 : natural := 0;
  signal s_n_errors_a0 : natural := 0;
  signal s_n_checks_a0 : natural := 0;
  signal s_done_a1     : boolean := false;
  signal s_done_a0     : boolean := false;
  signal sim_end       : boolean := false;

  function f_within(a, b : std_logic_vector; tol : natural) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= tol;
  end function;

  --* True if a float bit pattern has exp_field = 0 (subnormal or +-0).
  function f_ref_is_subnormal(s : std_logic_vector) return boolean is
  begin
    return unsigned(s(C_W - 2 downto g_data_mant)) = 0;
  end function;

  --* dout component "FTZ-zero" when exp + mant fields are zero (the
  --  sign bit may be 0 or 1; prod preserves the sign through its
  --  clamp).
  function f_is_zero_mag(s : std_logic_vector) return boolean is
  begin
    return unsigned(s(C_W - 2 downto 0)) = 0;
  end function;

  --* Compute "a * b" with the same FTZ rule that lm_math_fpu_prod
  --  applies internally: if the IEEE product has exp_field = 0
  --  (subnormal magnitude) the result is replaced by signed zero
  --  (sign of the IEEE product preserved). Used to model each
  --  lm_math_fpu_prod instance inside mult_cmplx -- both
  --  architectures place FTZ at every prod output, so this same
  --  helper applies in both reference paths (the architectures
  --  differ in WHICH products feed which downstream sum, not in
  --  whether each prod flushes).
  function f_prod_ftz(a, b : float) return float is
    variable v : float(g_data_exp downto -g_data_mant);
    variable s : std_logic_vector(C_W - 1 downto 0);
  begin
    v := a * b;
    s := to_slv(v);
    if f_ref_is_subnormal(s) then
      s(C_W - 2 downto 0) := (others => '0');
      v := to_float(s, g_data_exp, g_data_mant);
    end if;
    return v;
  end function;

  --* Verify a single dout component against the (post-FTZ)
  --  reference. Returns true if the DUT output matches the model:
  --    * if the reference is zero-magnitude (exp + mant fields all
  --      zero, which captures the post-FTZ +-0 case), the DUT must
  --      be zero-magnitude AND have a matching sign bit
  --      (prod preserves sign through its clamp);
  --    * otherwise compare full bit pattern within tolerance.
  --  Used by the denormal-phase checker to fold re and im checks
  --  into a single combined "dout" assertion, mirroring the
  --  normal-phase pattern (one dout check + one error_o check
  --  per vector).
  function f_check_component(dut, ref : std_logic_vector;
                             tol : natural) return boolean is
  begin
    if f_is_zero_mag(ref) then
      return f_is_zero_mag(dut) and (dut(C_W - 1) = ref(C_W - 1));
    else
      return f_within(dut, ref, tol);
    end if;
  end function;

begin

  --   special cases: NaN/inf in one component
  C_SPEC_A_RE(0) <= f_nan('0');     C_SPEC_A_IM(0) <= f_normal(0.0);
  C_SPEC_B_RE(0) <= f_normal(1.0);  C_SPEC_B_IM(0) <= f_normal(0.0);

  C_SPEC_A_RE(1) <= f_normal(1.0);  C_SPEC_A_IM(1) <= f_nan('0');
  C_SPEC_B_RE(1) <= f_normal(1.0);  C_SPEC_B_IM(1) <= f_normal(0.0);

  C_SPEC_A_RE(2) <= f_inf('0');     C_SPEC_A_IM(2) <= f_normal(0.0);
  C_SPEC_B_RE(2) <= f_normal(1.0);  C_SPEC_B_IM(2) <= f_normal(0.0);

  C_SPEC_A_RE(3) <= f_normal(1.0);  C_SPEC_A_IM(3) <= f_normal(0.0);
  C_SPEC_B_RE(3) <= f_inf('0');     C_SPEC_B_IM(3) <= f_nan('0');

  --   vec 4: +inf isolated in b_im. The previous set never put a
  --   special into b_im alone, so the cross-product
  --   ad = a_re * b_im feeds inf into the downstream im sum.
  C_SPEC_A_RE(4) <= f_normal(1.0);  C_SPEC_A_IM(4) <= f_normal(0.0);
  C_SPEC_B_RE(4) <= f_normal(1.0);  C_SPEC_B_IM(4) <= f_inf('0');

  --   vec 5: -inf in a_re. Locks down the negative-sign inf path:
  --   the previous set only used sign='0' specials, so this is the
  --   first time the special-detection path sees sign='1'.
  C_SPEC_A_RE(5) <= f_inf('1');     C_SPEC_A_IM(5) <= f_normal(0.0);
  C_SPEC_B_RE(5) <= f_normal(1.0);  C_SPEC_B_IM(5) <= f_normal(0.0);

  --   vec 6: NaN isolated in b_re (no other special). Verifies the
  --   NaN-detection path on the b_re-only input -- vec 0 / vec 1
  --   covered NaN on a_re / a_im, and vec 3 had NaN on b_im paired
  --   with inf on b_re. This vec isolates b_re as the sole special.
  C_SPEC_A_RE(6) <= f_normal(1.0);  C_SPEC_A_IM(6) <= f_normal(0.0);
  C_SPEC_B_RE(6) <= f_nan('0');     C_SPEC_B_IM(6) <= f_normal(0.0);

  uut_arch1 : entity lm_math_float_lib.lm_math_fpu_mult_cmplx
    generic map(
      g_data_exp     => g_data_exp,
      g_data_mant    => g_data_mant,
      g_round_mode   => g_round_mode,
      g_architecture => '1',
      g_pipe_stages  => g_pipe_stages
    )
    port map(
      clk_i       => clk_i,
      dv_i        => dv_i,
      data_a_re_i => data_a_re_i,
      data_a_im_i => data_a_im_i,
      data_b_re_i => data_b_re_i,
      data_b_im_i => data_b_im_i,
      dout_re_o   => dout_re_a1,
      dout_im_o   => dout_im_a1,
      dv_o        => dv_a1,
      error_o     => err_a1
    );

  uut_arch0 : entity lm_math_float_lib.lm_math_fpu_mult_cmplx
    generic map(
      g_data_exp     => g_data_exp,
      g_data_mant    => g_data_mant,
      g_round_mode   => g_round_mode,
      g_architecture => '0',
      g_pipe_stages  => g_pipe_stages
    )
    port map(
      clk_i       => clk_i,
      dv_i        => dv_i,
      data_a_re_i => data_a_re_i,
      data_a_im_i => data_a_im_i,
      data_b_re_i => data_b_re_i,
      data_b_im_i => data_b_im_i,
      dout_re_o   => dout_re_a0,
      dout_im_o   => dout_im_a0,
      dv_o        => dv_a0,
      error_o     => err_a0
    );

  proc_clk : process
  begin
    while not sim_end loop
      clk_i <= '0';
      wait for g_clk_period / 2;
      clk_i <= '1';
      wait for g_clk_period / 2;
    end loop;
    wait;
  end process;

  proc_stim : process
  begin
    wait for 5 * g_clk_period;
    wait until rising_edge(clk_i);
    dv_i <= '1';
    for i in 0 to C_N_NORM - 1 loop
      data_a_re_i <= f_normal(C_A_RE(i));
      data_a_im_i <= f_normal(C_A_IM(i));
      data_b_re_i <= f_normal(C_B_RE(i));
      data_b_im_i <= f_normal(C_B_IM(i));
      wait until rising_edge(clk_i);
    end loop;
    for i in 0 to C_N_SPEC - 1 loop
      data_a_re_i <= C_SPEC_A_RE(i);
      data_a_im_i <= C_SPEC_A_IM(i);
      data_b_re_i <= C_SPEC_B_RE(i);
      data_b_im_i <= C_SPEC_B_IM(i);
      wait until rising_edge(clk_i);
    end loop;
    for i in 0 to C_N_DENO - 1 loop
      data_a_re_i <= f_normal(C_AD_RE(i));
      data_a_im_i <= f_normal(C_AD_IM(i));
      data_b_re_i <= f_normal(C_BD_RE(i));
      data_b_im_i <= f_normal(C_BD_IM(i));
      wait until rising_edge(clk_i);
    end loop;
    dv_i <= '0';
    wait;
  end process;

  --* check arch='1' DUT against the float-domain reference.
  proc_check_a1 : process
    variable v_re, v_im : float(g_data_exp downto -g_data_mant);
    variable v_ar, v_ai, v_br, v_bi
                       : float(g_data_exp downto -g_data_mant);
    variable v_re_ok, v_im_ok : boolean;
  begin
    wait until dv_a1 = '1';
    --   normal phase
    for i in 0 to C_N_NORM - 1 loop
      v_re := to_float(C_A_RE(i), g_data_exp, g_data_mant)
              * to_float(C_B_RE(i), g_data_exp, g_data_mant)
              - to_float(C_A_IM(i), g_data_exp, g_data_mant)
              * to_float(C_B_IM(i), g_data_exp, g_data_mant);
      v_im := to_float(C_A_RE(i), g_data_exp, g_data_mant)
              * to_float(C_B_IM(i), g_data_exp, g_data_mant)
              + to_float(C_A_IM(i), g_data_exp, g_data_mant)
              * to_float(C_B_RE(i), g_data_exp, g_data_mant);
      wait for 1 ps;
      if not f_within(dout_re_a1, to_slv(v_re), C_TOL)
         or not f_within(dout_im_a1, to_slv(v_im), C_TOL) then
        s_n_errors_a1 <= s_n_errors_a1 + 1;
        report "mult_cmplx(arch1) dout mismatch vec " & integer'image(i)
          severity warning;
      end if;
      if err_a1 /= "00" then
        s_n_errors_a1 <= s_n_errors_a1 + 1;
        report "mult_cmplx(arch1) error_o /= 0 on normal vec "
               & integer'image(i) severity warning;
      end if;
      s_n_checks_a1 <= s_n_checks_a1 + 2;
      wait until rising_edge(clk_i);
    end loop;

    --   special phase: only require error_o to be non-zero (some bit
    --   asserted). Output values are implementation-defined on NaN/inf
    --   complex operands.
    for i in 0 to C_N_SPEC - 1 loop
      wait for 1 ps;
      if err_a1 = "00" then
        s_n_errors_a1 <= s_n_errors_a1 + 1;
        report "mult_cmplx(arch1) error_o = 0 on special vec "
               & integer'image(i) severity warning;
      end if;
      s_n_checks_a1 <= s_n_checks_a1 + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   denormal / boundary phase. The reference is built by
    --   applying prod's FTZ rule at each lm_math_fpu_prod instance
    --   output in the arch=1 (4-mult, straightforward) datapath:
    --       ac = a_re * b_re   (FTZ if subnormal)
    --       bd = a_im * b_im   (FTZ if subnormal)
    --       ad = a_re * b_im   (FTZ if subnormal)
    --       bc = a_im * b_re   (FTZ if subnormal)
    --       v_re = ac - bd     (downstream sum, full subnormal OK)
    --       v_im = ad + bc
    --   A simple "if final component is subnormal -> expect FTZ"
    --   check would miss the case where two normal-magnitude
    --   products cancel into a subnormal final result (no flush
    --   there). The arch=0 reference is built differently below.
    --   Overflow vecs only check error_o.
    for i in 0 to C_N_DENO - 1 loop
      v_ar := to_float(C_AD_RE(i), g_data_exp, g_data_mant);
      v_ai := to_float(C_AD_IM(i), g_data_exp, g_data_mant);
      v_br := to_float(C_BD_RE(i), g_data_exp, g_data_mant);
      v_bi := to_float(C_BD_IM(i), g_data_exp, g_data_mant);
      v_re := f_prod_ftz(v_ar, v_br) - f_prod_ftz(v_ai, v_bi);
      v_im := f_prod_ftz(v_ar, v_bi) + f_prod_ftz(v_ai, v_br);
      wait for 1 ps;
      if err_a1 /= C_DENO_ERR(i) then
        s_n_errors_a1 <= s_n_errors_a1 + 1;
        report "mult_cmplx(arch1) error_o mismatch on denormal vec "
               & integer'image(i)
               & " actual=" & to_string(err_a1)
               & " expected=" & to_string(C_DENO_ERR(i))
          severity warning;
      end if;
      if C_DENO_ERR(i) = "00" then
        --   Combined dout check: both components must match the
        --   post-FTZ reference (per-component: zero-magnitude with
        --   matching sign, or within tolerance). Counts as a single
        --   "dout" comparison so the +2 increment matches the
        --   normal phase pattern (dout + error_o).
        v_re_ok := f_check_component(dout_re_a1, to_slv(v_re), C_TOL);
        v_im_ok := f_check_component(dout_im_a1, to_slv(v_im), C_TOL);
        if not (v_re_ok and v_im_ok) then
          s_n_errors_a1 <= s_n_errors_a1 + 1;
          report "mult_cmplx(arch1) dout mismatch on vec "
                 & integer'image(i)
                 & " (re_ok=" & boolean'image(v_re_ok)
                 & " im_ok=" & boolean'image(v_im_ok) & ")"
                 & " re="     & to_hstring(dout_re_a1)
                 & " ref_re=" & to_hstring(to_slv(v_re))
                 & " im="     & to_hstring(dout_im_a1)
                 & " ref_im=" & to_hstring(to_slv(v_im))
            severity warning;
        end if;
        s_n_checks_a1 <= s_n_checks_a1 + 2;
      else
        s_n_checks_a1 <= s_n_checks_a1 + 1;
      end if;
      wait until rising_edge(clk_i);
    end loop;

    s_done_a1 <= true;
    wait;
  end process;

  --* check arch='0' DUT identically.
  proc_check_a0 : process
    variable v_re, v_im : float(g_data_exp downto -g_data_mant);
    variable v_ar, v_ai, v_br, v_bi
                        : float(g_data_exp downto -g_data_mant);
    variable v_c, v_d, v_e, v_f, v_g, v_h
                        : float(g_data_exp downto -g_data_mant);
    variable v_re_ok, v_im_ok : boolean;
  begin
    wait until dv_a0 = '1';
    for i in 0 to C_N_NORM - 1 loop
      v_re := to_float(C_A_RE(i), g_data_exp, g_data_mant)
              * to_float(C_B_RE(i), g_data_exp, g_data_mant)
              - to_float(C_A_IM(i), g_data_exp, g_data_mant)
              * to_float(C_B_IM(i), g_data_exp, g_data_mant);
      v_im := to_float(C_A_RE(i), g_data_exp, g_data_mant)
              * to_float(C_B_IM(i), g_data_exp, g_data_mant)
              + to_float(C_A_IM(i), g_data_exp, g_data_mant)
              * to_float(C_B_RE(i), g_data_exp, g_data_mant);
      wait for 1 ps;
      if not f_within(dout_re_a0, to_slv(v_re), C_TOL)
         or not f_within(dout_im_a0, to_slv(v_im), C_TOL) then
        s_n_errors_a0 <= s_n_errors_a0 + 1;
        report "mult_cmplx(arch0) dout mismatch vec " & integer'image(i)
          severity warning;
      end if;
      if err_a0 /= "00" then
        s_n_errors_a0 <= s_n_errors_a0 + 1;
        report "mult_cmplx(arch0) error_o /= 0 on normal vec "
               & integer'image(i) severity warning;
      end if;
      s_n_checks_a0 <= s_n_checks_a0 + 2;
      wait until rising_edge(clk_i);
    end loop;

    for i in 0 to C_N_SPEC - 1 loop
      wait for 1 ps;
      if err_a0 = "00" then
        s_n_errors_a0 <= s_n_errors_a0 + 1;
        report "mult_cmplx(arch0) error_o = 0 on special vec "
               & integer'image(i) severity warning;
      end if;
      s_n_checks_a0 <= s_n_checks_a0 + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   denormal / boundary phase with arch=0 (3-mult Gauss /
    --   Karatsuba) reference. Internal datapath in
    --   gen_3_mult_struct:
    --       c = b_re + b_im             (full subnormal in sum)
    --       d = a_im + a_re             (full subnormal)
    --       e = a_im - a_re             (full subnormal)
    --       f = a_re * c                (FTZ if subnormal)
    --       g = b_im * d                (FTZ if subnormal)
    --       h = b_re * e                (FTZ if subnormal)
    --       v_re = f - g                (full subnormal)
    --       v_im = f + h
    --   FTZ is applied at the three prod outputs f, g, h (not at
    --   ac/bd/ad/bc which don't exist in this datapath).
    for i in 0 to C_N_DENO - 1 loop
      v_ar := to_float(C_AD_RE(i), g_data_exp, g_data_mant);
      v_ai := to_float(C_AD_IM(i), g_data_exp, g_data_mant);
      v_br := to_float(C_BD_RE(i), g_data_exp, g_data_mant);
      v_bi := to_float(C_BD_IM(i), g_data_exp, g_data_mant);
      v_c  := v_br + v_bi;
      v_d  := v_ai + v_ar;
      v_e  := v_ai - v_ar;
      v_f  := f_prod_ftz(v_ar, v_c);
      v_g  := f_prod_ftz(v_bi, v_d);
      v_h  := f_prod_ftz(v_br, v_e);
      v_re := v_f - v_g;
      v_im := v_f + v_h;
      wait for 1 ps;
      if err_a0 /= C_DENO_ERR(i) then
        s_n_errors_a0 <= s_n_errors_a0 + 1;
        report "mult_cmplx(arch0) error_o mismatch on denormal vec "
               & integer'image(i)
               & " actual=" & to_string(err_a0)
               & " expected=" & to_string(C_DENO_ERR(i))
          severity warning;
      end if;
      if C_DENO_ERR(i) = "00" then
        --   Combined dout check (mirrors arch1, see proc_check_a1
        --   for the rationale).
        v_re_ok := f_check_component(dout_re_a0, to_slv(v_re), C_TOL);
        v_im_ok := f_check_component(dout_im_a0, to_slv(v_im), C_TOL);
        if not (v_re_ok and v_im_ok) then
          s_n_errors_a0 <= s_n_errors_a0 + 1;
          report "mult_cmplx(arch0) dout mismatch on vec "
                 & integer'image(i)
                 & " (re_ok=" & boolean'image(v_re_ok)
                 & " im_ok=" & boolean'image(v_im_ok) & ")"
                 & " re="     & to_hstring(dout_re_a0)
                 & " ref_re=" & to_hstring(to_slv(v_re))
                 & " im="     & to_hstring(dout_im_a0)
                 & " ref_im=" & to_hstring(to_slv(v_im))
            severity warning;
        end if;
        s_n_checks_a0 <= s_n_checks_a0 + 2;
      else
        s_n_checks_a0 <= s_n_checks_a0 + 1;
      end if;
      wait until rising_edge(clk_i);
    end loop;

    s_done_a0 <= true;
    wait;
  end process;

  proc_finish : process
    variable v_total_err : natural;
    variable v_total_chk : natural;
  begin
    wait until s_done_a1 and s_done_a0;
    wait for 5 * g_clk_period;
    v_total_err := s_n_errors_a1 + s_n_errors_a0;
    v_total_chk := s_n_checks_a1 + s_n_checks_a0;
    assert v_total_err = 0
      report "TEST FAILED: " & integer'image(v_total_err) & " / "
             & integer'image(v_total_chk) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(v_total_chk) & " comparisons OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
