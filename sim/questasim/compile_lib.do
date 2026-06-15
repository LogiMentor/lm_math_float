# =============================================================================
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor
# Compile script for the lm_math_float_lib library
# Usage   : do compile_lib.do
# Sources : ../../src/*.vhd
# =============================================================================

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set REPO_ROOT  [file normalize [file join $SCRIPT_DIR ../..]]
set SRC        [file join $REPO_ROOT src]
set SIM_TB_DIR [file join $REPO_ROOT sim]
set BUILD_DIR  [file join $REPO_ROOT build questasim]

file mkdir $BUILD_DIR
cd $BUILD_DIR

# wipe previous compilation if present
if {[file exists lm_math_float_lib]} { vdel -all -lib lm_math_float_lib }
if {[file exists work]}              { vdel -all -lib work }

vlib lm_math_float_lib
vmap lm_math_float_lib lm_math_float_lib
vlib work

# 1) support package -- no dependencies
vcom -2008 -work lm_math_float_lib $SRC/lm_math_float_pkg.vhd

# 2) leaf modules that depend only on the package
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fi_mult.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_int_div.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_rounding.vhd

# 3) intermediate modules
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_sum.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_prod.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_div.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_div2.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_sqrt.vhd

# 4) top-level conversions / composite modules
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fix_to_fpu.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_to_fix.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_to_fpu.vhd
vcom -2008 -work lm_math_float_lib $SRC/lm_math_fpu_mult_cmplx.vhd

puts "compile_lib.do: lm_math_float_lib compiled."
