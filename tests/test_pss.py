#!/usr/bin/env python3
"""Comprehensive test suite for personal-settings-sync (Python CLIs, sync engine, and shell modules)."""

from __future__ import annotations

import base64
import http.server
import importlib.util
import json
import os
import py_compile
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
BIN_DIR = REPO_ROOT / "configs" / "bin"
WORK_BIN_DIR = REPO_ROOT / "workspaces" / "work" / "bin"

sys.path.insert(0, str(SCRIPTS_DIR))
sys.path.insert(0, str(BIN_DIR))

import local_state  # noqa: E402
import profile_groups  # noqa: E402


def load_extensionless_module(name: str, path: Path):
    """Load an extensionless Python CLI file as a module for unit testing."""
    spec = importlib.util.spec_from_loader(
        name,
        importlib.machinery.SourceFileLoader(name, str(path)),
    )
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_bash() -> str | None:
    """Locate GNU Bash 5 executable (preferring Git Bash on Windows over WSL shim)."""
    if os.name == "nt":
        for candidate in (
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ):
            if Path(candidate).is_file():
                return candidate
    found = shutil.which("bash")
    if found and os.name == "nt" and "system32" in found.lower():
        return None
    return found


def make_jwt(payload: dict, header: dict | None = None) -> str:
    """Create a base64url-encoded JWT token without signature verification."""
    hdr = header or {"alg": "HS256", "typ": "JWT"}

    def _enc(obj: dict) -> str:
        raw = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    return f"{_enc(hdr)}.{_enc(payload)}.fakesig"


def init_git_repo(repo_dir: Path, initial_branch: str = "main", with_commit: bool = True) -> None:
    """Create an isolated sandbox git repository independent of host ~/.gitconfig."""
    repo_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-b", initial_branch, str(repo_dir)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo_dir), "config", "user.name", "Test User"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo_dir), "config", "user.email", "test@example.com"], check=True, capture_output=True)
    # Prevent host ~/.gitconfig core.hooksPath from running global hooks in temp test repos
    subprocess.run(["git", "-C", str(repo_dir), "config", "core.hooksPath", ".git/hooks"], check=True, capture_output=True)
    if with_commit:
        readme = repo_dir / "README.md"
        readme.write_text("# Sandbox\n", encoding="utf-8", newline="\n")
        subprocess.run(["git", "-C", str(repo_dir), "add", "README.md"], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(repo_dir), "commit", "-m", "chore: initial commit"],
            check=True,
            capture_output=True,
        )


def run_cli(script_path: Path, args: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None, stdin_text: str | None = None) -> subprocess.CompletedProcess[str]:
    """Run a Python CLI script using the active interpreter."""
    merged_env = os.environ.copy()
    merged_env["NO_COLOR"] = "1"
    if env:
        merged_env.update(env)
    kwargs: dict = {
        "cwd": str(cwd) if cwd else None,
        "env": merged_env,
        "capture_output": True,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
    }
    if stdin_text is None:
        kwargs["stdin"] = subprocess.DEVNULL
    else:
        kwargs["input"] = stdin_text
    return subprocess.run([sys.executable, str(script_path), *args], **kwargs)


class TestSyntaxAndMetadata(unittest.TestCase):
    def test_python_files_compile(self) -> None:
        targets = [
            REPO_ROOT / "pss",
            SCRIPTS_DIR / "local_state.py",
            SCRIPTS_DIR / "profile_groups.py",
            BIN_DIR / "_pss_common.py",
            BIN_DIR / "st",
            BIN_DIR / "unpushed",
            BIN_DIR / "git-pss-diff",
            BIN_DIR / "cmp",
            BIN_DIR / "jwt",
            BIN_DIR / "decide",
            BIN_DIR / "ask-helper",
            WORK_BIN_DIR / "workset",
            REPO_ROOT / "configs" / "git" / "hooks" / "validate_commit_msg.py",
            REPO_ROOT / "configs" / "skills" / "visualize" / "scripts" / "prepare-d2-svg.py",
            Path(__file__).resolve(),
        ]
        for path in targets:
            self.assertTrue(path.is_file(), f"Missing Python file: {path}")
            py_compile.compile(str(path), doraise=True)

    def test_shell_scripts_bash_syntax(self) -> None:
        bash = find_bash()
        self.assertIsNotNone(bash, "GNU Bash (Git Bash on Windows) is required to syntax-check shell files.")
        shell_files = [
            REPO_ROOT / "bootstrap.sh",
            REPO_ROOT / "setup.sh",
            SCRIPTS_DIR / "setup-linux.sh",
            REPO_ROOT / "configs" / "git" / "hooks" / "commit-msg",
            *sorted((REPO_ROOT / "configs" / "zsh").glob("*.zsh")),
            REPO_ROOT / "workspaces" / "personal" / "zsh" / "profile.zsh",
            REPO_ROOT / "workspaces" / "work" / "zsh" / "profile.zsh",
            REPO_ROOT / "workspaces" / "work" / "zsh" / "worksets.zsh",
        ]
        for sf in shell_files:
            self.assertTrue(sf.is_file(), f"Missing shell file: {sf}")
            res = subprocess.run([bash, "-n", str(sf)], capture_output=True, text=True, encoding="utf-8", errors="replace")
            self.assertEqual(res.returncode, 0, f"bash -n failed for {sf}:\n{res.stderr}")

    def test_all_public_shell_functions_have_cmd_headers(self) -> None:
        zsh_files = [
            *sorted((REPO_ROOT / "configs" / "zsh").glob("*.zsh")),
            REPO_ROOT / "workspaces" / "personal" / "zsh" / "profile.zsh",
            REPO_ROOT / "workspaces" / "work" / "zsh" / "profile.zsh",
            REPO_ROOT / "workspaces" / "work" / "zsh" / "worksets.zsh",
        ]
        func_re = re.compile(r"^([a-zA-Z0-9_.]+)\s*\(\)\s*\{")
        cmd_re = re.compile(r"^#\s*@cmd:\s*(\S+)\s+[—-]+\s+(.+)$")

        for zf in zsh_files:
            lines = zf.read_text(encoding="utf-8", errors="replace").splitlines()
            discovered_names = {c["name"] for c in profile_groups.extract_group_commands(zf)}
            for idx, line in enumerate(lines):
                m = func_re.match(line.strip())
                if not m:
                    continue
                fname = m.group(1)
                if fname.startswith("_"):
                    continue
                prev = lines[idx - 1].strip() if idx > 0 else ""
                cm = cmd_re.match(prev)
                self.assertIsNotNone(cm, f"Public function '{fname}' in {zf.name}:{idx+1} missing '# @cmd: {fname} — ...' header (prev='{prev}')")
                assert cm is not None
                self.assertEqual(cm.group(1), fname)
                self.assertIn(fname, discovered_names, f"profile_groups failed to extract '{fname}' from {zf.name}")


class TestLocalStateAndProfileGroups(unittest.TestCase):
    def test_state_paths_and_migration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checkout = root / "repo"
            checkout.mkdir()
            state_home = root / "state" / "pss"
            (checkout / ".workspace.local").write_text("work\n", encoding="utf-8")
            (root / ".project-roots").write_text(f"{root / 'projects'}\n", encoding="utf-8")

            paths = local_state.get_local_state_paths(checkout, state_home=state_home, home_dir=root)
            self.assertEqual(paths["root"], state_home)

            preview = local_state.migrate_legacy_local_state(paths, checkout, home_dir=root, what_if=True)
            self.assertGreaterEqual(len(preview), 2)
            self.assertFalse(paths["workspace"].exists())

            migrated = local_state.migrate_legacy_local_state(paths, checkout, home_dir=root, what_if=False)
            self.assertEqual(paths["workspace"].read_text(encoding="utf-8").strip(), "work")
            self.assertFalse((checkout / ".workspace.local").exists())
            self.assertFalse((root / ".project-roots").exists())
            self.assertTrue(any("project-roots" in m or "workspace" in m for m in migrated))

            # Conflict safety: legacy file differs from already-migrated destination -> raise & preserve both
            (checkout / ".workspace.local").write_text("personal\n", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                local_state.migrate_legacy_local_state(paths, checkout, home_dir=root, what_if=False)
            self.assertEqual(paths["workspace"].read_text(encoding="utf-8").strip(), "work")
            self.assertEqual((checkout / ".workspace.local").read_text(encoding="utf-8").strip(), "personal")

    def test_profile_groups_personal_vs_work(self) -> None:
        personal_groups = profile_groups.get_profile_groups(REPO_ROOT, "personal")
        work_groups = profile_groups.get_profile_groups(REPO_ROOT, "work")
        self.assertEqual([g["name"] for g in personal_groups], ["shared", "git", "navigation", "search", "ai", "personal"])
        self.assertEqual([g["name"] for g in work_groups], ["shared", "git", "navigation", "search", "ai", "worksets", "work"])

        res = run_cli(
            SCRIPTS_DIR / "profile_groups.py",
            ["--root", str(REPO_ROOT), "--workspace", "work", "--project-roots", "~/.local/state/pss/project-roots", "--profile-help"],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("[git]", res.stdout)
        self.assertIn("[worksets]", res.stdout)
        self.assertIn("unpushed", res.stdout)


class TestPssCli(unittest.TestCase):
    def _create_sandbox_checkout(self, root: Path) -> Path:
        sandbox_repo = root / "pss-repo"
        sandbox_repo.mkdir()
        shutil.copy2(REPO_ROOT / "pss", sandbox_repo / "pss")
        shutil.copy2(REPO_ROOT / "sync.config.json", sandbox_repo / "sync.config.json")
        shutil.copytree(REPO_ROOT / "scripts", sandbox_repo / "scripts")
        shutil.copytree(REPO_ROOT / "configs", sandbox_repo / "configs")
        shutil.copytree(REPO_ROOT / "workspaces", sandbox_repo / "workspaces")
        return sandbox_repo

    def test_workspace_status_apply_diff_and_backups(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sandbox_repo = self._create_sandbox_checkout(tmp_path)
            home_dir = tmp_path / "home"
            home_dir.mkdir()
            state_home = home_dir / ".local" / "state" / "pss"

            env = {
                "HOME": str(home_dir),
                "USERPROFILE": str(home_dir),
                "XDG_CONFIG_HOME": str(home_dir / ".config"),
                "XDG_STATE_HOME": str(home_dir / ".local" / "state"),
                "PSS_STATE_HOME": str(state_home),
            }

            # Select personal workspace without applying yet
            res_ws = run_cli(sandbox_repo / "pss", ["workspace", "use", "personal", "--no-apply"], env=env)
            self.assertEqual(res_ws.returncode, 0, res_ws.stdout + res_ws.stderr)
            expected_ws_file = local_state.get_local_state_paths(sandbox_repo, state_home=state_home, home_dir=home_dir)["workspace"]
            self.assertEqual(expected_ws_file.read_text(encoding="utf-8").strip(), "personal")

            # Seed an existing ~/.zshrc and ~/.config/starship.toml to verify backup behavior
            (home_dir / ".zshrc").write_text("# unmanaged user zshrc\n", encoding="utf-8")
            (home_dir / ".config").mkdir(parents=True)
            (home_dir / ".config" / "starship.toml").write_text("# old starship\n", encoding="utf-8")

            # Status before apply should show Unmanaged/File/Missing
            res_st1 = run_cli(sandbox_repo / "pss", ["status", "--include", "zsh,starship,git,gemini"], env=env)
            self.assertEqual(res_st1.returncode, 0, res_st1.stderr)
            self.assertIn("Unmanaged Local File", res_st1.stdout)

            # Diff should catch Starship mismatch too
            res_diff1 = run_cli(sandbox_repo / "pss", ["diff", "--include", "zsh,starship"], env=env)
            self.assertEqual(res_diff1.returncode, 0, res_diff1.stderr)
            self.assertIn("Starship Prompt", res_diff1.stdout)
            self.assertIn("Zsh Profile", res_diff1.stdout)

            # Apply all subsystems in sandbox
            res_apply = run_cli(sandbox_repo / "pss", ["apply", "--force", "--yes"], env=env)
            self.assertEqual(res_apply.returncode, 0, res_apply.stdout + res_apply.stderr)

            # Verify backup created for overwritten files
            backups_root = sandbox_repo / ".backups"
            self.assertTrue(backups_root.is_dir())
            snapshots = sorted(p for p in backups_root.iterdir() if p.is_dir())
            self.assertGreaterEqual(len(snapshots), 1)
            self.assertTrue((snapshots[-1] / "zsh" / ".zshrc").is_file())
            self.assertTrue((snapshots[-1] / "starship" / "starship.toml").is_file())

            # Verify .zshrc loader + .gitconfig includes + starship link
            zshrc_txt = (home_dir / ".zshrc").read_text(encoding="utf-8")
            self.assertIn("Managed by personal-settings-sync (pss)", zshrc_txt)
            self.assertIn("configs/zsh/init.zsh", zshrc_txt)
            gitconfig_txt = (home_dir / ".gitconfig").read_text(encoding="utf-8")
            self.assertIn("configs/git/.gitconfig.shared", gitconfig_txt)
            self.assertIn("workspaces/personal/git/.gitconfig", gitconfig_txt)

            # Diff on zsh+starship+git should now show 0 differences
            res_diff2 = run_cli(sandbox_repo / "pss", ["diff", "--include", "zsh,starship,git"], env=env)
            self.assertEqual(res_diff2.returncode, 0, res_diff2.stderr)
            self.assertIn("All inspected configurations are in sync", res_diff2.stdout)

            # Switch to work workspace and apply
            res_work = run_cli(sandbox_repo / "pss", ["workspace", "use", "work"], env=env)
            self.assertEqual(res_work.returncode, 0, res_work.stdout + res_work.stderr)
            gitconfig_work = (home_dir / ".gitconfig").read_text(encoding="utf-8")
            self.assertIn("workspaces/work/git/.gitconfig", gitconfig_work)


class TestGitHelpers(unittest.TestCase):
    def test_st_unpushed_and_diff_across_repos(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            remote = tmp_path / "remote.git"
            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)

            repo_ahead = tmp_path / "projects" / "repo-ahead"
            init_git_repo(repo_ahead, "main")
            subprocess.run(["git", "-C", str(repo_ahead), "remote", "add", "origin", str(remote)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo_ahead), "push", "-u", "origin", "main"], check=True, capture_output=True)

            # Create feature branch and make ahead commit + dirty files
            subprocess.run(["git", "-C", str(repo_ahead), "switch", "-c", "feat/demo"], check=True, capture_output=True)
            (repo_ahead / "app.txt").write_text("v1\n", encoding="utf-8", newline="\n")
            subprocess.run(["git", "-C", str(repo_ahead), "add", "app.txt"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo_ahead), "commit", "-m", "feat: add app"], check=True, capture_output=True)
            (repo_ahead / "untracked.txt").write_text("u\n", encoding="utf-8")

            # Clean synced repo
            repo_clean = tmp_path / "projects" / "repo-clean"
            init_git_repo(repo_clean, "main")
            subprocess.run(["git", "-C", str(repo_clean), "remote", "add", "origin", str(remote)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo_clean), "push", "-u", "origin", "main:refs/heads/clean-main"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo_clean), "branch", "--set-upstream-to=origin/clean-main"], check=True, capture_output=True)

            # st tests
            res_st = run_cli(BIN_DIR / "st", ["-n"], cwd=repo_ahead)
            self.assertEqual(res_st.returncode, 0, res_st.stderr)
            self.assertIn("feat/demo", res_st.stdout)
            self.assertIn("1 untracked", res_st.stdout)
            self.assertIn("Base branch: not compared", res_st.stdout)

            res_st_cmp = run_cli(BIN_DIR / "st", ["main", "-Files", "-NoFetch"], cwd=repo_ahead)
            self.assertEqual(res_st_cmp.returncode, 0, res_st_cmp.stderr)
            self.assertIn("Commits ahead: 1", res_st_cmp.stdout)
            self.assertIn("app.txt", res_st_cmp.stdout)

            # unpushed tests using PSS_PROJECT_ROOTS
            roots_file = tmp_path / "project-roots"
            roots_file.write_text(f"{tmp_path / 'projects'}\n", encoding="utf-8", newline="\n")
            env = {"PSS_PROJECT_ROOTS": str(roots_file)}

            res_unp = run_cli(BIN_DIR / "unpushed", ["--commits", "--files"], env=env)
            self.assertEqual(res_unp.returncode, 0, res_unp.stderr)
            self.assertIn("repo-ahead", res_unp.stdout)
            self.assertNotIn("repo-clean", res_unp.stdout)
            self.assertIn("1 ahead", res_unp.stdout)
            self.assertIn("untracked.txt", res_unp.stdout)

            res_unp_all = run_cli(BIN_DIR / "unpushed", ["--all"], env=env)
            self.assertEqual(res_unp_all.returncode, 0, res_unp_all.stderr)
            self.assertIn("repo-clean", res_unp_all.stdout)

            # git-pss-diff tests
            res_outside = run_cli(BIN_DIR / "git-pss-diff", [], cwd=tmp_path)
            self.assertNotEqual(res_outside.returncode, 0)
            self.assertIn("Use 'cmp <file1> <file2>'", res_outside.stderr)

            (repo_ahead / "README.md").write_text("# Changed\n", encoding="utf-8", newline="\n")
            (repo_ahead / "staged.txt").write_text("s\n", encoding="utf-8", newline="\n")
            subprocess.run(["git", "-C", str(repo_ahead), "add", "staged.txt"], check=True, capture_output=True)

            res_diff_u = run_cli(BIN_DIR / "git-pss-diff", [], cwd=repo_ahead)
            self.assertEqual(res_diff_u.returncode, 0, res_diff_u.stderr)
            self.assertIn("1 staged", res_diff_u.stdout)
            self.assertIn("# Changed", res_diff_u.stdout)

            res_diff_pr = run_cli(BIN_DIR / "git-pss-diff", ["pr", "main", "--stat"], cwd=repo_ahead)
            self.assertEqual(res_diff_pr.returncode, 0, res_diff_pr.stderr)
            self.assertIn("GitHub PR preview -> origin/main", res_diff_pr.stdout)
            self.assertIn("Commits included (1):", res_diff_pr.stdout)


class TestClipboardJwtAndDecide(unittest.TestCase):
    def test_cmp_files_and_clipboard(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            f1 = p / "a.txt"
            f2 = p / "b.txt"
            f_crlf = p / "crlf.txt"
            clip = p / "clipboard.txt"

            f1.write_text("line1\nline2\n", encoding="utf-8", newline="\n")
            f2.write_text("line1\nline2\n", encoding="utf-8", newline="\n")
            f_crlf.write_bytes(b"line1\r\nline2\r\n")
            clip.write_text("line1\nchanged\n", encoding="utf-8", newline="\n")

            env = {"PSS_CLIPBOARD_FILE": str(clip)}

            self.assertEqual(run_cli(BIN_DIR / "cmp", [str(f1), str(f2)], env=env).returncode, 0)

            res_crlf = run_cli(BIN_DIR / "cmp", [str(f1), str(f_crlf)], env=env)
            self.assertEqual(res_crlf.returncode, 1)
            self.assertIn("CRLF vs LF mismatch", res_crlf.stdout)

            res_ws = run_cli(BIN_DIR / "cmp", [str(f1), str(f_crlf), "-IgnoreWhitespace"], env=env)
            self.assertEqual(res_ws.returncode, 0)

            res_clip = run_cli(BIN_DIR / "cmp", [str(f1)], env=env)
            self.assertEqual(res_clip.returncode, 1)
            self.assertIn("Difference", res_clip.stdout)

    def test_jwt_arg_stdin_and_clipboard(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / "clip.txt"
            env = {"PSS_CLIPBOARD_FILE": str(clip)}

            valid_tok = make_jwt({"sub": "123", "exp": int(time.time()) + 3600})
            expired_tok = make_jwt({"sub": "999", "exp": 1000000})

            r1 = run_cli(BIN_DIR / "jwt", [f"Bearer {valid_tok}"], env=env)
            self.assertEqual(r1.returncode, 0, r1.stderr)
            self.assertIn('"sub": "123"', r1.stdout)
            self.assertIn("[VALID]", r1.stdout)

            r2 = run_cli(BIN_DIR / "jwt", [], env=env, stdin_text=expired_tok)
            self.assertEqual(r2.returncode, 0, r2.stderr)
            self.assertIn("[EXPIRED]", r2.stdout)

            clip.write_text(valid_tok, encoding="utf-8")
            r3 = run_cli(BIN_DIR / "jwt", [], env=env)
            self.assertEqual(r3.returncode, 0, r3.stderr)
            self.assertIn("[VALID]", r3.stdout)

    def test_decide_requires_key_and_renders_mock_verdict(self) -> None:
        env_nokey = {"GEMINI_API_KEY": ""}
        r_fail = run_cli(BIN_DIR / "decide", ["Should we deploy?"], env=env_nokey)
        self.assertNotEqual(r_fail.returncode, 0)
        self.assertIn("GEMINI_API_KEY", r_fail.stderr)

        captured_requests: list[dict] = []

        class _Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args):  # noqa: A002
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length).decode("utf-8"))
                captured_requests.append(body)
                payload = {
                    "answers": {
                        "verdict": {
                            "choice": "fast",
                            "confidence": 0.86,
                            "probabilities": {"fast": 0.86, "safe": 0.10, "cheap": 0.04},
                        }
                    }
                }
                raw = json.dumps(payload).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        server = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = {
                "GEMINI_API_KEY": "test-key",
                "PSS_DECIDE_ENDPOINT": f"http://127.0.0.1:{port}/v1beta/decisions",
            }
            res = run_cli(
                BIN_DIR / "decide",
                ["--choices", "fast,safe,cheap", "Which option wins?"],
                env=env,
                stdin_text="Latency matters most",
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("[FAST]", res.stdout)
            self.assertIn("86%", res.stdout)
            self.assertIn("fast 86%", res.stdout)
            self.assertEqual(len(captured_requests), 1)
            self.assertEqual(captured_requests[0]["model"], "gemini-decision-1")
            self.assertIn("Latency matters most", captured_requests[0]["input"])
        finally:
            server.shutdown()
            server.server_close()


class TestAskHelper(unittest.TestCase):
    def test_terminal_blocks_slices_out_and_streaming_cleanup(self) -> None:
        ask_mod = load_extensionless_module("ask_helper_mod", BIN_DIR / "ask-helper")

        lines = [
            "top scrolled output line",
            "~/repo \ue0b0 \u276f ls",
            "a.txt",
            "b.txt",
            "",
            "~/repo  main  \u276f pytest",
            "2 passed",
            "~/repo \u276f ",
        ]
        blocks = ask_mod.convert_to_terminal_blocks(lines)
        self.assertEqual(len(blocks), 2)
        self.assertEqual(blocks[0]["command"], "ls")
        self.assertEqual(blocks[0]["output"], ["a.txt", "b.txt"])
        self.assertEqual(blocks[1]["command"], "pytest")
        self.assertEqual(blocks[1]["output"], ["2 passed"])

        # Fallback command recovers leading output when only trailing active prompt visible
        scroll_blocks = ask_mod.convert_to_terminal_blocks(
            ["scrolled line 1", "", "~/repo \u276f "],
            fallback_command="git status",
        )
        self.assertEqual(scroll_blocks, [{"command": "git status", "output": ["scrolled line 1"]}])

        self.assertEqual(ask_mod.resolve_block_indices("~2", 4), [2])
        self.assertEqual(ask_mod.resolve_block_indices("2", 4), [2, 3])
        self.assertEqual(ask_mod.resolve_block_indices("~3..2", 4), [1, 2])
        self.assertEqual(ask_mod.resolve_block_indices("~3..~1", 4), [1, 2, 3])

        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            buf = tpath / "screen.txt"
            buf.write_text("\n".join(lines) + "\n", encoding="utf-8")
            env = {"PSS_TEST_TERMINAL_BUFFER": str(buf)}

            res_out = run_cli(BIN_DIR / "ask-helper", ["out", "~2", "-c"], env=env)
            self.assertEqual(res_out.returncode, 0, res_out.stderr)
            self.assertEqual(res_out.stdout.splitlines(), ["$ ls", "a.txt", "b.txt"])

            res_prompt = run_cli(BIN_DIR / "ask-helper", ["build-prompt", "--ctx", "2", "why?"], env=env)
            self.assertEqual(res_prompt.returncode, 0, res_prompt.stderr)
            self.assertIn('[Context: Terminal Commands & Output ("2")]', res_prompt.stdout)
            self.assertIn("$ ls", res_prompt.stdout)
            self.assertIn("$ pytest", res_prompt.stdout)

            # Test streaming runner + ephemeral agy cleanup
            cli_dir = tpath / "agy-cli"
            conv_dir = cli_dir / "conversations"
            brain_dir = cli_dir / "brain"
            conv_dir.mkdir(parents=True)
            brain_dir.mkdir(parents=True)
            db_sum = cli_dir / "conversation_summaries.db"
            con = sqlite3.connect(str(db_sum))
            con.execute("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY)")
            con.execute("INSERT INTO conversation_summaries VALUES ('conv-ephem')")
            con.commit()
            con.close()

            mock_agy = tpath / "mock_agy.py"
            mock_agy.write_text(
                "\n".join(
                    [
                        "import json, sys",
                        "from pathlib import Path",
                        f"conv_dir = Path({repr(str(conv_dir))})",
                        f"brain_dir = Path({repr(str(brain_dir))})",
                        "(conv_dir / 'conv-ephem.db').write_text('x', encoding='utf-8')",
                        "(brain_dir / 'conv-ephem').mkdir(exist_ok=True)",
                        "events = [",
                        "  {'event': 'step_update', 'conversation_id': 'conv-ephem', 'step_update': {'step_type': 'agent_response', 'step_index': 0, 'text_delta': 'Hello '}},",
                        "  {'event': 'step_update', 'step_update': {'step_type': 'agent_response', 'step_index': 1, 'text_delta': 'World'}},",
                        "  {'event': 'step_update', 'step_update': {'step_type': 'error_message'}},",
                        "  {'event': 'result', 'result': {'status': 'SUCCESS', 'conversation_id': 'conv-ephem'}},",
                        "]",
                        "for e in events:",
                        "  print(json.dumps(e), flush=True)",
                    ]
                ),
                encoding="utf-8",
            )
            launcher = tpath / ("mock_agy.cmd" if os.name == "nt" else "mock_agy.sh")
            if os.name == "nt":
                launcher.write_text(f'@echo off\r\n"{sys.executable}" "{mock_agy}" %*\r\n', encoding="utf-8")
            else:
                launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{mock_agy}" "$@"\n', encoding="utf-8")
                launcher.chmod(0o755)

            run_env = {**env, "PSS_AGY_CLI_DIR": str(cli_dir)}
            res_run = run_cli(
                BIN_DIR / "ask-helper",
                ["run", "--engine", "agy", "--executable", str(launcher), "say", "hi"],
                env=run_env,
            )
            self.assertEqual(res_run.returncode, 0, res_run.stderr)
            self.assertEqual(res_run.stdout.strip().splitlines(), ["Hello ", "World"])
            self.assertIn("▸ ask (gemini-4-hydrogen-low)", res_run.stderr)
            self.assertIn("[agy step interrupted — retrying]", res_run.stderr)
            # Ephemeral state must be cleaned up
            self.assertFalse((conv_dir / "conv-ephem.db").exists())
            self.assertFalse((brain_dir / "conv-ephem").exists())
            con_check = sqlite3.connect(str(db_sum))
            rows = con_check.execute("SELECT conversation_id FROM conversation_summaries").fetchall()
            con_check.close()
            self.assertEqual(rows, [])


class TestWorkset(unittest.TestCase):
    def test_workset_lifecycle_and_safety(self) -> None:
        ws_mod = load_extensionless_module("workset_mod", WORK_BIN_DIR / "workset")

        self.assertEqual(ws_mod.convert_to_workset_name("Feat / Ticket-42 "), "feat-ticket-42")
        with self.assertRaises(ValueError):
            ws_mod.convert_to_workset_name("CON")
        with self.assertRaises(ValueError):
            ws_mod.convert_to_workset_name("x" * 101)

        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            ws_root = tpath / "worksets-store"
            repo = tpath / "service-repo"
            init_git_repo(repo, "feat/ticket-99")
            target_file = repo / "src.txt"
            target_file.write_text("code\n", encoding="utf-8")

            env = {"PSS_WORKSETS_ROOT": str(ws_root)}

            r_new = run_cli(WORK_BIN_DIR / "workset", ["new"], cwd=repo, env=env)
            self.assertEqual(r_new.returncode, 0, r_new.stderr)
            self.assertIn("feat-ticket-99", r_new.stdout)

            r_add = run_cli(WORK_BIN_DIR / "workset", ["add", "-Files", str(target_file)], cwd=repo, env=env)
            self.assertEqual(r_add.returncode, 0, r_add.stderr)

            r_cur = run_cli(
                WORK_BIN_DIR / "workset",
                ["--current-name", "--root", str(repo.resolve()), "--branch", "feat/ticket-99"],
                env=env,
            )
            self.assertEqual(r_cur.stdout.strip(), "feat-ticket-99")

            # Switch branch and verify 'open --what-if --code' warns without mutating current branch
            subprocess.run(["git", "-C", str(repo), "switch", "-c", "other-branch"], check=True, capture_output=True)
            r_open = run_cli(
                WORK_BIN_DIR / "workset",
                ["open", "feat-ticket-99", "--code", "--what-if"],
                cwd=repo,
                env=env,
            )
            self.assertEqual(r_open.returncode, 0, r_open.stderr)
            self.assertIn("Branch mismatch", r_open.stderr)
            self.assertIn("WHAT-IF: Open workset 'feat-ticket-99' in VS Code", r_open.stdout)

            # Confirm branch did NOT change
            cur_branch = subprocess.run(["git", "-C", str(repo), "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
            self.assertEqual(cur_branch, "other-branch")

            self.assertEqual(run_cli(WORK_BIN_DIR / "workset", ["archive", "feat-ticket-99"], env=env).returncode, 0)
            self.assertIn("feat-ticket-99", run_cli(WORK_BIN_DIR / "workset", ["list", "--archived"], env=env).stdout)
            self.assertEqual(run_cli(WORK_BIN_DIR / "workset", ["restore", "feat-ticket-99"], env=env).returncode, 0)
            self.assertIn("feat-ticket-99", run_cli(WORK_BIN_DIR / "workset", ["list"], env=env).stdout)
            self.assertEqual(run_cli(WORK_BIN_DIR / "workset", ["delete", "feat-ticket-99"], env=env).returncode, 0)

    def test_workset_multirepo_badge_rm_relative_and_split(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            ws_root = tpath / "worksets-store"
            backend = tpath / "backend-repo"
            frontend = tpath / "frontend-repo"
            init_git_repo(backend, "feat/ticket-101")
            init_git_repo(frontend, "feat/ui-101")

            (backend / "App.sln").write_text("", encoding="utf-8")
            cs_file = backend / "Program.cs"
            cs_file.write_text("class Program {}\n", encoding="utf-8")
            ts_file = frontend / "index.ts"
            ts_file.write_text("export const x = 1;\n", encoding="utf-8")

            env = {"PSS_WORKSETS_ROOT": str(ws_root)}

            self.assertEqual(run_cli(WORK_BIN_DIR / "workset", ["new"], cwd=backend, env=env).returncode, 0)
            self.assertEqual(run_cli(WORK_BIN_DIR / "workset", ["add", str(cs_file), str(ts_file)], cwd=backend, env=env).returncode, 0)

            # Repo-relative paths stored in files.txt
            files_txt = (ws_root / "active" / "feat-ticket-101" / "files.txt").read_text(encoding="utf-8")
            self.assertIn("backend-repo/Program.cs", files_txt)
            self.assertIn("frontend-repo/index.ts", files_txt)

            # Multi-repo badge tracking works from secondary frontend repo too
            r_badge_be = run_cli(
                WORK_BIN_DIR / "workset",
                ["--prompt-badge", "--root", str(backend.resolve()), "--branch", "feat/ticket-101"],
                env=env,
            )
            self.assertEqual(r_badge_be.stdout.strip(), "✦2")

            r_badge_fe = run_cli(
                WORK_BIN_DIR / "workset",
                ["--prompt-badge", "--root", str(frontend.resolve()), "--branch", "feat/ui-101"],
                env=env,
            )
            self.assertEqual(r_badge_fe.stdout.strip(), "feat-ticket-101 ✦2")

            # Hybrid split open --what-if (on Linux without devenv, falls back cleanly to VS Code; with --code opens all in VS Code)
            r_split = run_cli(WORK_BIN_DIR / "workset", ["open", "feat-ticket-101", "--what-if"], env=env)
            self.assertEqual(r_split.returncode, 0, r_split.stderr)
            self.assertIn("WHAT-IF: Open workset 'feat-ticket-101'", r_split.stdout)

            # Remove one file via workset rm
            r_rm = run_cli(WORK_BIN_DIR / "workset", ["rm", "feat-ticket-101", str(ts_file)], env=env)
            self.assertEqual(r_rm.returncode, 0, r_rm.stderr)
            r_badge_after = run_cli(
                WORK_BIN_DIR / "workset",
                ["--prompt-badge", "--root", str(backend.resolve()), "--branch", "feat/ticket-101"],
                env=env,
            )
            self.assertEqual(r_badge_after.stdout.strip(), "✦1")

    def test_clipboard_shared_transforms(self) -> None:
        common = load_extensionless_module("pss_common_mod", BIN_DIR / "_pss_common.py")
        raw = "  \033[36mhello\033[0m\nworld  \n"
        self.assertEqual(
            common.transform_clipboard_text(raw, trim=True, single_line=True, strip_ansi=True),
            "hello world",
        )


class TestZshFunctionsViaBash(unittest.TestCase):
    def _run_bash_snippet(self, body: str, *, env: dict[str, str] | None = None, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        bash = find_bash()
        self.assertIsNotNone(bash)
        init_posix = REPO_ROOT.as_posix() + "/configs/zsh/init.zsh"
        if os.name == "nt":
            # Convert drive path C:/... to /c/... cleanly inside Git Bash via cygpath if needed
            preamble = f'PSS_INIT_FILE="$(cygpath -u "{init_posix}")"\nsource "$PSS_INIT_FILE"\n'
        else:
            preamble = f'source "{init_posix}"\n'

        full_script = preamble + body
        merged_env = os.environ.copy()
        merged_env["NO_COLOR"] = "1"
        merged_env["PSS_PYTHON"] = sys.executable
        if env:
            merged_env.update(env)

        with tempfile.TemporaryDirectory() as tmp:
            script_file = Path(tmp) / "test_snippet.sh"
            script_file.write_text(full_script, encoding="utf-8", newline="\n")
            return subprocess.run(
                [bash, str(script_file)],
                cwd=str(cwd) if cwd else str(REPO_ROOT),
                env=merged_env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )

    def test_shell_functions_end_to_end(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tpath = Path(tmp)
            state_home = tpath / "state" / "pss"
            state_home.mkdir(parents=True)
            (state_home / "workspace").write_text("personal\n", encoding="utf-8")

            roots_file = state_home / "project-roots"
            proj_parent = tpath / "projects"
            proj_alpha = proj_parent / "alpha-app"
            proj_alpha.mkdir(parents=True)
            clip_file = tpath / "clipboard.txt"
            hist_file = tpath / "rerun_history.txt"
            sln_dir = tpath / "dotnet-sol" / "sub"
            sln_dir.mkdir(parents=True)
            (tpath / "dotnet-sol" / "Demo.sln").write_text("", encoding="utf-8")

            env = {
                "PSS_STATE_HOME": str(state_home),
                "PSS_PROJECT_ROOTS": str(roots_file),
                "PSS_WORKSPACE": "personal",
                "PSS_CLIPBOARD_FILE": str(clip_file),
                "PSS_TEST_RERUN_HISTORY_FILE": str(hist_file),
            }

            # 1. Help checks, which, p, mkcd, copy/paste, gdiff, work-workspace vs --what-if
            proj_parent_posix = proj_parent.as_posix()
            tpath_posix = tpath.as_posix()
            sln_sub_posix = sln_dir.as_posix()

            script1 = "\n".join(
                [
                    "set -e",
                    "for fn in commit push gdiff b nb lg wip unwip stashes groot mkcd p open out lastout rerun which venv copy paste ask; do",
                    '  "$fn" -h >/dev/null',
                    "done",
                    "which profile -h",
                    "which commit -h",
                    f'p --add "$(cygpath -u "{proj_parent_posix}" 2>/dev/null || echo "{proj_parent_posix}")"',
                    "p --list",
                    "p alpha",
                    "pwd",
                    "p --remove projects",
                    f'cd "$(cygpath -u "{tpath_posix}" 2>/dev/null || echo "{tpath_posix}")"',
                    "mkcd nested/dir",
                    "pwd",
                    "copy 'hello clipboard'",
                    "paste",
                ]
            )
            r1 = self._run_bash_snippet(script1, env=env)
            self.assertEqual(r1.returncode, 0, f"STDOUT:\n{r1.stdout}\nSTDERR:\n{r1.stderr}")
            self.assertIn("[git]", r1.stdout)
            self.assertIn("Source: commit is a function", r1.stdout)
            self.assertIn("alpha-app", r1.stdout)
            self.assertIn("hello clipboard", r1.stdout)

            work_env = {**env, "PSS_WORKSPACE": "work"}
            r_vs = self._run_bash_snippet(
                f'vs -h >/dev/null && vs "$(cygpath -u "{sln_sub_posix}" 2>/dev/null || echo "{sln_sub_posix}")" --what-if',
                env=work_env,
            )
            self.assertEqual(r_vs.returncode, 0, f"STDOUT:\n{r_vs.stdout}\nSTDERR:\n{r_vs.stderr}")
            self.assertIn('What if: Performing the operation "Open', r_vs.stdout)
            self.assertIn("Demo.sln", r_vs.stdout)

            # 2. Git shell workflow (nb, commit, wip, unwip, b)
            repo = tpath / "git-work"
            init_git_repo(repo, "main")
            script2 = "\n".join(
                [
                    "set -e",
                    "nb feat/shell-test",
                    "echo hi > hello.txt",
                    'commit -a -m "feat: add hello"',
                    "echo tmp > wip.txt",
                    "wip",
                    "unwip",
                    "b main",
                    "git branch --show-current",
                ]
            )
            r2 = self._run_bash_snippet(script2, env=env, cwd=repo)
            self.assertEqual(r2.returncode, 0, f"STDOUT:\n{r2.stdout}\nSTDERR:\n{r2.stderr}")
            self.assertEqual(r2.stdout.strip().splitlines()[-1], "main")

            # 3. rerun filtering + nesting guard
            hist_file.write_text(
                "echo FIRST_CMD\nrerun ~1\necho rerun\n",
                encoding="utf-8",
                newline="\n",
            )
            script3 = "\n".join(
                [
                    "rerun -y ~2..1",
                    "if __PSS_IN_RERUN=1 rerun -y >/dev/null 2>&1; then exit 99; fi",
                ]
            )
            r3 = self._run_bash_snippet(script3, env=env)
            self.assertEqual(r3.returncode, 0, f"STDOUT:\n{r3.stdout}\nSTDERR:\n{r3.stderr}")
            self.assertIn("FIRST_CMD", r3.stdout, f"STDOUT:\n{r3.stdout}\nSTDERR:\n{r3.stderr}")
            self.assertIn("> echo rerun", r3.stdout, f"STDOUT:\n{r3.stdout}\nSTDERR:\n{r3.stderr}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
