#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor

"""Run local FPGA builds and collect timing/utilization summaries."""

from __future__ import annotations

import argparse
import csv
import os
import platform
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------------------
# Local environment configuration
# ---------------------------------------------------------------------------
# Edit this block for the workstation that runs the local vendor builds.
# Values can also be overridden through the matching LM_SYNTH_* environment
# variables or command-line options.

HOST_PLATFORM = "auto"  # auto, windows, linux
CLOCK_PERIOD_NS = 10.0
OUTPUT_ROOT = Path("build") / "synth"
DEFAULT_TOOLS = ("vivado", "quartus", "diamond", "libero")

TOOL_INSTALL_DIRS = {
    "vivado": os.environ.get("LM_SYNTH_VIVADO_DIR", ""),
    "quartus": os.environ.get("LM_SYNTH_QUARTUS_DIR", ""),
    "diamond": os.environ.get("LM_SYNTH_DIAMOND_DIR", ""),
    "libero": os.environ.get("LM_SYNTH_LIBERO_DIR", ""),
}

TOOL_EXECUTABLES = {
    "vivado": os.environ.get("LM_SYNTH_VIVADO_EXE", "vivado"),
    "quartus": os.environ.get("LM_SYNTH_QUARTUS_SH", "quartus_sh"),
    "diamond": os.environ.get("LM_SYNTH_DIAMONDC", "diamondc"),
    "libero": os.environ.get("LM_SYNTH_LIBERO_EXE", "libero"),
}

VIVADO_PART = os.environ.get("LM_SYNTH_VIVADO_PART", "xc7a35tcsg324-1")

QUARTUS_FAMILY = os.environ.get("LM_SYNTH_QUARTUS_FAMILY", "Cyclone V")
QUARTUS_DEVICE = os.environ.get("LM_SYNTH_QUARTUS_DEVICE", "5CSEMA5F31C6")

DIAMOND_DEVICE = os.environ.get("LM_SYNTH_DIAMOND_DEVICE", "LFE5U-25F-6CABGA381C")
DIAMOND_SYNTH = os.environ.get("LM_SYNTH_DIAMOND_SYNTH", "synplify")

LIBERO_FAMILY = os.environ.get("LM_SYNTH_LIBERO_FAMILY", "PolarFire")
LIBERO_DIE = os.environ.get("LM_SYNTH_LIBERO_DIE", "MPF100T")
LIBERO_PACKAGE = os.environ.get("LM_SYNTH_LIBERO_PACKAGE", "FCG484")
LIBERO_SPEED = os.environ.get("LM_SYNTH_LIBERO_SPEED", "-1")

# ---------------------------------------------------------------------------

LIB_NAME = "lm_math_float_lib"

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

SYNTH_TOPS = [
    "lm_math_fi_mult",
    "lm_math_int_div",
    "lm_math_fpu_rounding",
    "lm_math_fpu_sum",
    "lm_math_fpu_prod",
    "lm_math_fpu_div",
    "lm_math_fpu_div2",
    "lm_math_fpu_sqrt",
    "lm_math_fix_to_fpu",
    "lm_math_fpu_to_fix",
    "lm_math_fpu_to_fpu",
    "lm_math_fpu_mult_cmplx",
]

UTIL_PATTERNS = {
    "lut": [
        r"Slice LUTs\s*\|\s*([0-9,]+)",
        r"Total LUTs\s*[:;]\s*([0-9,]+)",
        r"Combinational ALUTs\s*[:;]\s*([0-9,]+)",
        r"Logic LUTs\s*[:;]\s*([0-9,]+)",
    ],
    "reg": [
        r"Slice Registers\s*\|\s*([0-9,]+)",
        r"Total registers\s*[:;]\s*([0-9,]+)",
        r"Dedicated logic registers\s*[:;]\s*([0-9,]+)",
        r"Registers\s*[:;]\s*([0-9,]+)",
    ],
    "dsp": [
        r"DSPs\s*\|\s*([0-9,]+)",
        r"DSP Blocks\s*[:;]\s*([0-9,]+)",
        r"embedded multiplier.*?[:;]\s*([0-9,]+)",
        r"Mult(?:iplier)?s?\s*[:;]\s*([0-9,]+)",
    ],
    "ram": [
        r"Block RAM Tile\s*\|\s*([0-9,]+)",
        r"Block RAMs?\s*[:;]\s*([0-9,]+)",
        r"Memory bits\s*[:;]\s*([0-9,]+)",
        r"EBRs?\s*[:;]\s*([0-9,]+)",
    ],
}

TOOL_SUBDIRS = {
    "vivado": ("", "bin"),
    "quartus": ("", "bin", "bin64", "quartus/bin", "quartus/bin64"),
    "diamond": ("", "bin", "bin/nt", "bin/nt64", "ispfpga/bin/nt", "ispfpga/bin/nt64"),
    "libero": ("", "bin"),
}

TOOL_BASENAMES = {
    "vivado": ("vivado",),
    "quartus": ("quartus_sh",),
    "diamond": ("diamondc",),
    "libero": ("libero",),
}


@dataclass
class SynthResult:
    tool: str
    top: str
    status: str
    report_dir: Path
    log_file: Path
    fmax_mhz: float | None = None
    wns_ns: float | None = None
    utilization: dict[str, str] = field(default_factory=dict)


def host_is_windows() -> bool:
    if HOST_PLATFORM.lower() == "windows":
        return True
    if HOST_PLATFORM.lower() == "linux":
        return False
    return platform.system().lower().startswith("win")


def abs_path(path: Path | str) -> Path:
    path = Path(path)
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def tool_work_dir(output_root: Path, tool: str, top: str) -> Path:
    return output_root / tool / top


def path_is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def executable_names(tool: str, executable: str) -> list[str]:
    roots: list[str] = []
    if executable:
        roots.append(Path(executable).name)
    roots.extend(TOOL_BASENAMES[tool])

    names: list[str] = []
    for root in roots:
        root_lower = root.lower()
        candidates = [root]
        if host_is_windows() and not root_lower.endswith((".bat", ".exe")):
            candidates.extend([root + ".bat", root + ".exe"])
        for name in candidates:
            if name not in names:
                names.append(name)
    return names


def resolve_tool(tool: str, executable: str, install_dir: str) -> str | None:
    exe_path = Path(executable)
    if executable and (exe_path.is_absolute() or exe_path.parent != Path(".")):
        candidate = abs_path(exe_path)
        if candidate.exists():
            return str(candidate)

    if install_dir:
        root = abs_path(install_dir)
        for subdir in TOOL_SUBDIRS[tool]:
            search_dir = root / subdir if subdir else root
            for name in executable_names(tool, executable):
                candidate = search_dir / name
                if candidate.exists():
                    return str(candidate)
        return None

    if executable:
        found = shutil.which(executable)
        if found:
            return found
    for name in executable_names(tool, ""):
        found = shutil.which(name)
        if found:
            return found
    return None


def tcl_path(path: Path | str) -> str:
    return abs_path(path).as_posix()


def tcl_quote(value: str | Path) -> str:
    text = str(value).replace("\\", "/")
    return "{" + text.replace("}", "\\}") + "}"


def write_file(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def source_list_tcl() -> str:
    return " ".join(tcl_quote(tcl_path(ROOT / src)) for src in SRC_FILES)


def write_common_sdc(work_dir: Path, clock_period_ns: float) -> Path:
    sdc = work_dir / "clock.sdc"
    write_file(
        sdc,
        f"create_clock -name clk_i -period {clock_period_ns:.3f} [get_ports {{clk_i}}]\n",
    )
    return sdc


def vivado_script(top: str, work_dir: Path, clock_period_ns: float) -> Path:
    script = work_dir / "run_vivado.tcl"
    files = source_list_tcl()
    write_file(
        script,
        f"""set part {VIVADO_PART}
set clk_period {clock_period_ns:.3f}
set src_files [list {files}]
create_project -in_memory -part ${{part}}
set_property target_language VHDL [current_project]
foreach src ${{src_files}} {{
  read_vhdl -vhdl2008 -library {LIB_NAME} $src
}}
synth_design -top {top} -part ${{part}} -mode out_of_context
if {{[llength [get_ports -quiet clk_i]] > 0}} {{
  create_clock -period ${{clk_period}} -name clk_i [get_ports clk_i]
}}
report_utilization -file {tcl_quote(tcl_path(work_dir / "utilization.rpt"))}
opt_design
place_design
route_design
report_timing_summary -delay_type max -file {tcl_quote(tcl_path(work_dir / "timing.rpt"))}
set paths [get_timing_paths -quiet -max_paths 1 -setup]
if {{[llength ${{paths}}] > 0}} {{
  set wns [get_property SLACK [lindex ${{paths}} 0]]
  puts "LM_SYNTH_METRIC WNS_NS=${{wns}}"
}}
puts "LM_SYNTH_METRIC CLOCK_PERIOD_NS=${{clk_period}}"
""",
    )
    return script


def quartus_script(top: str, work_dir: Path, clock_period_ns: float) -> Path:
    sdc = write_common_sdc(work_dir, clock_period_ns)
    script = work_dir / "run_quartus.tcl"
    assignments = "\n".join(
        f"set_global_assignment -name VHDL_FILE {tcl_quote(tcl_path(ROOT / src))} -library {LIB_NAME}"
        for src in SRC_FILES
    )
    write_file(
        script,
        f"""load_package flow
project_new {top} -overwrite
set_global_assignment -name FAMILY {tcl_quote(QUARTUS_FAMILY)}
set_global_assignment -name DEVICE {tcl_quote(QUARTUS_DEVICE)}
set_global_assignment -name TOP_LEVEL_ENTITY {top}
set_global_assignment -name VHDL_INPUT_VERSION VHDL_2008
{assignments}
set_global_assignment -name SDC_FILE {tcl_quote(tcl_path(sdc))}
execute_flow -compile
project_close
""",
    )
    return script


def diamond_script(top: str, work_dir: Path, clock_period_ns: float) -> Path:
    sdc = write_common_sdc(work_dir, clock_period_ns)
    script = work_dir / "run_diamond.tcl"
    sources = "\n".join(
        f"prj_src add {tcl_quote(tcl_path(ROOT / src))} -work {LIB_NAME}" for src in SRC_FILES
    )
    write_file(
        script,
        f"""set project_name {top}
set impl_name impl1
prj_project new -name ${{project_name}} -impl ${{impl_name}} -dev {DIAMOND_DEVICE} -synthesis {DIAMOND_SYNTH}
{sources}
prj_src add {tcl_quote(tcl_path(sdc))}
prj_impl option top {top}
prj_run Synthesis -impl ${{impl_name}}
prj_run Map -impl ${{impl_name}}
prj_run PAR -impl ${{impl_name}}
prj_project save
prj_project close
""",
    )
    return script


def libero_script(top: str, work_dir: Path, clock_period_ns: float) -> Path:
    sdc = write_common_sdc(work_dir, clock_period_ns)
    script = work_dir / "run_libero.tcl"
    imports = "\n".join(
        f"import_files -hdl_source {tcl_quote(tcl_path(ROOT / src))} -library {LIB_NAME}"
        for src in SRC_FILES
    )
    write_file(
        script,
        f"""new_project \\
  -location {tcl_quote(tcl_path(work_dir))} \\
  -name {top} \\
  -hdl VHDL \\
  -family {tcl_quote(LIBERO_FAMILY)} \\
  -die {tcl_quote(LIBERO_DIE)} \\
  -package {tcl_quote(LIBERO_PACKAGE)} \\
  -speed {tcl_quote(LIBERO_SPEED)}
{imports}
set_root -module {top}
import_files -sdc {tcl_quote(tcl_path(sdc))}
run_tool -name {{SYNTHESIZE}}
run_tool -name {{PLACEROUTE}}
run_tool -name {{VERIFYTIMING}}
save_project
close_project
""",
    )
    return script


SCRIPT_WRITERS = {
    "vivado": vivado_script,
    "quartus": quartus_script,
    "diamond": diamond_script,
    "libero": libero_script,
}


def command_for(tool: str, command: str, script: Path) -> list[str]:
    base = [command]
    if tool == "vivado":
        return base + ["-mode", "batch", "-source", str(script)]
    if tool == "quartus":
        return base + ["-t", str(script)]
    if tool == "diamond":
        return base + [str(script)]
    if tool == "libero":
        return base + [f"SCRIPT:{script}"]
    raise ValueError(f"unknown tool: {tool}")


def run_command(command: list[str], cwd: Path, log_file: Path) -> int:
    printable = " ".join(command)
    print(f"+ {printable}", flush=True)
    with log_file.open("w", encoding="utf-8", newline="\n") as log:
        log.write(f"+ {printable}\n")
        log.flush()
        proc = subprocess.Popen(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            log.write(line)
        return proc.wait()


def parse_number(text: str) -> float | None:
    cleaned = text.replace(",", "").strip()
    try:
        return float(cleaned)
    except ValueError:
        return None


def parse_int_text(text: str) -> str | None:
    match = re.search(r"([0-9][0-9,]*)", text)
    if not match:
        return None
    return match.group(1).replace(",", "")


def parse_metrics(text: str, fallback_period_ns: float) -> tuple[float | None, float | None]:
    wns_ns: float | None = None
    period_ns: float | None = None
    fmax_mhz: float | None = None

    for key, value in re.findall(r"LM_SYNTH_METRIC\s+([A-Z0-9_]+)=([^\s]+)", text):
        number = parse_number(value)
        if number is None:
            continue
        if key == "WNS_NS":
            wns_ns = number
        elif key == "CLOCK_PERIOD_NS":
            period_ns = number
        elif key == "FMAX_MHZ":
            fmax_mhz = number

    if fmax_mhz is None:
        match = re.search(r"Fmax[^0-9\n\r-]*([0-9]+(?:\.[0-9]+)?)\s*MHz", text, re.IGNORECASE)
        if match:
            fmax_mhz = parse_number(match.group(1))

    if wns_ns is None:
        for pattern in (r"WNS\(ns\)\s*[:|]\s*(-?[0-9]+(?:\.[0-9]+)?)", r"slack\s*[:=]\s*(-?[0-9]+(?:\.[0-9]+)?)"):
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                wns_ns = parse_number(match.group(1))
                break

    if fmax_mhz is None and wns_ns is not None:
        period = period_ns or fallback_period_ns
        achieved = period - wns_ns
        if achieved > 0:
            fmax_mhz = 1000.0 / achieved

    return fmax_mhz, wns_ns


def parse_utilization(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for key, patterns in UTIL_PATTERNS.items():
        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if not match:
                continue
            value = parse_int_text(match.group(1))
            if value is not None:
                values[key] = value
                break
    return values


def collect_report_text(report_dir: Path, log_file: Path) -> str:
    chunks: list[str] = []
    if log_file.exists():
        chunks.append(log_file.read_text(encoding="utf-8", errors="replace"))

    suffixes = {".rpt", ".summary", ".sta", ".fit", ".map", ".mrp", ".twr", ".log"}
    for path in sorted(report_dir.rglob("*")):
        if not path.is_file() or path == log_file:
            continue
        if path.suffix.lower() not in suffixes:
            continue
        try:
            chunks.append(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
    return "\n".join(chunks)


def build_one(
    tool: str,
    top: str,
    command: str,
    output_root: Path,
    clock_period_ns: float,
    emit_only: bool,
) -> SynthResult:
    work_dir = tool_work_dir(output_root, tool, top)
    work_dir.mkdir(parents=True, exist_ok=True)
    script = SCRIPT_WRITERS[tool](top, work_dir, clock_period_ns)
    log_file = work_dir / f"{tool}.log"

    if emit_only:
        return SynthResult(tool=tool, top=top, status="scripted", report_dir=work_dir, log_file=log_file)

    cmd = command_for(tool, command, script)
    rc = run_command(cmd, work_dir, log_file)
    report_text = collect_report_text(work_dir, log_file)
    fmax_mhz, wns_ns = parse_metrics(report_text, clock_period_ns)
    utilization = parse_utilization(report_text)
    status = "pass" if rc == 0 else f"fail({rc})"
    return SynthResult(
        tool=tool,
        top=top,
        status=status,
        report_dir=work_dir,
        log_file=log_file,
        fmax_mhz=fmax_mhz,
        wns_ns=wns_ns,
        utilization=utilization,
    )


def parse_tools(value: str) -> list[str]:
    if value == "auto":
        return list(DEFAULT_TOOLS)
    requested = [item.strip().lower() for item in value.split(",") if item.strip()]
    unknown = [tool for tool in requested if tool not in DEFAULT_TOOLS]
    if unknown:
        raise argparse.ArgumentTypeError(f"unknown tool(s): {', '.join(unknown)}")
    return requested


def parse_modules(values: list[str] | None) -> list[str]:
    if not values:
        return list(SYNTH_TOPS)
    modules: list[str] = []
    for value in values:
        modules.extend(item.strip() for item in value.split(",") if item.strip())
    unknown = [module for module in modules if module not in SYNTH_TOPS]
    if unknown:
        raise argparse.ArgumentTypeError(f"unknown module(s): {', '.join(unknown)}")
    return modules


def format_float(value: float | None) -> str:
    if value is None:
        return ""
    return f"{value:.2f}"


def write_summary(results: list[SynthResult], output_root: Path, clock_period_ns: float) -> None:
    output_root.mkdir(parents=True, exist_ok=True)
    csv_path = output_root / "synthesis_summary.csv"
    md_path = output_root / "synthesis_summary.md"

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["tool", "module", "status", "fmax_mhz", "wns_ns", "lut", "reg", "dsp", "ram", "report_dir"])
        for result in results:
            writer.writerow(
                [
                    result.tool,
                    result.top,
                    result.status,
                    format_float(result.fmax_mhz),
                    format_float(result.wns_ns),
                    result.utilization.get("lut", ""),
                    result.utilization.get("reg", ""),
                    result.utilization.get("dsp", ""),
                    result.utilization.get("ram", ""),
                    str(result.report_dir),
                ]
            )

    lines = [
        "# Local Synthesis Summary",
        "",
        f"Clock target: {clock_period_ns:.3f} ns",
        "",
        "| Tool | Module | Status | Fmax MHz | WNS ns | LUT | Reg | DSP | RAM |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for result in results:
        lines.append(
            "| "
            + " | ".join(
                [
                    result.tool,
                    f"`{result.top}`",
                    result.status,
                    format_float(result.fmax_mhz),
                    format_float(result.wns_ns),
                    result.utilization.get("lut", ""),
                    result.utilization.get("reg", ""),
                    result.utilization.get("dsp", ""),
                    result.utilization.get("ram", ""),
                ]
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "Raw logs and vendor reports are stored under the per-tool module directories.",
        ]
    )
    write_file(md_path, "\n".join(lines) + "\n")


def list_tools(commands: dict[str, str], install_dirs: dict[str, str]) -> None:
    for tool in DEFAULT_TOOLS:
        command = commands[tool]
        install_dir = install_dirs[tool] or "<PATH>"
        found = resolve_tool(tool, command, install_dirs[tool])
        status = found if found else "not found"
        print(f"{tool:8s} dir={install_dir} exe={command} -> {status}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tools",
        default="auto",
        type=parse_tools,
        help="Comma-separated tools to run, or auto for all known tools.",
    )
    parser.add_argument(
        "--module",
        action="append",
        help="Module to build. May be repeated or comma-separated. Defaults to all modules.",
    )
    parser.add_argument(
        "--clock-period",
        type=float,
        default=CLOCK_PERIOD_NS,
        help="Clock period in ns used for generated constraints.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=OUTPUT_ROOT,
        help="Output directory for generated scripts, logs, and summaries.",
    )
    parser.add_argument("--vivado-dir", default=TOOL_INSTALL_DIRS["vivado"], help="Vivado install or bin directory")
    parser.add_argument("--quartus-dir", default=TOOL_INSTALL_DIRS["quartus"], help="Quartus install or bin directory")
    parser.add_argument("--diamond-dir", default=TOOL_INSTALL_DIRS["diamond"], help="Diamond install or bin directory")
    parser.add_argument("--libero-dir", default=TOOL_INSTALL_DIRS["libero"], help="Libero install or bin directory")
    parser.add_argument("--vivado", default=TOOL_EXECUTABLES["vivado"], help="Vivado executable name or path")
    parser.add_argument("--quartus-sh", default=TOOL_EXECUTABLES["quartus"], help="quartus_sh executable name or path")
    parser.add_argument("--diamondc", default=TOOL_EXECUTABLES["diamond"], help="diamondc executable name or path")
    parser.add_argument("--libero", default=TOOL_EXECUTABLES["libero"], help="Libero executable name or path")
    parser.add_argument(
        "--emit-only",
        action="store_true",
        help="Generate vendor scripts without running the tools.",
    )
    parser.add_argument(
        "--list-tools",
        action="store_true",
        help="Print tool discovery results and exit.",
    )
    parser.add_argument(
        "--keep-build",
        action="store_true",
        help="Keep the output directory before generating new reports.",
    )
    args = parser.parse_args()

    commands = {
        "vivado": args.vivado,
        "quartus": args.quartus_sh,
        "diamond": args.diamondc,
        "libero": args.libero,
    }
    install_dirs = {
        "vivado": args.vivado_dir,
        "quartus": args.quartus_dir,
        "diamond": args.diamond_dir,
        "libero": args.libero_dir,
    }

    if args.list_tools:
        list_tools(commands, install_dirs)
        return 0

    try:
        modules = parse_modules(args.module)
    except argparse.ArgumentTypeError as exc:
        parser.error(str(exc))
    output_root = abs_path(args.output_dir)
    if output_root.exists() and not args.keep_build:
        build_root = abs_path("build")
        if not path_is_relative_to(output_root, build_root):
            print("Refusing to clean an output directory outside build/. Use --keep-build.", file=sys.stderr)
            return 2
        shutil.rmtree(output_root)
    output_root.mkdir(parents=True, exist_ok=True)

    selected_tools = args.tools
    resolved_commands = {
        tool: resolve_tool(tool, commands[tool], install_dirs[tool]) for tool in selected_tools
    }
    if not args.emit_only:
        selected_tools = [tool for tool in selected_tools if resolved_commands[tool] is not None]
        if not selected_tools:
            print("No requested vendor tool was found. Set *_DIR in the script or use --emit-only.", file=sys.stderr)
            return 2

    results: list[SynthResult] = []
    for tool in selected_tools:
        for top in modules:
            print("=" * 72)
            print(f"{tool}: {top}")
            print("=" * 72)
            result = build_one(
                tool=tool,
                top=top,
                command=resolved_commands[tool] or commands[tool],
                output_root=output_root,
                clock_period_ns=args.clock_period,
                emit_only=args.emit_only,
            )
            results.append(result)

    write_summary(results, output_root, args.clock_period)
    print(f"Wrote {output_root / 'synthesis_summary.md'}")
    print(f"Wrote {output_root / 'synthesis_summary.csv'}")

    return 1 if any(result.status.startswith("fail") for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
