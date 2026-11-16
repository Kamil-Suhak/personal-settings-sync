# Shared issue file sets ('worksets') shell integration

# @cmd: workset — Manage named cross-repository issue file sets backed by Obsidian notes (new, add, rm, show, edit, open, gh, list, archive, restore, delete)
workset() {
    "${PSS_PYTHON:-python3}" "$PSS_ROOT/configs/bin/workset" "$@"
    local rc=$?
    if [ "$rc" -eq 0 ] && command -v _pss_update_prompt_vars >/dev/null 2>&1; then
        _pss_update_prompt_vars
    fi
    return "$rc"
}
