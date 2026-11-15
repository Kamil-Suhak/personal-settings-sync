# Work workspace Zsh profile overrides (WSL2 Ubuntu)

# Optional Windows host git interop when working directly inside /mnt/<drive> repos
if [ "${PSS_WSL_GIT_INTEROP:-0}" = "1" ] && command -v git.exe >/dev/null 2>&1; then
    # @cmd: git — Route git calls inside /mnt/[a-z]/ to Windows git.exe when PSS_WSL_GIT_INTEROP=1
    git() {
        case "$PWD" in
            /mnt/[a-zA-Z]/*|/mnt/[a-zA-Z])
                git.exe "$@"
                ;;
            *)
                command git "$@"
                ;;
        esac
    }
fi

# @cmd: ask — Ask company-approved GitHub Copilot CLI (--ctx, piped stdin)
ask() {
    case "${1:-}" in
        -h|--help|-Help)
            cat <<'EOF'
Usage: ask [--ctx [<sel>]] <question>

Query GitHub Copilot CLI ('copilot -p') with streamed output and optional terminal context.
Accepts piped input (e.g. 'out | ask "explain this error"').
Options:
  --ctx         Include terminal command/output slice (default ~1; pass 2, ~2, or ~3..2 before question)
  -h, --help    Show this help
EOF
            return 0
            ;;
    esac

    local last_cmd=""
    if command -v _pss_last_history_command >/dev/null 2>&1; then
        last_cmd="$(_pss_last_history_command)"
    fi

    if [ -n "$last_cmd" ]; then
        "${PSS_PYTHON:-python3}" "$PSS_ROOT/configs/bin/ask-helper" run --engine copilot --fallback-command "$last_cmd" "$@"
    else
        "${PSS_PYTHON:-python3}" "$PSS_ROOT/configs/bin/ask-helper" run --engine copilot "$@"
    fi
}

# @cmd: azwho — Show active Azure CLI subscription, tenant, and signed-in user
azwho() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        printf 'Usage: azwho\n\nDisplay active Azure CLI subscription name, ID, tenant, and signed-in user.\n'
        return 0
    fi
    if ! command -v az >/dev/null 2>&1; then
        printf "✖ azwho: Azure CLI ('az') not found in PATH.\n" >&2
        return 1
    fi
    az account show --query "{Subscription:name, Id:id, Tenant:tenantId, User:user.name}" -o table
}

# Load worksets shell wrapper
if [ -f "$PSS_ROOT/workspaces/work/zsh/worksets.zsh" ]; then
    . "$PSS_ROOT/workspaces/work/zsh/worksets.zsh"
fi

_pss_find_devenv() {
    if command -v devenv >/dev/null 2>&1; then
        command -v devenv
        return 0
    fi
    if command -v devenv.exe >/dev/null 2>&1; then
        command -v devenv.exe
        return 0
    fi
    local vs_base="/mnt/c/Program Files/Microsoft Visual Studio"
    if [ -d "$vs_base" ]; then
        local found
        found="$("${PSS_PYTHON:-python3}" - "$vs_base" <<'PY'
import glob
import sys

hits = sorted(glob.glob(f"{sys.argv[1]}/*/*/Common7/IDE/devenv.exe"), reverse=True)
if hits:
    print(hits[0])
PY
)"
        if [ -n "$found" ] && [ -e "$found" ]; then
            printf '%s' "$found"
            return 0
        fi
    fi
    return 1
}

# @cmd: vs — Open Visual Studio .sln/.slnx found up to --max-depth parent levels (--what-if supported)
vs() {
    local target_path="."
    local max_depth=5
    local what_if=0
    local extra_files=()
    local got_path=0
    local reading_files=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help|-Help)
                cat <<'EOF'
Usage: vs [<path>] [--max-depth <n>] [--files <file>...] [--what-if]

Locate .sln/.slnx in <path> (or up to --max-depth parent directories) and open Visual Studio.
EOF
                return 0
                ;;
            -WhatIf|--what-if|-whatif)
                reading_files=0
                what_if=1
                shift
                ;;
            -MaxDepth|--max-depth|-m)
                reading_files=0
                shift
                if [ "$#" -eq 0 ]; then
                    printf '✖ vs: missing value after --max-depth\n' >&2
                    return 2
                fi
                max_depth="$1"
                shift
                ;;
            -Files|--files|-f)
                reading_files=1
                shift
                ;;
            -*)
                printf "✖ vs: Unknown flag '%s'\n" "$1" >&2
                return 2
                ;;
            *)
                if [ "$reading_files" -eq 1 ]; then
                    extra_files+=("$1")
                elif [ "$got_path" -eq 0 ]; then
                    target_path="$1"
                    got_path=1
                else
                    extra_files+=("$1")
                fi
                shift
                ;;
        esac
    done

    local resolved_info
    resolved_info="$("${PSS_PYTHON:-python3}" - "$target_path" "$max_depth" "${extra_files[@]}" <<'PY'
import json
import sys
from pathlib import Path

target = Path(sys.argv[1]).expanduser()
max_depth = max(0, min(20, int(sys.argv[2])))
extra_raw = sys.argv[3:]

if not target.exists():
    print(json.dumps({"error": f"✖ vs: Path not found: {target}"}))
    sys.exit(0)

resolved_files = []
for f_raw in extra_raw:
    fp = Path(f_raw).expanduser()
    if not fp.is_file():
        print(json.dumps({"error": f"✖ vs: File not found: {fp}"}))
        sys.exit(0)
    resolved_files.append(str(fp.resolve()))

solutions = []
if target.is_file() and target.suffix.lower() in (".sln", ".slnx"):
    solutions = [str(target.resolve())]
else:
    if target.is_dir():
        start_dir = target.resolve()
    else:
        start_dir = target.resolve().parent
        resolved_files.insert(0, str(target.resolve()))

    cur = start_dir
    for _ in range(max_depth + 1):
        hits = sorted(
            [p for p in cur.iterdir() if p.is_file() and p.suffix.lower() in (".sln", ".slnx")],
            key=lambda p: p.name.lower(),
        )
        if hits:
            solutions = [str(p.resolve()) for p in hits]
            break
        if cur.parent == cur:
            break
        cur = cur.parent

    if not solutions:
        print(
            json.dumps(
                {
                    "error": f"✖ vs: No .sln or .slnx file found in '{start_dir}' or within {max_depth} parent level(s)."
                }
            )
        )
        sys.exit(0)

dedup_files = []
for rf in resolved_files:
    if rf not in dedup_files:
        dedup_files.append(rf)

print(json.dumps({"solutions": solutions, "files": dedup_files}))
PY
)"

    local err_msg
    err_msg="$("${PSS_PYTHON:-python3}" - "$resolved_info" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
if "error" in data:
    print(data["error"])
PY
)"
    if [ -n "$err_msg" ]; then
        printf '%s\n' "$err_msg" >&2
        return 1
    fi

    local chosen_sln
    chosen_sln="$("${PSS_PYTHON:-python3}" - "$resolved_info" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
sols = data["solutions"]
if len(sols) == 1:
    print(sols[0])
else:
    print("\n".join(sols))
PY
)"

    local sln_count
    sln_count="$(printf '%s\n' "$chosen_sln" | wc -l | tr -d ' ')"
    local selected_sln=""
    if [ "$sln_count" -eq 1 ]; then
        selected_sln="$chosen_sln"
    elif [ "$what_if" -eq 0 ] && [ -t 0 ]; then
        printf '\nMultiple solutions found:\n'
        nl -w3 -s'] ' <<<"$chosen_sln" | sed 's/^/  [/'
        local pick
        printf '\nSelect solution [1-%s] (Enter for 1): ' "$sln_count"
        IFS= read -r pick || pick="1"
        pick="${pick:-1}"
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$sln_count" ]; then
            selected_sln="$(printf '%s\n' "$chosen_sln" | sed -n "${pick}p")"
        else
            printf 'Cancelled.\n'
            return 0
        fi
    else
        selected_sln="$(printf '%s\n' "$chosen_sln" | sed -n '1p')"
    fi

    local launch_files=()
    local f_line
    while IFS= read -r f_line; do
        [ -n "$f_line" ] && launch_files+=("$f_line")
    done < <("${PSS_PYTHON:-python3}" - "$resolved_info" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
for fp in data["files"]:
    print(fp)
PY
)

    local desc="Open '$selected_sln'"
    if [ "${#launch_files[@]}" -gt 0 ]; then
        desc="$desc and extra file(s)"
    fi

    if [ "$what_if" -eq 1 ]; then
        printf 'What if: Performing the operation "%s" on target "%s".\n' "$desc" "$selected_sln"
        return 0
    fi

    local devenv
    devenv="$(_pss_find_devenv)" || devenv=""
    if [ -n "$devenv" ]; then
        local args=()
        if command -v wslpath >/dev/null 2>&1 && [[ "$devenv" == *.exe ]]; then
            args+=("$(wslpath -w "$selected_sln")")
            for f_line in "${launch_files[@]}"; do
                args+=("$(wslpath -w "$f_line")")
            done
        else
            args+=("$selected_sln" "${launch_files[@]}")
        fi
        "$devenv" "${args[@]}" >/dev/null 2>&1 &
        return 0
    fi

    if [ "${#launch_files[@]}" -gt 0 ]; then
        printf '✖ vs: devenv not found; cannot open extra files alongside solution.\n' >&2
        return 1
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$selected_sln" >/dev/null 2>&1 &
        return 0
    fi
    printf '✖ vs: devenv executable not found.\n' >&2
    return 1
}

# @cmd - List issues assigned to me that are not BackendReady in the OptifyRequirements project.
optify-issues() {
    local me
    me="$(gh api user -q .login)" || return 1

    gh project item-list 11 --owner Dodge-MPTC --limit 200 --format json \
      | jq -r --arg me "$me" '
        .items[]
        | select(
            .content.type == "Issue"
            and (.backendStatus // "") != "Ready"
            and ((.assignees // []) | index($me))
          )
        | "#\(.content.number)\t\(.status // "No Status")\t\(.backendStatus // "Unset")\t\(.title)"
      ' \
      | column -t -s $'\t' \
      | if [[ -t 1 ]]; then
          awk '
          {
            line = $0
            # Issue number (#4519) -> cyan bold
            sub(/^#[0-9]+/, "\033[1;36m&\033[0m", line)

            # BackendStatus colors
            gsub(/InProgress/, "\033[1;33mInProgress\033[0m", line)
            gsub(/ToDo/,       "\033[0;34mToDo\033[0m", line)
            gsub(/Unset/,      "\033[2;37mUnset\033[0m", line)

            # Title tags ([US], [Epic], [Bug])
            gsub(/\[Epic\]/,   "\033[1;35m[Epic]\033[0m", line)
            gsub(/\[US\]/,     "\033[1;32m[US]\033[0m", line)
            gsub(/\[Bug\]/,    "\033[1;31m[Bug]\033[0m", line)

            # Dim the board status column ("In progress development (PL)")
            sub(/In progress development \(PL\)/, "\033[2m&\033[0m", line)

            print line
          }'
        else
          cat
        fi
}
