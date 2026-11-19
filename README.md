# Personal Settings Sync (`rig`)

Repo-as-source-of-truth dotfile, shell, CLI, and AI customization manager for **EndeavourOS (`personal`)** and **WSL2 (`rbc` / `work`)**.

Driven by `sync.config.json`, `./rig` links Zsh + Starship, Git config/hooks, `configs/bin/` utilities, and `~/.gemini` agent rules/skills/plugins, with local state stored in `~/.local/state/rig/`.

## Setup

```sh
git clone -b zsh https://github.com/Kamil-Suhak/rig.git ~/code/projects/rig
cd ~/code/projects/rig
./bootstrap.sh
```

Or non-interactively for a specific workspace:

```sh
./rig workspace use personal   # or: rbc / work
./rig setup
```

## Common Commands

- `rig status` / `rig apply` / `rig diff` — Inspect or sync managed configs
- `rig workspace [list|use <name>]` — Switch active workspace (`personal`, `work`, `rbc`)
- `rig apps` / `rig fonts` — Install configured packages (`pacman`/`apt`) and Nerd Fonts
- `which profile -h` — List all shell commands inside an interactive Zsh session
- `python3 -m unittest discover -s tests` — Run the test suite

Detailed documentation (agents/skills, shell commands, `workset`, packages, and WSL notes) lives in the Obsidian vault under `wiki/Projects/rig/`.
