#!/usr/bin/env bash
# dan-hebrew installer — symlinks the source files into ~/.hammerspoon
# without overwriting an existing init.lua.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/src"
HS_DIR="$HOME/.hammerspoon"

mkdir -p "$HS_DIR"

# Symlink the modules.
for f in language_converter.lua clipboard_manager.lua hotkey_manager.lua bidi_clipboard.lua; do
  ln -sf "$SRC_DIR/$f" "$HS_DIR/$f"
  echo "linked  $HS_DIR/$f  →  $SRC_DIR/$f"
done

# init.lua handling — don't overwrite an existing one.
if [ -e "$HS_DIR/init.lua" ] && [ ! -L "$HS_DIR/init.lua" ]; then
  cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.bak.$(date +%s)"
  echo "backed up existing init.lua"
  echo ""
  echo "⚠️  An existing init.lua was backed up. Manually merge the contents of"
  echo "    $SRC_DIR/init.lua into your $HS_DIR/init.lua."
else
  ln -sf "$SRC_DIR/init.lua" "$HS_DIR/init.lua"
  echo "linked  $HS_DIR/init.lua  →  $SRC_DIR/init.lua"
fi

echo ""
echo "✅ Done. Open Hammerspoon → Reload Config (or restart it)."
