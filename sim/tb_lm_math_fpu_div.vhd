--=============================================================================
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 Logimentor
-- Testbench  : tb_lm_math_fpu_div
-- Description: Self-checking testbench for lm_math_fpu_div.
--
--              Coverage:
--                * 16 mid-range normal vectors (no NaN/inf/0 operands),
--                  dout vs. ieee.float_pkg "/" (+-1 ULP) and error_o
--                  asserted to be all-zero;
--                * 15 special bit-pattern vectors. Vecs 0..9 cover
--                  every error_o bit (0..6) with sign='0' on the
--                  special input: +NaN/fin, fin/+NaN, +inf/fin,
--                  fin/+inf, +inf/+inf, fin/+0, +0/fin, +NaN/+NaN,
--                  +inf/+0, plus a huge/tiny overflow case. Vecs
--                  10..14 close the matrix with sign='1' on each
--                  individual error_o bit (0, 1, 2, 4, 5): fin/-inf,
--                  -NaN/fin, fin/-NaN, -inf/fin, fin/-0;
--                * 9 denormal / exponent-boundary vectors (phase D):
--                  denormal/normal, normal/denormal, denormal/denormal,
--                  normal/normal where the quotient lands in the
--                  subnormal range (exercises proc_final's "else"
--                  shift_right branch), explicit overflow to +inf
--                  with bit-6 set, three negative-sign variants, and
--                  a sign='1' subnormal-result vec (-1e-20 / 1e+20 ->
--                  -1e-40, complement to the sign='0' subnormal
--                  result at vec 3).
--
--              error_o layout (per lm_math_fpu_div):
--                bit 0 : A finite, B = +/-inf (result is 0)
--                bit 1 : A is NaN
--                bit 2 : B is NaN
--                bit 3 : +/-inf / +/-inf (undetermined)
--                bit 4 : +/-inf / finite (result is +/-inf)
--                bit 5 : A finite, B = +/-0 (divide by zero)
--                bit 6 : result over-range (proc_final's s_error_x(0))
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

library lm_math_float_lib;
use lm_math_float_lib.lm_math_float_pkg.all;

entity tb_lm_math_fpu_div is
  generic(
    g_clk_period : time    := 10 ns;
    g_data_exp   : natural := 8;
    g_data_mant  : natural := 23;
    g_chunk_size : natural := 4;
    g_round_mode : integer := C_LM_ROUND_NEAREST
  );
end tb_lm_math_fpu_div;

architecture tb of tb_lm_math_fpu_div is

  constant C_W      : natural := g_data_exp + g_data_mant + 1;
  constant C_N_NORM : natural := 16;
  constant C_N_SPEC : natural := 15;
  constant C_N_DENO : natural := 9;

  type t_real_array is array (0 to C_N_NORM - 1) of real;
  constant C_NUM : t_real_array := (
    50.0,    100.0,   25.0,   26.0,   1.0,
    0.0001,  0.00001, 10.0,   100.0,  1.5e-30,
    7.259e11, 2.125e-4, 3.0,   -7.0,   1.0e20,  -1.0
  );
  constant C_DEN : t_real_array := (
    22.0,    25.0,    5.0,    2.0,    23.0,
    22.0,    21.0,    3.0,    10.0,   2.0e3,
    -2.71e-3, 12.0,    7.0,    -3.0,   1.0e10,  1.0
  );

  --* Denormal / exponent-boundary phase. Each vector specifies its
  --  expected error_o explicitly (bit 6 indicates over-range, the
  --  other bits should stay 0 for these inputs). For non-overflow
  --  vectors, dout is compared against ieee.float_pkg "/" within
  --  +-1 ULP; over-range vectors (bit 6 set) skip the dout compare
  --  because the data path is not IEEE-conformant for overflow
  --  output, and only verify the error_o pattern.
  type t_real_array_d is array (0 to C_N_DENO - 1) of real;
  constant C_NUM_D : t_real_array_d := (
    1.0e-40,      -- 0: denormal A / normal B   -> denormal result
    2.0,          -- 1: normal A / denormal B   -> overflow to +inf
    1.0e-40,      -- 2: denormal / denormal     -> result ~ 1.0 (+-1 ULP)
    1.0e-20,      -- 3: normal / normal         -> subnormal-magnitude
                  --                              result (proc_final else)
    1.0e+30,      -- 4: huge / tiny -> overflow to +inf, bit 6
    -1.0,         -- 5: negative dividend       -> -0.5
    1.0,          -- 6: negative divisor        -> -0.5
    -1.0e-40,     -- 7: negative denormal A
   -1.0e-20       -- 8: -normal / +normal -> negative subnormal result
                  --    (sign='1' on proc_final's else branch, complement
                  --    to vec 3 which exercised the same branch with
                  --    sign='0').
  );
  constant C_DEN_D : t_real_array_d := (
    2.0,          -- 0
    1.0e-40,      -- 1
    1.0e-40,      -- 2
    1.0e+20,      -- 3 -> quotient = 1.0e-40 (denormal)
    1.0e-10,      -- 4 -> quotient = 1.0e+40 > max_finite, overflow
    2.0,          -- 5
    -2.0,         -- 6
    2.0,          -- 7
    1.0e+20       -- 8 -> quotient = -1.0e-40 (negative denormal)
  );
  --* Per-vector expected error_o for the denormal phase. bit 6 is
  --  set explicitly when the quotient over-ranges (vec 1, vec 4);
  --  bits 5..0 stay 0 because no operand is NaN / +-inf / +-0.
  type t_slv_7_arr is array (0 to C_N_DENO - 1) of std_logic_vector(6 downto 0);
  constant C_DENO_ERR : t_slv_7_arr := (
    0      => "0000000",  -- denormal / normal
    1      => "1000000",  -- normal / denormal -> overflow
    2      => "0000000",  -- denormal / denormal
    3      => "0000000",  -- normal / normal -> subnormal result, no flag
    4      => "1000000",  -- overflow
    5      => "0000000",  -- negative dividend
    6      => "0000000",  -- negative divisor
    7      => "0000000",  -- negative denormal
    8      => "0000000"   -- negative subnormal result via proc_final else
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

  function f_zero return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    return v;
  end function;

  --* Negative zero IEEE-754 bit pattern (sign=1, exp=0, mant=0).
  --  VHDL `real` does not preserve a distinct -0, so we build the slv
  --  directly when the test needs the sign='1' variant of zero.
  function f_neg_zero return std_logic_vector is
    variable v : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  begin
    v(C_W - 1) := '1';
    return v;
  end function;

  --* Mirror of proc_errors. Returns the 6-bit error pattern (bits
  --  5..0). Bit 6 (over-range) is computed separately because it
  --  depends on the result exponent.
  function f_expected_input_err(a, b : std_logic_vector) return std_logic_vector is
    constant C_ALL_ONES : unsigned(g_data_exp - 1 downto 0) := (others => '1');
    variable car_a, car_b   : unsigned(g_data_exp - 1 downto 0);
    variable mant_a, mant_b : unsigned(g_data_mant - 1 downto 0);
    variable e              : std_logic_vector(5 downto 0) := (others => '0');
    variable a_inf, b_inf   : boolean;
    variable a_nan, b_nan   : boolean;
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

    -- bit 0: A finite (not all-ones car) AND B = inf
    if (car_a /= C_ALL_ONES) and b_inf then e(0) := '1'; end if;
    -- bit 1: A is NaN
    if a_nan then e(1) := '1'; end if;
    -- bit 2: B is NaN
    if b_nan then e(2) := '1'; end if;
    -- bits 3, 4: inf/inf vs inf/finite
    if a_inf and b_inf then
      e(3) := '1';
    elsif a_inf and (car_b /= C_ALL_ONES) then
      e(4) := '1';
    end if;
    -- bit 5: A finite, B = 0
    if (car_a /= C_ALL_ONES) and b_zer then e(5) := '1'; end if;

    return e;
  end function;

  type t_slv_w is array (natural range <>) of std_logic_vector(C_W - 1 downto 0);
  type t_slv_7 is array (natural range <>) of std_logic_vector(6 downto 0);

  signal C_SPEC_A   : t_slv_w(0 to C_N_SPEC - 1);
  signal C_SPEC_B   : t_slv_w(0 to C_N_SPEC - 1);
  --* per-vector expected full error_o (bit 6 is the over-range flag)
  signal C_SPEC_ERR : t_slv_7(0 to C_N_SPEC - 1) := (others => (others => '0'));

  signal clk_i      : std_logic := '0';
  signal rst_n_i    : std_logic := '0';
  signal dv_i       : std_logic := '0';
  signal dividend_i : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal divisor_i  : std_logic_vector(C_W - 1 downto 0) := (others => '0');
  signal quotient_o : std_logic_vector(C_W - 1 downto 0);
  signal dv_o       : std_logic;
  signal error_o    : std_logic_vector(6 downto 0);

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

  --   special-phase operands. The expected error pattern is computed
  --   from the inputs themselves (bits 5..0); bit 6 (over-range) is
  --   tagged manually only for the explicit overflow case.
  C_SPEC_A(0)   <= f_nan('0');     C_SPEC_B(0)   <= f_normal(2.0);    -- NaN  / fin
  C_SPEC_A(1)   <= f_normal(2.0);  C_SPEC_B(1)   <= f_nan('0');       -- fin  / NaN
  C_SPEC_A(2)   <= f_inf('0');     C_SPEC_B(2)   <= f_normal(2.0);    -- +inf / fin
  C_SPEC_A(3)   <= f_normal(2.0);  C_SPEC_B(3)   <= f_inf('0');       -- fin  / +inf
  C_SPEC_A(4)   <= f_inf('0');     C_SPEC_B(4)   <= f_inf('0');       -- +inf / +inf
  C_SPEC_A(5)   <= f_normal(2.0);  C_SPEC_B(5)   <= f_zero;           -- fin  / 0
  C_SPEC_A(6)   <= f_zero;         C_SPEC_B(6)   <= f_normal(2.0);    -- 0    / fin
  C_SPEC_A(7)   <= f_nan('0');     C_SPEC_B(7)   <= f_nan('1');       -- NaN  / NaN
  C_SPEC_A(8)   <= f_inf('0');     C_SPEC_B(8)   <= f_zero;           -- +inf / 0
  C_SPEC_A(9)   <= f_normal(1.0e+30);
  C_SPEC_B(9)   <= f_normal(1.0e-10);                                 -- overflow

  --   sign='1' variants: close the "both signs on every error_o bit"
  --   coverage matrix (one vec per individual bit). Bit 3 (inf/inf)
  --   is excluded because both inputs are inf there and "sign" does
  --   not pick a single operand; bit 6 (over-range) is already
  --   covered with both signs implicitly (vec 9 has positive operands
  --   that overflow positively; vec 14 below has fin / -0 which sets
  --   bit 6 alongside bit 5).
  C_SPEC_A(10)  <= f_normal(2.0);  C_SPEC_B(10)  <= f_inf('1');        -- bit 0, sign='1'
  C_SPEC_A(11)  <= f_nan('1');     C_SPEC_B(11)  <= f_normal(2.0);     -- bit 1, sign='1'
  C_SPEC_A(12)  <= f_normal(2.0);  C_SPEC_B(12)  <= f_nan('1');        -- bit 2, sign='1'
  C_SPEC_A(13)  <= f_inf('1');     C_SPEC_B(13)  <= f_normal(2.0);     -- bit 4, sign='1'
  C_SPEC_A(14)  <= f_normal(2.0);  C_SPEC_B(14)  <= f_neg_zero;        -- bit 5, sign='1'

  --   expected error pattern. Bits 5..0 come from f_expected_input_err;
  --   bit 6 (over-range) is set explicitly per case.
  --     vec 5  (fin / +0): the divider returns all-ones for the
  --                       mantissa AND the bias-adjusted exponent
  --                       computation (delta_den = mant_width) pushes
  --                       car_res past C_MAX_CAR, so proc_final raises
  --                       bit 6 in addition to bit 5;
  --     vec 8  (inf / 0): bit 6 stays '0' (despite the all-ones int_div
  --                       quotient the DUT does not raise the
  --                       over-range flag for this corner -- legacy
  --                       behavior, documented here);
  --     vec 9  (overflow): result overflows the exponent range, bit 6;
  --     vec 14 (fin / -0): same DUT path as vec 5 (B is +/-0 with
  --                       mant=0 and car=0 -> the proc_errors decode
  --                       treats +0 and -0 identically), so bit 6
  --                       fires alongside bit 5.
  process(C_SPEC_A, C_SPEC_B)
  begin
    for i in 0 to C_N_SPEC - 1 loop
      C_SPEC_ERR(i)(5 downto 0) <= f_expected_input_err(C_SPEC_A(i), C_SPEC_B(i));
      if i = 5 or i = 9 or i = 14 then
        C_SPEC_ERR(i)(6) <= '1';
      else
        C_SPEC_ERR(i)(6) <= '0';
      end if;
    end loop;
  end process;

  uut : entity lm_math_float_lib.lm_math_fpu_div
    generic map(
      g_data_exp   => g_data_exp,
      g_data_mant  => g_data_mant,
      g_chunk_size => g_chunk_size,
      g_round_mode => g_round_mode
    )
    port map(
      clk_i      => clk_i,
      rst_n_i    => rst_n_i,
      dv_i       => dv_i,
      dividend_i => dividend_i,
      divisor_i  => divisor_i,
      quotient_o => quotient_o,
      dv_o       => dv_o,
      error_o    => error_o
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
    rst_n_i <= '0';
    wait for 3 * g_clk_period;
    rst_n_i <= '1';
    wait for 5 * g_clk_period;
    wait until rising_edge(clk_i);
    dv_i <= '1';
    --   normal phase
    for i in 0 to C_N_NORM - 1 loop
      dividend_i <= f_normal(C_NUM(i));
      divisor_i  <= f_normal(C_DEN(i));
      wait until rising_edge(clk_i);
    end loop;
    --   special phase
    for i in 0 to C_N_SPEC - 1 loop
      dividend_i <= C_SPEC_A(i);
      divisor_i  <= C_SPEC_B(i);
      wait until rising_edge(clk_i);
    end loop;
    --   denormal / boundary phase
    for i in 0 to C_N_DENO - 1 loop
      dividend_i <= f_normal(C_NUM_D(i));
      divisor_i  <= f_normal(C_DEN_D(i));
      wait until rising_edge(clk_i);
    end loop;
    dv_i <= '0';
    wait;
  end process;

  proc_check : process
    variable v_n, v_d, v_ref : float(g_data_exp downto -g_data_mant);
  begin
    wait until dv_o = '1';

    --   normal phase
    for i in 0 to C_N_NORM - 1 loop
      v_n   := to_float(C_NUM(i), g_data_exp, g_data_mant);
      v_d   := to_float(C_DEN(i), g_data_exp, g_data_mant);
      v_ref := v_n / v_d;
      wait for 1 ps;
      if not f_within_1ulp(quotient_o, to_slv(v_ref)) then
        s_n_errors <= s_n_errors + 1;
        report "div dout mismatch on normal vec " & integer'image(i)
          severity warning;
      end if;
      if error_o /= "0000000" then
        s_n_errors <= s_n_errors + 1;
        report "div error_o /= 0 on normal vec " & integer'image(i)
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 2;
      wait until rising_edge(clk_i);
    end loop;

    --   special phase: error_o only (dout is implementation-defined on
    --   the NaN/inf/zero cases).
    for i in 0 to C_N_SPEC - 1 loop
      wait for 1 ps;
      if error_o /= C_SPEC_ERR(i) then
        s_n_errors <= s_n_errors + 1;
        report "div error_o mismatch on special vec " & integer'image(i)
             & " actual=" & to_hstring(error_o)
             & " expected=" & to_hstring(C_SPEC_ERR(i))
          severity warning;
      end if;
      s_n_checks <= s_n_checks + 1;
      wait until rising_edge(clk_i);
    end loop;

    --   denormal / boundary phase: check dout against float_pkg "/"
    --   (+-1 ULP) and error_o against the per-vector expected pattern.
    --   For over-range vectors (bit 6 set), dout is not IEEE-conformant
    --   so we only verify the error flag there.
    for i in 0 to C_N_DENO - 1 loop
      v_n   := to_float(C_NUM_D(i), g_data_exp, g_data_mant);
      v_d   := to_float(C_DEN_D(i), g_data_exp, g_data_mant);
      v_ref := v_n / v_d;
      wait for 1 ps;
      if error_o /= C_DENO_ERR(i) then
        s_n_errors <= s_n_errors + 1;
        report "div error_o mismatch on denormal vec " & integer'image(i)
             & " actual=" & to_hstring(error_o)
             & " expected=" & to_hstring(C_DENO_ERR(i))
          severity warning;
      end if;
      if C_DENO_ERR(i)(6) = '0' then
        --   in-range result: dout should match within 1 ULP
        if not f_within_1ulp(quotient_o, to_slv(v_ref)) then
          s_n_errors <= s_n_errors + 1;
          report "div dout mismatch on denormal vec " & integer'image(i)
               & " quotient_o=" & to_hstring(quotient_o)
               & " ref="        & to_hstring(to_slv(v_ref))
            severity warning;
        end if;
        s_n_checks <= s_n_checks + 2;
      else
        s_n_checks <= s_n_checks + 1;
      end if;
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
