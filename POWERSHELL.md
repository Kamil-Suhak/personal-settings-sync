# PowerShell Profile Cheatsheet

Quick reference for custom functions, aliases, and keybindings across [`configs/powershell/Microsoft.PowerShell_profile.ps1`](configs/powershell/Microsoft.PowerShell_profile.ps1) and workspace profiles (`workspaces/<workspace>/powershell/profile.ps1`).

---

## 1. Git Automation & Workflows

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `push` | `[<message>]` | Pushes commits to remote. If `<message>` is passed, stages and commits first. Automatically sets upstream tracking on new branches. |
| `commit` | `<message>` | Stages all files and creates a commit: `git add -A; git commit -m "<message>"`. |
| `amend` | `[<message>]` | Stages all changes and amends the latest commit (updates message if provided). |
| `catchup` | `[<branch>] [-r\|--rebase] [-c\|--check]` | Fetches upstream `develop` (or `main`) and merges or rebases (`-r`) into current branch. Use `-c` to preview without applying. |
| `gsync` | `[-r\|--rebase]` | Pulls with merge (or `-r` for rebase with autostash), then pushes. |
| `b` | `[<branch>] [-n\|-new]` | Smart branch switcher. Lists 10 recent branches with no args, switches if found, or prompts to create. |
| `nb` | `<branch>` | Creates and switches to a new branch (`git switch -c`). |
| `main` | *none* | Switches back to `main` (falls back to `master`). |
| `undo` | *none* | Soft-resets the last commit while keeping changes staged (`git reset --soft HEAD~1`). |
| `wip` | `[<message>] [-a\|--all]` | Stashes staged changes (or everything including untracked with `-a`). |
| `unwip` | *none* | Pops the latest stash back into the working tree. |
| `stashes` | *none* | Formatted, colorized list of all git stashes. |
| `st` | *none* | Compact status (`git status -sb`). |
| `lg` | `[<count>]` | Compact colorized commit graph (default: 10 commits). |
| `gbc` | *none* | Deletes local branches already merged into `main`. |
| `groot` | *none* | Jumps to the root directory of the current git repository. |

---

## 2. Navigation & Project Switching

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `..` / `...` / `....` | *none* | Jump up 1, 2, or 3 directory levels. |
| `back` | *none* | Toggles back to the previous working directory. |
| `mkcd` | `<path>` | Creates directory (including parents) and navigates into it. |
| `p` | `[<name>] [-a\|-r\|-l]` | Project jumper reading roots from `~/.project-roots` (`-a` add, `-r` remove, `-l` list). |
| `rev` | `[<path>]` | Opens Windows File Explorer at `<path>` (defaults to `.`). |

---

## 3. Development, AI & System Helpers (Shared)

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `decide` (`decision`) | `[-Choices <a,b>] [-Instructions <text>] <question>` | Evaluates a scenario or piped input via the Gemini Decision API (`gemini-decision-1`) with a confidence bar. Requires `$env:GEMINI_API_KEY`. |
| `jwt` | `<token>` (or piped) | Offline JWT header & payload decoder with expiration status (zero network calls). |
| `find` | `<name> [<path>] [-o\|--open]` | Fuzzy file finder (`git ls-files` inside repos, `.NET` walker outside); copies selection to clipboard and optionally opens in VS Code (`-o`). |
| `findstr` | `<pattern> [<path>] [-v\|-c\|-l]` | Dual-mode search: filters piped output or searches repo via `git grep` (with `.NET` fallback outside repos). |
| `which` | `<command> [-h]` / `which profile [-h]` | Locates executables/functions. `which profile -h` lists both Shared and active Workspace functions. |
| `venv` | `[<name>]` | Activates Python virtualenv (default: `.venv`), creating it first if missing. |
| `cmp` | `<file1> <file2>` | Compares SHA-256 hashes of two files. |
| `sudo` | `<command>` | Windows 11 native elevation (supports `sudo !!`). |
| `copy` / `paste` | `[<value>]` | Clipboard aliases for `Set-Clipboard` / `Get-Clipboard`. |
| `pss` | `[<arguments>...]` | Invokes `pss.ps1` from any directory. Run `. $PROFILE` to reload profile edits in the current shell. |

---

## 4. Workspace-Specific Functions

### `personal` ([`workspaces/personal/powershell/profile.ps1`](workspaces/personal/powershell/profile.ps1))
| Command | Description |
| :--- | :--- |
| `ask` | Ephemeral `agy -p` query using recent terminal commands, screen buffer, and piped input (`-High`, `-Clean`, `-KeepHistory`). |
| `brave` | Non-blocking Brave Browser launcher (supports piped URLs and flags). |
| `passbolt` / `passbolt-stop` | Starts or stops local Passbolt containers (`~/passbolt`). |

### `work` ([`workspaces/work/powershell/profile.ps1`](workspaces/work/powershell/profile.ps1))
| Command | Description |
| :--- | :--- |
| `git` wrapper | Automatically routes `git` through `cmd.exe /c` when Carbon Black / AppLocker blocks direct `git.exe` execution. |
| `ask` | Company-compliant `copilot -p` query using recent terminal commands, screen buffer, and piped input (`-Clean`). |
| `azwho` | Prints the active Azure CLI subscription, tenant, and signed-in account. |
| `slnclean` | Recursively deletes `.NET` `bin/` and `obj/` build artifact folders (supports `-WhatIf`). |

---

## 5. PSReadLine & Powerline Prompt

- **PSReadLine**: `Tab`/`Shift+Tab` inline completion cycling, `Ctrl+Space` menu complete, `RightArrow` accept next prediction word, `F2` toggle `InlineView`/`ListView`.
- **Powerline Prompt**: Renders `⚡ ADMIN`, 2-tier `Parent/Child` path, active `(.venv)`, cached Git branch, command duration (`> 500ms`), and `❯` status chevron.
