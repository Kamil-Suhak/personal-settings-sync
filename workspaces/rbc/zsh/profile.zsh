# RBC workspace Zsh profile overrides (inherits from work)

# @cmd: optify-issues — List or interactively pick assigned OptifyRequirements project issues
optify-issues() {
    local pick=0
    local show_all=0
    local status_filter=""
    local backend_filter=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                cat <<'EOF'
Usage: optify-issues [options]

List issues assigned to you in the OptifyRequirements GitHub Project (default: backendStatus != Ready).
Options:
  -i, --pick            Pick an issue interactively with fzf and run 'gh issue view'
  -a, --all             Include issues where backendStatus is Ready
  --status <text>       Filter by board status (case-insensitive substring)
  --backend <text>      Filter by backendStatus (case-insensitive substring)
  -h, --help            Show this help
EOF
                return 0
                ;;
            -i|--pick)
                pick=1
                shift
                ;;
            -a|--all)
                show_all=1
                shift
                ;;
            --status)
                status_filter="${2:-}"
                shift 2
                ;;
            --backend)
                backend_filter="${2:-}"
                shift 2
                ;;
            *)
                printf "✖ optify-issues: Unknown option '%s'\n" "$1" >&2
                return 2
                ;;
        esac
    done

    local me raw_json
    me="$(gh api user -q .login)" || return 1
    raw_json="$(gh project item-list 11 --owner Dodge-MPTC --limit 200 --format json)" || return 1

    local formatted
    formatted="$(printf '%s' "$raw_json" | jq -r \
        --arg me "$me" \
        --argjson show_all "$show_all" \
        --arg status_f "$status_filter" \
        --arg backend_f "$backend_filter" '
        .items[]
        | select(
            .content.type == "Issue"
            and ((.assignees // []) | index($me))
            and ($show_all == 1 or (.backendStatus // "") != "Ready")
            and ($status_f == "" or ((.status // "") | ascii_downcase | contains($status_f | ascii_downcase)))
            and ($backend_f == "" or ((.backendStatus // "Unset") | ascii_downcase | contains($backend_f | ascii_downcase)))
          )
        | "#\(.content.number)\t\(.status // "No Status")\t\(.backendStatus // "Unset")\t\(.title)"
      ' | column -t -s $'\t')"

    [ -z "$formatted" ] && return 0

    local colorized
    if [ -t 1 ] || [ "$pick" -eq 1 ]; then
        colorized="$(printf '%s\n' "$formatted" | awk '
        {
          line = $0
          sub(/^#[0-9]+/, "\033[1;36m&\033[0m", line)
          gsub(/InProgress/, "\033[1;33mInProgress\033[0m", line)
          gsub(/ToDo/,       "\033[0;34mToDo\033[0m", line)
          gsub(/Unset/,      "\033[2;37mUnset\033[0m", line)
          gsub(/\[Epic\]/,   "\033[1;35m[Epic]\033[0m", line)
          gsub(/\[US\]/,     "\033[1;32m[US]\033[0m", line)
          gsub(/\[Bug\]/,    "\033[1;31m[Bug]\033[0m", line)
          sub(/In progress development \(PL\)/, "\033[2m&\033[0m", line)
          print line
        }')"
    else
        colorized="$formatted"
    fi

    if [ "$pick" -eq 1 ]; then
        if ! command -v fzf >/dev/null 2>&1; then
            printf "✖ optify-issues: 'fzf' is required for --pick.\n" >&2
            return 1
        fi
        local chosen num repo
        chosen="$(printf '%s\n' "$colorized" | fzf --ansi --height 50% --reverse --prompt="issue> ")" || return 0
        num="${chosen%% *}"
        num="${num#\#}"
        [ -z "$num" ] && return 0
        repo="$(printf '%s' "$raw_json" | jq -r --argjson n "$num" '.items[] | select(.content.number == $n) | .content.repository // empty' | head -n 1)"
        if [ -n "$repo" ]; then
            gh issue view "$num" -R "$repo"
        else
            gh issue view "$num"
        fi
        return $?
    fi

    printf '%s\n' "$colorized"
}
