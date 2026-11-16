---
name: bootstrap-docs
description: Bootstrap Obsidian wiki/Projects/<repo>/ documentation for an undocumented repository by scanning its codebase, verifying facts, and interviewing the author for non-code context. Use when the user invokes /bootstrap-docs or asks to document a project into the Obsidian vault.
---

# Bootstrap Project Docs (`bootstrap-docs`)

Generate grounded, Obsidian-native project documentation in `<vault>/wiki/Projects/<repo>/`, using the active vault defined in your global `AGENTS.md` (e.g., `~/notes` on `personal`, `~/work-notes` on `rbc`).

## Constraints

- **Docs only**: Never modify source code or run `git add`/`git commit`.
- **Vault-first**: Write to `<vault>/wiki/Projects/<repo>/`, never per-repo `AGENTS.md` or nested directory `README.md`s. Use `read_file` (not sandboxed `ls`/`rg`) to check existing vault files.
- **Hub naming**: Name the main hub `<repo>/<repo>.md` (never `_Index.md`) and link it from `<vault>/wiki/Projects/Projects.md`.
- **Cross-link existing notes**: If `Projects.md` already has related notes (e.g., `SpeedQueen - *`), cross-link them from `<repo>/<repo>.md` instead of silently moving or duplicating them.
- **Zero fabrication**: Only document file paths, routes, env vars, schemas, and commands directly observed in the repo. Mark unknowns as open questions.

## Workflow

### 1. Ecosystem & Structure Discovery
- Inspect root manifests (`package.json`, `Cargo.toml`, `pyproject.toml`, `*.sln`, `wrangler.toml`, `Dockerfile`, `.env.example`, `.github/workflows/*`, etc.) to record stack, CI/CD jobs, scripts, and exact **Verification Commands** (test, lint, typecheck, build).
- Run `git branch -a` and `git log -n 15 --oneline` to surface branching conventions (e.g., `dev`-only workflows) and recent architectural fixes or workarounds. Note any commented-out framework features or defensive patterns in root configs.
- Map top-level source directories (ignoring `.git`, `node_modules`, `.next`, `dist`, `build`, `.venv`, and `.gitignore` entries) to identify entrypoints, routes/pages, data models, and external integrations.
- Check `<vault>/raw/<repo>.md` via `read_file` (if present) for existing context before drafting questions—do not edit or delete `raw/` unless asked. If the user references a prior conversation (`conversation://...`), inspect its transcript for decisions and gotchas too.

### 2. Propose Structure & Short Author Interview
Before writing vault files, present a concise proposed doc split—inspired by **Hay** (hub rollup) + **Peanuts** (focused leaf notes):
- `<repo>.md` (**Hub**): Overview, stack, verification commands, active status/rules (e.g. hand-coded vs `agy`-driven), and `[[wikilinks]]` to child notes.
- 2–4 focused child notes (only as needed, e.g. `Architecture.md`, `Routes & API.md`, `Deployment & Env.md`, `Integrations.md`).

Use the `ask_question` tool for the interview (instead of passing the turn in plain text) to ask **3–5 targeted questions** for context the code cannot tell you:
- Branching/release rules (e.g., which branch agents work on).
- The **"why"** behind unusual workarounds, static snapshots, or commented-out config blocks.
- **"Do not refactor" invariants & gotchas** (billing traps, domain-specific quirks, offline/sandbox build issues).
- Deployment/hosting quirks or active priorities/TODOs.

### 3. Write & Verify
- Write `<repo>/<repo>.md` and the agreed child notes using `[[wikilinks]]`.
- Add `<repo>` to `<vault>/wiki/Projects/Projects.md`.
- Verify every cited file path, symbol, env var, and command exists in the repository before finishing.
