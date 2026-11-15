## Work Workspace Context

* **Enterprise Data Protection**: Use approved company-provided Copilot CLI/plans for work repositories; never send proprietary code, internal URLs, or secrets to unapproved external services.
* **Primary Stack**: .NET backend APIs, Azure infrastructure, and large multi-project git repositories.
* **Shell Constraints**: Work environment runs on WSL2 + Zsh (`configs/zsh/` + `configs/bin/`); native Linux `/usr/bin/git` runs inside WSL without Carbon Black `git.exe` blocking, and Windows VS/browser interop is bridged via `wslpath`.
