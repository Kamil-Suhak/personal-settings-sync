#!/usr/bin/env sh
# One-line bootstrapper for rig on EndeavourOS (Arch) and WSL2.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Kamil-Suhak/rig/main/bootstrap.sh | sh -s -- --workspace personal

set -eu

REPO_OWNER="Kamil-Suhak"
REPO_NAME="rig"
BRANCH="zsh"
TARGET_DIR="$HOME/code/projects/rig"
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
    TMP_TAR="$(mktemp -t rig-bootstrap.XXXXXX.tar.gz)"
    TMP_DIR="$(mktemp -d -t rig-extract.XXXXXX)"
    cleanup() { rm -rf "$TMP_TAR" "$TMP_DIR"; }
    trap cleanup EXIT
    curl -fsSL "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.tar.gz" -o "$TMP_TAR"
    tar -xzf "$TMP_TAR" -C "$TMP_DIR"
    mkdir -p "$TARGET_DIR"
    cp -a "$TMP_DIR"/"$REPO_NAME"-"$BRANCH"/. "$TARGET_DIR"/
fi

RIG_BIN="$TARGET_DIR/rig"
if [ ! -f "$RIG_BIN" ]; then
    echo "ERROR: Could not locate rig in $TARGET_DIR" >&2
    exit 1
fi

PY_BIN="python3"
command -v python3 >/dev/null 2>&1 || PY_BIN="python"

if [ -n "$WORKSPACE" ]; then
    echo ">>> Binding active workspace '$WORKSPACE'..."
    "$PY_BIN" "$RIG_BIN" workspace use "$WORKSPACE" --no-apply
fi

if [ "$SKIP_APPS" -eq 0 ]; then
    echo ">>> Installing workspace packages..."
    "$PY_BIN" "$RIG_BIN" apps install || true
fi

if [ "$SKIP_SETUP" -eq 0 ]; then
    echo ">>> Running Linux developer environment setup..."
    "$PY_BIN" "$RIG_BIN" setup || true
fi

echo ">>> Linking configurations via rig apply..."
"$PY_BIN" "$RIG_BIN" apply

echo "Setup complete! Start a new Zsh session with: exec zsh -l"
