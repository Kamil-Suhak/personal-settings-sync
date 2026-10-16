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
- **Ecosystem**: PowerShell 7+ (`pwsh` on Windows), Bash (POSIX).
- **Conventions**:
  - Chained commands using `&&` (logical AND), `||` (logical OR), and `;` (sequential) are fully supported in `pwsh`.
  - Prefer `&&` over `;` when chaining commands that depend on prior success (e.g., `cd <dir> && git status`).
  - `cd` and `p <project>` inside a chained command work for that execution (e.g., `p sync && npm test`).
  - Standalone `cd` in isolation does not affect subsequent tool calls (since each tool call spawns an independent subshell). For persistent workspace scoping, set `Cwd` directly.
  - Use explicit parameter switches over positional guessing.

### Custom PowerShell Profile Functions (`$PROFILE`)
The agent shell runs in `pwsh` and loads the developer's PowerShell profile functions:
- **`p <project>` (Project Jumper)**: Supported in chained commands (e.g., `p sync && git status`). Jumps dynamically across configured project roots (`~/.project-roots`).
- **`killport <port>`**: Safe to use. Kills whatever process is occupying a local port (e.g., `killport 3000`, `killport 8080`).
- **`cmp <file1> <file2>`**: Safe to use. Compares SHA-256 hashes of two files to verify whether they are identical.
- **`which <command>`**: Safe to use. Prints the full path of an executable or cmdlet.
- **`push`**: **Do NOT use**. Bypasses review and pushes to remote, violating the safety rule against pushing without explicit approval.
- **`find`**: **Do NOT use**. Uses interactive `Read-Host` prompts; use native file tools instead.

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

