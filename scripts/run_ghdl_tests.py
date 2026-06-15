#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor

"""Compile and run the self-checking VHDL testbenches with GHDL."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "ghdl"

SRC_FILES = [
    "src/lm_math_float_pkg.vhd",
    "src/lm_math_fi_mult.vhd",
    "src/lm_math_int_div.vhd",
    "src/lm_math_fpu_rounding.vhd",
    "src/lm_math_fpu_sum.vhd",
    "src/lm_math_fpu_prod.vhd",
    "src/lm_math_fpu_div.vhd",
    "src/lm_math_fpu_div2.vhd",
    "src/lm_math_fpu_sqrt.vhd",
    "src/lm_math_fix_to_fpu.vhd",
    "src/lm_math_fpu_to_fix.vhd",
    "src/lm_math_fpu_to_fpu.vhd",
    "src/lm_math_fpu_mult_cmplx.vhd",
]

TB_LIST = [
    "tb_lm_math_float_pkg",
    "tb_lm_math_fi_mult",
    "tb_lm_math_int_div",
    "tb_lm_math_fpu_rounding",
    "tb_lm_math_fpu_sum",
    "tb_lm_math_fpu_prod",
    "tb_lm_math_fpu_div",
    "tb_lm_math_fpu_div_rst",
    "tb_lm_math_fpu_div2",
    "tb_lm_math_fpu_sqrt",
    "tb_lm_math_fpu_sqrt_rst",
    "tb_lm_math_fpu_mult_cmplx",
    "tb_lm_math_fix_to_fpu",
    "tb_lm_math_fpu_to_fix",
    "tb_lm_math_fpu_to_fpu",
]


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    printable = " ".join(cmd)
    print(f"+ {printable}", flush=True)
    result = subprocess.run(
        cmd,
        cwd=BUILD,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    return result


def analyze_sources(ghdl: str) -> tuple[bool, str]:
    BUILD.mkdir(parents=True, exist_ok=True)
    for src in SRC_FILES:
        result = run(
            [
                ghdl,
                "-a",
                "--std=08",
                "--work=lm_math_float_lib",
                f"--workdir={BUILD}",
                str(ROOT / src),
            ]
        )
        if result.returncode != 0:
            return False, f"source analysis failed: {src}"
    return True, "source analysis passed"


def run_testbench(ghdl: str, tb: str, stop_time: str) -> tuple[bool, str]:
    tb_file = ROOT / "sim" / f"{tb}.vhd"
    result = run(
        [
            ghdl,
            "-a",
            "--std=08",
            f"--workdir={BUILD}",
            f"-P{BUILD}",
            str(tb_file),
        ]
    )
    if result.returncode != 0:
        return False, "testbench analysis failed"

    result = run([ghdl, "-e", "--std=08", f"--workdir={BUILD}", f"-P{BUILD}", tb])
    if result.returncode != 0:
        return False, "testbench elaboration failed"

    result = run(
        [
            ghdl,
            "-r",
            "--std=08",
            f"--workdir={BUILD}",
            f"-P{BUILD}",
            tb,
            "--assert-level=error",
            f"--stop-time={stop_time}",
        ]
    )
    output = result.stdout or ""
    ok = result.returncode == 0 and "TEST PASSED" in output and "TEST FAILED" not in output
    if not ok and result.returncode != 0:
        return False, "simulation failed"
    if "TEST PASSED" not in output:
        return False, "missing TEST PASSED marker"
    if "TEST FAILED" in output:
        return False, "TEST FAILED marker found"
    return True, "passed"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghdl", default="ghdl", help="GHDL executable")
    parser.add_argument(
        "--stop-time",
        default="200us",
        help="Simulation stop time used because TBs end with a passive wait",
    )
    parser.add_argument(
        "--keep-build",
        action="store_true",
        help="Keep build/ghdl instead of starting from a clean work library",
    )
    args = parser.parse_args()

    if shutil.which(args.ghdl) is None:
        print(f"error: '{args.ghdl}' was not found on PATH", file=sys.stderr)
        return 127

    if BUILD.exists() and not args.keep_build:
        shutil.rmtree(BUILD)

    ok, reason = analyze_sources(args.ghdl)
    if not ok:
        print(f"GHDL regression failed: {reason}")
        return 1

    failed: list[tuple[str, str]] = []
    for tb in TB_LIST:
        print("=" * 72)
        print(f"Running {tb}")
        print("=" * 72)
        ok, reason = run_testbench(args.ghdl, tb, args.stop_time)
        if not ok:
            failed.append((tb, reason))

    if failed:
        print("GHDL regression failed:")
        for tb, reason in failed:
            print(f"  - {tb}: {reason}")
        return 1

    print(f"GHDL regression passed: {len(TB_LIST)} testbenches.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
