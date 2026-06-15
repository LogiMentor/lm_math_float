# =============================================================================
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor
# Run every testbench in sequence. Every TB is self-checking and ends with
# "TEST PASSED" (severity note) or stops simulation with "TEST FAILED"
# (severity failure). Inspect the transcript and grep for those markers to
# see the per-TB outcome. See TESTPLAN.md for the coverage matrix.
#
# Usage: vsim -c -do "do run_all.do; quit -f"
# =============================================================================

set TB_LIST [list \
    tb_lm_math_float_pkg      \
    tb_lm_math_fi_mult        \
    tb_lm_math_int_div        \
    tb_lm_math_fpu_rounding   \
    tb_lm_math_fpu_sum        \
    tb_lm_math_fpu_prod       \
    tb_lm_math_fpu_div        \
    tb_lm_math_fpu_div_rst    \
    tb_lm_math_fpu_div2       \
    tb_lm_math_fpu_sqrt       \
    tb_lm_math_fpu_sqrt_rst   \
    tb_lm_math_fpu_mult_cmplx \
    tb_lm_math_fix_to_fpu     \
    tb_lm_math_fpu_to_fix     \
    tb_lm_math_fpu_to_fpu     \
]

do compile_lib.do

# keep the script going across the per-TB "severity failure" assertions
onerror {resume}
onbreak {resume}

foreach tb $TB_LIST {
    puts "==================================================================="
    puts "== Running $tb"
    puts "==================================================================="
    vcom -2008 -work work ../$tb.vhd
    vsim -t ps -voptargs="+acc" work.$tb
    run -all
    quit -sim
}

puts "==================================================================="
puts "run_all.do: finished. Search the transcript for 'TEST PASSED' /"
puts "                       'TEST FAILED' to see per-TB results."
puts "==================================================================="
