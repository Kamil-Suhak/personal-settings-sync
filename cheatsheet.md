# PowerShell → Zsh & Linux Cheatsheet

Quick migration map from the old PowerShell profile to the Zsh + Starship + Python CLI setup, including removed helpers, renamed commands, and native Linux package replacements (`rg`, `fd`, `fzf`).

---

## 1. Renamed, Moved & Removed Commands

| PowerShell (Old) | Zsh / Linux (New) | Notes |
| :--- | :--- | :--- |
| `rev [<path>]` | `open [<path>]` | Opens directory/file via `xdg-open` (Linux) or `explorer.exe` via `wslpath` (WSL). |
| `diff [mode]` | `gdiff [mode]` | Avoids shadowing system `diff`. Same modes: `unstaged`, `staged`, `all`, `up`, `pr <branch>`, `last [N]`, `-s`/`-f`. |
| `..` | `..` (native Zsh `AUTO_CD`) | Typing `..` directly changes up one directory without a custom function. |
| `...`, `....` | `cd ../..`, `cd ../../..` | Removed custom functions; use `cd ../..` (or `..` with `AUTO_CD`). |
| `back` | `cd -` | Native POSIX/Zsh toggle to `$OLDPWD`. Use `dirs -v` + `cd -<n>` for directory stack history (`AUTO_PUSHD`). |
| `vs [<path>]` | `vs [<path>]` (**`work` workspace only**) | Moved out of shared config into `workspaces/work/zsh/profile.zsh`. Supports `--max-depth`, `--files`, `--what-if`. |
| `brave [urls...]` | *Removed* | Use `xdg-open <url>` or `brave <url> &` directly. |
| `Get-Help <cmd>` / comment synopsis | `<cmd> -h` or `which profile -h` | Every command supports `-h`/`--help`; `which <cmd> -h` prints source + help; `which profile -h` lists all commands by category. |

---

## 2. Navigation & Project Switcher

| PowerShell | Zsh Equivalent | Notes |
| :--- | :--- | :--- |
| `mkcd <dir>` | `mkcd <dir>` | `mkdir -p` and `cd` into it. |
| `p [<name>]` | `p [<name>]` | Jump to a project under configured project roots (`~/.local/state/pss/project-roots`), or pick interactively via `fzf` when called with no args. |
| `p -List` / `-Add` / `-Remove` | `p -l` / `p -a [<dir>]` / `p -r <q>` | Manage project roots. |
| `groot` | `groot` | `cd` to the current Git repository root. |

---

## 3. Search & File Comparison (Packages Replacing Helpers)

`find` and `findstr` are still present in `configs/zsh/search.zsh` for muscle memory, but `fd`, `rg` (`ripgrep`), and `fzf` are faster, respect `.gitignore` by default, and cover more workflows:

| Old Habit / Helper | Recommended Tool / Command | Why It's Better |
| :--- | :--- | :--- |
| `findstr <pattern> [<path>]` | `rg <pattern> [<path>]` | Respects `.gitignore`, skips binaries/hidden files, highlights matches, supports `-i` (case-insensitive), `-l` (files only), `-g '*.py'` (glob filter), `-C 3` (context). |
| `... \| findstr <pattern>` | `... \| rg <pattern>` | Drop-in pipeline filter with color and regex support. |
| `find <query> [<path>]` | `fd <query> [<path>]` | Respects `.gitignore`, colorized output, intuitive glob/extension filters (`fd -e py`, `fd -H` for hidden). |
| Interactive file open | `Ctrl+T` (`fzf`) or `code "$(fd \| fzf)"` | `fzf` filters interactively in real time with preview. |
| `cmp [<f1> [<f2>]] [-w] [-q]` | `cmp [<f1> [<f2>]] [-w] [-q]` | Unchanged workflow: compares two files, file vs clipboard, or two interactive clipboard captures via `git diff --no-index`. |

---

## 4. Git Workflow

| Command | Summary |
| :--- | :--- |
| `st [<branches...>] [-f\|-n] [-i] [-a] [--files] [--full]` | Upstream delta, categorized working tree, stashes, cached fetch age, and base branch comparison. |
| `unpushed [<targets...>] [-a] [--files] [-c] [-f] [--depth N]` | Scan project roots or explicit repos/paths for uncommitted work and unpushed local branches. |
| `gdiff [unstaged\|staged\|all\|up\|pr <branch>\|last [N]] [-s\|-f] [paths...]` | Context-aware Git diff viewer (`ref...HEAD` PR preview) with working-copy reminders. |
| `commit [-a] [-m <msg>]` | Stage (`-a`) and commit, validated by the `commit-msg` Conventional Commits hook. |
| `push [-f] [-u]` | Push current branch (`-f` = `--force-with-lease`; auto-sets upstream when missing). |
| `b [<branch>]` | Switch branches directly or pick interactively via `fzf`. |
| `nb <new> [<base>]` | Create and switch to a new branch. |
| `lg [<count>]` | Compact colored Git graph log (default: 20 commits). |
| `wip [<note>]` / `unwip` | Create a `--no-verify` WIP commit or undo it back to the working tree. |
| `stashes` | Browse stashes interactively with diff preview via `fzf`. |

---

## 5. Dev Utilities, AI & Terminal Context

| Command | Summary |
| :--- | :--- |
| `venv [<dir>]` | Activate Python virtualenv (default: `.venv`), creating it if missing. |
| `copy [<text...>]` / `paste` | System clipboard read/write (`wl-clipboard`, `xclip`, `xsel`, `pbcopy`/`pbpaste`, or WSL interop). |
| `jwt [<token>]` | Decode JWT header, payload, and expiration from arg, stdin, or clipboard. |
| `out [<sel>] [-c]` / `lastout` | Capture completed command output from terminal scrollback (`1`, `N`, `~N`, `~A..B`). |
| `rerun [<sel>] [-y]` | Preview and re-execute prior shell commands (blocks recursive `rerun`). |
| `ask [--ctx [<sel>]] [--high] [--keep-history] <question>` | Ephemeral streamed Q&A (`agy` in `personal`, `copilot` in `work`). Pipeable to `copy`. |
| `decide [-c a,b] [-i instructions] <question>` | Evaluate binary or multi-choice scenarios via Gemini Decisions API (`GEMINI_API_KEY`). |
| `pss <subcommand>` | Manage symlinks, workspaces, packages, and fonts (`status`, `apply`, `diff`, `workspace`, `apps`, `fonts`, `setup`). |

### Work Workspace Only (`work`)

| Command / Setting | Summary |
| :--- | :--- |
| `vs [<path>] [--max-depth N] [--files ...] [--what-if]` | Find `.sln`/`.slnx` up to parent depth limit and launch Visual Studio. |
| `azwho` | Show active Azure CLI subscription, ID, tenant, and user. |
| `workset [list\|new\|add\|show\|edit\|open\|archive\|restore\|delete]` | Manage cross-repository issue file sets (`$cw` shown in prompt when active). |
| `PSS_WSL_GIT_INTEROP=1` | Optional toggle to route `git` to Windows `git.exe` inside `/mnt/<drive>/`. |

---

## 6. New Zsh, Starship & Plugin Capabilities

- **`zsh-autosuggestions`**: Press `→` (Right Arrow) or `End` to accept faded history suggestions inline; `Alt+→` accepts one word at a time.
- **`zsh-syntax-highlighting`**: Commands turn green when valid and red when invalid/misspelled before pressing Enter.
- **`fzf` Shell Keybindings**:
  - `Ctrl+R`: Fuzzy-search entire command history (replaces `PSReadLine` history search).
  - `Ctrl+T`: Fuzzy-pick a file path and insert it at the cursor.
  - `Alt+C`: Fuzzy-pick a subdirectory and `cd` into it.
- **Zsh Directory Stack (`AUTO_PUSHD`)**: Every `cd` pushes to the stack — run `dirs -v` to list recent folders and `cd -2` (etc.) to jump back.
- **Starship Prompt (`starship.toml`)**: Fast native prompt showing directory, Git branch/status, language versions, command duration, and `$cw` (active `workset` in `work` workspace).
- **Live Prompt Context Vars**: `$gr` (Git root), `$cb` (current branch), and `$cw` (active workset) stay updated before every prompt.
