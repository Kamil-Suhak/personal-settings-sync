# PowerShell Profile Cheatsheet

Quick reference for custom functions, aliases, and keybindings in the shared profile and its `git`, `navigation`, `search`, `launchers`, and `ai` groups under `configs/powershell/`, plus workspace profiles (`workspaces/<workspace>/powershell/`). [`scripts/profile-groups.ps1`](scripts/profile-groups.ps1) registers the files used for loading, help, and bootstrap; modified functions are routed back to their source files.

---

## 1. Git Automation & Workflows

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `commit` | `<message> \| amend [<message>] \| undo` | Stages all files and creates a commit, amends the latest commit (`amend`), or soft-resets `HEAD~1` keeping changes staged (`undo`). |
| `push` | `[<message>]` | Pushes commits to remote. If `<message>` is passed, stages and commits first. Automatically sets upstream tracking on new branches. |
| `repo` | `[<base>] [-f\|-n\|-a\|-i]` / `catchup` / `sync` | Fetches `origin --prune` (1m cooldown, `-f` force, `-n` skip), shows commit divergence vs remote & base (`branch.base` or `develop -> beta -> main`), and displays grouped working tree state. `repo catchup [<base>] [-r\|-m\|-c]` merges/rebases from base; `repo sync [-r]` pulls and pushes. |
| `diff` | `[staged\|all\|up\|base\|last] [<args>] [-s\|-f]` | **Overrides built-in `diff` (`Compare-Object`)**. Unpaged, side-labeled `git diff` across unstaged (default), `staged` (`s`), `all` (`a`), `up`, `base [<branch>]`, or `last [<n>]`; supports `-s` (`-Stat`), `-f` (`-Files`), and path filters. |
| `b` | `[<branch>] [-n\|-new]` | Smart branch switcher. Lists 10 recent branches with no args, switches if found, or prompts to create. |
| `nb` | `<branch> [<from>]` | Creates and switches to a new branch (`git switch -c`), recording its base branch locally for `repo` / `diff base`. |
| `lg` | `[<count>]` | Compact colorized commit graph (default: 10 commits). |
| `wip` | `[<message>] [-a]` | Stashes staged changes (or everything including untracked with `-a`). |
| `unwip` | *none* | Pops the latest stash back into the working tree. |
| `stashes` | *none* | Formatted, colorized list of all git stashes. |
| `groot` | *none* | Jumps to the root directory of the current git repository. |

---

## 2. Navigation & Project Switching

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `..` / `...` / `....` | *none* | Jump up 1, 2, or 3 directory levels. |
| `back` | *none* | Toggles back to the previous working directory. |
| `mkcd` | `<path>` | Creates directory (including parents) and navigates into it. |
| `p` | `[<name>] [-a\|-r\|-l]` | Project jumper reading machine-local roots from `%LOCALAPPDATA%\PersonalSettingsSync\project-roots` (`-a` add, `-r` remove, `-l` list). |
| `rev` | `[<path>]` | Opens Windows File Explorer at `<path>` (defaults to `.`). |

---

## 3. Development, AI & System Helpers (Shared)

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `decide` (`decision`) | `[-Choices <a,b>] [-Instructions <text>] <question>` | Evaluates a scenario or piped input via the Gemini Decision API (`gemini-decision-1`) with a confidence bar. Requires `$env:GEMINI_API_KEY`. |
| `jwt` | `[<token>]` (or piped / clipboard) | Offline JWT header & payload decoder with expiration status (zero network calls; pulls clipboard if omitted). |
| `find` | `[<name>] [<path>] [-o]` (or piped / clipboard) | Fuzzy file finder (`git ls-files` inside repos, `.NET` walker outside); accepts piped query or short clipboard text when omitted. |
| `findstr` | `[<pattern>] [<path>] [-v\|-c\|-l]` | Dual-mode search: filters piped output or searches repo via `git grep`; pulls short single-line clipboard text if `<pattern>` omitted. |
| `which` | `<command> [-h]` / `which profile [-h]` | Locates executables/functions. `which profile -h` lists public functions and synopses under shared and active workspace group headings. |
| `venv` | `[<name>]` | Activates Python virtualenv (default: `.venv`), creating it first if missing. |
| `cmp` | `[<file1> [<file2>]] [-w] [-q]` | `cmp` watches next 2 clipboard copies; `cmp <file>` diffs file vs clipboard; `cmp <f1> <f2>` diffs files (`-w` ignores whitespace, `-q` summary only). |
| `brave` | `[<url\|args>...]` | Non-blocking Brave Browser launcher (supports piped URLs, flags, and clipboard URL fallback). |
| `vs` | `[<path>] [-MaxDepth <n>] [-Files <paths>]` | Opens Visual Studio for a `.sln`/`.slnx` in the current/target directory or up to `MaxDepth` (default: 5) parent levels; opens specified files alongside the solution. |
| `sudo` | `<command>` | Windows 11 native elevation (supports `sudo !!`). |
| `copy` / `paste` | `[<value>]` | Clipboard aliases for `Set-Clipboard` / `Get-Clipboard` (**overrides built-in `copy` -> `Copy-Item`**). |
| `pss` | `[<arguments>...]` | Invokes `pss.ps1` from any directory. Run `. $PROFILE` to reload profile edits in the current shell. |

---

## 4. Workspace-Specific Functions

### `personal` ([`workspaces/personal/powershell/profile.ps1`](workspaces/personal/powershell/profile.ps1))
| Command | Description |
| :--- | :--- |
| `ask` | Ephemeral `agy -p` query using recent terminal commands, screen buffer, and piped input (`-High`, `-Clean`, `-KeepHistory`). |

### `work` ([`workspaces/work/powershell/profile.ps1`](workspaces/work/powershell/profile.ps1))
| Command | Description |
| :--- | :--- |
| `git` wrapper | Automatically routes `git` through `cmd.exe /c` when Carbon Black / AppLocker blocks direct `git.exe` execution. |
| `ask` | Company-compliant `copilot -p` query using recent terminal commands, screen buffer, and piped input (`-Clean`). |
| `azwho` | Prints the active Azure CLI subscription, tenant, and signed-in account. |
| `slnclean` | Recursively deletes `.NET` `bin/` and `obj/` build artifact folders (supports `-WhatIf`). |
| `workset` | Manages named local issue file sets: `new`, `add`, `edit`, `show`, `list`, `open`, `archive`, `restore`, and `delete`. See [Worksets](README.md#worksets). |

---

## 5. PSReadLine & Powerline Prompt

- **PSReadLine**: `Tab`/`Shift+Tab` inline completion cycling, `Ctrl+Space` menu complete, smart `RightArrow` (`ForwardChar` inside typed text, `AcceptNextSuggestionWord` only at end-of-line), `F2` toggle `InlineView`/`ListView`.
- **Powerline Prompt**: Renders `⚡ ADMIN`, 2-tier `Parent/Child` path, active `(.venv)`, cached Git branch, and `❯` status chevron.
- **Prompt Variables**: Automatically updates `$cb` (current Git branch), `$gr` (current Git repository root), `$cw` (the unique active workset for the current checkout and branch, in the `work` workspace), and `$cmdtime` (last command execution time; set `$global:__show_prompt_timer = $true` to also render `⏱` on the prompt bar for commands > 500ms). `$cw` is `$null` when no workset matches, several match, or HEAD is detached.
