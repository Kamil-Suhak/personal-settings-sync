# Personal Settings Sync

A lightweight, zero-dependency automation system to synchronize and manage personal developer settings, application configurations, and installed software across multiple machines.

Currently configured for:
- **Applications (Winget)**: VS Code, Brave Browser, Spotify, Git, GitHub CLI, Node.js, Python (Latest)
- **Developer Fonts**: JetBrains Mono (automated download & user-scope installation, no Admin required)
- **VS Code**: `settings.json`, `keybindings.json` (and optional extension list)
- **PowerShell**: Unified `$PROFILE` across both PowerShell 7+ and Windows PowerShell 5.1 — see [POWERSHELL.md](POWERSHELL.md) for command cheatsheet
- **Windows Terminal**: `settings.json` (profiles, keybindings, JetBrains Mono font, color schemes)
- **Git**: `.gitconfig` (user identity, LFS filter, editor, default branch)
- Extensible to any application via `sync.config.json`

> [!CAUTION]
> **Public Repository Security Notice**: Never commit sensitive secrets, private credentials, or API keys (such as `id_rsa`, `.env`, tokens, or personal passwords) to this repository. Machine-specific credentials and custom aliases should always be stored in local, uncommitted files (`~/.gitconfig.local`, `~/.project-roots`, and `.profile.local.ps1`).

---

## The Best Way to Automate Settings Sync on Windows

When synchronizing settings across machines on Windows, there are two primary approaches:

| Strategy | How it Works | Pros | Considerations |
| :--- | :--- | :--- | :--- |
| **Copy-Based Sync** *(Default & Recommended)* | The script copies files between the repo and system locations (`Apply` / `Export`). | • **No Administrator or Developer Mode required**<br>• Fully safe: creates automatic timestamped `.backups/` (retains latest 10)<br>• Resilient to atomic editor file rewrites<br>• Easy side-by-side diffing before changes | Requires running `.\sync.ps1 apply` when pulling changes. |
| **Symbolic Links** *(Optional: `.\sync.ps1 link`)* | Local files become pointer links pointing directly into this repo clone. | • Edits in repo or app are instantly synchronized without running a command. | • Requires **Windows Developer Mode** or elevated Admin permissions.<br>• Some editors can sever symlinks during atomic saves. |

This repository implements **Copy-Based Sync with automated backups and diffing** by default, while also providing a built-in `link` command if you prefer symbolic links.

---

## Directory Structure

```text
personal-settings-sync/
├── configs/
│   ├── vscode/
│   │   ├── settings.json                       # VS Code user settings
│   │   ├── keybindings.json                    # (Optional) Keybindings
│   │   └── extensions.txt                      # (Optional) Installed extensions list
│   ├── powershell/
│   │   └── Microsoft.PowerShell_profile.ps1    # Unified profile for PowerShell 7+ & 5.1
│   ├── terminal/
│   │   └── settings.json                       # Windows Terminal settings
│   └── git/
│       └── .gitconfig                          # Global Git configuration (includes ~/.gitconfig.local)
├── scripts/
│   └── setup-windows.ps1                       # Windows dev tweaks, font installer & identity setup
├── .backups/                                   # Auto-generated prior backups (keeps latest 10)
├── sync.config.json                            # Declarative mapping of apps, fonts & repo files
├── winget-packages.json                        # Auto-synced Winget import/export manifest
├── sync.ps1                                    # Main PowerShell automation script
├── bootstrap.ps1                               # 1-line remote web bootstrapper for new machines
├── POWERSHELL.md                               # PowerShell profile command reference
└── README.md
```

---

## Complete New Machine Setup

### Option A: 1-Line Remote Setup (No Git or GitHub Login Required)

On a brand-new Windows PC, open Windows PowerShell (or Windows Terminal) and run:

```powershell
irm https://raw.githubusercontent.com/<YourUsername>/personal-settings-sync/main/bootstrap.ps1 | iex
```

*This automatically downloads the repository archive, applies Windows developer settings, installs the JetBrains Mono font, prompts for local Git identity and project directories, installs Winget apps, and deploys your configurations.*

### Option B: Local Setup (If already cloned)

```powershell
# 1. Apply Windows developer tweaks & install JetBrains Mono font
.\sync.ps1 setup

# 2. Install all essential applications (and fonts) in one go
.\sync.ps1 apps -Install

# 3. Deploy your personal settings to the system
.\sync.ps1 apply
```

*(Alternatively, use native Winget directly: `winget import -i winget-packages.json`)*

---

## Quick Start Workflows

### 1. Application, Font & Software Management (Winget)

```powershell
# View configured applications, package IDs, and fonts
.\sync.ps1 apps

# Install all missing applications and JetBrains Mono font
.\sync.ps1 apps -Install

# Download and install JetBrains Mono font standalone
.\sync.ps1 fonts

# Upgrade all installed software to the latest versions
.\sync.ps1 apps -Update
```

Configured packages in [`sync.config.json`](sync.config.json):
- **Visual Studio Code** (`Microsoft.VisualStudioCode`)
- **Brave Browser** (`Brave.Brave`)
- **Spotify** (`Spotify.Spotify`)
- **Git** (`Git.Git`)
- **GitHub CLI** (`GitHub.cli`)
- **Node.js (LTS)** (`OpenJS.NodeJS.LTS`)
- **Python 3 (Latest)** (`Python.Latest` - dynamically resolves newest release)
- **JetBrains Mono Font** (`JetBrains/JetBrainsMono` - automatically downloaded and installed to user fonts)

---

### 2. Primary Workflow (Edit in Repo $\rightarrow$ Push $\rightarrow$ Apply Anywhere)
1. Edit your settings directly inside the `configs/` directory.
2. Commit and push your changes to GitHub:
   ```powershell
   git commit -am "Update VS Code font and PowerShell aliases"
   git push
   ```
3. On another machine (or after pulling updates), run:
   ```powershell
   .\sync.ps1 apply -Pull
   ```
   *Fetches the latest commits from GitHub and overwrites your local machine settings with your updated repository configuration (automatically backing up the previous local versions first and keeping the 10 most recent backups).*

---

### 3. Reverse Workflow (Machine Tweaks $\rightarrow$ Update Repo $\rightarrow$ Upload)
If you made changes in your local app settings (e.g. inside VS Code settings UI) and want to save them back into the repository:
```powershell
.\sync.ps1 export
```
Or to harvest and commit/push in one command:
```powershell
.\sync.ps1 export -Push
```
*Copies the active machine files into `configs/`, synchronizes `winget-packages.json`, and commits/pushes to GitHub.*

---

### 4. Inspect Status and Differences
Check what's in sync or modified before applying:
```powershell
# View summary status table
.\sync.ps1 status

# View colored git diff between machine and repo versions
.\sync.ps1 diff
```

---

### 5. VS Code Extensions Sync (Optional)
To export your list of installed VS Code extensions to the repo:
```powershell
.\sync.ps1 export -SyncExtensions
```
To install all listed extensions on a new machine:
```powershell
.\sync.ps1 apply -SyncExtensions
```

---

## Command Reference

| Command | Description |
| :--- | :--- |
| `.\sync.ps1 status` | Shows a table comparing repo vs local files (`In Sync`, `Repo Newer`, `Machine Newer`, `Missing`). |
| `.\sync.ps1 apply` | Copies files from repo $\rightarrow$ machine (creates local backups in `.backups/`, retaining latest 10). |
| `.\sync.ps1 apply -Pull` | Runs `git pull` first, then deploys repo settings to machine. |
| `.\sync.ps1 apply -App vscode` | Applies settings only for a specific app (`vscode`, `powershell`, `terminal`, or `git`). |
| `.\sync.ps1 apply -Force` | Forces overwriting local files even when hashes already match. |
| `.\sync.ps1 apply -WhatIf` | Dry run: preview what files would be copied without touching anything. |
| `.\sync.ps1 export` | Copies files from machine $\rightarrow$ repo and syncs `winget-packages.json`. |
| `.\sync.ps1 export -Push` | Exports machine files $\rightarrow$ repo, then stages, commits, and pushes to remote if changed. |
| `.\sync.ps1 diff` | Displays unified line-by-line diff for any files that differ. |
| `.\sync.ps1 link` | Safely creates symbolic links from machine paths pointing directly to this repo (requires Developer Mode). |
| `.\sync.ps1 apps` | Lists all configured Winget packages, developer fonts, and available actions. |
| `.\sync.ps1 apps -Install` | Installs all missing software via Winget and installs the JetBrains Mono font. |
| `.\sync.ps1 apps -Update` | Upgrades all installed software to the latest versions via Winget. |
| `.\sync.ps1 fonts` | Downloads and installs the JetBrains Mono font to the user font directory (no Admin required). |
| `.\sync.ps1 setup` | Applies run-once Windows developer settings, Explorer tweaks, and installs JetBrains Mono font. |

---

## Adding More Applications & Packages

### Adding New Installed Software (Winget)
To install another application on every machine, add an entry to the `packages` list in [`sync.config.json`](sync.config.json) (running `.\sync.ps1 export` will automatically update [`winget-packages.json`](winget-packages.json)):

```json
{
  "id": "Discord.Discord",
  "name": "Discord",
  "category": "Social"
}
```

### Adding New Configuration Files
To sync settings for any other tool (e.g. SSH config, Cursor, Neovim), add an entry to `apps` in [`sync.config.json`](sync.config.json):

```json
{
  "name": "ssh",
  "displayName": "SSH Config",
  "files": [
    {
      "repoPath": "configs/ssh/config",
      "localPath": "%USERPROFILE%/.ssh/config",
      "required": false
    }
  ]
}
```

The script automatically expands `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%`, and `$DOCUMENTS` (which safely handles OneDrive Documents redirection).
