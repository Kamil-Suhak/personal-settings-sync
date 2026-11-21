#!/usr/bin/env bash
set -euo pipefail

dir="$HOME/Pictures/Screenshots"
mkdir -p "$dir"
file="$dir/screenshot-$(date +%Y%m%d-%H%M%S).png"

geom="$(slurp)" || exit 0
grim -g "$geom" "$file"

# Copy path first so cliphist records it, then copy the image as the active clipboard item
printf '%s' "$file" | wl-copy
sleep 0.1
wl-copy < "$file"
