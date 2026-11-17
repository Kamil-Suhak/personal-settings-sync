# Shared Zsh entrypoint (sourced by ~/.zshrc managed loader)

if [ -n "${ZSH_VERSION:-}" ]; then
    eval '_pss_init_file="${(%):-%x}"'
else
    _pss_init_file="${BASH_SOURCE[0]:-$0}"
fi
export PSS_ROOT
PSS_ROOT="$(cd "$(dirname "$_pss_init_file")/../.." && pwd)"
unset _pss_init_file

# Prevent Python virtualenv activate scripts from altering the prompt directly (Starship handles it)
export VIRTUAL_ENV_DISABLE_PROMPT=1

_pss_find_python() {
    if [ -n "${PSS_PYTHON:-}" ] && command -v "$PSS_PYTHON" >/dev/null 2>&1; then
        printf '%s' "$PSS_PYTHON"
        return 0
    fi
    local cand
    for cand in python3 python; do
        if command -v "$cand" >/dev/null 2>&1; then
            if "$cand" --version >/dev/null 2>&1; then
                printf '%s' "$cand"
                return 0
            fi
        fi
    done
    return 1
}

export PSS_PYTHON
PSS_PYTHON="$(_pss_find_python || printf 'python3')"

# Resolve machine-local XDG state paths (respecting env overrides for sandbox/tests)
_pss_state_json="$("$PSS_PYTHON" "$PSS_ROOT/scripts/local_state.py" --checkout "$PSS_ROOT" --migrate --json 2>/dev/null || true)"
if [ -n "$_pss_state_json" ]; then
    eval "$("$PSS_PYTHON" - "$_pss_state_json" <<'PY'
import json
import os
import shlex
import sys
from pathlib import Path

data = json.loads(sys.argv[1])
state_home = os.environ.get("PSS_STATE_HOME") or data["root"]
roots_file = os.environ.get("PSS_PROJECT_ROOTS") or data["project_roots"]
local_prof = data["local_profile"]
ws_file = data["workspace"]

ws = os.environ.get("PSS_WORKSPACE", "").strip()
if not ws and Path(ws_file).is_file():
    ws = Path(ws_file).read_text(encoding="utf-8", errors="replace").strip()
if not ws:
    ws = "personal"

print(f"export PSS_STATE_HOME={shlex.quote(state_home)}")
print(f"export PSS_PROJECT_ROOTS={shlex.quote(roots_file)}")
print(f"export PSS_LOCAL_PROFILE={shlex.quote(local_prof)}")
print(f"export PSS_WORKSPACE={shlex.quote(ws)}")
PY
)"
fi
unset _pss_state_json

export PSS_STATE_HOME="${PSS_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/pss}"
export PSS_PROJECT_ROOTS="${PSS_PROJECT_ROOTS:-$PSS_STATE_HOME/project-roots}"
export PSS_LOCAL_PROFILE="${PSS_LOCAL_PROFILE:-$PSS_STATE_HOME/profile.local.zsh}"
export PSS_WORKSPACE="${PSS_WORKSPACE:-personal}"

_pss_prepend_path() {
    local dir="$1"
    if [ -d "$dir" ]; then
        case ":$PATH:" in
            *":$dir:"*) ;;
            *) export PATH="$dir:$PATH" ;;
        esac
    fi
}

_pss_prepend_path "$HOME/.local/bin"
_pss_prepend_path "$PSS_ROOT"
_pss_prepend_path "$PSS_ROOT/configs/bin"

PSS_WORKSPACE_CHAIN="$("$PSS_PYTHON" - "$PSS_ROOT" "$PSS_WORKSPACE" <<'PY' 2>/dev/null || printf '%s\n' "$PSS_WORKSPACE"
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "configs" / "bin"))
from _pss_common import resolve_workspace_chain

for ws in resolve_workspace_chain(sys.argv[1], sys.argv[2]):
    print(ws)
PY
)"

while IFS= read -r _pss_ws; do
    [ -n "$_pss_ws" ] && _pss_prepend_path "$PSS_ROOT/workspaces/$_pss_ws/bin"
done <<EOF
$PSS_WORKSPACE_CHAIN
EOF
unset _pss_ws

# Source shared command groups
for _pss_group in git navigation search ai worksets; do
    if [ -f "$PSS_ROOT/configs/zsh/${_pss_group}.zsh" ]; then
        . "$PSS_ROOT/configs/zsh/${_pss_group}.zsh"
    fi
done
unset _pss_group

# --- Core System & Development Commands ---

# @cmd: which — Locate command source, inspect profile directory ('which profile -h'), or run command help ('which <cmd> -h')
which() {
    local want_profile=0
    local want_help=0
    local target=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help|-Help)
                want_help=1
                shift
                ;;
            -p|--profile|-Profile)
                want_profile=1
                shift
                ;;
            -ph|-hp)
                want_profile=1
                want_help=1
                shift
                ;;
            profile|\$profile)
                want_profile=1
                shift
                ;;
            *)
                if [ -z "$target" ]; then
                    target="$1"
                fi
                shift
                ;;
        esac
    done

    if [ "$want_profile" -eq 1 ]; then
        if [ "$want_help" -eq 0 ]; then
            printf '%s\n' "$PSS_ROOT/configs/zsh/init.zsh"
            return 0
        fi
        "$PSS_PYTHON" "$PSS_ROOT/scripts/profile_groups.py" \
            --root "$PSS_ROOT" \
            --workspace "$PSS_WORKSPACE" \
            --project-roots "$PSS_PROJECT_ROOTS" \
            --profile-help
        return $?
    fi

    if [ -z "$target" ]; then
        cat <<'EOF'
Usage:
  which <command>       Show path or definition of <command>
  which <command> -h    Show source location and invoke <command> --help
  which profile         Show shared profile path
  which profile -h      Display grouped directory of all profile & helper commands
EOF
        return 0
    fi

    if [ -n "${ZSH_VERSION:-}" ]; then
        if ! whence -w "$target" >/dev/null 2>&1; then
            printf "✖ which: Command '%s' not found.\n" "$target" >&2
            return 1
        fi
        if [ "$want_help" -eq 0 ]; then
            whence -v "$target"
            return 0
        fi
        printf 'Source: '
        whence -v "$target"
    else
        if ! type -t "$target" >/dev/null 2>&1; then
            printf "✖ which: Command '%s' not found.\n" "$target" >&2
            return 1
        fi
        if [ "$want_help" -eq 0 ]; then
            type "$target" | head -n 1
            return 0
        fi
        printf 'Source: '
        type "$target" | head -n 1
    fi

    "$target" --help
}

# @cmd: venv — Activate an existing Python virtualenv (default: .venv) or create one first
venv() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        cat <<'EOF'
Usage: venv [<dir>]

Activate Python virtual environment <dir> (default: .venv), creating it if missing.
EOF
        return 0
    fi

    local env_dir="${1:-.venv}"
    if [ ! -d "$env_dir" ]; then
        printf "Creating virtual environment in '%s'...\n" "$env_dir"
        "$PSS_PYTHON" -m venv "$env_dir" || return 1
    fi

    if [ -f "$env_dir/bin/activate" ]; then
        . "$env_dir/bin/activate"
    elif [ -f "$env_dir/Scripts/activate" ]; then
        . "$env_dir/Scripts/activate"
    else
        printf '✖ venv: Activation script not found in %s.\n' "$env_dir" >&2
        return 1
    fi
    printf 'Activated %s (%s)\n' "$env_dir" "$("$PSS_PYTHON" --version 2>&1)"
}

# @cmd: copy — Copy arguments or piped stdin to the system clipboard (-t/--trim, -1/--single-line, --strip-ansi)
copy() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
Usage: <cmd> | copy [options]   OR   copy [options] <text...>

Copy piped stdin or arguments to the clipboard.
Options:
  -t, --trim          Strip leading and trailing whitespace
  -1, --single-line   Collapse newlines into spaces
  --strip-ansi        Remove ANSI escape sequences
  -h, --help          Show this help
EOF
            return 0
            ;;
    esac
    "$PSS_PYTHON" - "$PSS_ROOT" "$@" <<'PY'
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "configs" / "bin"))
from _pss_common import transform_clipboard_text, write_clipboard

parser = argparse.ArgumentParser(prog="copy", add_help=False)
parser.add_argument("-t", "--trim", action="store_true")
parser.add_argument("-1", "--single-line", action="store_true")
parser.add_argument("--strip-ansi", action="store_true")
args, rest = parser.parse_known_args(sys.argv[2:])

raw = " ".join(rest) if rest else sys.stdin.read()
data = transform_clipboard_text(raw, trim=args.trim, single_line=args.single_line, strip_ansi=args.strip_ansi)
if not write_clipboard(data):
    print("✖ copy: No clipboard tool found (install wl-clipboard or xclip).", file=sys.stderr)
    sys.exit(1)
PY
}

# @cmd: paste — Output current clipboard text to stdout (-t/--trim, -1/--single-line, --strip-ansi)
paste() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
Usage: paste [options]

Write current clipboard contents to stdout.
Options:
  -t, --trim          Strip leading and trailing whitespace
  -1, --single-line   Collapse newlines into spaces
  --strip-ansi        Remove ANSI escape sequences
  -h, --help          Show this help
EOF
            return 0
            ;;
    esac
    "$PSS_PYTHON" - "$PSS_ROOT" "$@" <<'PY'
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "configs" / "bin"))
from _pss_common import read_clipboard, transform_clipboard_text

parser = argparse.ArgumentParser(prog="paste", add_help=False)
parser.add_argument("-t", "--trim", action="store_true")
parser.add_argument("-1", "--single-line", action="store_true")
parser.add_argument("--strip-ansi", action="store_true")
args, _ = parser.parse_known_args(sys.argv[2:])

text = read_clipboard()
if text is None:
    print("✖ paste: Clipboard is empty or unavailable.", file=sys.stderr)
    sys.exit(1)
sys.stdout.write(transform_clipboard_text(text, trim=args.trim, single_line=args.single_line, strip_ansi=args.strip_ansi))
PY
}

# @cmd: cmp — Compare two files, file vs clipboard, or two consecutive clipboard copies
cmp() {
    "${PSS_PYTHON:-python3}" "$PSS_ROOT/configs/bin/cmp" "$@"
}

# @cmd: jwt — Decode JWT header, payload, and expiration from arg, stdin, or clipboard
jwt() {
    "${PSS_PYTHON:-python3}" "$PSS_ROOT/configs/bin/jwt" "$@"
}

# @cmd: note — Workspace-aware Obsidian wiki/raw project note helper (pipes to stdout when redirected)
note() {
    "${PSS_PYTHON:-python3}" "$PSS_ROOT/configs/bin/note" "$@"
}

# @cmd: pss — Run Personal Settings Sync manager (status, apply, diff, workspace, fonts, apps)
pss() {
    "${PSS_PYTHON:-python3}" "$PSS_ROOT/pss" "$@"
}

# --- Prompt Context Variables & Interactive Zsh Configuration ---

_pss_update_prompt_vars() {
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ]; then
        export gr="$top"
        local branch
        branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true)"
        export cb="$branch"
        if command -v workset >/dev/null 2>&1 && [ -n "$branch" ]; then
            export cw="$(command workset --prompt-badge --root "$top" --branch "$branch" 2>/dev/null || true)"
        else
            unset cw 2>/dev/null || true
        fi
    else
        unset gr cb cw 2>/dev/null || true
    fi
}

if [ -n "${ZSH_VERSION:-}" ]; then
    # Only configure interactive Zsh plugins/prompt when running interactively
    if [[ -o interactive ]]; then
        HIST_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zsh"
        CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
        mkdir -p "$HIST_DIR" "$CACHE_DIR"
        export HISTFILE="$HIST_DIR/history"
        export HISTSIZE=50000
        export SAVEHIST=50000

        setopt SHARE_HISTORY
        setopt HIST_IGNORE_ALL_DUPS
        setopt HIST_IGNORE_SPACE
        setopt HIST_REDUCE_BLANKS
        setopt AUTO_CD
        setopt INTERACTIVE_COMMENTS

        autoload -Uz compinit
        compinit -d "$CACHE_DIR/zcompdump"
        zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
        zstyle ':completion:*' menu select

        if command -v fzf >/dev/null 2>&1; then
            eval "$(fzf --zsh 2>/dev/null)" || {
                for _fzf_file in \
                    /usr/share/fzf/key-bindings.zsh \
                    /usr/share/fzf/completion.zsh \
                    /usr/share/doc/fzf/examples/key-bindings.zsh \
                    /usr/share/doc/fzf/examples/completion.zsh; do
                    [ -f "$_fzf_file" ] && . "$_fzf_file"
                done
                unset _fzf_file
            }
        fi

        for _autosug in \
            /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
            /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh; do
            if [ -f "$_autosug" ]; then
                . "$_autosug"
                ZSH_AUTOSUGGEST_STRATEGY=(history completion)
                break
            fi
        done
        unset _autosug

        if [ -f "$PSS_ROOT/configs/zsh/keybinds.zsh" ]; then
            . "$PSS_ROOT/configs/zsh/keybinds.zsh"
        fi

        if [ -n "${precmd_functions+x}" ]; then
            precmd_functions+=(_pss_update_prompt_vars)
        else
            precmd_functions=(_pss_update_prompt_vars)
        fi

        if command -v starship >/dev/null 2>&1; then
            eval "$(starship init zsh)"
        fi

        for _synhl in \
            /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
            /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
            if [ -f "$_synhl" ]; then
                . "$_synhl"
                break
            fi
        done
        unset _synhl
    fi
fi

# --- Workspace & Machine-Local Profile Layers ---

while IFS= read -r _pss_ws; do
    if [ -n "$_pss_ws" ] && [ -f "$PSS_ROOT/workspaces/$_pss_ws/zsh/profile.zsh" ]; then
        . "$PSS_ROOT/workspaces/$_pss_ws/zsh/profile.zsh"
    fi
done <<EOF
$PSS_WORKSPACE_CHAIN
EOF
unset _pss_ws

if [ -f "$PSS_LOCAL_PROFILE" ]; then
    . "$PSS_LOCAL_PROFILE"
fi
