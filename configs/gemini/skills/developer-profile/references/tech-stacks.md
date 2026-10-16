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

### Custom PowerShell Profile Functions (`$PROFILE`)
The agent shell runs in `pwsh` and loads the developer's PowerShell profile functions:
- **`killport <port>`**: Safe to use. Kills whatever process is occupying a local port (e.g., `killport 3000`, `killport 8080`).
- **`cmp <file1> <file2>`**: Safe to use. Compares SHA-256 hashes of two files to verify whether they are identical.
- **`which <command>`**: Safe to use. Prints the full path of an executable or cmdlet.
- **`p <project>` (Project Jumper) & `..`**: **Do NOT use for agent navigation**.
  - `p` calls `Set-Location` internally. Because each agent command runs in an independent subshell process, directory changes do not persist to subsequent tool calls.
  - The agent MUST always set the working directory via the `Cwd` parameter on the tool call directly.
  - If the agent needs to find where a project lives, query `~/.project-roots` to discover its path and pass that path as `Cwd`.
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

