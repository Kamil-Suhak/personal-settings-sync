#!/usr/bin/env python3
"""Compile a .d2 diagram to a clean, font-stripped .svg for viewer-template.html."""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args(argv: list[str]) -> argparse.Namespace:
    normalized = []
    i = 0
    while i < len(argv):
        tok = argv[i]
        low = tok.lower()
        if low == "-layout":
            normalized.append("--layout")
        elif low == "-pad":
            normalized.append("--pad")
        elif low == "-sourcepath":
            normalized.append("--source")
        elif low == "-outpath":
            normalized.append("--out")
        else:
            normalized.append(tok)
        i += 1

    parser = argparse.ArgumentParser(
        description="Compile a .d2 diagram to a clean, font-stripped .svg."
    )
    parser.add_argument("source", help="Input .d2 diagram path")
    parser.add_argument("out", nargs="?", help="Output .svg path (defaults to source with .svg extension)")
    parser.add_argument("--layout", choices=["dagre", "elk"], help="D2 layout engine")
    parser.add_argument("--pad", type=int, default=24, help="Canvas padding (default: 24)")
    return parser.parse_args(normalized)


def main() -> int:
    args = parse_args(sys.argv[1:])
    src = Path(args.source)
    if not src.is_file():
        print(f"✖ prepare-d2-svg: Source file not found: {src}", file=sys.stderr)
        return 1

    d2_exe = shutil.which("d2")
    if not d2_exe:
        win_fallback = Path(r"C:\Program Files\D2\d2.exe")
        if win_fallback.is_file():
            d2_exe = str(win_fallback)

    if not d2_exe:
        print("✖ prepare-d2-svg: 'd2' binary not found on PATH.", file=sys.stderr)
        return 2

    out = Path(args.out) if args.out else src.with_suffix(".svg")
    out.parent.mkdir(parents=True, exist_ok=True)

    cmd = [d2_exe, "--pad", str(args.pad)]
    if args.layout:
        cmd.extend(["--layout", args.layout])
    cmd.extend([str(src), str(out)])

    res = subprocess.run(cmd)
    if res.returncode != 0:
        print(f"✖ prepare-d2-svg: d2 failed (exit {res.returncode}).", file=sys.stderr)
        return res.returncode

    raw = out.read_text(encoding="utf-8")
    clean = re.sub(r"^\s*<\?xml[^?]*\?>\s*", "", raw)
    clean = re.sub(r"@font-face\s*\{[^}]*\}", "", clean)
    clean = re.sub(r'\.d2-\d+\s+\.text(?:-(?:bold|italic))?\s*\{\s*font-family:\s*"d2-[^"]+";\s*\}', "", clean)
    clean = re.sub(r'<style type="text/css"><!\[CDATA\[\s*\]\]></style>', "", clean)

    out.write_text(clean, encoding="utf-8", newline="\n")

    m = re.search(r'viewBox="0 0 (\d+(?:\.\d+)?) (\d+(?:\.\d+)?)"', clean)
    if m:
        w, h = float(m.group(1)), float(m.group(2))
        ratio = round(w / h, 2) if h > 0 else 0
        w_str = int(w) if w.is_integer() else w
        h_str = int(h) if h.is_integer() else h
        dims = f"{w_str}x{h_str}, ratio {ratio}:1"
    else:
        dims = "unknown dimensions"

    kb = round(len(clean.encode("utf-8")) / 1024.0, 1)
    print(f"OK: {out} ({dims}, {kb} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
