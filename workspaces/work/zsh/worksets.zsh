# Work workspace issue file sets ('worksets') shell integration

# @cmd: workset — Manage named cross-repository issue file sets (new, add, show, edit, open, list, archive, restore, delete)
workset() {
    "${PSS_PYTHON:-python3}" "$PSS_ROOT/workspaces/work/bin/workset" "$@"
    local rc=$?
    if [ "$rc" -eq 0 ] && command -v _pss_update_prompt_vars >/dev/null 2>&1; then
        _pss_update_prompt_vars
    fi
    return "$rc"
}
