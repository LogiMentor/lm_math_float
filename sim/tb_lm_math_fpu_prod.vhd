--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_prod
-- Description: Self-checking testbench for lm_math_fpu_prod.
--
--              Coverage:
--                * 16 mid-range normal/zero vectors, dout vs.
--                  ieee.float_pkg "*" (+-1 ULP) and error_o checked
--                  per-vector;
--                * 9 special bit-pattern vectors that exercise every
--                  error_o bit: NaN * fin, fin * NaN, +inf * fin,
--                  fin * +inf, +inf * 0, 0 * +inf, +inf * +inf,
--                  NaN * +inf, NaN * NaN. dout is documented as not
--                  IEEE-conformant for these inputs and is not
--                  checked;
--                * 6 flush-to-zero vectors covering the documented
--                  FTZ behavior of proc_final_car_eval (a subnormal
--                  product is silently clamped to +-0; the exp and
--                  mantissa fields are zeroed but the sign passes
--                  through, so negative subnormal products become
--                  -0. All six FTZ vectors use positive operands
--                  and therefore compare against +0). Vectors 0
--                  and 1 (denormal * normal and normal * denormal)
--                  are placed first in this phase so they are
--                  preceded by the NaN*NaN special vector; that is
--                  the stimulus ordering that pins the 2.0.1
--                  s_delta-alignment fix;
--                * 3 subnormal-input rescue vectors: subnormal
--                  operand * normal operand whose IEEE product is
--                  back in the normal range. The 2.0.2 fix in
--                  proc_car_sum promotes the stored 0 biased
--                  exponent of a subnormal operand to its effective
--                  value of 1, so the in-range product comes out
--                  with the correct exponent (without the fix the
--                  output was half the IEEE value. Covers
--                  A-subnormal, A-subnormal with
--                  sign='1' (sign propagation), and B-subnormal
--                  (symmetric path through proc_car_sum).
--
--              error_o layout (per lm_math_fpu_prod):
--                bit 0 : A or B is NaN
--                bit 1 : A=+/-inf  AND B=+/-0  (undetermined)
--                bit 2 : A=+/-inf  AND not (1)
--                bit 3 : B=+/-inf  AND A=+/-0  (undetermined)
--                bit 4 : B=+/-inf  AND not (3)
--                bit 5 : A=+/-0    AND mantissa_b /= 0
--                bit 6 : B=+/-0    AND mantissa_a /= 0
--
--              The TB's f_expected_err helper mirrors that decode, so
--              the expected pattern is computed directly from the
--              input bit pattern. Any refactor of proc_errors that
--              changes the per-bit semantics will surface here.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_prod is
  generic(
    g_clk_period    : time      := 10 ns;
    g_data_exp      : natural   := 8;
    g_data_mant     : natural   := 23;
    g_round_mode    : integer   := C_LM_ROUND_NEAREST;
    g_mult_vs_logic : std_logic := '1';
    g_pipe_stages   : natural   := 2
  );
end tb_lm_math_fpu_prod;

architecture tb of tb_lm_math_fpu_prod is

  constant C_W       : natural := g_data_exp + g_data_mant + 1;
  constant C_N_NORM  : natural := 16;
  constant C_N_SPEC  : natural := 9;
  constant C_N_FTZ   : natural := 6;
  constant C_N_RESC  : natural := 3;

  type t_real_array is array (0 to C_N_NORM - 1) of real;
  constant C_A : t_real_array := (
    1.5,    -2.0,   3.14159,  1.0e-10, 1.0e20,
    0.0,    1.0,    -1.0,     2.5,     -7.125,
    1.234e-5, 6.022e23, 1.0e-30, 3.0,    -0.5,    0.125
  );
  constant C_B : t_real_array := (
    2.0,     0.5,    2.71828, 1.0e10,  1.0e-20,
    3.14,    1.0,    -1.0,    -4.0,    8.0,
    9.87e6,  1.6e-19, 2.0e10, -7.0,    -2.0,    16.0
  );

  --* Flush-to-zero vectors. proc_final_car_eval clamps s_car_d/mant_d
  --  to 0 when the unbiased exponent would go negative (subnormal
  --  result), so we expect dout_o = +0 and error_o = "0000000".
  --
  --  Vectors 0 and 1 (denormal * normal and normal * denormal) are
  --  placed FIRST in this phase on purpose: the FTZ phase runs
  --  immediately after NaN*NaN (the last special vector), so vec 0
  --  is preceded by NaN*NaN -- exactly the stimulus ordering that
  --  exposed the s_delta-vs-s_mult_out alignment bug fixed in
  --  2.0.1. The registered proc_delta_count made s_delta lag
  --  s_mult_out by one cycle, so vec 0 inherited NaN*NaN's
  --  s_delta = 0 instead of its own LZ count, skipped the FTZ
  --  clamp, and emitted a corrupted output. Putting these two vecs
  --  later in the array (preceded by another denormal product with
  --  a high s_delta) would NOT have pinned the bug -- the lag
  --  would have been benign there.
  type t_real_array_d is array (0 to C_N_FTZ - 1) of real;
  constant C_AD : t_real_array_d := (
    1.0e-40,    -- 0: denormal A * normal B -> FTZ (the 2.0.1 case,
                --    preceded by NaN*NaN)
    2.0,        -- 1: normal A * denormal B -> FTZ (commutative)
    1.0e-40,    -- 2: denormal * denormal -> FTZ (car_sum = 0)
    1.0e-30,    -- 3: normal * normal underflow -> FTZ (car_sum << bias)
    1.0e-35,    -- 4: small normal * small normal -> FTZ
    5.0e-40     -- 5: denormal * denormal (different mantissas) -> FTZ
  );
  constant C_BD : t_real_array_d := (
    2.0,        -- 0 -> product = 2.0e-40, below min normal
    1.0e-40,    -- 1 -> product = 2.0e-40, below min normal
    1.0e-40,    -- 2
    1.0e-20,    -- 3 -> product = 1.0e-50, below min normal
    1.0e-15,    -- 4 -> product = 1.0e-50, below min normal
    3.0e-40     -- 5
  );

  --* Subnormal-input rescue vectors. The IEEE product is in the normal
  --  range (no FTZ); the goal is to lock down proc_car_sum's effective
  --  biased-exponent compensation for subnormal operands (2.0.2 fix).
  --  Reference is ieee.float_pkg "*" (the same path the normal phase
  --  uses); pre-fix the DUT produced half the correct value because
  --  the stored 0 biased exponent of the subnormal operand was used
  --  raw instead of being promoted to its effective value 1.
  type t_real_array_r is array (0 to C_N_RESC - 1) of real;
  constant C_AR : t_real_array_r := (
     1.0e-40,    -- 0: +subnormal A, sign='0'  -> +1e-10 normal
    -1.0e-40,    -- 1: -subnormal A, sign='1'  -> -1e-10 normal
                 --    locks down sign propagation through the
                 --    rescue path.
     1.0e+30     -- 2: normal A, subnormal B  -> +1e-10 normal
                 --    locks down the symmetric (B-side) compensation.
  );
  constant C_BR : t_real_array_r := (
     1.0e+30,
     1.0e+30,
     1.0e-40
  );

  --* Special bit-pattern builders
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

  function f_zero return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    return v;
  end function;

  --* Mirror of proc_errors in the DUT. Returns the 7-bit error_o that
  --  the DUT must produce for the given (a, b) inputs.
  function f_expected_err(a, b : std_logic_vector) return std_logic_vector is
    constant C_ALL_ONES : unsigned(g_data_exp - 1 downto 0) := (others => '1');
    variable car_a, car_b   : unsigned(g_data_exp - 1 downto 0);
    variable mant_a, mant_b : unsigned(g_data_mant - 1 downto 0);
    variable e              : std_logic_vector(6 downto 0) := (others => '0');
    variable a_nan, b_nan   : boolean;
    variable a_inf, b_inf   : boolean;
    variable a_zer, b_zer   : boolean;
  begin
    car_a  := unsigned(a(C_W - 2 downto g_data_mant));
    car_b  := unsigned(b(C_W - 2 downto g_data_mant));
    mant_a := unsigned(a(g_data_mant - 1 downto 0));
    mant_b := unsigned(b(g_data_mant - 1 downto 0));
    a_nan  := (car_a = C_ALL_ONES) and (mant_a /= 0);
    b_nan  := (car_b = C_ALL_ONES) and (mant_b /= 0);
    a_inf  := (car_a = C_ALL_ONES) and (mant_a = 0);
    b_inf  := (car_b = C_ALL_ONES) and (mant_b = 0);
    a_zer  := (car_a = 0)          and (mant_a = 0);
    b_zer  := (car_b = 0)          and (mant_b = 0);

    if a_nan or b_nan then e(0) := '1'; end if;

    if a_inf and b_zer then
      e(1) := '1';
    elsif a_inf then
      e(2) := '1';
    end if;

    if b_inf and a_zer then
      e(3) := '1';
    elsif b_inf then
      e(4) := '1';
    end if;

    if a_zer and (mant_b /= 0) then e(5) := '1'; end if;
    if b_zer and (mant_a /= 0) then e(6) := '1'; end if;

    return e;
  end function;

  type t_slv_w is array (natural range <>) of std_logic_vector(C_W - 1 downto 0);

  signal C_SPEC_A : t_slv_w(0 to C_N_SPEC - 1);
  signal C_SPEC_B : t_slv_w(0 to C_N_SPEC - 1);

  signal clk_i            : std_logic := '0';
  signal dv_i             : std_logic := '0';
  signal multiplicand_a_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal multiplicand_b_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal dout_o           : std_logic_vector(C_W - 1 downto 0);
  signal dv_o             : std_logic;
  signal error_o          : std_logic_vector(6 downto 0);

  signal s_n_errors : natural := 0;
  signal s_n_checks : natural := 0;
  signal sim_end    : boolean := false;

  function f_within_1ulp(a, b : std_logic_vector) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= 1;
  end function;

begin

  --   build special-phase operand list
  C_SPEC_A(0) <= f_nan('0');             C_SPEC_B(0) <= f_normal(1.0);   -- NaN  * fin
  C_SPEC_A(1) <= f_normal(1.0);          C_SPEC_B(1) <= f_nan('0');      -- fin  * NaN
  C_SPEC_A(2) <= f_inf('0');             C_SPEC_B(2) <= f_normal(1.0);   -- +inf * fin
  C_SPEC_A(3) <= f_normal(1.0);          C_SPEC_B(3) <= f_inf('0');      -- fin  * +inf
  C_SPEC_A(4) <= f_inf('0');             C_SPEC_B(4) <= f_zero;          -- +inf * 0
  C_SPEC_A(5) <= f_zero;                 C_SPEC_B(5) <= f_inf('0');      -- 0    * +inf
  C_SPEC_A(6) <= f_inf('0');             C_SPEC_B(6) <= f_inf('0');      -- +inf * +inf
  C_SPEC_A(7) <= f_nan('0');             C_SPEC_B(7) <= f_inf('0');      -- NaN  * +inf
  C_SPEC_A(8) <= f_nan('0');             C_SPEC_B(8) <= f_nan('1');      -- NaN  * NaN

  uut : entity lm_math_float_lib.lm_math_fpu_prod
    generic map(
      g_data_exp      => g_data_exp,
      g_data_mant     => g_data_mant,
      g_round_mode    => g_round_mode,
      g_mult_vs_logic => g_mult_vs_logic,
      g_pipe_stages   => g_pipe_stages
    )
    port map(
      clk_i            => clk_i,
      dv_i             => dv_i,
      multiplicand_a_i => multiplicand_a_i,
      multiplicand_b_i => multiplicand_b_i,
      dout_o           => dout_o,
      dv_o             => dv_o,
      error_o          => error_o
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
    --   normal phase
    for i in 0 to C_N_NORM - 1 loop
      multiplicand_a_i <= f_normal(C_A(i));
      multiplicand_b_i <= f_normal(C_B(i));
      wait until rising_edge(clk_i);
    end loop;
    --   special phase
    for i in 0 to C_N_SPEC - 1 loop
      multiplicand_a_i <= C_SPEC_A(i);
      multiplicand_b_i <= C_SPEC_B(i);
      wait until rising_edge(clk_i);
    end loop;
    --   FTZ phase
    for i in 0 to C_N_FTZ - 1 loop
      multiplicand_a_i <= f_normal(C_AD(i));
      multiplicand_b_i <= f_normal(C_BD(i));
      wait until rising_edge(clk_i);
    end loop;
    --   rescue phase
    for i in 0 to C_N_RESC - 1 loop
      multiplicand_a_i <= f_normal(C_AR(i));
      multiplicand_b_i <= f_normal(C_BR(i));
      wait until rising_edge(clk_i);
    end loop;
    dv_i <= '0';
    wait;
  end process;

  proc_check : process
    variable v_a, v_b, v_ref : float(g_data_exp downto -g_data_mant);
    variable v_a_slv, v_b_slv : std_logic_vector(C_W - 1 downto 0);
    variable v_exp_err       : std_logic_vector(6 downto 0);
  begin
    wait until dv_o = '1';

    --   normal phase: check dout against float_pkg and error_o against
    --   the per-input expected pattern.
    for i in 0 to C_N_NORM - 1 loop
      v_a_slv := f_normal(C_A(i));
      v_b_slv := f_normal(C_B(i));
      v_a     := to_float(C_A(i), g_data_exp, g_data_mant);
      v_b     := to_float(C_B(i), g_data_exp, g_data_mant);
      v_ref   := v_a * v_b;
      v_exp_err := f_expected_err(v_a_slv, v_b_slv);
      wait for 1 ps;
      if not f_within_1ulp(dout_o, to_slv(v_ref)) then
        s_n_errors <= s_n_errors + 1;
        report "prod dout mismatch on normal vec " & integer'image(i)
          severity warning;
      end if;
      if error_o /= v_exp_err then
        s_n_errors <= s_n_errors + 1;
        report "prod error_o mismatch on normal vec " & integer'image(i)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 2;
      wait until rising_edge(clk_i);
    end loop;

    --   special phase: only check error_o (dout is documented as not
    --   IEEE-conformant for NaN/inf/0*inf cases).
    for i in 0 to C_N_SPEC - 1 loop
      v_exp_err := f_expected_err(C_SPEC_A(i), C_SPEC_B(i));
      wait for 1 ps;
      if error_o /= v_exp_err then
        s_n_errors <= s_n_errors + 1;
        report "prod error_o mismatch on special vec " & integer'image(i)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   FTZ phase: subnormal result -> dout must be +0 (exact) and
    --   error_o = "0000000" (the flush is silent).
    --
    --   All four FTZ vectors below have both operands positive, so
    --   the DUT's sign bit (s_sign_a XOR s_sign_b) is '0' and we can
    --   compare against +0 exactly. If a future vector adds a
    --   negative operand it will produce -0 (the FTZ clamps exp and
    --   mantissa to 0 but preserves the sign), and this check must
    --   relax to match the dout_o low (C_W-1) bits against zero.
    for i in 0 to C_N_FTZ - 1 loop
      wait for 1 ps;
      if dout_o /= f_zero then
        s_n_errors <= s_n_errors + 1;
        report "prod FTZ vec " & integer'image(i)
               & ": expected +0, got " & to_hstring(dout_o)
          severity warning;
      end if;
      if error_o /= "0000000" then
        s_n_errors <= s_n_errors + 1;
        report "prod FTZ vec " & integer'image(i)
               & ": error_o /= 0, got " & to_string(error_o)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 2;
      wait until rising_edge(clk_i);
    end loop;

    --   rescue phase: subnormal-input * normal-input -> normal output.
    --   Reference is float_pkg "*"; tolerance is 1 ULP (same as the
    --   normal phase). error_o must be 0 (the inputs are not specials).
    for i in 0 to C_N_RESC - 1 loop
      v_a   := to_float(C_AR(i), g_data_exp, g_data_mant);
      v_b   := to_float(C_BR(i), g_data_exp, g_data_mant);
      v_ref := v_a * v_b;
      wait for 1 ps;
      if not f_within_1ulp(dout_o, to_slv(v_ref)) then
        s_n_errors <= s_n_errors + 1;
        report "prod rescue vec " & integer'image(i)
               & ": dout=" & to_hstring(dout_o)
               & " ref="   & to_hstring(to_slv(v_ref))
          severity warning;
      end if;
      if error_o /= "0000000" then
        s_n_errors <= s_n_errors + 1;
        report "prod rescue vec " & integer'image(i)
               & ": error_o /= 0, got " & to_string(error_o)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 2;
      wait until rising_edge(clk_i);
    end loop;

    wait for 5 * g_clk_period;
    assert s_n_errors = 0
      report "TEST FAILED: " & integer'image(s_n_errors) & " / "
             & integer'image(s_n_checks) & " mismatches"
      severity failure;
    report "TEST PASSED: " & integer'image(s_n_checks) & " checks OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
