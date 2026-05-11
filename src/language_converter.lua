-- Language converter (EN ⇄ HE) for Hammerspoon.
-- Two paths:
--   GUI       → Cmd+V replaces the selection atomically.
--   Terminal  → walk-back from end-of-line until a Shift+Left selection matches
--               the copied target, then delete + inject Unicode.
local M = {}

local DEBUG = false
local function log(...) if DEBUG then print("[lang]", ...) end end

local ENG_IDS = { "com.apple.keylayout.ABC", "com.apple.keylayout.US" }
local HEB_IDS = { "com.apple.keylayout.Hebrew" }

-- Apps treated as terminal context (use backspace+type instead of Cmd+V).
-- Includes IDEs because the user works almost exclusively in their integrated
-- terminal panels, not in code editors.
local TERMINAL_BUNDLES = {
  ["com.apple.Terminal"]            = true,
  ["com.googlecode.iterm2"]         = true,
  ["dev.warp.Warp-Stable"]          = true,
  ["com.microsoft.VSCode"]          = true,
  ["com.microsoft.VSCodeInsiders"]  = true,
  ["com.visualstudio.code.oss"]     = true,
  ["com.todesktop.230313mzl4w4u92"] = true,  -- Cursor
  ["com.exafunction.windsurf"]      = true,
  ["com.google.antigravity"]        = true,
}

local TIMING = {
  clipboardWaitUs = 150000,
  pasteWaitUs     = 120000,
  switchDelaySec  = 0.15,
  modReleaseSec   = 0.12,
}

-- Israeli (macOS "Hebrew") layout, key-by-key.
local engToHeb = {
  q="/", w="'", e="ק", r="ר", t="א", y="ט", u="ו", i="ן", o="ם", p="פ",
  a="ש", s="ד", d="ג", f="כ", g="ע", h="י", j="ח", k="ל", l="ך",
  z="ז", x="ס", c="ב", v="ה", b="נ", n="מ", m="צ",
  ["`"]=";", ["["]="]", ["]"]="[",
  [";"]="ף", ["'"]=",",
  [","]="ת", ["."]="ץ", ["/"]=".",
}

local hebToEng = {}
for k, v in pairs(engToHeb) do hebToEng[v] = k end
hebToEng["׳"] = "w"
hebToEng["״"] = "w"

local function isIn(list, val)
  for _, v in ipairs(list) do if v == val then return true end end
  return false
end

local function utf8Len(s)
  local n = 0
  for _ in utf8.codes(s or "") do n = n + 1 end
  return n
end

local function utf8Reverse(s)
  local chars = {}
  for _, cp in utf8.codes(s or "") do
    table.insert(chars, 1, utf8.char(cp))
  end
  return table.concat(chars)
end

local function detectEnglish(text)
  local eng, heb = 0, 0
  for _, cp in utf8.codes(text) do
    if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) then
      eng = eng + 1
    elseif cp >= 0x05D0 and cp <= 0x05F4 then
      heb = heb + 1
    end
  end
  if eng == 0 and heb == 0 then return nil end
  return eng >= heb
end

local function convertText(text, fromEng)
  local out = {}
  for _, cp in utf8.codes(text) do
    local ch = utf8.char(cp)
    if fromEng then
      table.insert(out, engToHeb[ch:lower()] or ch)
    else
      table.insert(out, hebToEng[ch] or ch)
    end
  end
  return table.concat(out)
end

local function setInputSource(list)
  for _, id in ipairs(list) do
    if hs.keycodes.currentSourceID() == id then return true end
    if hs.keycodes.currentSourceID(id) then return true end
  end
  return false
end

local function switchToEnglish() setInputSource(ENG_IDS) end
local function switchToHebrew() setInputSource(HEB_IDS) end

local function toggleInputSource()
  local curr = hs.keycodes.currentSourceID()
  if isIn(ENG_IDS, curr) then switchToHebrew() else switchToEnglish() end
end

local function snapshotClipboard()
  if hs.pasteboard.readAllData then
    return { kind = "all",  data = hs.pasteboard.readAllData() }
  end
  return   { kind = "text", data = hs.pasteboard.getContents() }
end

local function restoreClipboard(snap)
  if not snap then return end
  if snap.kind == "all" and snap.data and hs.pasteboard.writeAllData then
    hs.pasteboard.writeAllData(snap.data)
  else
    hs.pasteboard.setContents(snap.data or "")
  end
end

local function copySelection()
  local prev = snapshotClipboard()
  hs.pasteboard.setContents("")
  hs.eventtap.keyStroke({"cmd"}, "c", 0)
  hs.timer.usleep(TIMING.clipboardWaitUs)
  local got = hs.pasteboard.getContents() or ""
  return got, got ~= "", prev
end

local function isTerminalContext()
  local app = hs.application.frontmostApplication()
  return app and TERMINAL_BUNDLES[app:bundleID()] == true
end

-- GUI path: paste replaces the still-active selection.
local function replaceInGui(converted, prevSnap)
  hs.pasteboard.setContents(converted)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
  hs.timer.usleep(TIMING.pasteWaitUs)
  restoreClipboard(prevSnap)
end

-- Terminal path: shell caret is decoupled from mouse selection, so we can
-- only reliably replace text that ends at the line's end. Switch input source
-- BEFORE injecting so RTL terminals don't visually reverse Latin output.
local function replaceInTerminal(target, converted, fromEng, prevSnap)
  local n = utf8Len(target)
  restoreClipboard(prevSnap)
  hs.timer.doAfter(TIMING.modReleaseSec, function()
    if fromEng then switchToHebrew() else switchToEnglish() end
    hs.hid.capslock.set(false)
    for _ = 1, n do
      hs.eventtap.keyStroke({}, "delete", 0)
    end
    -- Claude Code (and similar terminal TUIs) renders Hebrew left-to-right,
    -- so the copied selection arrives in visual order. Reverse before typing
    -- the English back so the result reads correctly.
    local toType = (not fromEng) and utf8Reverse(converted) or converted
    hs.eventtap.keyStrokes(toType)
  end)
end

local function finalizeGui(toEnglish)
  hs.timer.doAfter(TIMING.switchDelaySec, function()
    if toEnglish then switchToEnglish() else switchToHebrew() end
    hs.hid.capslock.set(false)
  end)
end

function M.run()
  local selected, hadSelection, prevSnap = copySelection()

  if not hadSelection then
    toggleInputSource()
    hs.hid.capslock.set(false)
    restoreClipboard(prevSnap)
    return
  end

  local fromEng = detectEnglish(selected)
  if fromEng == nil then
    restoreClipboard(prevSnap)
    return
  end

  local converted = convertText(selected, fromEng)
  log("convert", fromEng and "EN→HE" or "HE→EN", "len="..utf8Len(selected))

  if isTerminalContext() then
    replaceInTerminal(selected, converted, fromEng, prevSnap)
  else
    replaceInGui(converted, prevSnap)
    finalizeGui(not fromEng)
  end
end

return M
