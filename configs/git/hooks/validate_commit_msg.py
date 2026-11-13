#!/usr/bin/env python3
import sys
import re

ALLOWED_TYPES = {
    "docs", "refactor", "chore", "test", "feat",
    "fix", "visual", "ci", "perf", "build", "style"
}
MAX_SUBJECT_LEN = 100

def main():
    if len(sys.argv) < 2:
        print("[HOOK ERROR] Missing commit message file argument.", file=sys.stderr)
        sys.exit(1)

    commit_msg_file = sys.argv[1]
    try:
        with open(commit_msg_file, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if not line.strip().startswith("#")]
    except Exception as e:
        print(f"[HOOK ERROR] Failed to read commit message: {e}", file=sys.stderr)
        sys.exit(1)

    if not lines:
        print("[HOOK ERROR] Commit message is empty.", file=sys.stderr)
        sys.exit(1)

    subject = lines[0]

    # Ignore automatic merge / revert / squash commits
    if subject.startswith("Merge ") or subject.startswith("Revert ") or subject.startswith("fixup! ") or subject.startswith("squash! "):
        sys.exit(0)

    # 1. Reject scope parentheses: type(scope): ...
    if re.match(r"^[a-zA-Z0-9_-]+\([^)]+\):", subject):
        print(
            f"\n[POLICY VIOLATION] Scope parentheses are disallowed!\n"
            f"  Given:    \"{subject}\"\n"
            f"  Expected: \"<type>: <description>\" (without parentheses)\n"
            f"  Example:  \"feat: add token refresh\"\n",
            file=sys.stderr
        )
        sys.exit(1)

    # 2. Match <type>: <description>
    match = re.match(r"^([a-z]+):\s*(.+)$", subject)
    if not match:
        print(
            f"\n[POLICY VIOLATION] Commit message must follow \"<type>: <description>\":\n"
            f"  Given:    \"{subject}\"\n"
            f"  Allowed:  {', '.join(sorted(ALLOWED_TYPES))}\n"
            f"  Example:  \"fix: resolve null dereference in parser\"\n",
            file=sys.stderr
        )
        sys.exit(1)

    commit_type, description = match.group(1), match.group(2).strip()

    # 3. Check allowed type
    if commit_type not in ALLOWED_TYPES:
        print(
            f"\n[POLICY VIOLATION] Invalid commit type \"{commit_type}\"!\n"
            f"  Allowed types: {', '.join(sorted(ALLOWED_TYPES))}\n",
            file=sys.stderr
        )
        sys.exit(1)

    # 4. Length check
    if len(subject) > MAX_SUBJECT_LEN:
        print(
            f"\n[POLICY VIOLATION] Commit subject exceeds {MAX_SUBJECT_LEN} characters ({len(subject)} chars)!\n"
            f"  Subject: \"{subject}\"\n"
            f"  Please shorten the description to fit within {MAX_SUBJECT_LEN} chars.\n",
            file=sys.stderr
        )
        sys.exit(1)

    # 5. Trailing period check
    if description.endswith("."):
        print(
            f"\n[POLICY VIOLATION] Commit description must not end with a period!\n"
            f"  Given:    \"{subject}\"\n"
            f"  Expected: \"{subject[:-1]}\"\n",
            file=sys.stderr
        )
        sys.exit(1)

    sys.exit(0)

if __name__ == "__main__":
    main()
