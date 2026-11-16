---
name: vault-cleanup
description: Triage raw/ notes into Obsidian wiki/, update wikilinks and hub notes, and give honest pushback on vague or overengineered ideas. Use when the user invokes /vault-cleanup or asks to clean up, sort, or distill their Obsidian vault.
---

# Vault Cleanup & Triage Protocol

Clean, curate, and maintain the active Obsidian vault (`~/notes` for `personal`, `~/work-notes` for `rbc`).

## Workflow

### 1. Triage `raw/`
- List and read all files in `<vault>/raw/`.
- Classify each item by target destination in `wiki/`:
  - **Project / Spec / Bug** -> `wiki/Projects/<Project>/`
  - **Workset / Issue** -> `wiki/Worksets/` (`rbc`) or `wiki/Projects/<repo>/` (`personal`)
  - **Writing / Blog** -> `wiki/Writing/`
  - **University / Research** -> `wiki/University/`
  - **Gaming / Personal** -> `wiki/Gaming/` or `wiki/Personal/`
  - **Secrets / Credentials** -> `wiki/Credentials/` (never display secret values in chat)
  - **Stale / Already Done** -> flag for deletion instead of archiving clutter.

### 2. Idea Pushback & Critique
Before promoting raw ideas into `wiki/`:
- **Challenge vagueness**: Ask what problem it solves or what the MVP looks like.
- **Flag duplication**: Point out overlap with existing `wiki/` notes or repos.
- **Push back on overengineering**: Suggest simpler alternatives if a pitch adds unnecessary glue, tooling, or scope.

### 3. Distill & Link
- Write concise, structured markdown into `wiki/` using `<Topic>/<Topic>.md` for folder hubs (never `_Index.md`).
- Add `[[wikilinks]]` to parent projects, related notes, and the folder's hub note.

### 4. Vault Hygiene
- Run `python3 ~/.agents/skills/vault-cleanup/scripts/audit_vault.py [<vault>]` to scan for `raw/` files, `_Index.md` remnants, folders missing `<Topic>/<Topic>.md` hubs, broken `[[wikilinks]]`, orphan notes, and duplicate stems.
- Only delete processed `raw/` files after distilling or confirming with the user.
