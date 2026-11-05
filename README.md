# Personal Settings Sync (PSS)

A modular, context-aware automation system to synchronize and manage personal developer settings, application configurations, and installed software across multiple machines using **Workspaces** (`personal`, `work`, `school`).

Currently configured for:
- **Modular Workspaces**: Separate machine profiles (e.g. personal desktop vs. company laptop) sharing a common baseline.
- **Applications (Winget)**: VS Code, Brave Browser, Spotify, Git, GitHub CLI, Node.js, Python (Latest).
- **Developer Fonts**: JetBrains Mono (automated download & user-scope installation, no Admin required).
- **VS Code**: Layered `settings.shared.json` + workspace `settings.json` (recursive deep-merge), `keybindings.json`, and extension lists.
- **PowerShell**: Unified `$PROFILE` with git shortcuts (`gsync`, `commit`, `amend`) and `pss` CLI runner — see [POWERSHELL.md](POWERSHELL.md) for cheatsheet.
- **Windows Terminal**: Layered `settings.shared.json` + workspace overrides (profiles, keybindings, JetBrains Mono font, color schemes).
- **Git**: Global `.gitconfig.shared` combined with workspace-scoped identities (`~/.gitconfig.workspace`).
- **AI Coding Agents**: Global rules (`AGENTS.md`, `GEMINI.md`), curated skills (`developer-profile`, `repo-intro`, `ask`, `ux`, `readme`), and Antigravity plugins (`egm` - Elephant-Goldfish Model).
- Extensible to any application via `sync.config.json`.

> [!CAUTION]
> **Public Repository Security Notice**: Never commit sensitive secrets, private credentials, or enterprise tokens to this repository. Machine-specific credentials and custom aliases should always be stored in local, uncommitted files (`.workspace.local`, `.workspace.private.json`, `~/.gitconfig`, `~/.project-roots`, and `.profile.local.ps1`).

---

## Directory Structure

```text
personal-settings-sync/
├── pss.ps1                                    # Main unified PowerShell automation script
├── sync.config.json                           # Declarative mapping of apps, workspaces & subsystems
├── .workspace.local                           # Active workspace name for this machine (git-ignored)
├── configs/                                   # Shared baseline configurations (all machines)
│   ├── vscode/
│   │   ├── settings.shared.json               # Shared VS Code settings baseline
│   │   ├── keybindings.json                   # Shared keybindings
│   │   └── extensions.txt                     # Installed extensions list
│   ├── powershell/
│   │   └── Microsoft.PowerShell_profile.ps1   # Core PowerShell profile (contains pss & gsync)
│   ├── terminal/
│   │   └── settings.shared.json               # Shared Windows Terminal baseline
│   ├── git/
│   │   └── .gitconfig.shared                  # Universal Git configuration (included by ~/.gitconfig)
│   ├── gemini/                                # AI agent rules (~/.gemini/)
│   ├── skills/                                # Agent-agnostic skills (~/.agents/skills/)
│   └── plugins/                               # Antigravity plugins (~/.gemini/config/plugins/)
├── workspaces/                                # Context-specific workspace overrides
│   ├── personal/
│   │   ├── vscode/settings.json               # Personal VS Code overrides
│   │   ├── powershell/profile.ps1             # Personal shell additions (~/.profile.local.ps1)
│   │   └── git/.gitconfig                     # Personal user identity (~/.gitconfig.workspace)
│   └── work/
│       ├── vscode/settings.json               # Work-specific overrides (proxy, formatting)
│       ├── powershell/profile.ps1             # Corporate VPN/proxy environment scripts
│       └── git/.gitconfig                     # Corporate user identity (work email)
├── scripts/
│   └── setup-windows.ps1                      # Windows dev tweaks, font installer & identity setup
├── .backups/                                  # Auto-generated prior backups (keeps latest 10)
├── winget-packages.json                       # Winget import/export manifest
├── POWERSHELL.md                              # PowerShell profile command reference
└── README.md
```

---

## Quick Start Workflows

Once cloned, you can run `.\pss.ps1` from the repository root, or simply type `pss` from any folder once your profile is loaded.

### 1. Workspace Management
```powershell
# View all available workspaces (* marks active)
pss workspace list

# View current active workspace
pss workspace current

# Switch this machine to a workspace (persisted in .workspace.local)
pss workspace use work

# Create a new workspace context directory structure
pss workspace new school
```

### 2. Inspecting Status & Differences
```powershell
# Compare machine settings against synthesized state (shared + active workspace)
pss status

# View property-level diff for VS Code
pss diff -Include vscode

# View diff for all modified subsystems
pss diff
```

### 3. Deploying Settings (Repo $\rightarrow$ Machine)
```powershell
# Deploy all configurations
pss apply

# Fetch latest git commits first, then deploy
pss apply -Pull

# Deploy only specific subsystems
pss apply -Include vscode,powershell

# Exclude applications and skills
pss apply -Exclude apps,skills

# Preview changes without modifying disk
pss apply -WhatIf
```

### 4. Harvesting Machine Changes (Machine $\rightarrow$ Repo)
```powershell
# Interactive export: prompts namespace by namespace to route changes to Shared or Workspace
pss export

# Non-interactive export routed strictly to active workspace
pss export -Target Workspace

# Export and push directly to GitHub
pss export -Target Workspace -Push
```

### 5. Application & Font Management (Winget)
```powershell
# List configured Winget applications
pss apps

# Install all missing applications and JetBrains Mono font
pss apps install

# Upgrade all installed software
pss apps update

# Install developer font standalone
pss fonts
```

---

## Command Reference

| Command | Description |
| :--- | :--- |
| `pss status` | Shows sync matrix across subsystems evaluated against active workspace synthesis. |
| `pss apply` | Deep-merges and deploys repo configurations to local machine (creates `.backups/`). |
| `pss apply -Pull` | Pulls latest git commits first, then deploys settings. |
| `pss apply -Include <list>` | Targets specific subsystems (`vscode`, `powershell`, `terminal`, `git`, `gemini`, `skills`, `plugins`, `apps`, `fonts`). |
| `pss apply -Exclude <list>` | Skips specific subsystems. |
| `pss apply -WhatIf` | Dry run: preview file writes without touching filesystem. |
| `pss export` | Compares machine files against repo and interactively routes changes to `Shared` or `Workspace`. |
| `pss export -Target <layer>` | Non-interactive export routing all changes to `Shared` or `Workspace`. |
| `pss export -Push` | Harvests machine changes, verifies git credentials, commits, and pushes to remote. |
| `pss diff` | Shows property diffs for structured JSON and unified diffs for flat files. |
| `pss workspace list` | Lists all workspaces and marks current active workspace. |
| `pss workspace use <name>` | Sets active workspace in `.workspace.local`. |
| `pss workspace new <name>` | Creates template directory structure for a new workspace. |
| `pss workspace delete <name>` | Deletes an inactive workspace. |
| `pss apps install` | Installs configured software via Winget and installs JetBrains Mono font. |
| `pss apps update` | Upgrades installed software via Winget. |
| `pss fonts` | Downloads and installs JetBrains Mono font to user directory. |
| `pss setup` | Applies Windows developer settings and Explorer tweaks. |
| `pss help` | Displays full syntax, command descriptions, and examples. |
