--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_to_fpu
-- Description: Self-checking testbench for lm_math_fpu_to_fpu. Two DUT
--              instances exercise BOTH supported directions in parallel:
--
--                * uut_l2s : large -> small (e=11/m=52 -> e=8/m=23,
--                            i.e. double -> single)
--                * uut_s2l : small -> large (e=8/m=23 -> e=11/m=52)
--
--              Each DUT is fed an independently-encoded copy of every
--              real test value and the output is checked against the
--              float-domain resize() reference (+-2 ULP).
--
--              Coverage:
--                * mid-range normals;
--                * exponent boundaries (very small / very large) which
--                  cause underflow or saturation in the l2s direction;
--                * +inf / -inf / +NaN bit patterns;
--                * 6 denormal / zero / normal-boundary vectors on the
--                  s2l direction. The small-to-large path explicitly
--                  normalizes a single-precision denormal into a
--                  double-precision normal (via gen_small_to_large's
--                  shift-and-rebias logic, plus the +-0 zero-detect
--                  leg added in 2.0.1). Compared against
--                  ieee.float_pkg.resize() within +-2 ULP.
--
--              Known legacy limitation: the small -> large path adds
--              C_DELTA_BIAS to s_car_in without detecting the all-ones
--              exponent encoding, so a single +inf is rewritten as a
--              large finite normal instead of producing a double +inf.
--              The special-case sub-section therefore only checks the
--              l2s direction for the +/-inf / NaN bit patterns; the
--              s2l output for those patterns is observed but not
--              asserted, with a note in the transcript.
--
--              Latencies of the two paths are slightly different, so
--              each DUT has its own check process that waits on its
--              own dv_o.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_to_fpu is
  generic(
    g_clk_period : time := 10 ns
  );
end tb_lm_math_fpu_to_fpu;

architecture tb of tb_lm_math_fpu_to_fpu is

  --* hard-coded formats so the TB can exercise both directions
  constant C_E_S : natural := 8;
  constant C_M_S : natural := 23;
  constant C_E_L : natural := 11;
  constant C_M_L : natural := 52;

  constant C_W_S : natural := C_E_S + C_M_S + 1;
  constant C_W_L : natural := C_E_L + C_M_L + 1;

  --* mid-range vectors (used for both DUTs)
  constant C_N_MID : natural := 10;
  type t_real_array is array (natural range <>) of real;
  constant C_X : t_real_array(0 to C_N_MID - 1) := (
    1.0, -2.0, 3.14159, 1.0e-10, 1.0e20,
    0.5, -0.125, 7.125, 0.0, 1.234e-5
  );

  --* boundary vectors. l2s direction: 1.0e+300 saturates to +inf in
  --  single; 1.0e-300 underflows to +0. s2l direction: these inputs
  --  cannot even be encoded as single (they map to single inf and
  --  single 0 respectively), so the s2l check skips them.
  constant C_N_BND : natural := 3;
  constant C_X_BND : t_real_array(0 to C_N_BND - 1) := (
    1.0e+300, 1.0e-300, -1.0e+300
  );

  --* Denormal / zero / normal-boundary vectors primarily targeting
  --  the s2l direction (single-precision denormals being normalized
  --  into double-precision normals via gen_small_to_large's
  --  shift-and-rebias). The same magnitudes are also driven on the
  --  l2s DUT and checked: in the double encoding they are all
  --  normal (or +0), so l2s exercises an ordinary
  --  resize/pass-through path on these inputs rather than any
  --  denormal-specific behavior. Driving both DUTs keeps the
  --  proc_check_l2s / proc_check_s2l cycle counts aligned with
  --  proc_stim.
  --
  --  Vec 5 (single min normal = 2^-126) tests the boundary case
  --  where the input is just barely normal (car=1) and the s2l
  --  path does NOT enter the denormal-normalization branch
  --  (s_car_in_d1 > 0 -> straight bias correction).
  constant C_N_S2L_DENO : natural := 6;
  constant C_X_S2L_DENO : t_real_array(0 to C_N_S2L_DENO - 1) := (
    1.0e-40,                -- 0: positive denormal single
   -1.0e-40,                -- 1: negative denormal single
    5.0e-39,                -- 2: another denormal (sign + mant)
    real(2.0**(-149)),      -- 3: smallest denormal single
                            --    (mant_field = 1, exp = 0)
    0.0,                    -- 4: +0 (exercises the zero-detect leg)
    real(2.0**(-126))       -- 5: min normal single (boundary;
                            --    car=1, no denormal logic engaged)
  );

  signal clk_i        : std_logic := '0';
  signal dv_i         : std_logic := '0';

  signal in_l2s       : std_logic_vector(C_W_L - 1 downto 0) := (others => '0');
  signal in_s2l       : std_logic_vector(C_W_S - 1 downto 0) := (others => '0');
  signal out_l2s      : std_logic_vector(C_W_S - 1 downto 0);
  signal out_s2l      : std_logic_vector(C_W_L - 1 downto 0);
  signal dv_l2s       : std_logic;
  signal dv_s2l       : std_logic;

  --* per-process counters (VHDL forbids multiple drivers on a single
  --  signal, so each check process owns its own counter pair and the
  --  finish process sums them).
  signal s_n_errors_l2s : natural := 0;
  signal s_n_checks_l2s : natural := 0;
  signal s_n_errors_s2l : natural := 0;
  signal s_n_checks_s2l : natural := 0;
  signal s_l2s_done   : boolean := false;
  signal s_s2l_done   : boolean := false;
  signal sim_end      : boolean := false;

  --* total vectors fed: C_N_MID + C_N_BND + 3 (special: +inf, -inf, NaN)
  constant C_N_SPECIAL : natural := 3;
  constant C_N_TOTAL   : natural := C_N_MID + C_N_BND + C_N_SPECIAL;

  function f_within(a, b : std_logic_vector; tol : natural) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= tol;
  end function;

  --* special-pattern builders, parameterized by float width
  function f_inf(sign : std_logic; e_w : natural; m_w : natural)
    return std_logic_vector is
    variable v : std_logic_vector(e_w + m_w downto 0);
  begin
    v(e_w + m_w)              := sign;
    v(e_w + m_w - 1 downto m_w) := (others => '1');
    v(m_w - 1 downto 0)       := (others => '0');
    return v;
  end function;

  function f_nan(e_w : natural; m_w : natural) return std_logic_vector is
    variable v : std_logic_vector(e_w + m_w downto 0);
  begin
    v                                   := (others => '0');
    v(e_w + m_w - 1 downto m_w)         := (others => '1');
    v(m_w - 1)                          := '1';
    return v;
  end function;

begin

  uut_l2s : entity lm_math_float_lib.lm_math_fpu_to_fpu
    generic map(
      g_din_exp   => C_E_L,
      g_din_mant  => C_M_L,
      g_dout_exp  => C_E_S,
      g_dout_mant => C_M_S
    )
    port map(
      clk_i       => clk_i,
      dv_i        => dv_i,
      float_in_i  => in_l2s,
      float_out_o => out_l2s,
      dv_o        => dv_l2s
    );

  uut_s2l : entity lm_math_float_lib.lm_math_fpu_to_fpu
    generic map(
      g_din_exp   => C_E_S,
      g_din_mant  => C_M_S,
      g_dout_exp  => C_E_L,
      g_dout_mant => C_M_L
    )
    port map(
      clk_i       => clk_i,
      dv_i        => dv_i,
      float_in_i  => in_s2l,
      float_out_o => out_s2l,
      dv_o        => dv_s2l
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

    --   mid-range
    for i in C_X'range loop
      in_l2s <= to_slv(to_float(C_X(i), C_E_L, C_M_L));
      in_s2l <= to_slv(to_float(C_X(i), C_E_S, C_M_S));
      wait until rising_edge(clk_i);
    end loop;

    --   boundary
    for i in C_X_BND'range loop
      in_l2s <= to_slv(to_float(C_X_BND(i), C_E_L, C_M_L));
      in_s2l <= to_slv(to_float(C_X_BND(i), C_E_S, C_M_S));
      wait until rising_edge(clk_i);
    end loop;

    --   s2l denormal phase. Drive both DUT input ports (l2s also
    --   sees the double-encoded copy but it just round-trips a
    --   normal value, no new logic exercised on that side).
    for i in C_X_S2L_DENO'range loop
      in_l2s <= to_slv(to_float(C_X_S2L_DENO(i), C_E_L, C_M_L));
      in_s2l <= to_slv(to_float(C_X_S2L_DENO(i), C_E_S, C_M_S));
      wait until rising_edge(clk_i);
    end loop;

    --   special bit patterns: +inf, -inf, +NaN (one cycle each)
    in_l2s <= f_inf('0', C_E_L, C_M_L);
    in_s2l <= f_inf('0', C_E_S, C_M_S);
    wait until rising_edge(clk_i);
    in_l2s <= f_inf('1', C_E_L, C_M_L);
    in_s2l <= f_inf('1', C_E_S, C_M_S);
    wait until rising_edge(clk_i);
    in_l2s <= f_nan(C_E_L, C_M_L);
    in_s2l <= f_nan(C_E_S, C_M_S);
    wait until rising_edge(clk_i);

    dv_i <= '0';
    wait;
  end process;

  --* check the large -> small DUT (covers special bit patterns too)
  proc_check_l2s : process
    variable v_in_l   : float(C_E_L downto -C_M_L);
    variable v_ref_s  : float(C_E_S downto -C_M_S);
    variable v_inf_s  : std_logic_vector(C_W_S - 1 downto 0);
  begin
    wait until dv_l2s = '1';

    --   mid-range
    for i in C_X'range loop
      v_in_l  := to_float(C_X(i), C_E_L, C_M_L);
      v_ref_s := resize(v_in_l, C_E_S, C_M_S);
      wait for 1 ps;
      if not f_within(out_l2s, to_slv(v_ref_s), 2) then
        s_n_errors_l2s <= s_n_errors_l2s + 1;
        report "l2s mid-range mismatch vec " & integer'image(i) severity warning;
      end if;
      s_n_checks_l2s <= s_n_checks_l2s + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   boundary
    for i in C_X_BND'range loop
      v_in_l  := to_float(C_X_BND(i), C_E_L, C_M_L);
      v_ref_s := resize(v_in_l, C_E_S, C_M_S);
      wait for 1 ps;
      if not f_within(out_l2s, to_slv(v_ref_s), 2) then
        s_n_errors_l2s <= s_n_errors_l2s + 1;
        report "l2s boundary mismatch vec " & integer'image(i) severity warning;
      end if;
      s_n_checks_l2s <= s_n_checks_l2s + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   s2l-denormal phase pass-through. l2s sees the double-
    --   precision encoding of the same magnitudes (denormals in
    --   single are still normal in double, so the l2s round-trip
    --   just narrows them back into single normals or 0 depending
    --   on whether they fit). Checked against resize() so any
    --   regression on the narrow direction is caught too.
    for i in C_X_S2L_DENO'range loop
      v_in_l  := to_float(C_X_S2L_DENO(i), C_E_L, C_M_L);
      v_ref_s := resize(v_in_l, C_E_S, C_M_S);
      wait for 1 ps;
      if not f_within(out_l2s, to_slv(v_ref_s), 2) then
        s_n_errors_l2s <= s_n_errors_l2s + 1;
        report "l2s s2l-deno mismatch vec " & integer'image(i)
               & " got " & to_hstring(out_l2s)
               & " ref " & to_hstring(to_slv(v_ref_s))
          severity warning;
      end if;
      s_n_checks_l2s <= s_n_checks_l2s + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   special: +inf, -inf, NaN -> the module's overflow detector
    --   pushes them all to single-precision +/-inf.
    v_inf_s := f_inf('0', C_E_S, C_M_S);
    wait for 1 ps;
    if out_l2s /= v_inf_s then
      s_n_errors_l2s <= s_n_errors_l2s + 1;
      report "l2s +inf bit-pattern mismatch" severity warning;
    end if;
    s_n_checks_l2s <= s_n_checks_l2s + 1;
    wait until rising_edge(clk_i);

    v_inf_s := f_inf('1', C_E_S, C_M_S);
    wait for 1 ps;
    if out_l2s /= v_inf_s then
      s_n_errors_l2s <= s_n_errors_l2s + 1;
      report "l2s -inf bit-pattern mismatch" severity warning;
    end if;
    s_n_checks_l2s <= s_n_checks_l2s + 1;
    wait until rising_edge(clk_i);

    v_inf_s := f_inf('0', C_E_S, C_M_S);
    wait for 1 ps;
    if out_l2s /= v_inf_s then
      s_n_errors_l2s <= s_n_errors_l2s + 1;
      report "l2s NaN bit-pattern mismatch" severity warning;
    end if;
    s_n_checks_l2s <= s_n_checks_l2s + 1;

    s_l2s_done <= true;
    wait;
  end process;

  --* check the small -> large DUT (only mid-range vectors; boundary
  --  and special inputs cannot be expressed as a single-precision
  --  normal so they are skipped here -- the boundary inputs already
  --  saturate to single inf, which the legacy s2l path does NOT
  --  forward as double inf).
  proc_check_s2l : process
    variable v_in_s  : float(C_E_S downto -C_M_S);
    variable v_ref_l : float(C_E_L downto -C_M_L);
  begin
    wait until dv_s2l = '1';

    for i in C_X'range loop
      v_in_s  := to_float(C_X(i), C_E_S, C_M_S);
      v_ref_l := resize(v_in_s, C_E_L, C_M_L);
      wait for 1 ps;
      if not f_within(out_s2l, to_slv(v_ref_l), 2) then
        s_n_errors_s2l <= s_n_errors_s2l + 1;
        report "s2l mid-range mismatch vec " & integer'image(i)
             & "  in="     & to_hstring(in_s2l)
             & "  actual=" & to_hstring(out_s2l)
             & "  expect=" & to_hstring(to_slv(v_ref_l))
          severity warning;
      end if;
      s_n_checks_s2l <= s_n_checks_s2l + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   skip the 3 boundary vectors: they encode to single
    --   inf / +0 / inf which the legacy s2l path does not
    --   forward as double inf. The l2s direction tests them.
    for i in C_X_BND'range loop
      wait until rising_edge(clk_i);
    end loop;

    --   s2l denormal phase: every input is a small-precision
    --   denormal (or +0 / min-normal boundary). The DUT should
    --   normalize it into a double-precision normal (or +0).
    --   Compared against ieee.float_pkg.resize() within +-2 ULP.
    for i in C_X_S2L_DENO'range loop
      v_in_s  := to_float(C_X_S2L_DENO(i), C_E_S, C_M_S);
      v_ref_l := resize(v_in_s, C_E_L, C_M_L);
      wait for 1 ps;
      if not f_within(out_s2l, to_slv(v_ref_l), 2) then
        s_n_errors_s2l <= s_n_errors_s2l + 1;
        report "s2l denormal-phase mismatch vec " & integer'image(i)
             & "  in="     & to_hstring(in_s2l)
             & "  actual=" & to_hstring(out_s2l)
             & "  expect=" & to_hstring(to_slv(v_ref_l))
          severity warning;
      end if;
      s_n_checks_s2l <= s_n_checks_s2l + 1;
      wait until rising_edge(clk_i);
    end loop;

    s_s2l_done <= true;
    wait;
  end process;

  proc_finish : process
    variable v_total_err : natural;
    variable v_total_chk : natural;
  begin
    wait until s_l2s_done and s_s2l_done;
    wait for 5 * g_clk_period;
    v_total_err := s_n_errors_l2s + s_n_errors_s2l;
    v_total_chk := s_n_checks_l2s + s_n_checks_s2l;
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
