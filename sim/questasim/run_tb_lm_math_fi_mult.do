# =============================================================================
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor
# Compile and run tb_lm_math_fi_mult
# Usage: vsim -do run_tb_lm_math_fi_mult.do
# =============================================================================
do compile_lib.do
vcom -2008 -work work [file join $SIM_TB_DIR tb_lm_math_fi_mult.vhd]
vsim -t ps -voptargs="+acc" work.tb_lm_math_fi_mult
run -all
