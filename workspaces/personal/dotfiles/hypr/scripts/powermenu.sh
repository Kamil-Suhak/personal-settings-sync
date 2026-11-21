#!/usr/bin/env bash
set -euo pipefail

choice=$(printf "Lock\nSuspend\nLogout\nReboot\nShutdown" | fuzzel --dmenu --prompt="Power: " --lines=5)

case "$choice" in
  Lock) hyprlock ;;
  Suspend) systemctl suspend ;;
  Logout) hyprctl dispatch exit ;;
  Reboot) systemctl reboot ;;
  Shutdown) systemctl poweroff ;;
esac
