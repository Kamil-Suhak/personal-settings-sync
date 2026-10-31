---
name: repo-intro
description: >-
  Systematic, token-efficient repository onboarding protocol for an agent starting
  from an empty context window or unfamiliar codebase. Use when the user asks to
  familiarize with the repo, explore the project, get up to speed, or when starting
  work on an unfamiliar codebase.
---

# Repository Onboarding Protocol (`repo-intro`)

Use this protocol to systematically map and understand an unfamiliar repository without blowing up the context window.

## Guiding Principles
- **Passive read-only inspection**: Do NOT run test suites, dev servers, or build commands during onboarding unless explicitly requested.
- **Token efficiency**: Avoid reading large files in full; inspect directories at top levels first, and read manifests/documentation selectively.
- **Silent priming, brief delivery**: Prime your internal mental model, then output only a concise 2-3 bullet readiness summary to the user.

---

## Step-by-Step Procedure

### 1. Root & Directory Structure Discovery
Inspect top-level files and directories to understand the general shape of the project.
- List root directory entries, ignoring heavy build/cache folders (`node_modules`, `.git`, `bin`, `obj`, `target`, `dist`, `.next`, etc.).
- Identify the repository layout pattern (e.g., mono-repo vs single package, `src/` layout, `cmd/`, `app/`, `packages/`).

### 2. Manifest & Tooling Detection
Locate project manifests to identify the runtime, language, package manager, and available commands:
- **Node / JS / TS**: Inspect `package.json` (`scripts` block, dependencies, package manager).
- **Python**: Check `pyproject.toml`, `requirements.txt`, `Pipfile`, or `setup.py`.
- **.NET**: Check `*.sln`, `*.csproj`, `Directory.Build.props`.
- **Rust**: Check `Cargo.toml`.
- **Dart / Flutter**: Check `pubspec.yaml`.
- **Go**: Check `go.mod`.
- Note down the primary **test**, **lint**, **typecheck**, and **build** commands for future autonomous verification.

### 3. Documentation & Architecture Review
Read documentation entry points to understand the project's purpose and architecture:
- Read `README.md` (intro, setup, and architecture sections).
- Check for `ARCHITECTURE.md`, `CONTRIBUTING.md`, or a `docs/` folder.
- Note any critical environment variables (`.env.example`, `.env.template`).

### 4. Git State & Working Baseline
Establish the current version control baseline:
- Check current branch and uncommitted changes: `git status --short`.
- Inspect recent commits to observe project conventions and tone: `git log -n 5 --oneline`.

### 5. Conventions & Rules Discovery
Look for project-specific rules and linter configurations:
- Check for project-level `AGENTS.md`, `GEMINI.md`, or `.agents/rules/`.
- Check linter and formatter configs (`biome.json`, `.eslintrc*`, `ruff.toml`, `.editorconfig`, `tsconfig.json`).

---

## Output Format

Once the inspection steps are complete, respond to the user with a **concise 2 to 3 bullet readiness summary**:
- **Stack & Architecture**: Primary language/framework and repository structure (e.g., *TypeScript / Next.js app with flat service modules*).
- **Core Commands**: Identified verification commands (e.g., *Tests: `npm test`, Lint: `npm run lint`*).
- **Status / Next Steps**: Current branch, uncommitted changes (if any), and readiness to take on the first task.

