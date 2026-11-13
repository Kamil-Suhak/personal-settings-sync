# Personal Settings Sync (PSS)

A lean, repo-as-source-of-truth developer environment manager across **Workspaces** (`personal`, `work`, or custom contexts) for **PowerShell**, **Git**, and **AI Agent Rules/Skills/Plugins**.

## Core Philosophy

Instead of copying configs back and forth and trying to reverse-engineer edits into layers, **the repository is always the source of truth**:

- **PowerShell**: `$PROFILE` is a tiny managed loader stub dot-sourcing [`configs/powershell/Microsoft.PowerShell_profile.ps1`](configs/powershell/Microsoft.PowerShell_profile.ps1), which dynamically loads `workspaces/<active>/powershell/profile.ps1` and untracked `~/.profile.local.ps1`.
- **Git**: `~/.gitconfig` uses native `[include]` directives pointing directly to [`configs/git/.gitconfig.shared`](configs/git/.gitconfig.shared) and `workspaces/<active>/git/.gitconfig`, preserving local credentials and machine overrides.
- **AI Skills & Plugins**: Per-item Windows directory junctions (`~/.agents/skills/<name>` and `~/.gemini/config/plugins/<name>`) link directly into `configs/` without touching third-party skills/plugins, plus `~/.gemini/skills` $\rightarrow$ `~/.agents/skills`.
- **AI Agent Rules (`AGENTS.md`, `GEMINI.md`)**: One-way concatenation of `configs/gemini/` + `workspaces/<active>/gemini/`, plus `~` expansion for `skills.json`.
- **One-Time Machine Onboarding**: `pss bootstrap` parses existing standalone `$PROFILE` (via PowerShell AST), `~/.gitconfig`, and `AGENTS.md` to help route functions and sections into `Shared`, `Workspace`, or `Local`.

> [!CAUTION]
> **Public Repository Security Notice**: Never commit sensitive secrets, private credentials, or enterprise tokens. Store machine-local secrets in untracked files (`~/.profile.local.ps1`, `~/.gitconfig`, `~/.project-roots`, `.workspace.local`).

---

## Directory Structure

```text
personal-settings-sync/
├── pss.ps1                                    # Unified CLI (status, apply/link, diff, edit, bootstrap, workspace, apps)
├── bootstrap.ps1                              # One-line remote machine bootstrapper
├── setup.ps1                                  # Compatibility wrapper delegating to bootstrap.ps1
├── sync.config.json                           # Declarative subsystem & workspace-scoped Winget packages
├── .workspace.local                           # Active workspace name for this machine (git-ignored)
├── configs/                                   # Shared baseline (all machines)
│   ├── powershell/
│   │   └── Microsoft.PowerShell_profile.ps1   # Core PowerShell profile & shared helpers (see POWERSHELL.md)
│   ├── git/
│   │   └── .gitconfig.shared                  # Shared Git defaults
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
│       ├── powershell/profile.ps1             # Work additions (Carbon Black git bypass, copilot -p ask, slnclean, azwho)
│       ├── git/.gitconfig                     # Work git identity & large-repo tuning
│       └── gemini/AGENTS.md                   # Work AI compliance & stack context
├── scripts/
│   └── setup-windows.ps1                      # Windows Explorer tweaks, JetBrains Mono font & local identity setup
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
| `pss workspace use <name>` | Sets active workspace in `.workspace.local` and re-links workspace configs (pass `-NoApply` to skip). |
| `pss workspace new <name>` | Scaffolds a new workspace under `workspaces/<name>/`. |
| `pss workspace delete <name>` | Removes an inactive workspace. |
| `pss apps [list\|install\|update]` | Manages workspace-filtered Winget packages. |
| `pss fonts` | Installs JetBrains Mono font in user scope. |
| `pss setup` | Applies Windows developer tweaks, font, and local identity setup. |
