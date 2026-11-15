#!/usr/bin/env sh
# Compatibility wrapper delegating to bootstrap.sh.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/bootstrap.sh" ]; then
    exec sh "$SCRIPT_DIR/bootstrap.sh" "$@"
fi
curl -fsSL "https://raw.githubusercontent.com/Kamil-Suhak/personal-settings-sync/zsh/bootstrap.sh" | sh -s -- "$@"
