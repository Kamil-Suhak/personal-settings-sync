# Personal Settings Sync (PSS)

A lean, repo-as-source-of-truth developer environment manager across **Workspaces** (`personal`, `work`, or custom contexts) for **PowerShell**, **Git**, and **AI Agent Rules/Skills/Plugins**.

## Core Philosophy

Instead of copying configs back and forth and trying to reverse-engineer edits into layers, **the repository is always the source of truth**:

- **PowerShell**: `$PROFILE` is a tiny managed loader stub dot-sourcing [`configs/powershell/Microsoft.PowerShell_profile.ps1`](configs/powershell/Microsoft.PowerShell_profile.ps1), which loads shared groups, the active workspace, and machine-local overrides in that order. [`scripts/profile-groups.ps1`](scripts/profile-groups.ps1) registers the source files used by loading, `which profile -h`, and bootstrap.
- **Git**: `~/.gitconfig` uses native `[include]` directives pointing directly to [`configs/git/.gitconfig.shared`](configs/git/.gitconfig.shared) and `workspaces/<active>/git/.gitconfig`, preserving local credentials and machine overrides, plus a directory junction `~/.git-hooks` $\rightarrow$ [`configs/git/hooks/`](configs/git/hooks/) wired via `core.hooksPath = ~/.git-hooks`.
- **AI Skills & Plugins**: Per-item Windows directory junctions (`~/.agents/skills/<name>` and `~/.gemini/config/plugins/<name>`) link directly into `configs/` without touching third-party skills/plugins, plus `~/.gemini/skills` $\rightarrow$ `~/.agents/skills`.
- **AI Agent Rules (`AGENTS.md`, `GEMINI.md`)**: One-way concatenation of `configs/gemini/` + `workspaces/<active>/gemini/`, plus `~` expansion for `skills.json`.
- **One-Time Machine Onboarding**: `pss bootstrap` parses existing standalone `$PROFILE` (via PowerShell AST), `~/.gitconfig`, and `AGENTS.md` to help route functions and sections into `Shared`, `Workspace`, or `Local`.

> [!CAUTION]
> **Public Repository Security Notice**: Never commit sensitive secrets, private credentials, enterprise tokens, or workset contents. PSS local state lives outside this repository in `%LOCALAPPDATA%\PersonalSettingsSync`; Git credentials remain in their normal machine-local configuration.

---

## Directory Structure

```text
personal-settings-sync/
├── pss.ps1                                    # Unified CLI (status, apply/link, diff, edit, bootstrap, workspace, apps)
├── bootstrap.ps1                              # One-line remote machine bootstrapper
├── setup.ps1                                  # Compatibility wrapper delegating to bootstrap.ps1
├── sync.config.json                           # Declarative subsystem & workspace-scoped Winget packages
├── configs/                                   # Shared baseline (all machines)
│   ├── powershell/
│   │   ├── Microsoft.PowerShell_profile.ps1   # Core profile and loader (see POWERSHELL.md)
│   │   └── {git,navigation,search,launchers,ai}.ps1 # Shared function groups
│   ├── git/
│   │   ├── .gitconfig.shared                  # Shared Git defaults
│   │   └── hooks/                             # Global Git hooks (linked to ~/.git-hooks)
│   ├── gemini/
│   │   ├── AGENTS.md                          # Shared AI agent guidelines
│   │   ├── GEMINI.md                          # Canonical pointer to AGENTS.md
│   │   └── skills.json                        # Skill directory registry
│   ├── skills/                                # Shared skills (linked via junctions)
│   └── plugins/                               # Antigravity plugins (linked via junctions)
├── workspaces/                                # Context-specific overrides
│   ├── personal/
│   │   ├── powershell/profile.ps1             # Personal shell additions (agy ask)
│   │   ├── git/.gitconfig                     # Personal git identity
│   │   └── gemini/AGENTS.md                   # Personal AI workspace context
│   └── work/
│       ├── powershell/profile.ps1             # Work additions (Carbon Black git bypass, copilot -p ask, azwho)
│       ├── powershell/worksets.ps1            # Work-only issue file sets
│       ├── git/.gitconfig                     # Work git identity & large-repo tuning
│       └── gemini/AGENTS.md                   # Work AI compliance & stack context
├── scripts/
│   ├── setup-windows.ps1                      # Windows Explorer tweaks, JetBrains Mono font & local identity setup
│   ├── profile-groups.ps1                     # Profile group registry
│   └── local-state.ps1                        # Local paths and temporary legacy migration
└── tests/
    └── Test-PSS.ps1                           # Isolated end-to-end test suite
```

---

## Dual-Machine Workflow

### Initial Setup on a PC
```powershell
# 1. Select workspace (automatically updates Git includes & AI links/builds)
pss workspace use work      # or: pss workspace use personal

# 2. (Optional) If migrating an existing machine with custom functions/gitconfig:
pss bootstrap

# 3. Link/build all subsystems
pss apply
```

### Day-to-Day Editing
```powershell
pss edit shared powershell    # Edit shared PowerShell profile directly in repo
pss edit work powershell      # Edit work-only PowerShell overrides (or: pss edit personal git)
pss edit shared agents        # Edit shared AGENTS.md (shorthand: pss edit agents)
pss apply -Include gemini     # Rebuild concatenated AGENTS.md after editing AI rules
```
PowerShell and Git changes are live immediately via loader/includes—just `commit` and `push` via Git, then `pss apply -Pull` on your other PC.

### Machine-local state

PSS stores project roots, local profile overrides, checkout-specific workspace selection, and worksets under `%LOCALAPPDATA%\PersonalSettingsSync`. These files are **not synced**; back up anything you want to retain when moving machines. Checkout workspace selections are keyed by checkout path, so a moved checkout needs its workspace selected again.

On startup, PSS and its profile migrate legacy `~\.project-roots`, `~\.profile.local.ps1`, and the checkout's `.workspace.local`. They copy and verify all detected files before removing originals. Conflicting destinations or conflicting local profile files stop migration without deleting originals; resolve conflicts manually and retry. A failure during cleanup is reported and can be retried. `pss ... -WhatIf` previews migration without changing files.

### Worksets

In the `work` workspace, a workset is a local, named set of files for an issue, including files across repositories and ordinary folders:

```powershell
b feature/123-dashboard -New
workset new                           # name: feature-123-dashboard
workset add -Files "C:\projects\api\src\Dashboard.cs" "C:\projects\api\src\Model.cs"
workset add feature-123-dashboard -Files "C:\projects\docs\guide.md"
workset edit                          # edit the list in VS Code
workset show
workset open                          # VS for one repo with a solution; otherwise VS Code
workset open -Code                    # explicitly use VS Code
workset archive
workset restore feature-123-dashboard
workset delete                        # removes the workset list immediately
```

Omitted names resolve using the current repository checkout and branch. Use an explicit name outside that context. `workset list` lists active sets; `workset list -Archived`, `workset show <name> -Archived`, and `workset delete <name> -Archived` operate on archived sets. Branch-derived names are normalized; collisions must be resolved by choosing another name. Lists edited by hand contain one absolute file path per line. Opening reports missing files and warns if a recorded repository has changed branches; it never switches branches. `-Vs` requires a single repository and a solution discoverable by `vs`.

To prevent old tabs reopening with worksets in Visual Studio, disable **Tools → Options → Projects and Solutions → General → Reopen documents on solution load**. This setting affects all solutions.

---

## Command Reference

| Command | Description |
| :--- | :--- |
| `pss status` | Shows sync status across PowerShell, Git, AI Rules, Skills, and Plugins. |
| `pss apply` / `pss link` | Writes `$PROFILE` loader, updates `~/.gitconfig` `[include]`s, builds AI rules, and links junctions. |
| `pss apply -Pull` | Pulls latest commits first, then applies/links configurations. |
| `pss apply -Include <list>` | Filters subsystems (`powershell`, `git`, `gemini`, `skills`, `plugins`). |
| `pss apply -Exclude <list>` | Skips specified subsystems. |
| `pss apply -WhatIf` | Dry run without modifying disk. |
| `pss diff` | Shows diffs between local machine files and repo state. |
| `pss edit [<layer>] <target>` | Opens repo file for `shared` or `<workspace>` (`powershell`, `git`, `agents`, `gemini`, `skills.json`). |
| `pss bootstrap` | Interactively harvests functions/sections from existing `$PROFILE`, `~/.gitconfig`, and `AGENTS.md`. |
| `pss workspace list` | Lists all workspaces (`*` marks active). |
| `pss workspace current` | Shows active workspace and path. |
| `pss workspace use <name>` | Sets the checkout's active workspace in local app data and re-links workspace configs (pass `-NoApply` to skip). |
| `pss workspace new <name>` | Scaffolds a new workspace under `workspaces/<name>/`. |
| `pss workspace delete <name> [-y]` | Removes an inactive workspace (`-y`/`-Yes` skips confirmation while still printing preview). |
| `pss apps [list\|install\|update]` | Manages workspace-filtered Winget packages. |
| `pss fonts` | Installs JetBrains Mono font in user scope. |
| `pss setup` | Applies Windows developer tweaks, font, and local identity setup. |
