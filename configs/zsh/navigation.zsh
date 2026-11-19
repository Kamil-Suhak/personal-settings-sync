# Navigation and project switcher commands (sourced by init.zsh)

# @cmd: mkcd — Create directory (with parents) and cd into it
mkcd() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "$#" -eq 0 ]; then
        printf 'Usage: mkcd <directory>\n\nCreate <directory> (and parents) then cd into it.\n'
        [ "$#" -eq 0 ] && return 1 || return 0
    fi
    mkdir -p -- "$1" && cd -- "$1"
}

_rig_project_roots_list() {
    local roots_file="${RIG_PROJECT_ROOTS:-${RIG_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/rig}/project-roots}"
    if [ ! -f "$roots_file" ]; then
        return 0
    fi
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        # Strip CR and leading/trailing spaces without Zsh-only syntax
        line="${line%$'\r'}"
        case "$line" in
            ""|\#*) continue ;;
        esac
        if [ -d "$line" ]; then
            printf '%s\n' "$line"
        fi
    done < "$roots_file"
}

# @cmd: p — Jump to a project under configured project roots (-list, -add, -remove)
p() {
    local roots_file="${RIG_PROJECT_ROOTS:-${RIG_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/rig}/project-roots}"
    local mode=""
    local arg1="${1:-}"
    local arg2="${2:-}"

    case "$arg1" in
        -h|--help|-Help)
            cat <<'EOF'
Usage:
  p <name>              Jump to first matching project directory under configured roots
  p -l | --list         List configured project roots
  p -a | --add [<dir>]  Add directory (default: current directory) to project roots
  p -r | --remove [<q>] Remove matching root by path, basename, or index
  p                     Browse projects interactively with fzf (or show roots)
EOF
            return 0
            ;;
        -l|--list|-list|list)
            mode="list"
            ;;
        -a|--add|-add|add)
            mode="add"
            ;;
        -r|-rm|--remove|-remove|remove|rm)
            mode="remove"
            ;;
    esac

    if [ "$mode" = "list" ]; then
        printf '\nConfigured project roots (%s):\n' "$roots_file"
        local found_any=0
        local r
        while IFS= read -r r; do
            found_any=1
            printf '  • %s\n' "$r"
        done < <(_rig_project_roots_list)
        if [ "$found_any" -eq 0 ]; then
            printf "  (none — add one with 'p --add <path>')\n"
        fi
        printf '\n'
        return 0
    fi

    if [ "$mode" = "add" ]; then
        local target="${arg2:-$PWD}"
        if [ ! -d "$target" ]; then
            printf "✖ p: Directory not found: %s\n" "$target" >&2
            return 1
        fi
        local resolved
        resolved="$(cd "$target" && pwd)"
        mkdir -p "$(dirname "$roots_file")"
        if [ -f "$roots_file" ] && grep -Fxq -- "$resolved" "$roots_file"; then
            printf "'%s' is already in %s\n" "$resolved" "$roots_file"
            return 0
        fi
        printf '%s\n' "$resolved" >> "$roots_file"
        printf "Added '%s' to %s\n" "$resolved" "$roots_file"
        return 0
    fi

    if [ "$mode" = "remove" ]; then
        if [ ! -f "$roots_file" ]; then
            printf "No project roots file found (%s).\n" "$roots_file" >&2
            return 1
        fi
        if [ -z "$arg2" ]; then
            printf "Specify a root path, basename, or index to remove (see 'p --list').\n" >&2
            return 1
        fi
        "${RIG_PYTHON:-python3}" - "$roots_file" "$arg2" <<'PY'
import sys
from pathlib import Path

roots_path = Path(sys.argv[1])
query = sys.argv[2].strip()
raw_lines = [ln.strip() for ln in roots_path.read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.strip().startswith("#")]

match = None
if query.isdigit():
    idx = int(query)
    if 1 <= idx <= len(raw_lines):
        match = raw_lines[idx - 1]
else:
    q_res = str(Path(query).expanduser().resolve()) if Path(query).expanduser().exists() else query
    hits = [ln for ln in raw_lines if ln == query or ln == q_res or Path(ln).name == query]
    if len(hits) == 1:
        match = hits[0]
    elif len(hits) > 1:
        print(f"Multiple roots matched '{query}'; specify full path:", file=sys.stderr)
        for h in hits:
            print(f"  {h}", file=sys.stderr)
        sys.exit(1)

if not match:
    print(f"Root '{query}' not found in {roots_path}", file=sys.stderr)
    sys.exit(1)

remaining = [ln for ln in raw_lines if ln != match]
roots_path.write_text(("\n".join(remaining) + "\n") if remaining else "", encoding="utf-8", newline="\n")
print(f"Removed '{match}' from {roots_path}")
PY
        return $?
    fi

    local roots=()
    local r
    while IFS= read -r r; do
        roots+=("$r")
    done < <(_rig_project_roots_list)

    if [ "${#roots[@]}" -eq 0 ]; then
        printf "✖ p: No project roots configured in %s. Use 'p --add <path>' first.\n" "$roots_file" >&2
        return 1
    fi

    if [ -z "$arg1" ]; then
        if command -v fzf >/dev/null 2>&1 && [ -t 0 ]; then
            local pick
            pick="$("${RIG_PYTHON:-python3}" - "${roots[@]}" <<'PY' | fzf --height 40% --reverse --prompt='project> '
import sys
from pathlib import Path

for root in sys.argv[1:]:
    rp = Path(root)
    if not rp.is_dir():
        continue
    for child in sorted(rp.iterdir(), key=lambda p: p.name.lower()):
        if child.is_dir() and not child.name.startswith("."):
            print(str(child))
PY
)" || return 0
            if [ -n "$pick" ] && [ -d "$pick" ]; then
                cd "$pick" || return 1
            fi
            return 0
        fi
        p --list
        printf 'Usage: p <name> | p --add [<path>] | p --remove [<path>] | p --list\n\n'
        return 0
    fi

    local target_dir
    target_dir="$("${RIG_PYTHON:-python3}" - "$arg1" "${roots[@]}" <<'PY'
import sys
from pathlib import Path

query = sys.argv[1].lower()
roots = [Path(r) for r in sys.argv[2:]]
partial = []

for rp in roots:
    if not rp.is_dir():
        continue
    for child in sorted(rp.iterdir(), key=lambda p: p.name.lower()):
        if not child.is_dir():
            continue
        cname = child.name.lower()
        if cname == query:
            print(str(child))
            sys.exit(0)
        if query in cname:
            partial.append(str(child))

if partial:
    print(partial[0])
    sys.exit(0)
sys.exit(1)
PY
)"
    if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
        cd "$target_dir" || return 1
    else
        printf "Project matching '%s' not found in configured roots.\n" "$arg1" >&2
        return 1
    fi
}

# @cmd: open — Reveal path in file manager (xdg-open on Linux, explorer.exe on WSL)
open() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        printf 'Usage: open [<path>]\n\nOpen <path> (default: current directory) in the desktop file manager.\n'
        return 0
    fi
    local target="${1:-.}"
    if [ ! -e "$target" ]; then
        printf '✖ open: Path not found: %s\n' "$target" >&2
        return 1
    fi
    local abs_target
    if [ -d "$target" ]; then
        abs_target="$(cd "$target" && pwd)"
    else
        abs_target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    fi

    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ]; then
        if command -v explorer.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
            explorer.exe "$(wslpath -w "$abs_target")" >/dev/null 2>&1 &
            return 0
        fi
    fi

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$abs_target" >/dev/null 2>&1 &
        return 0
    fi
    if command -v open >/dev/null 2>&1; then
        command open "$abs_target" >/dev/null 2>&1 &
        return 0
    fi

    printf '✖ open: Neither xdg-open nor explorer.exe found.\n' >&2
    return 1
}
