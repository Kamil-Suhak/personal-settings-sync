---
name: feedback
description: Retrospective audit of the agent's tools, skills, environment, permissions, and documentation structure. Use when the user invokes /feedback or asks for honest feedback on developer/agent ergonomics and workflow friction.
---

# Tooling & Environment Feedback Protocol

Conduct an honest, high-signal retrospective on the tools, customizations, and environment you used during this session (or across the current workspace).

## Audit Dimensions

Review and report concrete observations across these areas (skip any category with nothing noteworthy):

1. **CLI & Shell Tools** (`pss`, `note`, `workset`, `out`, `rg`/`fd`, git helpers):
   - Commands that failed, had awkward flags, or required workarounds.
   - Missing subcommands, flags, or integrations that would save steps.
2. **Skills & Agent Customizations**:
   - Overlapping, bloated, or unclear skill instructions.
   - Repeated workflows that should be extracted into a skill or rule.
3. **Environment & Permissions**:
   - Sandbox restrictions, missing binaries, slow test/build loops, or unnecessary approval prompts.
4. **Docs & Vault Structure**:
   - `AGENTS.md` ambiguities, stale `wiki/` notes, broken links, or missing project context.

## Output Rules

- **Prioritize by impact**: Group findings into **High**, **Medium**, and **Low** impact.
- **Be specific**: Cite exact file paths, commands, flags, or error messages you observed—no generic praise or vague suggestions.
- **Propose concrete fixes**: For each item, give a short, actionable next step (e.g., exact flag change, rule tweak, or helper to add).
