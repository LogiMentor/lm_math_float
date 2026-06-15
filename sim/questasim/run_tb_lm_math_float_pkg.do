# =============================================================================
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor
# Compile and run tb_lm_math_float_pkg
# Usage: vsim -do run_tb_lm_math_float_pkg.do
# =============================================================================
do compile_lib.do
vcom -2008 -work work ../tb_lm_math_float_pkg.vhd
vsim -t ps -voptargs="+acc" work.tb_lm_math_float_pkg
run -all
