# Personal workspace Zsh profile overrides (EndeavourOS)

# @cmd: ask — Ask Gemini via ephemeral streamed agy session (--ctx, --high, --keep-history)
ask() {
    case "${1:-}" in
        -h|--help|-Help)
            cat <<'EOF'
Usage: ask [--ctx [<sel>]] [--high] [--keep-history] <question>

Query Antigravity CLI ('agy') ephemerally with streamed response and optional terminal context.
Accepts piped input (e.g. 'out | ask "why did this fail?"').
Options:
  --ctx              Include terminal command/output slice (default ~1; pass 2, ~2, or ~3..2 before question)
  --high             Use high-reasoning model (gemini-4-hydrogen-high)
  --keep-history     Keep conversation state in ~/.gemini/antigravity-cli
  -h, --help         Show this help
EOF
            return 0
            ;;
    esac

    local last_cmd=""
    if command -v _rig_last_history_command >/dev/null 2>&1; then
        last_cmd="$(_rig_last_history_command)"
    fi

    if [ -n "$last_cmd" ]; then
        "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/ask-helper" run --engine agy --fallback-command "$last_cmd" "$@"
    else
        "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/ask-helper" run --engine agy "$@"
    fi
}
