#!/usr/bin/env python3
"""Local machine state paths and safe legacy-state migration for PSS."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve_state_home(
    state_home: str | Path | None = None,
    home_dir: str | Path | None = None,
) -> Path:
    if state_home:
        return Path(state_home)
    env_pss = os.environ.get("PSS_STATE_HOME", "").strip()
    if env_pss:
        return Path(env_pss)
    xdg_state = os.environ.get("XDG_STATE_HOME", "").strip()
    if xdg_state:
        return Path(xdg_state) / "pss"
    base_home = Path(home_dir) if home_dir else Path.home()
    return base_home / ".local" / "state" / "pss"


def get_local_state_paths(
    checkout: str | Path,
    state_home: str | Path | None = None,
    home_dir: str | Path | None = None,
) -> dict[str, Path]:
    root = resolve_state_home(state_home=state_home, home_dir=home_dir)
    resolved_checkout = str(Path(checkout).resolve()).rstrip("/\\")
    canonical = os.path.normcase(resolved_checkout)
    checkout_id = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return {
        "root": root,
        "project_roots": root / "project-roots",
        "local_profile": root / "profile.local.zsh",
        "workspace": root / "checkouts" / checkout_id / "workspace.local",
        "worksets_root": root / "worksets" / "work",
    }


def migrate_legacy_local_state(
    paths: dict[str, Path],
    checkout: str | Path,
    home_dir: str | Path | None = None,
    what_if: bool = False,
) -> list[str]:
    checkout_path = Path(checkout)
    home_path = Path(home_dir) if home_dir else Path.home()

    candidates: list[tuple[Path, Path]] = [
        (home_path / ".project-roots", paths["project_roots"]),
        (home_path / ".profile.local.zsh", paths["local_profile"]),
        (home_path / ".profile.local.ps1", paths["local_profile"]),
        (checkout_path / ".workspace.local", paths["workspace"]),
    ]

    existing: list[tuple[Path, Path]] = [
        (src, dst) for src, dst in candidates if src.is_file()
    ]
    if not existing:
        return []

    messages: list[str] = []
    if what_if:
        for src, dst in existing:
            msg = f"WHAT-IF: Migrate '{src}' to '{dst}'."
            print(msg)
            messages.append(msg)
        return messages

    # 1. Pre-flight hash verification & conflict detection before touching disk
    source_hashes: dict[Path, str] = {}
    dest_expected_hashes: dict[Path, str] = {}

    for src, dst in existing:
        src_hash = _sha256_file(src)
        source_hashes[src] = src_hash

        if dst in dest_expected_hashes and dest_expected_hashes[dst] != src_hash:
            raise RuntimeError(
                f"Conflicting legacy files for '{dst}'; originals were preserved."
            )
        dest_expected_hashes[dst] = src_hash

        if dst.exists() or dst.is_symlink():
            if not dst.is_file() or _sha256_file(dst) != src_hash:
                raise RuntimeError(
                    f"Local-state destination conflicts: '{dst}'; originals were preserved."
                )

    # 2. Copy and verify destination integrity
    for src, dst in existing:
        if not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
        if _sha256_file(dst) != source_hashes[src]:
            raise RuntimeError(
                f"Verification failed for '{dst}'; originals were preserved."
            )

    # 3. Verify sources stayed unchanged before removing originals
    for src, _dst in existing:
        if _sha256_file(src) != source_hashes[src]:
            raise RuntimeError(
                f"Legacy file changed during migration: '{src}'; originals were preserved."
            )

    for src, dst in existing:
        if _sha256_file(src) != source_hashes[src]:
            raise RuntimeError(
                f"Legacy file changed before cleanup: '{src}'; remaining originals were preserved."
            )
        src.unlink()
        msg = f"Migrated '{src}' to '{dst}'."
        print(msg)
        messages.append(msg)

    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect or migrate PSS local state paths.")
    parser.add_argument("--checkout", required=True, help="PSS repository checkout path")
    parser.add_argument("--state-home", help="Override PSS state directory")
    parser.add_argument("--home-dir", help="Override HOME directory")
    parser.add_argument("--migrate", action="store_true", help="Run legacy local-state migration")
    parser.add_argument("--what-if", action="store_true", help="Preview migration without changing files")
    parser.add_argument("--json", action="store_true", help="Output state paths as JSON")
    args = parser.parse_args()

    paths = get_local_state_paths(
        args.checkout, state_home=args.state_home, home_dir=args.home_dir
    )
    if args.migrate:
        migrate_legacy_local_state(
            paths, args.checkout, home_dir=args.home_dir, what_if=args.what_if
        )
    if args.json:
        print(json.dumps({k: str(v) for k, v in paths.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
