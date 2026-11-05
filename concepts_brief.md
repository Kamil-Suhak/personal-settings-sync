# Workspaces: Context-Aware Modular Machine Configuration

* **Author:** Kamil-Suhak
* **Date:** 2026-11-06
* **Status:** Synthesized Concept Brief (Multi-Lens Reviewed & User Refined)

## Overview

The `personal-settings-sync` repository automates developer environment configuration across diverging environments (personal desktop vs. enterprise/corporate laptop). The **Workspaces** architecture introduces context modularity by partitioning configurations into a **shared baseline** plus **named workspace contexts** (`personal`, `work`, `school`).

Each machine binds locally to a single active workspace via an untracked `.workspace.local` file. Settings synchronization supports granular subsystem filtering (`-Include`, `-Exclude`).

For structured JSON configurations lacking native include primitives (VS Code `settings.json`, Windows Terminal `settings.json`), configurations employ a **Layered Files Model**:
- Baseline: `configs/vscode/settings.shared.json`
- Overrides: `workspaces/<name>/vscode/settings.json`

On `apply`, these layers are merged into the target system path with recursive deep-merge semantics (targeting PowerShell 7+ natively). On `export`, an interactive namespace-grouped terminal picker prompts the user to route new, modified, or deleted keys to either the shared baseline or the workspace override.

The CLI entrypoint is hard-renamed to `pss.ps1` (Personal Settings Sync) with a global profile function `pss`, while the profile's git sync helper `sync` is hard-renamed to `gsync` to eliminate function-script namespace collisions. No legacy deprecation shims are retained.

## Analysis

### 1. Refined Design Points & Decisions

1. **Hard Rename (No Shims):**
   - The repository CLI script `sync.ps1` is deleted and replaced by `pss.ps1`.
   - In `Microsoft.PowerShell_profile.ps1`, `function sync` is renamed directly to `function gsync`.
   - A global `function pss` is added to the profile to allow invoking the CLI from any path.
2. **Pragmatic Script Architecture (KISS / YAGNI):**
   - Over-engineered library decomposition (e.g., splitting into multiple micro-files like `JsonLayer.ps1`, `Workspace.ps1`) is rejected.
   - PowerShell 7+ allows implementing recursive dictionary deep-merging, local workspace state resolution, and JSON operations in concise, idiomatic functions (~15-20 lines) directly within `pss.ps1` or a single helper if needed.
3. **Deep Merge vs. Shallow Merge Mechanism:**
   - *Example:* In shared settings, `files.exclude` specifies `{ "**/.git": true, "**/.svn": true }`. On a work machine, a user also wants to hide `**/build`.
   - *Shallow Merge Failure:* Overwriting the entire `files.exclude` property with the work object removes `**/.git` and `**/.svn`.
   - *Deep Merge Behavior:* Recursively traverses nested dictionaries, merging child keys so the resulting object contains `**/.git`, `**/.svn`, and `**/build`.
4. **PowerShell 7+ Native Standard:**
   - Windows PowerShell 5.1 backwards compatibility is explicitly dropped.
   - Code targets modern PowerShell 7+ (`ConvertFrom-Json -AsHashtable`, native UTF-8 handling, clean language constructs).
5. **Synthesis-Aware Status and Diff:**
   - `pss.ps1 status` and `pss.ps1 diff` evaluate against the in-memory effective state (`shared` + active `workspace`) rather than comparing directly against shared files, preventing false-positive dirty states.
6. **Reconciliation for Deleted Settings:**
   - Property diffing during `export` tracks deleted keys and prompts the user to either remove them from the repository layer (`[D]`) or restore them from the repository (`[R]`).
7. **Secret Isolation:**
   - Workspace Git identities use scoped `.gitconfig` files per workspace (`workspaces/<name>/git/.gitconfig`).
   - `.workspace.private.json` is registered in `.gitignore` for machine-local secrets.
8. **Headless & Non-Interactive Safety:**
   - Detects `[Console]::IsInputRedirected`.
   - Halts immediately with exit code 1 if `.workspace.local` is missing in non-interactive sessions.
   - Requires explicit `-Target Shared` or `-Target Workspace` on `export` when non-interactive.

## Goals vs. Non-Goals

### In-Scope Goals
* **Modular Configuration Layout:** Shared configs in `configs/`, named workspace overrides in `workspaces/<name>/`.
* **Layered File Engine:** Pure recursive deep-merge for JSON targets (`apply`, `status`, `diff`).
* **Synthesis-Aware Comparison:** `status` and `diff` compare local state against the computed union of `shared + active_workspace`.
* **Interactive Terminal Reconciliation:** Namespace-grouped property picker for added, modified, and deleted settings during `export`.
* **Deterministic Machine Binding:** Untracked `.workspace.local` stores active workspace name without environment sniffing.
* **CLI Contract & Disambiguation:**
  - `pss.ps1` main entrypoint (hard rename).
  - Profile `sync` renamed directly to `gsync`, profile `pss` wrapper added.
  - Parameter validation: `-Include`, `-Exclude` with validated set (`vscode`, `powershell`, `terminal`, `git`, `skills`, `plugins`, `apps`, `fonts`).
  - Flag normalization: maps `--force`, `--include` with an informational note.
* **Modern PowerShell 7+ Target:** Clean, unencumbered by PS 5.1 workarounds.

### Out-of-Scope Non-Goals
* **Windows PowerShell 5.1 Support:** No legacy engine compatibility.
* **Legacy Forwarding Shims:** Clean hard rename without lingering aliases.
* **Automatic Environment Heuristics:** No detection via hostnames, domain membership, or environment variables.
* **Multi-Parent Inheritance Chains:** Strictly single-tier inheritance (`shared` + active workspace).
* **Plaintext Corporate Secret Storage:** No committing enterprise tokens to Git.

## Alternatives Weighed

### Alternative 1: Micro-File Library Decomposition (`scripts/lib/Workspace.ps1`, etc.)
* **Description:** Breaking the script into 3-4 separate utility files for workspace, json, and terminal prompts.
* **Rejection Reason:** Violates KISS and YAGNI. In PowerShell 7, recursive hashtable merging and `.workspace.local` handling take under 30 lines of code. Scattering them across micro-libraries adds indirection without modular benefit.

### Alternative 2: In-File Section Comments (`// === SECTION ===`)
* **Description:** Embedding delimiter comments inside a single `settings.json` file.
* **Rejection Reason:** VS Code GUI settings editor strips or rearranges comments, destroying section markers.

### Alternative 3: Retaining Forwarding Shims for `sync.ps1` and profile `sync`
* **Description:** Keeping `sync.ps1` as a wrapper and profile `sync` as a dual-purpose transition function.
* **Rejection Reason:** Leaves technical debt and ambiguity. Hard rename establishes clean separation immediately.

## Key Decisions & Staging for Next Steps

1. **Repository Layout:**
   ```text
   personal-settings-sync/
   ├── pss.ps1                                    # Primary unified CLI entrypoint (replaces sync.ps1)
   ├── sync.config.json                           # Subsystem metadata and packages
   ├── .workspace.local                           # Local active workspace name (git-ignored)
   ├── configs/                                   # Shared baseline configuration
   │   ├── vscode/settings.shared.json
   │   ├── terminal/settings.shared.json
   │   ├── git/.gitconfig.shared
   │   └── powershell/Microsoft.PowerShell_profile.ps1
   └── workspaces/                                # Named workspace context overrides
       ├── personal/
       │   ├── vscode/settings.json
       │   └── git/.gitconfig
       └── work/
           ├── vscode/settings.json
           └── git/.gitconfig
   ```

2. **Execution Flow Plan:**
   - **Phase 1: CLI Entrypoint & Profile Update:** Hard-rename `sync.ps1` to `pss.ps1`. In `Microsoft.PowerShell_profile.ps1`, hard-rename `sync` to `gsync` and add `pss` wrapper.
   - **Phase 2: Layered Files Engine & Synthesis:** Rename `configs/vscode/settings.json` to `settings.shared.json`. Implement PS7 native recursive deep merge and synthesis in `apply`, `status`, and `diff`.
   - **Phase 3: Interactive Reconciliation & CLI Polish:** Implement namespace-grouped property picker with deletion support, non-interactive fail-fast guards, and subsystem `-Include`/`-Exclude` validation.
