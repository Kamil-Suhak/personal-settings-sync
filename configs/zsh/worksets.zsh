# Shared issue file sets ('worksets') shell integration

# @cmd: workset — Manage named cross-repository issue file sets backed by Obsidian notes (new, add, rm, show, edit, open, gh, list, archive, restore, delete)
workset() {
    "${RIG_PYTHON:-python3}" "$RIG_ROOT/configs/bin/workset" "$@"
    local rc=$?
    case " $* " in
        *" --prompt-badge "*|*" --current-name "*) return "$rc" ;;
    esac
    if [ "$rc" -eq 0 ] && command -v _rig_update_prompt_vars >/dev/null 2>&1; then
        _rig_update_prompt_vars
    fi
    return "$rc"
}
