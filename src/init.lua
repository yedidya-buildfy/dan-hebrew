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

-- Cmd+Alt+Z (default) — select all, then convert (EN ⇄ HE).
hs.hotkey.bind(config.convertLanguageAll.mods, config.convertLanguageAll.key, function()
  hotkeyManager.incrementUsage("convertLanguageAll")
  hs.eventtap.keyStroke({"cmd"}, "a", 0)
  hs.timer.doAfter(0.05, function() langConverter.run() end)
end)

-- Cmd+Alt+V (default) — clipboard history panel.
clipMan.start(hotkeyManager)

-- Cmd+Alt+H (default) — open the hotkey manager UI.
hs.hotkey.bind(config.openManager.mods, config.openManager.key, function()
  hotkeyManager.incrementUsage("openManager")
  hotkeyManager.openManager()
end)

-- Lets `open -g hammerspoon://reload` reload the config without the menu bar.
hs.urlevent.bind("reload", function() hs.reload() end)

hs.alert.show("✓ dan-hebrew loaded")
