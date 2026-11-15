# Personal Settings Sync (`pss`)

Repo-as-source-of-truth dotfile and workstation configuration manager for **EndeavourOS (`personal`)** and **WSL2 (`work`)**.

All managed configuration lives in this repository and is symlinked or included into your machine using `./pss`. Local state (active workspace, project roots, local shell overrides, worksets, and backups) lives outside Git in XDG state storage (`~/.local/state/pss/`).

---

## Quick Start (Fresh Linux / WSL2 Machine)

```sh
git clone https://github.com/kamilsuhak/personal-settings-sync.git ~/Coding/Projects/personal-settings-sync
cd ~/Coding/Projects/personal-settings-sync
./bootstrap.sh
```

Or select a workspace non-interactively and apply immediately:

```sh
./pss workspace use personal   # or: work
./pss setup
```

---

## Architecture & Synced Subsystems

Driven declaratively by `sync.config.json`:

1. **Zsh & Prompt (`zsh`, `starship`)**
   - `~/.zshrc` contains a two-line managed loader sourcing `configs/zsh/init.zsh`.
   - `~/.config/starship.toml` symlinks to `configs/starship/starship.toml`.
   - Plain Zsh with `zsh-autosuggestions`, `zsh-syntax-highlighting`, `fzf`, and Starship (no framework bloat).
   - Standalone Python 3 standard-library utilities in `configs/bin/` and `workspaces/work/bin/` handle Git telemetry (`st`, `unpushed`, `git-pss-diff`), diffs (`cmp`), `jwt`, `decide`, terminal context (`ask-helper`), and worksets. See [`SHELL.md`](SHELL.md) for the complete command reference.

2. **Git (`git`)**
   - `~/.gitconfig` keeps `[include]` entries pointing to `configs/git/.gitconfig.shared` and `workspaces/<workspace>/git/.gitconfig`.
   - `~/.git-hooks` symlinks to `configs/git/hooks` (`commit-msg` enforces Conventional Commits without scope parentheses).

3. **AI Rules, Skills & Plugins (`gemini`, `skills`, `plugins`)**
   - Shared + workspace `AGENTS.md` / `GEMINI.md` and `skills.json` synced to `~/.gemini/`.
   - Skills and plugins linked from `configs/skills/` and `configs/plugins/`.

---

## Workspace Separation (`personal` vs. `work`)

- **`personal` (EndeavourOS):** Uses `gemini-4-hydrogen-low`/`high` via Antigravity CLI (`agy`) for `ask`, personal Git identity, and Arch package definitions (`pacman`/`yay`).
- **`work` (WSL2):** Uses GitHub Copilot CLI (`copilot`) for `ask`, Azure CLI identity checks (`azwho`), multi-repo issue `workset` management, optional WSL Git interop (`PSS_WSL_GIT_INTEROP=1`), and Ubuntu/APT package definitions.

---

## Daily CLI Commands

- `pss status` — Table showing sync health across Zsh, Starship, Git, Gemini rules, skills, and plugins.
- `pss apply` (or `pss link`) — Symlinks/updates machine configs to match the active workspace (backs up replaced files).
- `pss diff` — Shows diffs or missing/unmanaged state between local machine and repo.
- `pss edit` — Opens the shared repo config directory/repo in `$EDITOR` / VS Code.
- `pss workspace [list|use <name>]` — Switch between `personal` and `work` profiles.
- `pss apps` / `pss fonts` — Inspect/install configured packages (`pacman`/`apt`) and JetBrainsMono Nerd Font.
- `pss setup` — Runs full initial machine setup (`setup.sh` / `scripts/setup-linux.sh`).

For a full list of shell commands inside an interactive terminal, run `which profile -h` or read [`SHELL.md`](SHELL.md).

---

## Verification

Run the Python test suite (including Bash 5 syntax/behavior checks over `.zsh` modules):

```sh
python3 tests/test_pss.py
```
