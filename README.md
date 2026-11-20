# rig

Repo-as-source-of-truth dotfile, shell, CLI, and AI customization manager for **Arch Linux / EndeavourOS (`personal`)** and **Arch WSL2 (`rbc` / `work`)**.

Driven by `rig.config.json`, `./rig` links Zsh + Starship, Git config/hooks, `configs/bin/` utilities, and `~/.gemini` agent rules/skills/plugins, with local state stored in `~/.local/state/rig/`.

## Setup

```sh
curl -fsSL https://raw.githubusercontent.com/Kamil-Suhak/rig/zsh/bootstrap.sh | sh -s -- --workspace personal
```

Or from a local clone:

```sh
git clone -b zsh https://github.com/Kamil-Suhak/rig.git ~/code/projects/rig
cd ~/code/projects/rig
./bootstrap.sh --workspace personal   # or: --workspace rbc --mode terminal
```

Or directly via `./rig`:

```sh
./rig workspace use personal   # or: rbc / work
./rig setup                    # yay, fonts (full mode), git identity, project roots, zsh
./rig apps install             # auto-detects full vs terminal mode (or pass --mode)
```

## Common Commands

- `rig status` / `rig apply` / `rig diff` — Inspect or sync managed configs
- `rig workspace [list|use <name>]` — Switch active workspace (`personal`, `work`, `rbc`)
- `rig setup [--mode full|terminal]` — Machine setup (AUR `yay`, fonts, Git identity, project roots, Zsh)
- `rig apps [list|install|update] [--mode full|terminal]` — Manage packages via `yay` / `pacman`
- `rig fonts` — Install Nerd Fonts
- `which profile -h` — List all shell commands inside an interactive Zsh session
- `python3 -m unittest discover -s tests` — Run the test suite

Detailed documentation (agents/skills, shell commands, `workset`, packages, and WSL notes) lives in the Obsidian vault under `wiki/Projects/rig/`.
