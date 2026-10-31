---
name: developer-profile
description: >-
  Provides deep context on the developer's engineering preferences, architectural
  principles (YAGNI/KISS, the no-isolated-patch/anti-glue rule), tech stacks, and
  collaboration style. Use when designing features, refactoring existing code,
  making architectural decisions, or reviewing engineering practices.
---

# Developer Profile & Engineering Philosophy

This skill encapsulates the developer's architectural philosophy, coding standards, and engineering expectations. Consult this guide when designing features, considering refactors, or writing non-trivial logic.

---

## Quick Reference Summary

1. **Pragmatic Architecture (KISS & YAGNI)**:
   - Prefer flat, simple structures over deep abstraction hierarchies.
   - Do not add layers or patterns until concrete duplication or multi-variant needs demand them.
2. **The "No Isolated Patches / No Glue" Rule (Crucial)**:
   - Code written simply is valid, but when a new feature causes it to outgrow its original design, **never glue changes onto code that wasn't built to hold them**.
   - If an edit requires hacky workarounds or compromises the foundation, **flag the tension immediately** and propose restructuring the foundation before implementing the feature.
3. **Commit Formatting**:
   - Format: `<type>: <description>` (no scope parentheses, lowercase, imperative, under 72 chars).
   - Valid types: `docs`, `refactor`, `chore`, `test`, `feat`, `fix`, `visual`.
4. **Code Quality**:
   - Prefer pure functions, explicit parameter passing, and typed domain errors over implicit state or unhandled exceptions.
   - Do not write redundant comments; only document non-obvious logic and invariants.

---

## Detailed References

For deeper context during specific tasks, consult the modular references:

| Reference | When to Consult |
| :--- | :--- |
| [Architecture & Design Patterns](references/architecture-and-patterns.md) | Designing new modules, refactoring, evaluating KISS/YAGNI trade-offs, and handling structural tension |
| [Tech Stacks & Language Conventions](references/tech-stacks.md) | Language-specific idioms for TypeScript, .NET, Python, Flutter, Shell, and Rust |
| [Collaboration & Workflow Style](references/collaboration-style.md) | Agent persona expectations, verification autonomy, and git commit practices |

