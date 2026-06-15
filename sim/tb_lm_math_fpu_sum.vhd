--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_sum
-- Description: Self-checking testbench for lm_math_fpu_sum. Two DUT
--              instances run in parallel with the same operands but
--              different g_operation settings:
--                * uut_add (g_operation = 1) -> dout = a + b
--                * uut_sub (g_operation = 0) -> dout = a - b
--
--              Coverage:
--                * 18 normal vectors checked against ieee.float_pkg
--                  (+-1 ULP), error_o = "0000". Includes exact
--                  cancellation on the add path (vec 16: 1.0 + -1.0)
--                  and alignment-shift saturation (vec 17:
--                  1e+30 + 1e-30, the smaller operand is shifted out
--                  entirely);
--                * 10 special bit-pattern vectors exercising every
--                  error_o bit on both signs of the special inputs:
--                    +NaN-A, +NaN-B, +inf-A, +inf-B, +NaN + +inf,
--                    -inf-A (sign='1' on bit 2),
--                    +inf + -inf (both inf flags fire; result is
--                    IEEE NaN but the module flags inputs, not
--                    outputs),
--                    -NaN-A (sign='1' on bit 0),
--                    -NaN-B (sign='1' on bit 1),
--                    -inf-B (sign='1' on bit 3).
--                  dout is documented as not IEEE-conformant for
--                  these inputs and is not checked;
--                * 7 denormal-arithmetic vectors:
--                    denormal + denormal (stays denormal),
--                    denormal + denormal (crosses into normal),
--                    denormal - denormal (zero result, exact match),
--                    denormal - denormal (stays denormal),
--                    normal + denormal (denormal absorbed),
--                    denormal + zero,
--                    negative denormal + negative denormal (locks
--                    down sign propagation through the subnormal
--                    add/sub path; sub flips to opposite-sign
--                    subnormal),
--                  all compared against ieee.float_pkg (+-1 ULP) with
--                  error_o asserted to be "0000";
--                * dv_pre_o leads dv_o by exactly one clock (one-shot
--                  invariant check throughout simulation).
--
--              error_o layout (per lm_math_fpu_sum):
--                bit 0: A is NaN (car=all-ones, mant /= 0)
--                bit 1: B is NaN
--                bit 2: A is +/-inf (car=all-ones, mant = 0)
--                bit 3: B is +/-inf
--              Normal-vector phase asserts error_o = "0000"; the special
--              phase asserts the per-vector expected pattern.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_sum is
  generic(
    g_clk_period : time    := 10 ns;
    g_data_exp   : natural := 8;
    g_data_mant  : natural := 23;
    g_round_mode : integer := C_LM_ROUND_NEAREST
  );
end tb_lm_math_fpu_sum;

architecture tb of tb_lm_math_fpu_sum is

  constant C_W       : natural := g_data_exp + g_data_mant + 1;
  constant C_N_NORM  : natural := 18;
  constant C_N_SPEC  : natural := 10;
  constant C_N_DENO  : natural := 7;

  --* Normal-phase operands.
  --    vec 16: exact cancellation on the add DUT (1.0 + -1.0 = +0).
  --            The sub DUT computes 1.0 - (-1.0) = 2.0. vec 2 already
  --            covered cancellation on the sub side (a = b = -3.75
  --            -> sub = 0, add = -7.5), but the add-side cancellation
  --            path was previously unexercised.
  --    vec 17: alignment-shift saturation. 1e+30 and 1e-30 differ by
  --            ~199 bits of exponent, far more than the 23+guard
  --            mantissa width, so the smaller operand is shifted out
  --            entirely and the result equals the larger one. Locks
  --            down the alignment shifter on a magnitude difference
  --            that the previous set did not approach.
  type t_real_array is array (0 to C_N_NORM - 1) of real;
  constant C_A : t_real_array := (
    0.75, -0.05, -3.75,  2.3412e-38,  0.05,
    1.25e+38, 1.0,   1.3824e-10, -4.1546e-9, -9.1336e-13,
    11.1336e13, 0.0, -6.4319e-9, 1.2988e-9, 3.2160e-9, 0.3412e-38,
    1.0,    1.0e+30
  );
  constant C_B : t_real_array := (
    0.75,  0.18750, -3.75, -1.9397e-38, -0.18750,
    0.375e+37, 1.0,  -4.3656e-11,  1.2915e-9, 22.2916e-13,
    32.488e13, -1.5280e-9, 4.3219e-9, 6.1118e-10, 4.2164e-9, -0.9397e-38,
   -1.0,    1.0e-30
  );

  --* Denormal-arithmetic vectors (float32 has min normal = 2^-126 ~=
  --  1.18e-38; min denormal = 2^-149 ~= 1.40e-45; max denormal ~=
  --  5.88e-39). All values below are intentionally chosen to exercise
  --  the s_*_is_denorm code paths.
  type t_real_array_d is array (0 to C_N_DENO - 1) of real;
  constant C_AD : t_real_array_d := (
    1.0e-40,    -- 0: both denormal, sum stays denormal
    5.0e-39,    -- 1: both denormal, sum becomes normal (crosses boundary)
    1.0e-40,    -- 2: same value -> sub gives 0
    2.0e-40,    -- 3: subtraction stays denormal
    1.0,        -- 4: normal + denormal (denormal absorbed by ULP)
    1.0e-40,    -- 5: denormal + 0
   -1.0e-40     -- 6: both negative denormal; add stays subnormal-magnitude
                --    with sign='1'; sub crosses to opposite-sign subnormal
                --    (-1e-40 - (-2e-40) = +1e-40). Locks down negative-
                --    sign propagation through the denormal add/sub path.
  );
  constant C_BD : t_real_array_d := (
    2.0e-40,    -- 0
    6.0e-39,    -- 1
    1.0e-40,    -- 2
    1.0e-40,    -- 3
    1.0e-40,    -- 4
    0.0,        -- 5
   -2.0e-40     -- 6
  );

  --* Special bit-pattern builders
  function f_inf(sign : std_logic) return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0);
  begin
    v(C_W - 1)                       := sign;
    v(C_W - 2 downto g_data_mant)    := (others => '1');
    v(g_data_mant - 1 downto 0)      := (others => '0');
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

  type t_slv_w  is array (natural range <>) of std_logic_vector(C_W - 1 downto 0);
  type t_slv_4  is array (natural range <>) of std_logic_vector(3 downto 0);

  --* Special-phase A operands
  signal C_SPEC_A : t_slv_w(0 to C_N_SPEC - 1);
  --* Special-phase B operands
  signal C_SPEC_B : t_slv_w(0 to C_N_SPEC - 1);
  --* Expected error_o per special vector.
  --  bit 0 = NaN-A, bit 1 = NaN-B, bit 2 = inf-A, bit 3 = inf-B.
  --  The inf bits fire on either sign of infinity, the NaN bits on
  --  either sign of NaN.
  signal C_SPEC_E : t_slv_4(0 to C_N_SPEC - 1) := (
    "0001",  -- 0: +NaN + finite -> NaN-A
    "0010",  -- 1: fin  + +NaN   -> NaN-B
    "0100",  -- 2: +inf + finite -> inf-A
    "1000",  -- 3: fin  + +inf   -> inf-B
    "1001",  -- 4: +NaN + +inf   -> NaN-A | inf-B
    "0100",  -- 5: -inf + finite -> inf-A (sign='1' still trips bit 2)
    "1100",  -- 6: +inf + -inf   -> inf-A | inf-B (both inputs are inf,
             --    so both inf flags fire; the result is IEEE NaN but
             --    the module's error_o decodes INPUT classes, not the
             --    output, so no NaN bit fires here)
    "0001",  -- 7: -NaN + finite -> NaN-A (sign='1' trips bit 0)
    "0010",  -- 8: fin  + -NaN   -> NaN-B (sign='1' trips bit 1)
    "1000"   -- 9: fin  + -inf   -> inf-B (sign='1' trips bit 3).
             --    Together with vec 5 / 7 / 8 / 9, the set now
             --    covers sign='1' on every individual error_o bit
             --    (5 -> inf-A, 7 -> NaN-A, 8 -> NaN-B, 9 -> inf-B).
  );

  signal clk_i      : std_logic := '0';
  signal dv_i       : std_logic := '0';
  signal din_a_i    : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal din_b_i    : std_logic_vector(C_W - 1 downto 0) := (others => '0');

  signal dout_add   : std_logic_vector(C_W - 1 downto 0);
  signal dout_sub   : std_logic_vector(C_W - 1 downto 0);
  signal dv_pre_add : std_logic;
  signal dv_pre_sub : std_logic;
  signal dv_add     : std_logic;
  signal dv_sub     : std_logic;
  signal err_add    : std_logic_vector(3 downto 0);
  signal err_sub    : std_logic_vector(3 downto 0);

  signal s_n_errors    : natural := 0;
  signal s_n_checks    : natural := 0;
  signal s_n_inv_err   : natural := 0;  -- dv_pre invariant violations
  signal sim_end       : boolean := false;

  function f_within_1ulp(a, b : std_logic_vector) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= 1;
  end function;

begin

  --* Build the special-phase operand list. The "+" subtraction would
  --  flip B's sign; the error flag is on the original operand though,
  --  so the expected error_o is the same for the add and sub DUTs (the
  --  sub module inverts B's sign for the data path but not for the
  --  error decode).
  C_SPEC_A(0) <= f_nan('0');                                           -- NaN
  C_SPEC_B(0) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));        -- 1.0
  C_SPEC_A(1) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  C_SPEC_B(1) <= f_nan('0');
  C_SPEC_A(2) <= f_inf('0');                                            -- +inf
  C_SPEC_B(2) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  C_SPEC_A(3) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  C_SPEC_B(3) <= f_inf('0');
  C_SPEC_A(4) <= f_nan('0');                                            -- NaN + +inf
  C_SPEC_B(4) <= f_inf('0');
  -- vec 5: -inf in A, normal B. The inf-A flag (bit 2) must fire
  -- regardless of the inf's sign.
  C_SPEC_A(5) <= f_inf('1');
  C_SPEC_B(5) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  -- vec 6: +inf in A, -inf in B. Both inf flags fire (bits 2 + 3).
  -- The IEEE result is NaN but the module's error_o flags INPUTS, not
  -- the output, so no NaN bit is expected.
  C_SPEC_A(6) <= f_inf('0');
  C_SPEC_B(6) <= f_inf('1');
  -- vec 7: -NaN in A, normal B. The NaN-A flag (bit 0) must fire
  -- regardless of the NaN's sign.
  C_SPEC_A(7) <= f_nan('1');
  C_SPEC_B(7) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  -- vec 8: normal A, -NaN in B. The NaN-B flag (bit 1) must fire
  -- regardless of the NaN's sign.
  C_SPEC_A(8) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  C_SPEC_B(8) <= f_nan('1');
  -- vec 9: normal A, -inf in B. The inf-B flag (bit 3) must fire
  -- regardless of the inf's sign. With vec 5/7/8 this completes
  -- the "both signs on every error_o bit" coverage claim.
  C_SPEC_A(9) <= to_slv(to_float(1.0, g_data_exp, g_data_mant));
  C_SPEC_B(9) <= f_inf('1');

  uut_add : entity lm_math_float_lib.lm_math_fpu_sum
    generic map(
      g_data_exp   => g_data_exp,
      g_data_mant  => g_data_mant,
      g_round_mode => g_round_mode,
      g_operation  => 1
    )
    port map(
      clk_i    => clk_i,
      dv_i     => dv_i,
      din_a_i  => din_a_i,
      din_b_i  => din_b_i,
      dout_o   => dout_add,
      dv_pre_o => dv_pre_add,
      dv_o     => dv_add,
      error_o  => err_add
    );

  uut_sub : entity lm_math_float_lib.lm_math_fpu_sum
    generic map(
      g_data_exp   => g_data_exp,
      g_data_mant  => g_data_mant,
      g_round_mode => g_round_mode,
      g_operation  => 0
    )
    port map(
      clk_i    => clk_i,
      dv_i     => dv_i,
      din_a_i  => din_a_i,
      din_b_i  => din_b_i,
      dout_o   => dout_sub,
      dv_pre_o => dv_pre_sub,
      dv_o     => dv_sub,
      error_o  => err_sub
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

  --* Invariant: every cycle in which dv_pre_add was '1' must be
  --  followed by dv_add = '1' on the next clock. Runs continuously
  --  throughout the simulation and catches any drift between the two
  --  outputs.
  proc_dv_pre_invariant : process(clk_i)
    variable v_prev_dv_pre : std_logic := '0';
  begin
    if rising_edge(clk_i) then
      if v_prev_dv_pre = '1' and dv_add /= '1' then
        s_n_inv_err <= s_n_inv_err + 1;
        report "sum: dv_pre_o was '1' but dv_o did not follow on the next clock"
          severity warning;
      end if;
      v_prev_dv_pre := dv_pre_add;
    end if;
  end process;

  proc_stim : process
  begin
    wait for 5 * g_clk_period;
    wait until rising_edge(clk_i);
    dv_i <= '1';
    --   normal vectors
    for i in 0 to C_N_NORM - 1 loop
      din_a_i <= to_slv(to_float(C_A(i), g_data_exp, g_data_mant));
      din_b_i <= to_slv(to_float(C_B(i), g_data_exp, g_data_mant));
      wait until rising_edge(clk_i);
    end loop;
    --   special bit-pattern vectors
    for i in 0 to C_N_SPEC - 1 loop
      din_a_i <= C_SPEC_A(i);
      din_b_i <= C_SPEC_B(i);
      wait until rising_edge(clk_i);
    end loop;
    --   denormal-arithmetic vectors
    for i in 0 to C_N_DENO - 1 loop
      din_a_i <= to_slv(to_float(C_AD(i), g_data_exp, g_data_mant));
      din_b_i <= to_slv(to_float(C_BD(i), g_data_exp, g_data_mant));
      wait until rising_edge(clk_i);
    end loop;
    dv_i <= '0';
    wait;
  end process;

  proc_check : process
    variable v_a, v_b           : float(g_data_exp downto -g_data_mant);
    variable v_ref_add, v_ref_sub : float(g_data_exp downto -g_data_mant);
  begin
    wait until dv_add = '1';  -- add and sub have the same latency

    --   ---- normal phase ----
    for i in 0 to C_N_NORM - 1 loop
      v_a       := to_float(C_A(i), g_data_exp, g_data_mant);
      v_b       := to_float(C_B(i), g_data_exp, g_data_mant);
      v_ref_add := v_a + v_b;
      v_ref_sub := v_a - v_b;
      wait for 1 ps;
      if not f_within_1ulp(dout_add, to_slv(v_ref_add)) then
        s_n_errors <= s_n_errors + 1;
        report "sum(add) mismatch on vec " & integer'image(i) severity warning;
      end if;
      if not f_within_1ulp(dout_sub, to_slv(v_ref_sub)) then
        s_n_errors <= s_n_errors + 1;
        report "sum(sub) mismatch on vec " & integer'image(i) severity warning;
      end if;
      if err_add /= "0000" then
        s_n_errors <= s_n_errors + 1;
        report "sum(add) error_o /= 0 on normal vec " & integer'image(i)
          severity warning;
      end if;
      if err_sub /= "0000" then
        s_n_errors <= s_n_errors + 1;
        report "sum(sub) error_o /= 0 on normal vec " & integer'image(i)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 4;
      wait until rising_edge(clk_i);
    end loop;

    --   ---- special phase: only check error_o (dout is documented as
    --   not IEEE-conformant for NaN/inf inputs -- the module header
    --   tells users to read error_o before using dout in those cases)
    for i in 0 to C_N_SPEC - 1 loop
      wait for 1 ps;
      if err_add /= C_SPEC_E(i) then
        s_n_errors <= s_n_errors + 1;
        report "sum(add) error_o mismatch on special vec " & integer'image(i)
          severity warning;
      end if;
      if err_sub /= C_SPEC_E(i) then
        s_n_errors <= s_n_errors + 1;
        report "sum(sub) error_o mismatch on special vec " & integer'image(i)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 2;
      wait until rising_edge(clk_i);
    end loop;

    --   ---- denormal phase: check dout (1 ULP vs. float_pkg reference)
    --   and assert error_o = "0000" (denormals are not errors)
    for i in 0 to C_N_DENO - 1 loop
      v_a       := to_float(C_AD(i), g_data_exp, g_data_mant);
      v_b       := to_float(C_BD(i), g_data_exp, g_data_mant);
      v_ref_add := v_a + v_b;
      v_ref_sub := v_a - v_b;
      wait for 1 ps;
      if not f_within_1ulp(dout_add, to_slv(v_ref_add)) then
        s_n_errors <= s_n_errors + 1;
        report "sum(add) mismatch on denormal vec " & integer'image(i)
               & " dout=" & to_hstring(dout_add)
               & " ref="  & to_hstring(to_slv(v_ref_add))
          severity warning;
      end if;
      if not f_within_1ulp(dout_sub, to_slv(v_ref_sub)) then
        s_n_errors <= s_n_errors + 1;
        report "sum(sub) mismatch on denormal vec " & integer'image(i)
               & " dout=" & to_hstring(dout_sub)
               & " ref="  & to_hstring(to_slv(v_ref_sub))
          severity warning;
      end if;
      if err_add /= "0000" then
        s_n_errors <= s_n_errors + 1;
        report "sum(add) error_o /= 0 on denormal vec " & integer'image(i)
          severity warning;
      end if;
      if err_sub /= "0000" then
        s_n_errors <= s_n_errors + 1;
        report "sum(sub) error_o /= 0 on denormal vec " & integer'image(i)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 4;
      wait until rising_edge(clk_i);
    end loop;

    wait for 5 * g_clk_period;
    assert s_n_errors = 0 and s_n_inv_err = 0
      report "TEST FAILED: " & integer'image(s_n_errors + s_n_inv_err)
             & " errors (" & integer'image(s_n_inv_err)
             & " dv_pre/dv_o invariant violations) / "
             & integer'image(s_n_checks) & " comparisons"
      severity failure;
    report "TEST PASSED: " & integer'image(s_n_checks) & " checks OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
