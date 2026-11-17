# Personal Settings Sync (`pss`)

Repo-as-source-of-truth dotfile, shell, CLI, and AI customization manager for **EndeavourOS (`personal`)** and **WSL2 (`rbc` / `work`)**.

Driven by `sync.config.json`, `./pss` links Zsh + Starship, Git config/hooks, `configs/bin/` utilities, and `~/.gemini` agent rules/skills/plugins, with local state stored in `~/.local/state/pss/`.

## Setup

```sh
git clone -b zsh https://github.com/Kamil-Suhak/personal-settings-sync.git ~/code/projects/personal-settings-sync
cd ~/code/projects/personal-settings-sync
./bootstrap.sh
```

Or non-interactively for a specific workspace:

```sh
./pss workspace use personal   # or: rbc / work
./pss setup
```

## Common Commands

- `pss status` / `pss apply` / `pss diff` — Inspect or sync managed configs
- `pss workspace [list|use <name>]` — Switch active workspace (`personal`, `work`, `rbc`)
- `pss apps` / `pss fonts` — Install configured packages (`pacman`/`apt`) and Nerd Fonts
- `which profile -h` — List all shell commands inside an interactive Zsh session
- `python3 -m unittest discover -s tests` — Run the test suite

Detailed documentation (agents/skills, shell commands, `workset`, packages, and WSL notes) lives in the Obsidian vault under `wiki/Projects/personal-settings-sync/`.
