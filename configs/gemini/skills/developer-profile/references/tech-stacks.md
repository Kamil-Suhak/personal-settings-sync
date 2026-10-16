# Tech Stack Context & Guidelines

Guidelines and conventions across primary technologies:

---

## 1. TypeScript & JavaScript
- **Ecosystem**: Node.js, Next.js, Cloudflare Workers.
- **Conventions**:
  - Strict TypeScript: no loose `any`, leverage discriminated unions and inferred types.
  - Workers / Edge: obey platform boundaries, use streaming when dealing with unbounded payloads, prefer Web Crypto, avoid module-level mutable request state.
  - Async hygiene: always await or explicitly manage promises (or attach background work to `ctx.waitUntil`).

---

## 2. Shell & Automation
- **Ecosystem**: PowerShell (Windows primary), Bash (POSIX).
- **Conventions**:
  - Cross-platform awareness when appropriate.
  - Execute commands individually rather than chaining with `&&` or `;`.
  - Use explicit parameter switches over positional guessing.
  - Avoid `cd` in automated steps; pass paths explicitly.

---

## 3. Python
- **Conventions**:
  - Python 3.10+ modern type hints (`def func(val: str | None) -> bool:`).
  - Use `pathlib` over raw string manipulation for file paths.
  - Flat, pragmatic module structures; avoid deeply nested package hierarchies for small utilities.

---

## 4. .NET / C# (Professional Work)
- **Conventions**:
  - Modern C# features: record types for immutable DTOs, pattern matching, nullable reference types enabled.
  - Dependency injection for services with lifecycles explicitly managed.
  - Async/await all the way down without `Result` or `Wait()` deadlocks.

---

## 5. Dart / Flutter
- **Conventions**:
  - Effective Dart: explicit typing for public APIs, const constructors wherever possible.
  - Clean state management with minimal rebuilds.

---

## 6. Rust (Hobby)
- **Conventions**:
  - Idiomatic error handling via `Result<T, E>` and `?`.
  - Avoid premature `Arc<Mutex<T>>` or unnecessary cloning; embrace borrowing and clear ownership models.

