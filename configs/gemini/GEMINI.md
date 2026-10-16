# Global Agent Guidelines & Non-Negotiables

## Safety & Git Operations
* Never push changes to a remote repository without explicit user approval.
* Follow Conventional Commits format **without scope parentheses**: `<type>: <description>` (e.g., `feat: add token refresh`).
  * Allowed types: `docs`, `refactor`, `chore`, `test`, `feat`, `fix`, `visual`.
  * Use imperative mood, lowercase type, concise description (under 72 chars), no trailing period.

## Autonomous Verification
* Autonomously run test and validation commands (e.g., `npm test`, `flutter test`, `npx tsc`, `git status`, `git diff`) to verify your work and iterate on fixes until all tests pass.
* Never run `npm run dev`, launch long-running dev servers, or initiate browser testing/screenshots unless explicitly requested.
* Execute terminal commands individually rather than chaining them with `&&` or `;`. Do not use `cd`—set the working directory parameter directly.

## Architectural Integrity & Code Hygiene
* **Pragmatic Architecture (YAGNI & KISS)**: Keep code simple, flat, and free of premature abstractions.
* **Anti-Glue Rule**: Never make edits in isolation or glue changes onto code that was never designed to hold them. If new requirements outgrow the current simple design, flag the architectural tension immediately and propose a foundational refactor plan before bolting on complex logic.
* **Code Comments**: Don't write unnecessary comments; only comment code that is non-obvious at a glance or encodes business invariants.