#!/usr/bin/env sh
# One-line bootstrapper for personal-settings-sync on EndeavourOS (Arch) and WSL2.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Kamil-Suhak/personal-settings-sync/main/bootstrap.sh | sh -s -- --workspace personal

set -eu

REPO_OWNER="Kamil-Suhak"
REPO_NAME="personal-settings-sync"
BRANCH="zsh"
TARGET_DIR="$HOME/Coding/Projects/personal-settings-sync"
WORKSPACE=""
SKIP_APPS=0
SKIP_SETUP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --owner) REPO_OWNER="$2"; shift 2 ;;
        --repo) REPO_NAME="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --target-dir) TARGET_DIR="$2"; shift 2 ;;
        --workspace|-w) WORKSPACE="$2"; shift 2 ;;
        --skip-apps) SKIP_APPS=1; shift ;;
        --skip-setup) SKIP_SETUP=1; shift ;;
        -h|--help)
            echo "Usage: bootstrap.sh [--workspace <personal|work>] [--target-dir <path>] [--branch <name>] [--skip-apps] [--skip-setup]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

echo "=========================================================="
echo "   Personal Settings Sync - Linux / WSL Machine Setup     "
echo "=========================================================="

mkdir -p "$(dirname "$TARGET_DIR")"

if [ -d "$TARGET_DIR/.git" ]; then
    echo ">>> Repository already exists at $TARGET_DIR; pulling latest..."
    git -C "$TARGET_DIR" pull --ff-only || true
elif command -v git >/dev/null 2>&1; then
    echo ">>> Cloning $REPO_OWNER/$REPO_NAME ($BRANCH) to $TARGET_DIR..."
    git clone --branch "$BRANCH" "https://github.com/$REPO_OWNER/$REPO_NAME.git" "$TARGET_DIR"
else
    echo ">>> Downloading archive $REPO_OWNER/$REPO_NAME@$BRANCH..."
    TMP_TAR="$(mktemp -t pss-bootstrap.XXXXXX.tar.gz)"
    TMP_DIR="$(mktemp -d -t pss-extract.XXXXXX)"
    cleanup() { rm -rf "$TMP_TAR" "$TMP_DIR"; }
    trap cleanup EXIT
    curl -fsSL "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.tar.gz" -o "$TMP_TAR"
    tar -xzf "$TMP_TAR" -C "$TMP_DIR"
    mkdir -p "$TARGET_DIR"
    cp -a "$TMP_DIR"/"$REPO_NAME"-"$BRANCH"/. "$TARGET_DIR"/
fi

PSS_BIN="$TARGET_DIR/pss"
if [ ! -f "$PSS_BIN" ]; then
    echo "ERROR: Could not locate pss in $TARGET_DIR" >&2
    exit 1
fi

PY_BIN="python3"
command -v python3 >/dev/null 2>&1 || PY_BIN="python"

if [ -n "$WORKSPACE" ]; then
    echo ">>> Binding active workspace '$WORKSPACE'..."
    "$PY_BIN" "$PSS_BIN" workspace use "$WORKSPACE" --no-apply
fi

if [ "$SKIP_APPS" -eq 0 ]; then
    echo ">>> Installing workspace packages..."
    "$PY_BIN" "$PSS_BIN" apps install || true
fi

if [ "$SKIP_SETUP" -eq 0 ]; then
    echo ">>> Running Linux developer environment setup..."
    "$PY_BIN" "$PSS_BIN" setup || true
fi

echo ">>> Linking configurations via pss apply..."
"$PY_BIN" "$PSS_BIN" apply

echo "Setup complete! Start a new Zsh session with: exec zsh -l"
