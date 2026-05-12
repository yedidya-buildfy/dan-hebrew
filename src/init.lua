-- dan-hebrew — Hebrew utilities for Hammerspoon.
local hotkeyManager       = require("hotkey_manager")
local clipMan             = require("clipboard_manager")
local langConverter       = require("language_converter")

local config = hotkeyManager.getConfig()

-- Cmd+Alt+K (default) — convert selected text between EN ⇄ HE.
hs.hotkey.bind(config.convertLanguage.mods, config.convertLanguage.key, function()
  hotkeyManager.incrementUsage("convertLanguage")
  langConverter.run()
end)

-- Cmd+Alt+V (default) — clipboard history panel.
clipMan.start(hotkeyManager)

-- Cmd+Alt+H — open the hotkey manager UI.
hs.hotkey.bind({"cmd","alt"}, "H", function()
  hotkeyManager.openManager()
end)

hs.alert.show("✓ dan-hebrew loaded")
