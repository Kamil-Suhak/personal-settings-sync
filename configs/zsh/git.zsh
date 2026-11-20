# Shared Git workflow commands (sourced by init.zsh)

# @cmd: st — Show upstream delta, working tree status, stashes, and branch comparison
st() {
    "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/st" "$@"
}

# @cmd: unpushed — Scan repos or project roots for unpushed commits and dirty trees
unpushed() {
    "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/unpushed" "$@"
}

# @cmd: gdiff — Context-aware git diff viewer (unstaged, staged, all, up, pr <branch>, last)
gdiff() {
    "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/git-rig-diff" "$@"
}

# @cmd: b — Switch git branches (pass name directly or pick interactively with fzf)
b() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        cat <<'EOF'
Usage: b [<branch>]

Switch to <branch>, or open an interactive fzf branch selector when omitted.
EOF
        return 0
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '✖ b: not inside a git repository.\n' >&2
        return 1
    fi

    if [ "$#" -gt 0 ]; then
        local target="$1"
        if git show-ref --verify --quiet "refs/heads/$target"; then
            git switch "$target"
        else
            git switch --track "origin/$target" 2>/dev/null || git switch "$target"
        fi
        return $?
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        git branch -a
        return 0
    fi

    local choice
    choice="$(git branch --all --format='%(refname:short)' | grep -v '/HEAD$' | sort -u | fzf --height 40% --reverse --prompt='branch> ')" || return 0
    if [ -z "$choice" ]; then
        return 0
    fi
    if [[ "$choice" == origin/* ]]; then
        local local_name="${choice#origin/}"
        if git show-ref --verify --quiet "refs/heads/$local_name"; then
            git switch "$local_name"
        else
            git switch --track "$choice"
        fi
    else
        git switch "$choice"
    fi
}

# @cmd: nb — Create and switch to a new branch (optionally from a base branch)
nb() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ] || [ "$#" -eq 0 ]; then
        cat <<'EOF'
Usage: nb <new-branch> [<base-branch>]

Create a new git branch and switch to it immediately.
EOF
        [ "$#" -eq 0 ] && return 1 || return 0
    fi

    if [ "$#" -ge 2 ]; then
        git switch -c "$1" "$2"
    else
        git switch -c "$1"
    fi
}

# @cmd: lg — Compact colored git graph log (default 20 commits)
lg() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        cat <<'EOF'
Usage: lg [<count>] [git-log-args...]

Display a compact graph log of recent commits (default: 20).
EOF
        return 0
    fi

    local count=20
    if [ "$#" -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        count="$1"
        shift
    fi
    git log --graph --decorate --oneline -n "$count" "$@"
}

# @cmd: wip — Stage all changes and create a temporary bypass-hooks WIP commit
wip() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        cat <<'EOF'
Usage: wip [<note>]

Stage all working-tree changes and commit with message 'chore: wip...' (--no-verify).
EOF
        return 0
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '✖ wip: not inside a git repository.\n' >&2
        return 1
    fi
    if [ -z "$(git status --porcelain)" ]; then
        printf 'Working tree is clean; nothing to wip.\n'
        return 0
    fi
    local msg="chore: wip"
    if [ "$#" -gt 0 ]; then
        msg="chore: wip - $*"
    fi
    git add -A && git commit --no-verify -m "$msg"
}

# @cmd: unwip — Undo the latest commit back to the working tree if it is a WIP commit
unwip() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        cat <<'EOF'
Usage: unwip

Reset HEAD~1 back to the working tree only when the latest commit is a WIP commit.
EOF
        return 0
    fi

    local subject
    subject="$(git log -1 --pretty=%s 2>/dev/null)" || {
        printf '✖ unwip: failed to read latest commit.\n' >&2
        return 1
    }
    case "$subject" in
        "chore: wip"*|wip*|WIP*)
            git reset HEAD~1
            ;;
        *)
            printf "✖ unwip: latest commit '%s' is not a WIP commit.\n" "$subject" >&2
            return 1
            ;;
    esac
}

# @cmd: stashes — Browse and apply git stashes interactively with fzf (or list them)
stashes() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        cat <<'EOF'
Usage: stashes

Browse stashes with preview via fzf and apply selected stash (or list stashes).
EOF
        return 0
    fi

    local list
    list="$(git stash list 2>/dev/null)"
    if [ -z "$list" ]; then
        printf 'No stashes.\n'
        return 0
    fi
    if ! command -v fzf >/dev/null 2>&1 || [ ! -t 0 ]; then
        printf '%s\n' "$list"
        return 0
    fi
    local selected
    selected="$(printf '%s\n' "$list" | fzf --height 50% --reverse --delimiter=':' --preview 'git stash show -p {1}' --prompt='stash> ')" || return 0
    local ref="${selected%%:*}"
    if [ -n "$ref" ]; then
        git stash apply "$ref"
    fi
}

# @cmd: groot — Change directory to the top-level root of the current git repository
groot() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-Help" ]; then
        printf 'Usage: groot\n\ncd to the current git repository root.\n'
        return 0
    fi
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        printf '✖ groot: not inside a git repository.\n' >&2
        return 1
    }
    cd "$top" || return 1
}
