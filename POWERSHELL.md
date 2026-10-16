# PowerShell Profile Cheatsheet

Quick reference for all custom functions, aliases, and keybindings configured in [`configs/powershell/Microsoft.PowerShell_profile.ps1`](file:///c:/Users/kamil/Coding/Projects/personal-settings-sync/configs/powershell/Microsoft.PowerShell_profile.ps1).

---

## 1. Git Automation & Workflows

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `push` | `[<message>]` | Pushes commits to remote. If `<message>` is passed, stages and commits first (`git add -A; git commit -m`). **Automatically sets upstream tracking** on new branches. |
| `commit` | `<message>` | Stages all files and creates a commit: `git add -A; git commit -m "<message>"`. |
| `catchup` | `[<branch>] [-m\|--merge] [-c\|--check]` | Fetches upstream updates from `develop` (or `main`) and **rebases with autostash**. Use `-m` or `--merge` for a merge commit, or `-c` / `--check` to preview incoming commits without applying. |
| `sync` | *none* | Safely syncs current branch: pulls with `rebase --autostash`, then pushes. |
| `b` | `[<branch>]` | Switches to `<branch>`. If run with no arguments, lists your **10 most recently active branches**. |
| `nb` | `<branch>` | Creates and switches to a new branch: `git checkout -b <branch>`. |
| `main` | *none* | Jumps directly back to `main` (automatically falls back to `master` if repo uses master). |
| `undo` | *none* | **The safety net**: unwinds the last commit while keeping all changes safely staged (`git reset --soft HEAD~1`). |
| `st` | *none* | Compact, clean 1-line branch and file status (`git status -sb`). |
| `lg` | `[<count>]` | Compact colorized commit graph (`git log --graph --oneline`). Defaults to 10 commits. |
| `gbc` | *none* | Deletes all local branches that have already been merged into `main`. |

### Git Workflow Examples:
```powershell
nb feature-auth           # 1. Create and switch to new branch
push "feat: add login"    # 2. Stages, commits, and pushes (auto-sets upstream on GitHub)
catchup -Check            # 3. See what commits teammates pushed to develop
catchup                   # 4. Rebase cleanly on top of develop (with autostash)
undo                      # 5. Undo accidental commit without losing code
main                      # 6. Jump back to main branch
gbc                       # 7. Clean up merged branches
```

---

## 2. Navigation & Project Switching

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `..` | *none* | Go up 1 directory (`Set-Location ..`). |
| `...` | *none* | Go up 2 directories (`Set-Location ../..`). |
| `....` | *none* | Go up 3 directories (`Set-Location ../../..`). |
| `p` | `<name>` | **Universal Project Jumper**: fuzzy-matches `<name>` across `~/Coding/Projects`, `~/Dev`, and `~/Documents/Uczelnia` and jumps there immediately. |
| `api` | *none* | Direct jump to `$HOME\Dev\dodge-backend-api`. |
| `apim` | *none* | Direct jump to `$HOME\Dev\dodge-apim`. |
| `thesis` | *none* | Direct jump to `$HOME\Documents\Uczelnia\thesis`. |
| `rev` | `[<path>]` | Opens Windows File Explorer at the specified path (defaults to current directory `.`). |

### Navigation Examples:
```powershell
p dodge       # Jumps to ~/Dev/dodge-backend-api
p sync        # Jumps to ~/Coding/Projects/personal-settings-sync
p thesis      # Jumps to ~/Documents/Uczelnia/thesis
rev           # Opens current folder in Windows Explorer
...           # Jumps up 2 folder levels
```

---

## 3. Development & System Helpers

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `venv` | `[<name>]` | Activates Python virtual environment (default: `.venv`). **Automatically creates it** via `py -m venv` if it doesn't exist yet. |
| `killport` | `<port>` | Finds and kills whatever process is occupying a local port (e.g. `killport 5000`, `killport 5432`). |
| `find` | `<name> [<path>] [-o\|--open]` | Interactive fuzzy file finder. Excludes junk (`node_modules`, `.git`, `bin`), copies selection to clipboard, and optionally opens in VS Code with `-o` or `--open`. |
| `sudo` | `<command>` | Windows 11 native elevation. Supports `sudo !!` to re-run the previous command as Administrator. |
| `which` | `<command>` | Prints the full path of an executable or cmdlet (with error handling). |
| `cmp` | `<file1> <file2>` | Compares SHA-256 hashes of two files to verify whether they are identical. |
| `findstr` | `<pattern> [<path>] [-v\|--invert] [-c\|--case] [-l\|--files-only]` | Dual-mode text finder. Filters piped input (`docker ps \| findstr auth`) or searches codebase files recursively (`findstr "TODO"`), auto-skipping junk dirs (`.git`, `node_modules`, `bin`, `.venv`). |

### Development Examples:
```powershell
venv                  # Creates/activates .venv and integrates badge into prompt
killport 8080         # Kills hung backend dev server on port 8080
find user -o          # Searches for files matching 'user' and opens choice in VS Code
findstr "TODO"        # Recursive text search across codebase files
findstr "TODO" -l     # Only print filenames containing matches
docker ps | findstr auth  # Filters pipeline output for 'auth'
sudo winget upgrade   # Runs single command elevated
sudo !!               # Re-runs previous command as Administrator
which python          # Prints C:\Python314\python.exe
```

---

## 4. PSReadLine & Autocomplete Keybindings

Configured for **classic CMD inline cycling** (no popup menus getting in the way):

| Keybinding | Function | Description |
| :--- | :--- | :--- |
| `Tab` | `TabCompleteNext` | Cycles forward through matching files and commands inline. |
| `Shift + Tab` | `TabCompletePrevious` | Cycles backward through autocomplete options. |
| `Ctrl + Spacebar` | `MenuComplete` | Opens visual popup menu on demand if you want to inspect all options. |
| `Right Arrow` | `AcceptNextSuggestionWord` | Accepts a single word from gray inline history prediction (Fish shell style). |
| `F2` | `SwitchPredictionView` | Toggles predictive IntelliSense between single-line `InlineView` and multiline `ListView`. |

---

## 5. Powerline Status Prompt

A single-line, lightweight native Powerline prompt with dynamic transitions:

```text
 ⚡ ADMIN  Projects/dodge-backend-api  (.venv)  main  ⏱ 1.2s  ❯
```

### Prompt Segments (Rendered Only When Active):
1. **`⚡ ADMIN`** *(DarkRed / Yellow)*: Displays only when the PowerShell window itself is elevated as Administrator.
2. **`Parent/Child`** *(Blue / White)*: 2-tier working directory path (e.g. `Projects/personal-settings-sync` or `~/Documents`) to eliminate folder ambiguity without long paths.
3. **`(.venv)`** *(DarkGreen / White)*: Displays your active Python virtual environment name inside the status bar (no extra lines).
4. **`Git Branch`** *(DarkMagenta / White)*: Displays current git branch (fast cached check: never queries git outside repositories).
5. **`⏱ Timer`** *(DarkYellow / Black)*: Displays execution duration only if the previous command took $>500$ms.
6. **`❯ Chevron`** *(Green / Red)*: Green if previous command succeeded (`$global:?`), Red if it failed.
