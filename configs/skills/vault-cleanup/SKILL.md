---
name: vault-cleanup
description: Proactively triage raw/ and stray notes into Obsidian wiki/, audit Cleanup Inbox.md follow-ups, execute unambiguous tasks, synthesize exploratory guides, and maintain vault hygiene. Use when the user invokes /vault-cleanup or asks to clean up, sort, or distill their Obsidian vault.
---

# Vault Cleanup & Proactive Triage Protocol

Clean, curate, and maintain the active Obsidian vault (`~/notes` for `personal`, `~/work-notes` for `rbc`) **autonomously**—minimize interviewing the user and act directly whenever intent is clear.

## Workflow

### 0. Audit `wiki/Cleanup Inbox.md`
- Read `wiki/Cleanup Inbox.md` (create it and link from `wiki/wiki.md` if missing).
- **Delete checked-off (`- [x]`) items** automatically.
- **Execute follow-up notes:** If the user added an annotation/comment under an item (e.g., *"interesting, I'd like to know more about X regarding Y"*), treat it as an instruction—research, expand, or update the target note right away, then update/re-check the inbox entry.

### 1. Triage `raw/` & Stray Files
- Run `python3 ~/.agents/skills/vault-cleanup/scripts/audit_vault.py [<vault>]` with `BypassSandbox: true` (since `~/.agents/` and `~/notes/raw/` mutations require host access) to spot `raw/` files, stray files outside `wiki/` and `raw/` (ignoring `.obsidian/`, `.git/`, `.trash/`), `_Index.md` remnants, missing `<Topic>/<Topic>.md` hubs, broken `[[wikilinks]]`, orphans, and duplicates.
- Read all `raw/` and stray files and classify each by intent:
  - **Unambiguous Action / Task** (e.g., *"install spotatui"*, *"add X to Y"*, *"cleanup unused packages"*) → **Execute directly** if safe and possible (e.g., install package, edit config, run command). If blocked (e.g., `sudo` password, missing auth), log the exact command/blocker in `BIG TODO.md` or `Cleanup Inbox.md`.
  - **Bare YouTube Links** → Resolve titles in one call with `python3 ~/.agents/skills/vault-cleanup/scripts/audit_vault.py --yt-title <url...>` (`BypassSandbox: true`).
  - **Direct Questions (`Q:` / `follow-up Q:`)** → Treat as directed at you (the agent). Write a **short, to-the-point answer** directly in `wiki/Cleanup Inbox.md` (`- [ ] **Q: ...** — <concise answer>`) rather than creating a separate `wiki/` note, so it is deleted on the next run when checked off.
  - **Calendar Event Invites** → Check conflicts first, then create directly with `gcalendar` (no need to read the full `gcalendar` skill for basic events):
    - `gcalendar readonly events --date YYYY-MM-DD --max 50 --json`
    - `gcalendar mutate create --summary "<Title>" --start YYYY-MM-DDTHH:MM:SS+01:00 --end YYYY-MM-DDTHH:MM:SS+01:00 --location "<Loc>" --send-updates none`
  - **Unsure / Exploratory Note** (e.g., *"maybe switch to Arch on WSL2?"*, *"should I use X or Y?"*) → **Proactively write a concise tradeoffs summary & practical guide** in the appropriate `wiki/` folder, link it to its parent hub, and add it to `wiki/Cleanup Inbox.md` for the user to review.
  - **Clear Reference / Idea / Spec** → Check `wiki/` for duplicates/overlap first using `audit_vault.py --headings <Folder>` (`BypassSandbox: true`) before reading full files! Merge only net-new content into existing notes when overlap is high, or create a clean structured note in `wiki/`:
    - **Project / Spec / Bug** → `wiki/Projects/<Project>/`
    - **Workset / Issue** → `wiki/Worksets/` (`rbc`) or `wiki/Projects/<repo>/` (`personal`)
    - **Writing / Blog** → `wiki/Writing/`
    - **University / Research** → `wiki/University/`
    - **Gaming / Personal** → `wiki/Gaming/` or `wiki/Personal/`
    - **Secrets / Credentials** → `wiki/Credentials/` (never display secret values in chat)
  - **Ephemeral / Stale / Duplicate** → Delete directly instead of archiving clutter.

### 2. When to Pause & Ask (Exception Only)
Only ask the user before acting when:
- A note is genuinely too vague to act on safely (e.g., a bare URL with zero context and unresolvable title).
- An action is destructive/irreversible (e.g., deleting a substantive original idea, or modifying code/configs with unclear intent).
- Interactive credentials/secrets are required.

### 3. Distill, Link & Log
- Write concise, structured markdown into `wiki/` using `<Topic>/<Topic>.md` for folder hubs (never `_Index.md`).
- Add `[[wikilinks]]` to parent projects, related notes, and the folder's hub note.
- Add every newly generated guide or substantial distillation to `wiki/Cleanup Inbox.md` (`- [ ] [[Note]] — 1-line summary`).
- Delete processed `raw/` and stray files, then re-run `audit_vault.py` to confirm zero hygiene issues.
