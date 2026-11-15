# Ubuntu WSL Setup Guide

From-scratch setup for `personal-settings-sync` on an Ubuntu WSL2 instance.

---

## 1. Install Prerequisites

On a fresh Ubuntu WSL instance, install `git`, `curl`, `python3`, and `unzip` (used by `scripts/setup-linux.sh` to unpack JetBrains Mono when `pacman` is not present):

```sh
sudo apt update && sudo apt install -y git curl python3 unzip
```

---

## 2. Clone & Run the Bootstrapper

Cloning locally first is recommended over piping `curl | sh` so interactive prompts in `scripts/setup-linux.sh` (Git identity and `chsh -s $(which zsh)`) can read from your terminal:

```sh
git clone -b zsh https://github.com/Kamil-Suhak/personal-settings-sync.git ~/Coding/Projects/personal-settings-sync
sh ~/Coding/Projects/personal-settings-sync/bootstrap.sh --workspace work
```

*(Use `--workspace personal` for your personal machine.)*

If you prefer the one-liner instead, run `pss setup` afterwards to complete interactive prompts:

```sh
curl -fsSL https://raw.githubusercontent.com/Kamil-Suhak/personal-settings-sync/zsh/bootstrap.sh | sh -s -- --workspace work
pss setup
```

### What `bootstrap.sh` Does

1. Binds the active workspace (`pss workspace use <work|personal> --no-apply`).
2. Installs packages declared in `sync.config.json` via `apt` (`pss apps install`): `zsh`, `zsh-autosuggestions`, `zsh-syntax-highlighting`, `fzf`, `starship`, `fd-find`, `ripgrep`, `jq`, `git-delta`, etc.
3. Runs `pss setup` (`scripts/setup-linux.sh`): installs JetBrains Mono into `~/.local/share/fonts`, initializes `~/.local/state/pss/project-roots` (`~/Coding/Projects` and `~/Dev`), prompts for `~/.gitconfig` `user.name`/`user.email`, and offers `chsh -s $(which zsh)`.
4. Symlinks configurations via `pss apply` (`~/.zshrc`, `~/.config/starship.toml`, `~/.gitconfig`, `~/.gemini/AGENTS.md`, skills, etc.).

Start Zsh immediately once complete:

```sh
exec zsh -l
```

---

## 3. Ubuntu & WSL Notes

- **`starship` on Ubuntu 22.04 / 24.04:** Older Ubuntu releases do not include `starship` in default `apt` repos (`bootstrap.sh` continues past `apt` failures). Install it directly if missing:
  ```sh
  curl -sS https://starship.rs/install.sh | sh
  ```
- **`fd` command name on Ubuntu:** `apt`'s `fd-find` package installs the binary as `fdfind`. Symlink it into `~/.local/bin` if you want `fd`:
  ```sh
  mkdir -p ~/.local/bin && ln -s "$(which fdfind)" ~/.local/bin/fd
  ```
- **Windows Terminal font:** WSL does not control the host terminal's font. Set **JetBrainsMono Nerd Font** (or **JetBrains Mono**) in your Windows Terminal Ubuntu profile settings so Starship icons render cleanly.
- **Extra project roots & API keys:**
  - Register additional project roots with `p -a <dir>`.
  - Export `GEMINI_API_KEY` in your environment if you use `decide`.
- **Windows-side Git repos (`work` workspace):** Keep repositories inside the Linux filesystem (`~/Coding/Projects`) for best performance. If you must work in `/mnt/c/...`, you can set `export PSS_WSL_GIT_INTEROP=1` to route `git` to Windows `git.exe` there.
