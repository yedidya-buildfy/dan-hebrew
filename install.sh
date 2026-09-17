#!/usr/bin/env bash
# dan-hebrew installer — safe to run again and again (install and update alike):
# every step checks first and only changes what is not already in place.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/src"
HS_DIR="$HOME/.hammerspoon"

# 1. Hammerspoon itself.
# Asked of Launch Services, so a copy kept outside /Applications counts too.
if ! open -Ra Hammerspoon >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "installing Hammerspoon…"
    brew install --cask hammerspoon
  else
    echo "⚠️  Hammerspoon is not installed and Homebrew is missing."
    echo "    Download it from https://www.hammerspoon.org/ and run ./install.sh again."
    exit 1
  fi
fi

mkdir -p "$HS_DIR"

# 2. Every module in src/ (tests excluded), so a module added in an update is
#    linked by the next run without editing this list.
for path in "$SRC_DIR"/*.lua; do
  f="$(basename "$path")"
  case "$f" in init.lua|*_test.lua) continue ;; esac
  if [ "$(readlink "$HS_DIR/$f" 2>/dev/null)" != "$path" ]; then
    ln -sfn "$path" "$HS_DIR/$f"
    echo "linked  $HS_DIR/$f  →  $path"
  fi
done

# 3. init.lua — never overwrite one the user wrote.
if [ -e "$HS_DIR/init.lua" ] && [ ! -L "$HS_DIR/init.lua" ]; then
  if grep -q 'require("clipboard_manager")' "$HS_DIR/init.lua"; then
    : # already wired into their own init.lua
  else
    # One backup per distinct content: re-running does not pile up copies.
    already=""
    for b in "$HS_DIR"/init.lua.bak.*; do
      [ -e "$b" ] && cmp -s "$b" "$HS_DIR/init.lua" && already="$b" && break
    done
    if [ -z "$already" ]; then
      cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.bak.$(date +%s)"
      echo "backed up existing init.lua"
    fi
    echo ""
    echo "⚠️  You have your own init.lua. Merge the contents of"
    echo "    $SRC_DIR/init.lua into $HS_DIR/init.lua, then run ./install.sh again."
  fi
elif [ "$(readlink "$HS_DIR/init.lua" 2>/dev/null)" != "$SRC_DIR/init.lua" ]; then
  ln -sfn "$SRC_DIR/init.lua" "$HS_DIR/init.lua"
  echo "linked  $HS_DIR/init.lua  →  $SRC_DIR/init.lua"
fi

# 4. Load the new code: restart Hammerspoon if it runs, start it if not.
if pgrep -x Hammerspoon >/dev/null 2>&1; then
  osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Hammerspoon >/dev/null 2>&1 || break; sleep 0.5; done
fi
open -g -a Hammerspoon

echo ""
echo "✅ Done — you should see \"✓ dan-hebrew loaded\"."
echo "   First time only: System Settings → Privacy & Security → Accessibility → turn Hammerspoon on."
echo "   To update later:  cd \"$REPO_DIR\" && git pull && ./install.sh"
