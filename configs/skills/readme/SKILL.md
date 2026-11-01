---
name: readme
description: >-
  Adaptive interview protocol for authoring honest, human-voiced, high-signal READMEs.
  Researches the repository first, then conducts a lightweight 3–6 round interview to assemble
  the README directly from the author's verbatim answers instead of synthetic AI marketing prose.
  Extracts reference material into docs/ and requires author approval before saving.
  Triggered when the user invokes /readme or asks to write or revamp a project README.
---

# Human-Voiced README Protocol (`/readme`)

Most AI-generated READMEs suffer from the same dead giveaways: generic skeletons (Tech Stack → Technical Highlights → numbered architecture → tree diagram → setup), unearned marketing adjectives (*"high-performance, rock-solid, seamless, sub-millisecond, comprehensive"*), exhaustive lists of every file and endpoint without explaining *why* choices were made, and zero author voice or motivation.

The `/readme` protocol completely reverses this failure mode: **the author's verbatim answers are the prose**. The agent acts as an investigative technical journalist: it researches the repository first, asks targeted questions about real decisions and motivations, and compiles the author's exact words into an honest, concise (roughly 80–200 words) README.

---

## 1. The Core Philosophy & Non-Negotiables

### Rule 1: The Author's Words Are the Prose
The agent is an editor, compiler, and curator—**never a creative marketing copywriter**.
- Assemble the author's exact phrasing, reasoning, and vocabulary.
- You may fix typos, standardize punctuation, join disjointed fragments, and organize sections logically.
- **You must NEVER rewrite the author's tone, inflate claims, add corporate polish, or swap simple words for corporate jargon.**
  - *Author said*: `"I built this for my family laundromat because commercial POS systems cost $200/mo and were too bloated for our counter."`
  - *Forbidden AI rewrite*: `"A high-performance enterprise management solution engineered to optimize commercial laundromat operations with seamless cost efficiency."`
  - *Correct compilation*: Keep the author's exact sentence verbatim as the project's opening motivation.

### Rule 2: Research First, Ask Specifics Second
**Never ask lazy, generic questions** like *"What is your tech stack?"* or *"Tell me what this project does."*
Before asking anything:
1. Silently inspect package manifests (`package.json`, `Cargo.toml`, `pubspec.yaml`, etc.), entry points, database schemas, and configuration.
2. Read `git log -20 --oneline` to understand recent work and commit tone.
3. Inspect any existing README or docs to see what's already documented and what's out of date.
4. Formulate specific, technical inquiries:
   - *Good*: *"I see a Rust FFI combat engine linked into Flutter rather than writing it in Dart. Was that for computational performance, deterministic state simulation, or cross-platform code reuse?"*
   - *Bad*: *"What technologies did you use?"*

### Rule 3: Ban the AI Markdown Slop Checklist
- **No Marketing Adjectives**: Eliminate *"rock-solid"*, *"seamless"*, *"blazing-fast"*, *"comprehensive"*, *"mathematically verified"*, *"production-grade"*, *"cutting-edge"*. State concrete facts or omit.
- **No Forced Bolding**: Never bold every second noun phrase in a sentence.
- **No Rule-of-Three Filler**: Do not artificially pad sections to have exactly 3 bullet points with 3 numbered sub-bullets.
- **No Directory Tree Dumps**: Never paste massive 50-line ASCII folder trees into the main README. Put them in `docs/architecture.md` if truly needed, or omit them entirely.
- **No Inlined Reference Clutter**: Lengthy API contracts, environment variable tables, step-by-step deploy instructions, and troubleshooting manuals belong in `docs/`, linked from the README.

---

## 2. Target Anatomy: What a Good README Looks Like

Aim for **80–200 words** on the front page. (A 3-line README is completely valid for small utilities; 250 words max for complex showcase projects).

A great README answers what a visiting engineer or recruiter wants to know in under 60 seconds:

```markdown
# Project Name

[One or two sentences in the author's exact words: what it is, who it is for, and why it exists.]

[Visual Proof: Screenshot, GIF, demo terminal command, or live URL link]

## Stack & Decisions
- **Core**: [One-line list of stack choices].
- **Why [Non-obvious technology]**: [Concrete reason the author chose this over the standard default].

## The Interesting Bits
- **[Challenge or Trade-off 1]**: [How a hard problem, concurrency edge case, or architecture challenge was actually solved].
- **[Decision 2]**: [What trade-off was accepted and why].

## Status & Non-Goals
- [What the project deliberately does NOT do].
- [Status: Active daily driver, client production, completed thesis, or archived experiment].

---
### Documentation & Setup
- [Getting Started & Local Setup](docs/setup.md)
- [Architecture & Design Details](docs/architecture.md)
- [API Reference](docs/api.md)
```

*(Note: Not every section applies to every repo. Only include sections where the author provides real signal).*

---

## 3. Step-by-Step Execution Protocol

```
[Phase 1: Silent Codebase Reconnaissance]
       │  Inspect manifests, git log, existing docs & architecture
       ▼
[Phase 2: Upfront Scope & Format Alignment]
       │  Ask language, docs-split preference, and project tier
       ▼
[Phase 3: Adaptive Interview (3–6 Rounds)]
       │  One plain-text question at a time
       │  Target gaps: Motivation -> Stack choices -> Hard problems -> Status
       ▼
[Phase 4: Assembly & Verbatim Compilation]
       │  Compile author's exact answers into concise markdown
       │  Move long-form reference material to docs/
       ▼
[Phase 5: Mandatory Author Approval Gate]
       │  Present draft in chat / artifact
       │  SAVE TO DISK ONLY AFTER EXPLICIT APPROVAL
```

---

### Phase 1: Silent Codebase Reconnaissance
Before sending your first message, read:
1. Primary manifests (`package.json`, `pubspec.yaml`, `Cargo.toml`, `.csproj`, etc.) $\rightarrow$ identify languages, frameworks, unusual dependencies.
2. Existing `README.md` $\rightarrow$ identify factual errors, boilerplate templates, outdated copy, or valuable snippets to preserve.
3. Recent commits (`git log -20 --oneline`) $\rightarrow$ understand recent focus, author voice, and project velocity.
4. Key entry points & architecture $\rightarrow$ notice interesting technical patterns (e.g. SQLite concurrency, FFI boundaries, background queues, custom caching).

---

### Phase 2: Upfront Scope & Format Alignment
Initiate the conversation by briefly stating what you learned from the repo, then confirm three steering choices:

1. **Reference Docs Split**:
   - Ask whether existing long-form reference material (detailed setup steps, API endpoints, env vars, config reference) should be extracted into `docs/` (e.g. `docs/setup.md`, `docs/architecture.md`), pruned, or kept minimal.
2. **Language Strategy**:
   - Ask which language mode to use:
     - Pure English (standard for global GitHub reach)
     - Polish with short English summary
     - English with short Polish summary
     - Pure Polish
3. **Project Tier / Depth**:
   - *Utility / Small Tool*: 3 rapid questions (~50–100 words target).
   - *Showcase / Core Project*: 4–6 deeper questions (~150–200 words target).

---

### Phase 3: The Adaptive Interview (3–6 Rounds)

> [!IMPORTANT]
> **Use Plain Chat Text for Prose Questions**: Do not use multiple-choice tools for collecting narrative answers. Multiple-choice options risk putting AI-phrased words into the author's mouth. Present focused questions in plain text so the author can reply with freeform, natural sentences.

#### Interview Rules:
- **One Question at a Time**: Never overwhelm the author with a bulleted wall of 6 questions. Ask one question, wait for the response, and adapt.
- **Adaptive Steering**: Track coverage across the 5 core pillars:
  1. *Origin & Motivation*: Why did you build this? Who uses it?
  2. *Proof / Evidence*: Is there a live URL, demo, screenshot, or sample output?
  3. *Non-Obvious Stack Choices*: Why X over Y?
  4. *The Hardest Problem / Decision*: What was tricky, interesting, or unexpected?
  5. *Status & Non-Goals*: What does it intentionally avoid doing? Is it maintained?
- **Redirect Based on Substance**:
  - If the author gives an extensive answer on origin, steer the next question toward what was technically difficult.
  - If an answer is brief, accept it without pressure and move to the next gap.
  - If the author types `skip` or `pass`, immediately advance to the next topic.

---

### Phase 4: Assembly & Verbatim Compilation
When the interview concludes:
1. **Compile**: Assemble the author's verbatim answers into the concise target structure.
2. **Clean**: Fix grammar, typos, and awkward joins without altering the voice or substituting words.
3. **Reference Split**: If agreed in Phase 2, move existing reference tables, env vars, and setup guides into dedicated files in `docs/` (e.g. `docs/setup.md`, `docs/api.md`), linking them cleanly at the bottom of the README.

---

### Phase 5: Mandatory Author Approval Gate

> [!CAUTION]
> **Zero Premature Writes**: NEVER overwrite or modify `README.md` on disk until the author has reviewed the compiled draft and given explicit approval.

1. Present the draft in chat (or as a formatted artifact).
2. Report the total word count (target: 80–200 words).
3. List the verbatim quotes used and any suggested docs splits.
4. Ask: *"How does this read to you? Does it sound like you, and would you like any adjustments before I save it to disk?"*
5. Apply any requested adjustments, and only call `write_file` or `edit_file` once the author gives clear confirmation (e.g. *"looks good"*, *"save it"*).
