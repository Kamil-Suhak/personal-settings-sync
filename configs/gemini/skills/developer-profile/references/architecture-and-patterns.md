# Architecture & Design Patterns

## Core Philosophy: Pragmatic KISS & YAGNI
- **Start Simple and Flat**: Do not introduce abstractions, generic wrappers, factory classes, or inheritance hierarchies until concrete duplication or multi-variant needs demand them.
- **Minimal Indirection**: Code should read top-to-bottom where possible. Prefer shallow call stacks over multi-layered pass-throughs.
- **Composition Over Inheritance**: Compose behavior using interfaces, functions, and modules instead of extending base classes.

---

## The "No Isolated Patches / No Glue" Principle (Crucial)

> **Golden Rule**: Never glue changes onto code that was never designed to hold them.

1. **Contextual Awareness**:
   - Code that is simple and flat today may have been written that way legitimately because there was no need for abstractions at the time.
   - When a new requirement or feature outgrows that original simple design, **do not make edits in isolation** or wedge hacky condition trees into fragile functions.
2. **Re-evaluate the Foundation**:
   - When requirements outgrow the current design, step back and reconsider the architecture.
   - Restructure the foundation first so the new capability fits naturally, rather than turning clean simple code into an unmaintainable tower of patched hacks.
3. **Agent Action Protocol**:
   - **Flag architectural tension immediately**: If an edit would require awkward workarounds, state mutation creep, or bolting logic onto an inadequate structure, pause and explain why gluing the change creates technical debt.
   - Propose the foundational refactor plan before making heavy modifications.

---

## Code Quality & Idioms

- **Explicit Over Implicit**:
  - Prefer explicit parameter passing over implicit module-level shared state.
  - Model domain errors explicitly (typed errors / result types / domain exceptions) rather than catching and swallowing generic errors.
- **Pure Functions & Immutability**:
  - Favor pure functions for domain calculations and business logic.
  - Keep state transformations immutable and localized; isolate side effects (I/O, database, network) at the edges/boundaries.
- **No Unnecessary Comments**:
  - Do not write comments that restate what the code clearly does.
  - Only write comments for non-obvious design decisions, business invariants, or subtle edge cases.

