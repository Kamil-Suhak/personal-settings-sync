#!/usr/bin/env python3
"""Profile group registry and `# @cmd:` documentation extractor for PSS."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CMD_ANNOTATION_RE = re.compile(r"^\s*#\s*@cmd:\s*(\S+)\s+[—\-–]+\s+(.+?)\s*$")
FUNC_DEF_RE = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_.\-]*)\s*\(\s*\)\s*\{?")

_BIN_DIR = Path(__file__).resolve().parent.parent / "configs" / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))
from _pss_common import resolve_workspace_chain  # noqa: E402


def get_profile_groups(root: str | Path, workspace: str) -> list[dict]:
    root_path = Path(root)
    groups: list[dict] = [
        {
            "name": "shared",
            "path": root_path / "configs" / "zsh" / "init.zsh",
            "scope": "shared",
            "required": True,
        }
    ]
    for name in ("git", "navigation", "search", "ai"):
        groups.append(
            {
                "name": name,
                "path": root_path / "configs" / "zsh" / f"{name}.zsh",
                "scope": "shared",
                "required": True,
            }
        )
    for ws in resolve_workspace_chain(root_path, workspace):
        worksets_file = root_path / "workspaces" / ws / "zsh" / "worksets.zsh"
        if worksets_file.is_file():
            groups.append(
                {
                    "name": "worksets",
                    "path": worksets_file,
                    "scope": "workspace",
                    "required": True,
                }
            )
        groups.append(
            {
                "name": ws,
                "path": root_path / "workspaces" / ws / "zsh" / "profile.zsh",
                "scope": "workspace",
                "required": False,
            }
        )
    return groups


def extract_group_commands(file_path: str | Path) -> list[dict]:
    path = Path(file_path)
    if not path.is_file():
        return []

    commands: list[dict] = []
    seen: set[str] = set()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines:
        m = CMD_ANNOTATION_RE.match(line)
        if m:
            name, summary = m.group(1).strip(), m.group(2).strip()
            if name not in seen:
                seen.add(name)
                commands.append({"name": name, "summary": summary, "path": str(path)})
    return commands


def extract_shell_functions(file_path: str | Path) -> dict[str, str]:
    """Extracts top-level shell function blocks for `pss bootstrap`."""
    path = Path(file_path)
    if not path.is_file():
        return {}

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    functions: dict[str, str] = {}
    i = 0
    while i < len(lines):
        m = FUNC_DEF_RE.match(lines[i])
        if m and not lines[i].lstrip().startswith("#"):
            fn_name = m.group(1)
            block: list[str] = []
            # Capture immediate preceding `# @cmd:` comment if present
            if i > 0 and CMD_ANNOTATION_RE.match(lines[i - 1]):
                block.append(lines[i - 1])
            depth = 0
            started = False
            j = i
            while j < len(lines):
                line = lines[j]
                block.append(line)
                # Strip simple single-line comments after tokens only if outside quotes;
                # simple brace counting handles standard shell function bodies cleanly.
                opens = line.count("{")
                closes = line.count("}")
                if opens > 0:
                    started = True
                depth += opens - closes
                if started and depth <= 0:
                    break
                j += 1
            functions[fn_name] = "\n".join(block)
            i = j + 1
            continue
        i += 1
    return functions


def format_profile_help(
    root: str | Path,
    workspace: str,
    state_project_roots: str | None = None,
) -> str:
    root_path = Path(root)
    init_path = root_path / "configs" / "zsh" / "init.zsh"
    cyan, yellow, green, gray, reset = (
        "\033[36m",
        "\033[33m",
        "\033[32m",
        "\033[90m",
        "\033[0m",
    )
    out: list[str] = [
        f"\n{cyan}Profile Commands ({workspace}){reset}  {gray}{init_path}{reset}",
        f"{gray}{'─' * 60}{reset}",
        "",
    ]

    for group in get_profile_groups(root_path, workspace):
        cmds = extract_group_commands(group["path"])
        if not cmds:
            continue
        out.append(f"  {yellow}[{group['name']}]{reset}")
        pad = max(max((len(c["name"]) for c in cmds), default=10) + 2, 12)
        for c in cmds:
            out.append(f"    {green}{c['name'].ljust(pad)}{reset} {c['summary']}")
        out.append("")

    if state_project_roots:
        out.append(f"  {gray}Project roots file: {state_project_roots}{reset}")
        out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="List PSS Zsh profile groups and commands.")
    parser.add_argument("--root", required=True, help="PSS repository root")
    parser.add_argument("--workspace", default="personal", help="Active workspace")
    parser.add_argument("--project-roots", help="Project roots file path to display")
    parser.add_argument("--profile-help", action="store_true", help="Print formatted profile command directory")
    parser.add_argument("--json", action="store_true", help="Emit JSON metadata")
    args = parser.parse_args()

    if args.profile_help:
        print(format_profile_help(args.root, args.workspace, state_project_roots=args.project_roots))
        return 0

    groups = get_profile_groups(args.root, args.workspace)
    payload = [
        {
            "name": g["name"],
            "path": str(g["path"]),
            "scope": g["scope"],
            "required": g["required"],
            "commands": extract_group_commands(g["path"]),
        }
        for g in groups
    ]
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        for g in payload:
            print(f"{g['scope']}\t{g['name']}\t{g['path']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
