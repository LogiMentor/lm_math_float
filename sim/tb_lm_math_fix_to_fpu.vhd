--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fix_to_fpu
-- Description: Self-checking testbench for lm_math_fix_to_fpu. Two DUT
--              instances run in parallel with the same fix_in_i but
--              different g_is_signed settings:
--                * uut_signed   : g_is_signed = '1', input treated as
--                                 two's-complement;
--                * uut_unsigned : g_is_signed = '0', input treated as
--                                 unsigned magnitude (output sign bit
--                                 must always be '0', even when the
--                                 fix input has its MSB set).
--              For each fix_in_i bit pattern the TB computes two real
--              references (signed interp and unsigned interp) and
--              verifies each DUT's output against its own reference.
--              Tolerance is ±2 ULP on the mantissa.
--
--              The vector list now spans the full leading-zero
--              ladder (every LZ count from 0 to 17) on BOTH DUTs.
--              proc_count_delta's input is the post-abs value on
--              the signed DUT and the raw pattern on the unsigned
--              DUT, so the two paths see different LZ counts for
--              negative inputs; the C_FIX list below annotates each
--              vector with both LZ counts and the combined list
--              covers 0..17 on each DUT. Two alternating-bit
--              patterns (0x15555 / 0x2AAAA) round out the coverage
--              with non-trivial mantissa content.
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fix_to_fpu is
  generic(
    g_clk_period : time      := 10 ns;
    g_dout_exp   : natural   := 8;
    g_dout_mant  : natural   := 23;
    g_fix_length : natural   := 18;
    g_fix_bpoint : natural   := 9
  );
end tb_lm_math_fix_to_fpu;

architecture tb of tb_lm_math_fix_to_fpu is

  constant C_F      : natural := g_fix_length;
  constant C_OUT_W  : natural := g_dout_exp + g_dout_mant + 1;
  constant C_N_TEST : natural := 29;

  type t_fix_array is array (0 to C_N_TEST - 1) of integer;

  --* Test bit patterns. They are stored as Q18.0 signed integers; the
  --  TB converts them to the corresponding 18-bit slv and interprets
  --  the same pattern as both signed Q9.9 (range ~[-256, 256)) and
  --  unsigned UQ9.9 (range ~[0, 512)) for the two DUT references.
  --
  --  Mix of:
  --    * MSB-clear codes (signed positive == unsigned)
  --    * MSB-set codes (signed negative vs. unsigned large positive)
  --    * full-range boundaries (max signed pos / min signed neg /
  --      max unsigned)
  constant C_FIX : t_fix_array := (
    --   existing mid-range
    512, 1024, -512, 0, 1, -1, 65536, -65536, 256, -256,
    --   bit-pattern corners
    131071,  -- 0x1FFFF: max signed positive (255.998 signed/unsigned)
    -131072, -- 0x20000: min signed (-256 signed, +256 unsigned)
    -131071, -- 0x20001: just above min  (-255.998 signed, +256.002 unsigned)
    -2,      -- 0x3FFFE: signed -0.0039, unsigned 511.996
    65535,   -- 0x0FFFF: signed +127.998, unsigned same
    -65535,  -- 0x30001: signed -127.998, unsigned 384.002
    --   Leading-zero ladder fillers. The LZ count below is the
    --   shift amount that proc_count_delta sees on the f_count_delta
    --   input. For each DUT this input is:
    --     * signed DUT   : abs(fix_in_i)  (so LZ of |code|).
    --     * unsigned DUT : fix_in_i       (so LZ of the raw pattern).
    --   For positive codes the two coincide; for negative codes they
    --   differ (the signed path takes the two's-complement abs first).
    --   The annotations below give the LZ count seen by BOTH DUTs in
    --   the format "LZ_s / LZ_u". Combined with the existing 16
    --   corner codes (which already hit LZ 0/1/2/7/8/9/16/17 on the
    --   signed path and LZ 0/1/2/7/8/9/17 on the unsigned path), the
    --   13 entries below complete the ladder so EVERY LZ count from
    --   0 to 17 is exercised on BOTH DUTs.
    16384,   -- 0x04000: LZ 3 / 3,    +32.0
    8192,    -- 0x02000: LZ 4 / 4,    +16.0
    4096,    -- 0x01000: LZ 5 / 5,     +8.0
    2048,    -- 0x00800: LZ 6 / 6,     +4.0
    128,     -- 0x00080: LZ 10 / 10,   +0.25
    64,      -- 0x00040: LZ 11 / 11,   +0.125
    32,      -- 0x00020: LZ 12 / 12,   +0.0625
    16,      -- 0x00010: LZ 13 / 13,   +0.03125
    8,       -- 0x00008: LZ 14 / 14,   +0.015625
    4,       -- 0x00004: LZ 15 / 15,   +0.0078125
    2,       -- 0x00002: LZ 16 / 16,   +0.00390625
             --                 (covers LZ=16 on the unsigned DUT;
             --                 the signed LZ=16 is also covered by
             --                 -2 above, but -2's unsigned raw
             --                 0x3FFFE has LZ=0, so the unsigned
             --                 DUT needs this positive value too)
    87381,   -- 0x15555: LZ 1 / 1, alternating 010101..., +170.666
             --                 (signed and unsigned identical)
    -87382   -- 0x2AAAA: LZ 1 / 0, alternating 101010...
             --                 signed abs = 0x15556 (LZ=1),
             --                 unsigned raw = 0x2AAAA (LZ=0).
             --                 signed -170.668, unsigned +341.332
  );

  signal clk_i       : std_logic := '0';
  signal dv_i        : std_logic := '0';
  signal fix_in_i    : std_logic_vector(C_F - 1 downto 0) := (others => '0');
  signal float_out_s : std_logic_vector(C_OUT_W - 1 downto 0);  -- signed   DUT
  signal float_out_u : std_logic_vector(C_OUT_W - 1 downto 0);  -- unsigned DUT
  signal dv_s        : std_logic;
  signal dv_u        : std_logic;

  signal s_n_errors : natural := 0;
  signal s_n_checks : natural := 0;
  signal sim_end    : boolean := false;

  function f_within(a, b : std_logic_vector; tol : natural) return boolean is
    variable va, vb, d : unsigned(a'length - 1 downto 0);
  begin
    va := unsigned(a);
    vb := unsigned(b);
    if va > vb then d := va - vb; else d := vb - va; end if;
    return d <= tol;
  end function;

  --* Reference helpers. The bit pattern of the input is encoded as a
  --  signed integer that fits in g_fix_length bits (the TB feeds
  --  std_logic_vector(to_signed(C_FIX(i), C_F)) into both DUTs).
  --  f_signed_to_real reads the pattern as two's complement; the
  --  unsigned helper reads it as a magnitude. The reference floats are
  --  then computed in real precision and converted with float_pkg.
  function f_signed_to_real(code : integer) return real is
  begin
    return real(code) / real(2**g_fix_bpoint);
  end function;

  function f_unsigned_to_real(code : integer) return real is
    variable v_uns : real;
  begin
    if code >= 0 then
      v_uns := real(code);
    else
      v_uns := real(code) + 2.0**g_fix_length;  -- wrap to unsigned
    end if;
    return v_uns / real(2**g_fix_bpoint);
  end function;

begin

  uut_signed : entity lm_math_float_lib.lm_math_fix_to_fpu
    generic map(
      g_dout_exp   => g_dout_exp,
      g_dout_mant  => g_dout_mant,
      g_fix_length => g_fix_length,
      g_fix_bpoint => g_fix_bpoint,
      g_is_signed  => '1'
    )
    port map(
      clk_i       => clk_i,
      dv_i        => dv_i,
      fix_in_i    => fix_in_i,
      float_out_o => float_out_s,
      dv_o        => dv_s
    );

  uut_unsigned : entity lm_math_float_lib.lm_math_fix_to_fpu
    generic map(
      g_dout_exp   => g_dout_exp,
      g_dout_mant  => g_dout_mant,
      g_fix_length => g_fix_length,
      g_fix_bpoint => g_fix_bpoint,
      g_is_signed  => '0'
    )
    port map(
      clk_i       => clk_i,
      dv_i        => dv_i,
      fix_in_i    => fix_in_i,
      float_out_o => float_out_u,
      dv_o        => dv_u
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
    for i in 0 to C_N_TEST - 1 loop
      fix_in_i <= std_logic_vector(to_signed(C_FIX(i), C_F));
      wait until rising_edge(clk_i);
    end loop;
    dv_i <= '0';
    wait;
  end process;

  proc_check : process
    variable v_ref_s : float(g_dout_exp downto -g_dout_mant);
    variable v_ref_u : float(g_dout_exp downto -g_dout_mant);
    variable v_msb   : boolean;
  begin
    wait until dv_s = '1';  -- both DUTs use the same latency
    for i in 0 to C_N_TEST - 1 loop
      v_ref_s := to_float(f_signed_to_real  (C_FIX(i)), g_dout_exp, g_dout_mant);
      v_ref_u := to_float(f_unsigned_to_real(C_FIX(i)), g_dout_exp, g_dout_mant);
      wait for 1 ps;
      if not f_within(float_out_s, to_slv(v_ref_s), 2) then
        s_n_errors <= s_n_errors + 1;
        report "fix_to_fpu (signed) mismatch on vector " & integer'image(i)
          severity warning;
      end if;
      if not f_within(float_out_u, to_slv(v_ref_u), 2) then
        s_n_errors <= s_n_errors + 1;
        report "fix_to_fpu (unsigned) mismatch on vector " & integer'image(i)
          severity warning;
      end if;
      -- The unsigned DUT must NEVER emit a negative float, even when
      -- the fix input has its MSB set. This locks down the round-2 fix
      -- (s_sign_in is forced to '0' when g_is_signed = '0').
      v_msb := C_FIX(i) < 0;
      if v_msb and float_out_u(float_out_u'left) = '1' then
        s_n_errors <= s_n_errors + 1;
        report "fix_to_fpu (unsigned) emitted negative sign on vector "
               & integer'image(i)
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
    report "TEST PASSED: " & integer'image(s_n_checks) & " comparisons OK"
      severity note;
    sim_end <= true;
    wait;
  end process;

end tb;
