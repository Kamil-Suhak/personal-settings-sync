# Search helpers: smart file finder and grep wrapper (sourced by init.zsh)

_pss_clipboard_short_query() {
    "${PSS_PYTHON:-python3}" - "$PSS_ROOT" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "configs" / "bin"))
from _pss_common import read_clipboard

raw = read_clipboard()
if not raw:
    sys.exit(1)
trimmed = raw.strip()
if not trimmed or len(trimmed) > 200 or "\n" in trimmed or "\r" in trimmed:
    print("Clipboard text is multi-line or >200 chars; skipped auto-query.", file=sys.stderr)
    sys.exit(1)
print(trimmed)
PY
}

# @cmd: find — Fuzzy file finder (-o opens in VS Code; preserves GNU 'find <dir> -name ...' predicates)
find() {
    local arg1="${1:-}"
    local arg2="${2:-}"

    # Preserve standard GNU/POSIX find usage when predicates like -name/-type are passed
    case "$arg1" in
        -h|--help|-Help)
            cat <<'EOF'
Usage:
  find [-o|--open] <query> [<path>]   Fuzzy file search inside repo/dir; copies match & optionally opens in code
  find <dir> -<predicate> ...         Passed directly through to system 'find'

Options:
  -o, --open    Open selected file in VS Code
  -h, --help    Show this help
EOF
            return 0
            ;;
        -[a-zA-Z0-9]*|\!|\()
            if [ "$arg1" != "-o" ] && [ "$arg1" != "--open" ] && [ "$arg1" != "-Open" ]; then
                command find "$@"
                return $?
            fi
            ;;
    esac
    if [ "$#" -ge 2 ]; then
        case "$arg2" in
            -name|-iname|-type|-maxdepth|-mindepth|-path|-regex|-size|-mtime|-exec|-print*)
                command find "$@"
                return $?
                ;;
        esac
    fi

    local open_code=0
    local positional=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o|--open|-Open)
                open_code=1
                shift
                ;;
            -h|--help|-Help)
                find --help
                return 0
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    local query=""
    local search_path="."
    # Normalize positional args without relying on 0-based vs 1-based array indexing
    if [ "${#positional[@]}" -gt 0 ]; then
        set -- "${positional[@]}"
        query="${1:-}"
        search_path="${2:-.}"
    fi

    if [ -z "$query" ] && [ ! -t 0 ]; then
        IFS= read -r query || true
        query="${query%$'\r'}"
    fi
    if [ -z "$query" ]; then
        query="$(_pss_clipboard_short_query 2>/dev/null)" || true
        if [ -n "$query" ]; then
            printf "Searching clipboard filename query: '%s'\n" "$query" >&2
        fi
    fi

    if [ -z "$query" ]; then
        printf "Usage: find <name> [<path>] [-o]  (or copy a short filename to clipboard)\n" >&2
        return 1
    fi

    local matches
    matches="$("${PSS_PYTHON:-python3}" - "$PSS_ROOT" "$query" "$search_path" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

query = sys.argv[2]
search_path = Path(sys.argv[3]).expanduser()
tokens = [re.escape(t) for t in re.split(r"[\s\-_.]+", query) if t]
pattern = re.compile(".?".join(tokens), re.IGNORECASE) if tokens else re.compile(re.escape(query), re.IGNORECASE)

exclude_dirs = {".git", "node_modules", "bin", "obj", "target", "dist", "build", ".vs", ".venv", "__pycache__", ".backups"}
results = []

is_git = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
if is_git.returncode == 0 and is_git.stdout.strip() == "true":
    root_res = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    git_root = Path(root_res.stdout.strip()) if root_res.returncode == 0 else Path.cwd()
    ls_args = ["git", "ls-files", "--cached", "--others", "--exclude-standard"]
    if str(search_path) not in (".", ""):
        ls_args.extend(["--", str(search_path)])
    ls_res = subprocess.run(ls_args, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if ls_res.returncode == 0:
        for rel in ls_res.stdout.splitlines():
            p = git_root / rel
            if pattern.search(p.name):
                results.append(str(p))

if not results:
    base = search_path if search_path.exists() else Path(".")
    for root_str, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in exclude_dirs)
        for fname in sorted(files):
            if pattern.search(fname):
                results.append(str((Path(root_str) / fname).resolve()))

for item in results:
    print(item)
PY
)"

    if [ -z "$matches" ]; then
        printf "No files found matching '%s'.\n" "$query"
        return 0
    fi

    local count
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    local selected=""

    if [ "$count" -eq 1 ]; then
        selected="$matches"
    elif command -v fzf >/dev/null 2>&1 && [ -t 0 ]; then
        selected="$(printf '%s\n' "$matches" | fzf --height 40% --reverse --prompt='find> ')" || return 0
    else
        printf '\nFound %s matches:\n' "$count"
        nl -w3 -s'] ' <<<"$matches" | sed 's/^/  [/'
        if [ -t 0 ]; then
            local idx
            printf '\nSelect [1-%s] (Enter to cancel): ' "$count"
            IFS= read -r idx || return 0
            if [ -n "$idx" ] && [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$count" ]; then
                selected="$(printf '%s\n' "$matches" | sed -n "${idx}p")"
            fi
        fi
    fi

    if [ -z "$selected" ]; then
        return 0
    fi

    "${PSS_PYTHON:-python3}" - "$PSS_ROOT" "$selected" <<'PY' >/dev/null 2>&1 || true
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "configs" / "bin"))
from _pss_common import write_clipboard

write_clipboard(sys.argv[2])
PY
    printf 'Copied to clipboard: %s\n' "$selected"

    if [ "$open_code" -eq 1 ]; then
        if command -v code >/dev/null 2>&1; then
            code "$selected"
        else
            printf "✖ find: 'code' not found in PATH.\n" >&2
            return 1
        fi
    fi
}

# @cmd: findstr — Search content across files or filter piped lines (-v invert, -c case-sensitive, -l files-only)
findstr() {
    local invert=0
    local case_sensitive=0
    local files_only=0
    local positional=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help|-Help)
                cat <<'EOF'
Usage: findstr [-v] [-c] [-l] <pattern> [<path>]

Filter piped stdin lines, or search repository/directory files (git grep / grep).
Options:
  -v, --invert           Invert match
  -c, --case-sensitive   Case-sensitive matching (default: case-insensitive)
  -l, --files-only       Print matching filenames only
  -h, --help             Show this help
EOF
                return 0
                ;;
            -v|--invert|-Invert)
                invert=1
                shift
                ;;
            -c|--case-sensitive|-CaseSensitive)
                case_sensitive=1
                shift
                ;;
            -l|--files-only|-FilesOnly)
                files_only=1
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    local pattern=""
    local search_path="."
    if [ "${#positional[@]}" -gt 0 ]; then
        set -- "${positional[@]}"
        pattern="${1:-}"
        search_path="${2:-.}"
    fi

    if [ -z "$pattern" ] && [ -t 0 ]; then
        pattern="$(_pss_clipboard_short_query 2>/dev/null)" || true
        if [ -n "$pattern" ]; then
            printf "Searching clipboard pattern: '%s'\n" "$pattern" >&2
        fi
    fi

    if [ -z "$pattern" ]; then
        printf "Usage: findstr <pattern> [<path>] [-v] [-c] [-l]\n" >&2
        return 1
    fi

    local grep_flags=(-E)
    if [ "$case_sensitive" -eq 0 ]; then
        grep_flags+=(-i)
    fi
    if [ "$invert" -eq 1 ]; then
        grep_flags+=(-v)
    fi

    # Piped input filter mode
    if [ ! -t 0 ]; then
        grep "${grep_flags[@]}" -- "$pattern"
        return $?
    fi

    if [ "$files_only" -eq 1 ]; then
        grep_flags+=(-l)
    else
        grep_flags+=(-n)
    fi

    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local git_flags=(-I --color=auto)
        if [ "$case_sensitive" -eq 0 ]; then git_flags+=(-i); fi
        if [ "$invert" -eq 1 ]; then git_flags+=(-v); fi
        if [ "$files_only" -eq 1 ]; then git_flags+=(-l); else git_flags+=(-n); fi
        if [ "$search_path" != "." ]; then
            git grep "${git_flags[@]}" -e "$pattern" -- "$search_path"
        else
            git grep "${git_flags[@]}" -e "$pattern"
        fi
        return $?
    fi

    if command -v rg >/dev/null 2>&1; then
        local rg_flags=(--color=auto)
        if [ "$case_sensitive" -eq 0 ]; then rg_flags+=(-i); fi
        if [ "$files_only" -eq 1 ]; then rg_flags+=(-l); else rg_flags+=(-n); fi
        if [ "$invert" -eq 1 ]; then
            # Non-matching files outside git
            grep -rnI --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv -v -E "$pattern" "$search_path"
        else
            rg "${rg_flags[@]}" -- "$pattern" "$search_path"
        fi
        return $?
    fi

    grep -rI \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=bin \
        --exclude-dir=obj \
        --exclude-dir=target \
        --exclude-dir=.vs \
        --exclude-dir=.venv \
        --exclude-dir=__pycache__ \
        "${grep_flags[@]}" -- "$pattern" "$search_path"
}
