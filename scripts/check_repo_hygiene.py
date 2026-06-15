#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Logimentor

"""Repository hygiene checks for source, metadata, and git refs."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

WORD_EDGE = r"(?<![A-Za-z0-9_])"
WORD_TAIL = r"(?![A-Za-z0-9_])"


def marker(*parts: str) -> str:
    return "".join(parts)


def word_marker(*parts: str) -> re.Pattern[str]:
    return re.compile(WORD_EDGE + re.escape(marker(*parts)) + WORD_TAIL, re.IGNORECASE)


def text_marker(*parts: str) -> re.Pattern[str]:
    return re.compile(re.escape(marker(*parts)), re.IGNORECASE)


FORBIDDEN_TEXT_PATTERNS = [
    word_marker("a", "i"),
    re.compile(WORD_EDGE + "a" + r"\." + "i" + r"\." + WORD_TAIL, re.IGNORECASE),
    re.compile(WORD_EDGE + "a" + r"[\s_-]*" + "i" + r"[\s_-]*assisted" + WORD_TAIL, re.IGNORECASE),
    word_marker("l", "l", "m"),
    word_marker("ag", "ent"),
    word_marker("ag", "ents"),
    word_marker("ag", "enti"),
    text_marker("cl", "aude"),
    re.compile(
        re.escape(marker("cl", "aude")) + r"[\s_-]+" + re.escape(marker("co", "de")),
        re.IGNORECASE,
    ),
    text_marker("co", "dex"),
    text_marker("anth", "ropic"),
    text_marker("open", "a", "i"),
    text_marker("chat", "g", "pt"),
    text_marker("co", "pilot"),
]

FORBIDDEN_PATH_PARTS = {
    "." + "a" + "i",
    ".ag" + "ent",
    ".cl" + "aude",
    ".co" + "dex",
    ".ag" + "ents",
}

SKIP_SUFFIXES = {
    ".cf",
    ".ghw",
    ".png",
    ".jpg",
    ".jpeg",
    ".pdf",
    ".qdb",
    ".qpg",
    ".qtl",
    ".vcd",
    ".wlf",
}

VHDL_SUFFIXES = {".vhd", ".vhdl"}
SCRIPT_SUFFIXES = {".py", ".do", ".yml", ".yaml"}

OUTPUT_DIR_NAMES = {
    "__pycache__",
    ".xil",
    "incremental_db",
    "lm_math_float_lib",
    "output_files",
    "work",
    "xsim.dir",
}

OUTPUT_FILE_NAMES = {
    "modelsim.ini",
    "transcript",
    "vivado.jou",
    "vivado.log",
    "vsim.wlf",
}

OUTPUT_SUFFIXES = {
    ".cf",
    ".dcp",
    ".dll",
    ".dylib",
    ".edf",
    ".edif",
    ".exe",
    ".ghw",
    ".jou",
    ".log",
    ".mrp",
    ".o",
    ".obj",
    ".pyc",
    ".pyo",
    ".qdb",
    ".qpf",
    ".qsf",
    ".rpt",
    ".so",
    ".srr",
    ".str",
    ".summary",
    ".twr",
    ".vcd",
    ".wlf",
}

SCAN_SKIP_DIRS = {
    ".git",
    ".venv",
    "build",
    "venv",
}


def run_git_ls_files() -> list[Path]:
    result = run_git(
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        include_untracked=True,
    )
    return [ROOT / line.strip() for line in result.stdout.splitlines() if line.strip()]


def run_git(*args: str, include_untracked: bool = False) -> subprocess.CompletedProcess[str]:
    command = ["git"]
    if include_untracked:
        command.extend(["-c", "core.excludesFile="])
    command.extend(args)
    return subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def display_path(path: Path) -> str:
    try:
        return rel(path)
    except ValueError:
        return str(path)


def walk_workspace_entries() -> list[Path]:
    entries: list[Path] = []
    stack = [ROOT]
    while stack:
        current = stack.pop()
        try:
            children = list(current.iterdir())
        except OSError:
            continue
        for child in children:
            if child.is_dir():
                if child.name in SCAN_SKIP_DIRS:
                    continue
                entries.append(child)
                stack.append(child)
            else:
                entries.append(child)
    return entries


def check_generated_outputs() -> list[str]:
    errors: list[str] = []
    for path in walk_workspace_entries():
        name = path.name.lower()
        if path.is_dir():
            if name in OUTPUT_DIR_NAMES:
                errors.append(f"{rel(path)}/: generated output directory outside build/")
            continue
        if name in OUTPUT_FILE_NAMES or path.suffix.lower() in OUTPUT_SUFFIXES:
            errors.append(f"{rel(path)}: generated output file outside build/")
    return errors


def should_skip(path: Path) -> bool:
    relative = path.resolve().relative_to(ROOT)
    if any(part in FORBIDDEN_PATH_PARTS for part in relative.parts):
        return False
    if path.suffix.lower() in SKIP_SUFFIXES:
        return True
    return False


def read_text(path: Path, *, skip_known_outputs: bool = True) -> str | None:
    if skip_known_outputs and should_skip(path):
        return None
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="replace")


def check_forbidden_paths(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        parts = path.resolve().relative_to(ROOT).parts
        for part in parts:
            if part.lower() in FORBIDDEN_PATH_PARTS:
                errors.append(f"{rel(path)}: forbidden local-tool path component '{part}'")
    return errors


def find_forbidden_text(label: str, text: str) -> list[str]:
    errors: list[str] = []
    for pattern in FORBIDDEN_TEXT_PATTERNS:
        for match in pattern.finditer(text):
            errors.append(f"{label}: forbidden repository marker '{match.group(0)}'")
    return errors


def check_forbidden_terms(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        text = read_text(path)
        if text is None:
            continue
        errors.extend(find_forbidden_text(display_path(path), text))
    return errors


def check_message_files(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        text = read_text(path, skip_known_outputs=False)
        if text is None:
            errors.append(f"{display_path(path)}: message file is not readable")
            continue
        errors.extend(find_forbidden_text(display_path(path), text))
    return errors


def check_current_branch_name() -> list[str]:
    try:
        result = run_git("branch", "--show-current")
    except subprocess.CalledProcessError:
        return []
    branch = result.stdout.strip()
    if not branch:
        return []
    return find_forbidden_text("current branch", branch)


def check_ref_names(all_refs: bool) -> list[str]:
    if not all_refs:
        return check_current_branch_name()
    try:
        result = run_git("for-each-ref", "--format=%(refname)")
    except subprocess.CalledProcessError:
        return []
    errors: list[str] = []
    for refname in result.stdout.splitlines():
        errors.extend(find_forbidden_text(f"git ref {refname}", refname))
    return errors


def check_git_history(all_refs: bool) -> list[str]:
    revisions = ["--all"] if all_refs else ["HEAD"]
    try:
        result = run_git("log", "--format=%H%x00%B%x00END%x00", *revisions)
    except subprocess.CalledProcessError as exc:
        return [f"git history: unable to inspect commit messages ({exc})"]

    errors: list[str] = []
    for record in result.stdout.split("\0END\0"):
        record = record.strip("\0\n")
        if not record:
            continue
        commit_hash, _, message = record.partition("\0")
        errors.extend(find_forbidden_text(f"commit {commit_hash[:12]}", message))
    return errors


def check_spdx_headers(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        suffix = path.suffix.lower()
        if suffix not in VHDL_SUFFIXES and suffix not in SCRIPT_SUFFIXES:
            continue
        text = read_text(path)
        if text is None:
            continue
        first_lines = "\n".join(text.splitlines()[:8])
        if "SPDX-License-Identifier: Apache-2.0" not in first_lines:
            errors.append(f"{rel(path)}: missing Apache-2.0 SPDX header")
        if "Copyright 2026 Logimentor" not in first_lines:
            errors.append(f"{rel(path)}: missing Logimentor copyright header")
    return errors


def check_license_file() -> list[str]:
    license_file = ROOT / "LICENSE"
    if not license_file.exists():
        return ["LICENSE: missing Apache-2.0 license file"]
    text = license_file.read_text(encoding="utf-8", errors="replace")
    if "Apache License" not in text or "Version 2.0" not in text:
        return ["LICENSE: does not look like Apache-2.0"]
    return []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="Optional paths to check. Defaults to git-tracked files.",
    )
    parser.add_argument(
        "--all-refs",
        action="store_true",
        help="Also inspect commit messages reachable from every local ref.",
    )
    parser.add_argument(
        "--no-history",
        action="store_true",
        help="Skip branch-name and commit-message checks.",
    )
    parser.add_argument(
        "--message-file",
        action="store_true",
        help="Treat positional paths as commit-message files and scan the repository too.",
    )
    args = parser.parse_args()

    message_files: list[Path] = []
    if args.message_file:
        message_files = [Path(p).resolve() for p in args.paths]
        paths = run_git_ls_files()
    elif args.paths:
        paths = [Path(p).resolve() for p in args.paths]
    else:
        paths = run_git_ls_files()

    paths = [path for path in paths if path.exists()]

    errors: list[str] = []
    errors.extend(check_license_file())
    errors.extend(check_generated_outputs())
    errors.extend(check_forbidden_paths(paths))
    errors.extend(check_forbidden_terms(paths))
    errors.extend(check_message_files(message_files))
    errors.extend(check_spdx_headers(paths))
    if not args.no_history:
        errors.extend(check_ref_names(args.all_refs))
        errors.extend(check_git_history(args.all_refs))

    if errors:
        print("Repository hygiene check failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(f"Repository hygiene check passed ({len(paths)} candidate files checked).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
