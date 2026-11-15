# Shell & CLI Reference

Zsh profile, Starship prompt, and standalone Python 3 helper tools managed by `pss`.

## Architecture

- **Shell runtime:** Plain **Zsh** with `zsh-autosuggestions`, `zsh-syntax-highlighting`, `fzf`, and **Starship** (`~/.config/starship.toml`).
- **Two-tier implementation:**
  - **Shell functions** (`configs/zsh/*.zsh`, `workspaces/*/zsh/*.zsh`): Commands that mutate live shell state (`cd`, virtualenvs, `$cb`/`$gr`/`$cw`, `rerun`) or wrap external tools. Kept portable and free of Zsh-only expansion syntax.
  - **Python 3 CLIs** (`configs/bin/*`, `workspaces/work/bin/workset`, `pss`): Structured tools for Git inspection, multi-repo scanning, diffing, JWT decoding, terminal buffer capture, Decisions API, and worksets.
- **Self-documenting help:** Every public command supports `-h` / `--help`. Every public shell function carries a `# @cmd: <name> — <summary>` header so `which profile -h` prints a fast categorized directory without AST parsing.

## Prompt Context Variables

Updated automatically via `precmd` before each prompt render:

- `$gr`: Top-level root of the current Git repository
- `$cb`: Current Git branch name (or short SHA if detached)
- `$cw`: Active `workset` name when inside a `work` repository branch (`starship.toml` displays `$cw`)

---

## Git Commands

| Command | Summary |
| :--- | :--- |
| `commit [-a] [-m <msg>]` | Stage (with `-a`/`--all`) and create a commit validated by the `commit-msg` hook |
| `push [-f] [-u]` | Push current branch (`-f` maps to `--force-with-lease`; auto-sets upstream when missing) |
| `st [<branches...>] [-f\|-n] [-i] [-a] [--files] [--full]` | Upstream delta, categorized working tree, stashes, cached fetch age, and base branch comparison |
| `unpushed [<targets...>] [-a] [--files] [-c] [-f] [--depth N]` | Scan project roots or explicit repos/paths for uncommitted work and unpushed local branches |
| `gdiff [unstaged\|staged\|all\|up\|pr <branch>\|last [N]] [-s\|-f] [paths...]` | Context-aware Git diff viewer with PR preview (`ref...HEAD`) and working-copy reminders |
| `b [<branch>]` | Switch branches directly or interactively via `fzf` |
| `nb <new> [<base>]` | Create and switch to a new branch |
| `lg [<count>]` | Compact colored Git graph log (default: 20 commits) |
| `wip [<note>]` | Stage everything and create a temporary `--no-verify` WIP commit |
| `unwip` | Undo the latest commit back to the working tree if it is a WIP commit |
| `stashes` | Browse stashes interactively with preview via `fzf` |
| `groot` | `cd` to the current Git repository root |

---

## Navigation & Project Switcher

| Command | Summary |
| :--- | :--- |
| `mkcd <dir>` | Create directory (including parents) and `cd` into it |
| `p [<name> \| -l \| -a [<dir>] \| -r <q>]` | Jump to a project under configured project roots (`~/.local/state/pss/project-roots`) or open interactive `fzf` picker |
| `open [<path>]` | Open path in desktop file manager (`xdg-open` on Linux, `explorer.exe` via `wslpath` on WSL) |

---

## Search & File Comparison

| Command | Summary |
| :--- | :--- |
| `find [-o] <query> [<path>]` | Fuzzy filename search (copies match to clipboard; `-o` opens in VS Code). Standard predicates (`find . -name ...`) pass through to system `find` |
| `findstr [-v] [-c] [-l] <pattern> [<path>]` | Filter piped stdin or search repo/directory files via `git grep`, `rg`, or `grep` |
| `cmp [<f1> [<f2>]] [-w] [-q]` | Compare two files, a file against clipboard, or two interactive clipboard copies via `git diff --no-index` |

---

## Launchers & Development

| Command | Summary |
| :--- | :--- |
| `venv [<dir>]` | Activate Python virtualenv (default: `.venv`), creating it if missing |
| `copy [<text...>]` / `paste` | Read/write system clipboard (`wl-clipboard`, `xclip`, `xsel`, `pbcopy`/`pbpaste`, or WSL interop) |
| `jwt [<token>]` | Decode JWT header, payload, and local expiration status from argument, stdin, or clipboard |
| `which [<cmd> \| profile] [-h]` | Locate command path/definition; `which profile -h` lists all commands; `which <cmd> -h` shows source + `--help` |
| `pss <subcommand>` | Run Personal Settings Sync manager (`status`, `apply`, `diff`, `workspace`, `apps`, `fonts`, `setup`) |

---

## AI & Terminal Context

| Command | Summary |
| :--- | :--- |
| `out [<sel>] [-c]` / `lastout` | Capture completed command output from terminal scrollback (`1`, `N`, `~N`, `~A..B`) |
| `rerun [<sel>] [-y]` | Preview and re-execute prior shell commands (blocks recursive `rerun` invocation) |
| `ask [--ctx [<sel>]] [--high] [--keep-history] <question>` | Streamed ephemeral Q&A (`agy` in `personal`, `copilot` in `work`); pipeable to `copy` |
| `decide [-c a,b] [-i instructions] <question>` / `decision` | Evaluate binary or multi-choice scenarios via the Gemini Decisions API (`GEMINI_API_KEY`) |

---

## Workspace Extensions (`work`)

- `vs [<path>] [--max-depth N] [--files ...] [--what-if]`: Locate `.sln`/`.slnx` up to parent depth limit and launch Visual Studio.
- `azwho`: Display active Azure CLI subscription name, ID, tenant, and signed-in user.
- `workset [list|new|add|show|edit|open|archive|restore|delete]`: Manage cross-repository issue file sets stored under `~/.local/state/pss/worksets/work/`.
- `PSS_WSL_GIT_INTEROP=1`: Optional toggle causing `git` to invoke Windows `git.exe` automatically when working inside `/mnt/<drive>/`.
