# Global Agent Guidelines

* **Git**: Use Conventional Commits without scope parens: `<type>: <description>` (`feat|fix|docs|refactor|chore|test|visual|ci|perf|build`, lowercase, imperative, max 72 chars, no trailing period). Never run `git push` without explicit approval.
* **No Inline Eval Blobs**: Never execute multi-line or complex inline scripts via `node -e`, `python -c`, `bash -c`, or nested `powershell`/`pwsh -Command`.
* **Archives & Binaries (`.docx`, `.xlsx`, `.zip`, `.sqlite`, `.pdf`)**: Use standard CLI tools (`tar`, `python -m zipfile`); if custom logic is needed, use `write_file` in your conversation `scratch/` directory and execute the script file.
* **Verification**: Run relevant tests, typechecks, and `git status`/`git diff`, iterating until checks pass. Never run `npm run dev`, long-running dev servers, or browser tests/screenshots unless asked.
* **Architecture (DRY/KISS & Anti-Glue)**: Keep code simple, flat, and free of duplicate logic or premature abstractions. Never bolt isolated patches onto code not designed for them—flag architectural tension and propose a refactor first.
