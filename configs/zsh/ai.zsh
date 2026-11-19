# AI utilities, terminal capture, and rerun workflow (sourced by init.zsh)

_rig_last_history_command() {
    if [ -n "${RIG_LAST_COMMAND:-}" ]; then
        printf '%s' "$RIG_LAST_COMMAND"
        return 0
    fi
    if [ -n "${RIG_SHELL_HISTORY_FILE:-}" ] && [ -f "$RIG_SHELL_HISTORY_FILE" ]; then
        tail -n 1 "$RIG_SHELL_HISTORY_FILE" 2>/dev/null || true
        return 0
    fi
    fc -ln -1 -1 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

# @cmd: out — Extract output from recent completed command block(s) (e.g. out, out ~2, out ~3..2)
out() {
    case "${1:-}" in
        -h|--help|-Help)
            cat <<'EOF'
Usage: out [<selector>] [-c|--include-command]

Capture output of recent completed command(s) from Kitty/WezTerm/tmux scrollback.
Selectors:
  1 / ~1       Last completed command (default)
  N            Last N commands in chronological order
  ~N           Nth-most-recent command
  ~A..B        Chronological slice between offsets A and B

Options:
  -c, --include-command   Prepend '$ <command>' header
  -h, --help              Show this help
EOF
            return 0
            ;;
    esac

    local last_cmd
    last_cmd="$(_rig_last_history_command)"
    if [ -n "$last_cmd" ]; then
        "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/ask-helper" out "$@" --fallback-command "$last_cmd"
    else
        "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/ask-helper" out "$@"
    fi
}

# @cmd: lastout — Alias for 'out'
lastout() {
    out "$@"
}

# @cmd: rerun — Re-run recent shell commands selected by N, ~N, or ~A..B (-y to skip confirmation)
rerun() {
    if [ "${__RIG_IN_RERUN:-0}" = "1" ]; then
        printf '✖ rerun: Nested rerun invocation blocked.\n' >&2
        return 1
    fi

    local selector="~1"
    local assume_yes=0
    local got_selector=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help|-Help)
                cat <<'EOF'
Usage: rerun [<selector>] [-y|--yes]

Inspect and re-execute prior shell commands (skips entries whose command verb is 'rerun').
Selectors: ~1 (default), N (last N), ~N (Nth last), ~A..B (chronological slice).
EOF
                return 0
                ;;
            -y|--yes|-Yes)
                assume_yes=1
                shift
                ;;
            *)
                if [ "$got_selector" -eq 0 ]; then
                    selector="$1"
                    got_selector=1
                    shift
                else
                    printf "✖ rerun: Unexpected argument '%s'\n" "$1" >&2
                    return 2
                fi
                ;;
        esac
    done

    local hist_dump=""
    if [ -n "${RIG_TEST_RERUN_HISTORY_FILE:-}" ] && [ -f "$RIG_TEST_RERUN_HISTORY_FILE" ]; then
        hist_dump="$(cat "$RIG_TEST_RERUN_HISTORY_FILE")"
    elif [ -n "${RIG_SHELL_HISTORY_FILE:-}" ] && [ -f "$RIG_SHELL_HISTORY_FILE" ]; then
        hist_dump="$(cat "$RIG_SHELL_HISTORY_FILE")"
    else
        hist_dump="$(fc -ln -200 -1 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
    fi

    local selected_lines
    selected_lines="$("${RIG_PYTHON:-python3}" - "$RIG_ROOT" "$selector" "$hist_dump" <<'PY'
import importlib.machinery
import importlib.util
import shlex
import sys
from pathlib import Path

rig_root = Path(sys.argv[1])
selector = sys.argv[2]
hist_raw = sys.argv[3]

loader = importlib.machinery.SourceFileLoader("ask_helper", str(rig_root / "configs" / "bin" / "ask-helper"))
spec = importlib.util.spec_from_loader("ask_helper", loader)
ask_helper = importlib.util.module_from_spec(spec)
loader.exec_module(ask_helper)

def invokes_rerun(cmd: str) -> bool:
    # Check command verbs across ;, &&, ||, | boundaries while keeping 'echo rerun'
    try:
        lexer = shlex.shlex(cmd, posix=True, punctuation_chars=";|&")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        tokens = cmd.split()
    at_cmd_pos = True
    for tok in tokens:
        if tok in (";", "&&", "||", "|", "&"):
            at_cmd_pos = True
            continue
        if at_cmd_pos:
            if "=" in tok and not tok.startswith("="):
                continue
            if tok == "rerun":
                return True
            at_cmd_pos = False
    return False

candidates = [ln.strip() for ln in hist_raw.splitlines() if ln.strip() and not invokes_rerun(ln.strip())]
if not candidates:
    buf_lines = ask_helper.read_terminal_buffer()
    blocks = ask_helper.convert_to_terminal_blocks(buf_lines)
    candidates = [b["command"] for b in blocks if b.get("command") and not invokes_rerun(b["command"])]

if not candidates:
    print("No prior commands found to re-run.", file=sys.stderr)
    sys.exit(1)

try:
    indices = ask_helper.resolve_block_indices(selector, len(candidates))
except ValueError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)

if not indices:
    print(f"Selector '{selector}' matched none of the {len(candidates)} recorded command(s).", file=sys.stderr)
    sys.exit(1)

for idx in indices:
    print(candidates[idx])
PY
)" || return $?

    local cmds=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && cmds+=("$line")
    done <<<"$selected_lines"

    if [ "${#cmds[@]}" -eq 0 ]; then
        printf 'No matching commands selected for rerun.\n' >&2
        return 1
    fi

    printf '\nCommands to execute:\n'
    for line in "${cmds[@]}"; do
        printf '  > %s\n' "$line"
    done

    if [ "$assume_yes" -eq 0 ]; then
        local reply=""
        printf 'Proceed? [y/N]: '
        IFS= read -r reply || reply=""
        case "$reply" in
            y|Y|yes|YES|Yes) ;;
            *)
                printf 'Aborted.\n'
                return 0
                ;;
        esac
    fi

    __RIG_IN_RERUN=1
    local rc=0
    for line in "${cmds[@]}"; do
        eval "$line"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '✖ Command exited with code %s: %s\n' "$rc" "$line" >&2
            __RIG_IN_RERUN=0
            return "$rc"
        fi
    done
    __RIG_IN_RERUN=0
    return 0
}

# @cmd: decide — Evaluate a scenario or piped input using the Gemini Decisions API
decide() {
    "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/decide" "$@"
}

# @cmd: decision — Alias for 'decide'
decision() {
    decide "$@"
}
