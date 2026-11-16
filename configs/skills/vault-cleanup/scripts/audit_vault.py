#!/usr/bin/env python3
"""Audit an Obsidian vault's raw/ and wiki/ directories for hygiene issues."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
ATTACHMENT_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf", ".mp4", ".mp3", ".wav"}


def resolve_vault(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    env_vault = os.environ.get("PSS_NOTES_VAULT")
    if env_vault:
        return Path(os.path.expandvars(env_vault)).expanduser().resolve()
    return (Path.home() / "notes").resolve()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit Obsidian vault raw/ and wiki/ hygiene.")
    parser.add_argument("vault", nargs="?", help="Vault root path (defaults to $PSS_NOTES_VAULT or ~/notes)")
    parser.add_argument("--strict", action="store_true", help="Exit with code 1 if any issues are found")
    args = parser.parse_args(argv)

    vault = resolve_vault(args.vault)
    raw = vault / "raw"
    wiki = vault / "wiki"

    raw_files = sorted(p.relative_to(raw) for p in raw.rglob("*") if p.is_file()) if raw.is_dir() else []
    print(f"=== Vault: {vault} ===")
    print(f"\n=== RAW ({len(raw_files)} files) ===")
    for rf in raw_files:
        print(f"  - {rf}")

    wiki_md = sorted(wiki.rglob("*.md")) if wiki.is_dir() else []
    all_attachments = {p.name.lower() for p in vault.rglob("*") if p.is_file() and p.suffix.lower() in ATTACHMENT_EXTS}
    stems: dict[str, list[Path]] = {}
    for p in wiki_md:
        stems.setdefault(p.stem.lower(), []).append(p)

    index_files = [p for p in wiki_md if p.stem.lower() == "_index"]
    missing_hubs: list[Path] = []
    for d in sorted(p for p in wiki.rglob("*") if p.is_dir()):
        if d.name == "archived" or not any(d.glob("*.md")):
            continue
        if not (d / f"{d.name}.md").is_file():
            missing_hubs.append(d.relative_to(wiki))

    broken_links: list[tuple[str, str]] = []
    inbound_counts: dict[Path, int] = {p: 0 for p in wiki_md}

    for p in wiki_md:
        text = p.read_text(encoding="utf-8", errors="replace")
        cleaned = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
        cleaned = re.sub(r"``.*?``|`[^`\n]+`", "", cleaned)
        for m in WIKILINK_RE.finditer(cleaned):
            raw_target = m.group(1).split("|", 1)[0].split("#", 1)[0].strip()
            if not raw_target:
                continue
            key = raw_target.lower()
            if Path(key).suffix in ATTACHMENT_EXTS and Path(key).name in all_attachments:
                continue

            matched_paths: list[Path] = []
            if "/" in key:
                for cand in wiki_md:
                    if cand.relative_to(wiki).with_suffix("").as_posix().lower() == key:
                        matched_paths.append(cand)
            else:
                matched_paths = stems.get(key, [])

            if not matched_paths:
                broken_links.append((p.relative_to(wiki).as_posix(), raw_target))
            else:
                for mp in matched_paths:
                    if mp != p:
                        inbound_counts[mp] += 1

    orphans = [
        p.relative_to(wiki).as_posix()
        for p, cnt in inbound_counts.items()
        if cnt == 0 and p.relative_to(wiki).as_posix() != "wiki.md" and "archived" not in p.parts
    ]
    dups = {k: v for k, v in stems.items() if len(v) > 1}

    print(f"\n=== _Index.md files ({len(index_files)}) ===")
    for p in index_files:
        print(f"  - {p.relative_to(wiki)}")

    print(f"\n=== Folders missing <Topic>/<Topic>.md hub ({len(missing_hubs)}) ===")
    for d in missing_hubs:
        print(f"  - {d}")

    print(f"\n=== Broken [[wikilinks]] ({len(broken_links)}) ===")
    for src, tgt in broken_links:
        print(f"  - {src} -> [[{tgt}]]")

    print(f"\n=== Orphan notes (0 inbound links) ({len(orphans)}) ===")
    for o in orphans:
        print(f"  - {o}")

    print(f"\n=== Duplicate note stems ({len(dups)}) ===")
    for k, paths in dups.items():
        print(f"  - {k}: {[str(p.relative_to(wiki)) for p in paths]}")

    has_issues = bool(index_files or missing_hubs or broken_links or orphans or dups)
    return 1 if (args.strict and has_issues) else 0


if __name__ == "__main__":
    raise SystemExit(main())
