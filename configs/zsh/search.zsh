# Search helpers: unified file and content search (sourced by init.zsh)

_pss_clipboard_query() {
    local allow_multiline="${1:-0}"
    "${PSS_PYTHON:-python3}" - "$PSS_ROOT" "$allow_multiline" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "configs" / "bin"))
from _pss_common import read_clipboard

allow_multiline = sys.argv[2] == "1"
raw = read_clipboard()
if not raw:
    sys.exit(1)
if allow_multiline:
    trimmed = raw.strip("\r\n")
    if not trimmed:
        sys.exit(1)
    sys.stdout.write(trimmed)
    sys.exit(0)

trimmed = raw.strip()
if not trimmed or len(trimmed) > 200 or "\n" in trimmed or "\r" in trimmed:
    print("Clipboard text is multi-line or >200 chars; skipped auto-query.", file=sys.stderr)
    sys.exit(1)
print(trimmed)
PY
}

_pss_copy_and_maybe_open() {
    local selected="$1"
    local open_code="${2:-0}"

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
            printf "✖ seek: 'code' not found in PATH.\n" >&2
            return 1
        fi
    fi
}

_pss_pick_file() {
    local matches="$1"
    local prompt="${2:-seek> }"
    local count
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    local selected=""

    if [ "$count" -eq 1 ]; then
        selected="$matches"
    elif command -v fzf >/dev/null 2>&1 && [ -t 0 ]; then
        selected="$(printf '%s\n' "$matches" | fzf --height 50% --reverse --prompt="$prompt" --preview 'head -n 80 {}' 2>/dev/null || printf '%s\n' "$matches" | fzf --height 40% --reverse --prompt="$prompt")" || return 0
    else
        printf '\nFound %s matches:\n' "$count" >&2
        nl -w3 -s'] ' <<<"$matches" | sed 's/^/  [/' >&2
        if [ -t 0 ]; then
            local idx
            printf '\nSelect [1-%s] (Enter to cancel): ' "$count" >&2
            IFS= read -r idx || return 0
            if [ -n "$idx" ] && [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$count" ]; then
                selected="$(printf '%s\n' "$matches" | sed -n "${idx}p")"
            fi
        fi
    fi

    printf '%s' "$selected"
}

# @cmd: seek — Search filenames (default) or file contents (-s/--str); supports multiline literal (-F), fzf picker (-p), and VS Code open (-o)
seek() {
    local str_mode=0
    local open_code=0
    local pick_mode=0
    local fixed_mode=0
    local invert=0
    local case_sensitive=0
    local files_only=0
    local positional=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help|-Help)
                cat <<'EOF'
Usage:
  seek [-o] [<query>] [<path>]                      Fuzzy filename search; copies match (& opens in code with -o)
  seek -s [options] [<pattern>] [<path>]            Search file contents or filter piped stdin

Content (-s / --str) options:
  -s, --str              Search file contents instead of filenames
  -F, --fixed            Literal / multiline fixed-string search (rg -F -U; no regex parsing)
  -p, --pick             Pick a matching file interactively (fzf) and copy its path
  -o, --open             Pick a matching file (implies -p) and open in VS Code
  -l, --files-only       Print matching filenames only
  -c, --case-sensitive   Case-sensitive matching (default: case-insensitive)
  -v, --invert           Invert match (single-line mode / piped stdin)
  -h, --help             Show this help

Tip: With 'seek -s -F' and no <pattern>, reads multiline literal text directly from clipboard.
EOF
                return 0
                ;;
            -s|--str)
                str_mode=1
                shift
                ;;
            -o|--open|-Open)
                open_code=1
                pick_mode=1
                shift
                ;;
            -p|--pick)
                pick_mode=1
                shift
                ;;
            -F|--fixed|--literal)
                fixed_mode=1
                str_mode=1
                shift
                ;;
            -v|--invert|-Invert)
                invert=1
                str_mode=1
                shift
                ;;
            -c|--case-sensitive|-CaseSensitive)
                case_sensitive=1
                str_mode=1
                shift
                ;;
            -l|--files-only|-FilesOnly)
                files_only=1
                str_mode=1
                shift
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    positional+=("$1")
                    shift
                done
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    local query=""
    local search_path="."
    if [ "${#positional[@]}" -gt 0 ]; then
        set -- "${positional[@]}"
        query="${1:-}"
        search_path="${2:-.}"
    fi

    # --- Filename search mode ---
    if [ "$str_mode" -eq 0 ]; then
        if [ -z "$query" ] && [ ! -t 0 ]; then
            IFS= read -r query || true
            query="${query%$'\r'}"
        fi
        if [ -z "$query" ]; then
            query="$(_pss_clipboard_query 0 2>/dev/null)" || true
            if [ -n "$query" ]; then
                printf "Searching clipboard filename query: '%s'\n" "$query" >&2
            fi
        fi

        if [ -z "$query" ]; then
            printf "Usage: seek <name> [<path>] [-o]  (or seek -s <pattern> [<path>])\n" >&2
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

        local selected
        selected="$(_pss_pick_file "$matches" "seek> ")"
        if [ -n "$selected" ]; then
            _pss_copy_and_maybe_open "$selected" "$open_code"
        fi
        return 0
    fi

    # --- Content / string search mode (-s / --str) ---
    if [ -z "$query" ] && [ -t 0 ]; then
        query="$(_pss_clipboard_query "$fixed_mode" 2>/dev/null)" || true
        if [ -n "$query" ]; then
            printf "Searching clipboard pattern.\n" >&2
        fi
    fi

    if [ -z "$query" ]; then
        printf "Usage: seek -s <pattern> [<path>] [-F] [-p] [-o] [-l] [-c] [-v]\n" >&2
        return 1
    fi

    # Auto-enable literal multiline mode if the pattern itself spans multiple lines
    if [[ "$query" == *$'\n'* ]]; then
        fixed_mode=1
    fi

    # Piped input filter mode
    if [ ! -t 0 ]; then
        local grep_flags=()
        if [ "$fixed_mode" -eq 1 ]; then grep_flags+=(-F); else grep_flags+=(-E); fi
        if [ "$case_sensitive" -eq 0 ]; then grep_flags+=(-i); fi
        if [ "$invert" -eq 1 ]; then grep_flags+=(-v); fi
        grep "${grep_flags[@]}" -- "$query"
        return $?
    fi

    # Interactive pick / open mode -> collect matching file paths and feed fzf
    if [ "$pick_mode" -eq 1 ]; then
        local file_matches=""
        if command -v rg >/dev/null 2>&1; then
            local rg_flags=(-l)
            if [ "$fixed_mode" -eq 1 ]; then rg_flags+=(-F -U); fi
            if [ "$case_sensitive" -eq 0 ]; then rg_flags+=(-i); fi
            file_matches="$(printf '%s' "$query" | rg "${rg_flags[@]}" -f - -- "$search_path")" || true
        elif [ "$fixed_mode" -eq 0 ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            local git_flags=(-I -l)
            if [ "$case_sensitive" -eq 0 ]; then git_flags+=(-i); fi
            file_matches="$(git grep "${git_flags[@]}" -e "$query" -- "$search_path")" || true
        else
            local g_flags=(-rlI)
            if [ "$fixed_mode" -eq 1 ]; then g_flags+=(-F); else g_flags+=(-E); fi
            if [ "$case_sensitive" -eq 0 ]; then g_flags+=(-i); fi
            file_matches="$(grep "${g_flags[@]}" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv -- "$query" "$search_path")" || true
        fi

        if [ -z "$file_matches" ]; then
            printf "No files matched pattern.\n"
            return 0
        fi

        local selected
        selected="$(_pss_pick_file "$file_matches" "seek -s> ")"
        if [ -n "$selected" ]; then
            _pss_copy_and_maybe_open "$selected" "$open_code"
        fi
        return 0
    fi

    # Standard output mode
    if [ "$fixed_mode" -eq 1 ] && command -v rg >/dev/null 2>&1; then
        local rg_flags=(--color=auto -F -U)
        if [ "$case_sensitive" -eq 0 ]; then rg_flags+=(-i); fi
        if [ "$files_only" -eq 1 ]; then rg_flags+=(-l); else rg_flags+=(-n); fi
        printf '%s' "$query" | rg "${rg_flags[@]}" -f - -- "$search_path"
        return $?
    fi

    if [ "$fixed_mode" -eq 0 ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local git_flags=(-I --color=auto)
        if [ "$case_sensitive" -eq 0 ]; then git_flags+=(-i); fi
        if [ "$invert" -eq 1 ]; then git_flags+=(-v); fi
        if [ "$files_only" -eq 1 ]; then git_flags+=(-l); else git_flags+=(-n); fi
        if [ "$search_path" != "." ]; then
            git grep "${git_flags[@]}" -e "$query" -- "$search_path"
        else
            git grep "${git_flags[@]}" -e "$query"
        fi
        return $?
    fi

    if command -v rg >/dev/null 2>&1 && [ "$invert" -eq 0 ]; then
        local rg_flags=(--color=auto)
        if [ "$fixed_mode" -eq 1 ]; then rg_flags+=(-F -U); fi
        if [ "$case_sensitive" -eq 0 ]; then rg_flags+=(-i); fi
        if [ "$files_only" -eq 1 ]; then rg_flags+=(-l); else rg_flags+=(-n); fi
        rg "${rg_flags[@]}" -- "$query" "$search_path"
        return $?
    fi

    local grep_flags=(-rI)
    if [ "$fixed_mode" -eq 1 ]; then grep_flags+=(-F); else grep_flags+=(-E); fi
    if [ "$case_sensitive" -eq 0 ]; then grep_flags+=(-i); fi
    if [ "$invert" -eq 1 ]; then grep_flags+=(-v); fi
    if [ "$files_only" -eq 1 ]; then grep_flags+=(-l); else grep_flags+=(-n); fi
    grep "${grep_flags[@]}" \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=bin \
        --exclude-dir=obj \
        --exclude-dir=target \
        --exclude-dir=.vs \
        --exclude-dir=.venv \
        --exclude-dir=__pycache__ \
        -- "$query" "$search_path"
}
