#!/usr/bin/env sh
# Run-once Linux (EndeavourOS / WSL2) environment tweaks, JetBrains Mono font, git identity, project roots, and Zsh default shell.

set -eu

WHAT_IF=0
FORCE=0
FONTS_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --what-if|-WhatIf) WHAT_IF=1; shift ;;
        --force|-Force) FORCE=1; shift ;;
        --fonts-only|-FontsOnly) FONTS_ONLY=1; shift ;;
        -h|--help)
            echo "Usage: setup-linux.sh [--fonts-only] [--what-if] [--force]"
            exit 0
            ;;
        *) shift ;;
    esac
done

install_fonts() {
    font_dir="$HOME/.local/share/fonts"
    check_file="$font_dir/JetBrainsMono-Regular.ttf"
    if [ -f "$check_file" ] && [ "$FORCE" -eq 0 ]; then
        echo "[OK] JetBrains Mono font is already installed in $font_dir."
        return 0
    fi
    if fc-list 2>/dev/null | grep -qi "JetBrainsMono" && [ "$FORCE" -eq 0 ]; then
        echo "[OK] JetBrains Mono font is already installed."
        return 0
    fi
    if [ "$WHAT_IF" -eq 1 ]; then
        echo "[WHAT-IF] Would install JetBrains Mono font."
        return 0
    fi

    if command -v pacman >/dev/null 2>&1; then
        echo "[INSTALL] Installing ttf-jetbrains-mono-nerd via pacman..."
        sudo pacman -S --needed --noconfirm ttf-jetbrains-mono-nerd && return 0
    fi

    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
        tmp_dir="$(mktemp -d)"
        cleanup_font() { rm -rf "$tmp_dir"; }
        mkdir -p "$font_dir"
        url="https://download.jetbrains.com/fonts/JetBrainsMono-2.304.zip"
        echo "[DOWNLOAD] Fetching JetBrains Mono from $url..."
        curl -fsSL "$url" -o "$tmp_dir/jbm.zip"
        unzip -oq "$tmp_dir/jbm.zip" "fonts/ttf/*.ttf" -d "$tmp_dir/out" 2>/dev/null || unzip -oq "$tmp_dir/jbm.zip" -d "$tmp_dir/out"
        find "$tmp_dir/out" -type f -name "*.ttf" ! -name "*\[*" -exec cp -f {} "$font_dir/" \;
        rm -rf "$tmp_dir"
        if command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$font_dir" >/dev/null 2>&1 || true
        fi
        echo "[APPLIED] Installed JetBrains Mono into $font_dir"
    else
        echo "[WARN] Install 'ttf-jetbrains-mono-nerd' (Arch) or curl+unzip to install JetBrains Mono."
    fi
}

configure_git_identity() {
    current_email="$(git config --global user.email 2>/dev/null || true)"
    if [ -n "$current_email" ] && [ "$FORCE" -eq 0 ]; then
        echo "[OK] Git user identity already configured in ~/.gitconfig."
        return 0
    fi
    if [ "$WHAT_IF" -eq 1 ]; then
        echo "[WHAT-IF] Would prompt for Git user.name and user.email in ~/.gitconfig"
        return 0
    fi
    if [ -t 0 ]; then
        printf "Enter Git user.name: "
        read -r g_name
        printf "Enter Git user.email: "
        read -r g_email
        [ -n "$g_name" ] && git config --global user.name "$g_name"
        [ -n "$g_email" ] && git config --global user.email "$g_email"
        echo "[APPLIED] Saved Git identity to ~/.gitconfig"
    fi
}

configure_project_roots() {
    state_home="${RIG_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/rig}"
    roots_file="$state_home/project-roots"
    if [ -f "$roots_file" ] && [ "$FORCE" -eq 0 ]; then
        echo "[OK] Project roots already configured in $roots_file."
        return 0
    fi
    if [ "$WHAT_IF" -eq 1 ]; then
        echo "[WHAT-IF] Would initialize project roots in $roots_file"
        return 0
    fi
    mkdir -p "$state_home" "$HOME/code/projects"
    printf "%s\n" "$HOME/code/projects" > "$roots_file"
    echo "[APPLIED] Initialized project roots in $roots_file"
}

configure_default_shell() {
    if ! command -v zsh >/dev/null 2>&1; then
        echo "[WARN] zsh not found on PATH; install zsh first."
        return 0
    fi
    zsh_bin="$(command -v zsh)"
    current_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "${SHELL:-}")"
    if [ "$current_shell" = "$zsh_bin" ]; then
        echo "[OK] Default login shell is already $zsh_bin."
        return 0
    fi
    if [ "$WHAT_IF" -eq 1 ]; then
        echo "[WHAT-IF] Would offer 'chsh -s $zsh_bin'"
        return 0
    fi
    if [ -t 0 ]; then
        printf "Set Zsh (%s) as your default login shell? [y/N] " "$zsh_bin"
        read -r reply
        case "$reply" in
            [Yy]*) chsh -s "$zsh_bin" && echo "[APPLIED] Default shell set to $zsh_bin" ;;
            *) echo "[SKIP] Kept current login shell ($current_shell)." ;;
        esac
    fi
}

install_fonts
if [ "$FONTS_ONLY" -eq 1 ]; then
    exit 0
fi

configure_git_identity
configure_project_roots
configure_default_shell

echo ""
echo "Linux/WSL setup complete!"
