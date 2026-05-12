-- Wrong-layout watcher: notices when the current word looks like gibberish
-- in the active input source but a plausible word in the other one, and offers
-- a Tab-to-fix hint.
--
-- Detection v1 — simple heuristic:
--   * Hebrew layout suspicious if buffer contains a final-form letter
--     (ך ם ן ף ץ) in a non-final position — this is impossible in real Hebrew
--     and very common when typing English on a Hebrew layout (l→ך, o→ם, i→ן).
--   * English layout suspicious if buffer is ≥4 chars and has no vowel.
--   * Trigger only when current=suspicious AND converted=looks-fine.
--
-- Terminals (Claude Code, iTerm, Warp, IDEs in TERMINAL_BUNDLES) are skipped
-- entirely: they have their own RTL quirks and command-line text routinely
-- looks gibberish to a natural-language heuristic.
local M = {}

local lang = require("language_converter")

local DEBUG = false
local function log(...) if DEBUG then print("[wrong-layout]", ...) end end

local buffer = ""
local currentSuggestion = nil  -- { buffer, converted, isHebLayout }
local keyTap = nil
local mouseTap = nil
local appWatcher = nil
local hintAlertId = nil
local hintHideTimer = nil

local MIN_LEN_HEB = 3
local MIN_LEN_ENG = 3
local MAX_BUFFER  = 40
local HINT_TTL    = 4.0

local FINAL_FORMS = { ["ך"]=true, ["ם"]=true, ["ן"]=true, ["ף"]=true, ["ץ"]=true }
local ENG_VOWELS  = { a=true, e=true, i=true, o=true, u=true, y=true }

-- Top common English bigrams. If a word has length ≥ 3 and *none* of its
-- adjacent letter pairs appear here, treat it as suspicious — this is what
-- catches Hebrew words typed on an English layout (e.g. "akuo" for שלום),
-- which always produce uncommon Latin bigrams.
local COMMON_BIGRAMS = {}
for _, bg in ipairs({
  "th","he","in","er","an","re","on","at","en","nd","ti","es","or","te","of",
  "ed","is","it","al","ar","st","to","nt","ng","se","ha","as","ou","io","le",
  "ve","co","me","de","hi","ri","ro","ic","ne","ea","ra","ce","li","ch","ll",
  "be","ma","si","om","ur","ca","el","ta","la","ns","di","fo","ho","pe","ec",
  "pr","no","ct","us","ac","ot","il","tr","ly","nc","et","ut","ss","so","rs",
  "un","lo","wa","ge","ie","wh","ee","wi","em","ad","ol","rt","po","we","na",
  "ul","ni","ts","mo","ow","pa","im","mi","ai","sh","ir","su","id","ld","ay",
  "ke","oo","fi","pl","ev","tu","ag","do","sa","ap","ti","ki","ee","ff",
}) do COMMON_BIGRAMS[bg] = true end

------------------------------------------------------------
-- Buffer helpers
------------------------------------------------------------
local function clearBuffer()
  buffer = ""
end

local function popLastUtf8()
  if buffer == "" then return end
  local lastStart = 1
  for p in utf8.codes(buffer) do lastStart = p end
  buffer = buffer:sub(1, lastStart - 1)
end

local function appendChar(ch)
  buffer = buffer .. ch
  if lang.utf8Len(buffer) > MAX_BUFFER then
    -- Drop chars from the front until we're back under the cap.
    while lang.utf8Len(buffer) > MAX_BUFFER do
      local secondStart = nil
      local i = 0
      for p in utf8.codes(buffer) do
        i = i + 1
        if i == 2 then secondStart = p; break end
      end
      if not secondStart then break end
      buffer = buffer:sub(secondStart)
    end
  end
end

------------------------------------------------------------
-- Heuristics
------------------------------------------------------------
local function isSuspiciousHebrew(s)
  if lang.utf8Len(s) < MIN_LEN_HEB then return false end
  local chars, n = {}, 0
  for _, cp in utf8.codes(s) do
    n = n + 1
    chars[n] = utf8.char(cp)
  end
  for i = 1, n - 1 do
    if FINAL_FORMS[chars[i]] then return true end
  end
  return false
end

local function looksFineHebrew(s)
  if lang.utf8Len(s) < 1 then return false end
  local chars, n = {}, 0
  for _, cp in utf8.codes(s) do
    n = n + 1
    chars[n] = utf8.char(cp)
    -- Reject any non-Hebrew letter as "fine Hebrew".
    if not (cp >= 0x05D0 and cp <= 0x05EA) then
      -- Allow geresh/gershayim/etc to pass; punctuation breaks "fine".
      if not (cp == 0x05F3 or cp == 0x05F4) then return false end
    end
  end
  for i = 1, n - 1 do
    if FINAL_FORMS[chars[i]] then return false end
  end
  return true
end

local function isSuspiciousEnglish(s)
  if lang.utf8Len(s) < MIN_LEN_ENG then return false end
  local lower = s:lower()
  -- Rule 1: no vowels at all in 4+ chars → suspicious (consonant pile-up).
  if #lower >= 4 then
    local hasVowel = false
    for i = 1, #lower do
      if ENG_VOWELS[lower:sub(i, i)] then hasVowel = true; break end
    end
    if not hasVowel then return true end
  end
  -- Rule 2: zero common English bigrams → suspicious (Hebrew word typed on EN
  -- layout, e.g. "akuo" → ak, ku, uo — none common in real English).
  local total, common = 0, 0
  for i = 1, #lower - 1 do
    local bg = lower:sub(i, i + 1)
    if bg:match("^[a-z][a-z]$") then
      total = total + 1
      if COMMON_BIGRAMS[bg] then common = common + 1 end
    end
  end
  if total >= 2 and common == 0 then return true end
  return false
end

local function looksFineEnglish(s)
  if #s < 2 then return false end
  local hasVowel = false
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp):lower()
    if ENG_VOWELS[ch] then hasVowel = true end
    -- Reject anything that's not a-z.
    if not (cp >= 0x61 and cp <= 0x7A) and not (cp >= 0x41 and cp <= 0x5A) then
      return false
    end
  end
  return hasVowel
end

------------------------------------------------------------
-- Hint canvas
------------------------------------------------------------
local function hideHint()
  if hintHideTimer then hintHideTimer:stop(); hintHideTimer = nil end
  if hintAlertId then
    pcall(hs.alert.closeSpecific, hintAlertId)
    hintAlertId = nil
  end
  currentSuggestion = nil
end

local function showHint(text)
  if hintHideTimer then hintHideTimer:stop(); hintHideTimer = nil end
  if hintAlertId then pcall(hs.alert.closeSpecific, hintAlertId) end
  local label = "⇥  Tab to fix → " .. text
  hintAlertId = hs.alert.show(label, {
    textSize         = 28,
    radius           = 12,
    strokeColor      = { red = 0.29, green = 0.62, blue = 1.0, alpha = 0.9 },
    fillColor        = { red = 0.05, green = 0.05, blue = 0.05, alpha = 0.88 },
    textColor        = { white = 1, alpha = 1 },
    fadeInDuration   = 0.05,
    fadeOutDuration  = 0.15,
  }, HINT_TTL)
  hintHideTimer = hs.timer.doAfter(HINT_TTL + 0.1, function()
    hintAlertId = nil
    currentSuggestion = nil
  end)
end

------------------------------------------------------------
-- Evaluate buffer → maybe set currentSuggestion
------------------------------------------------------------
local function isHebLayoutNow()
  local curr = hs.keycodes.currentSourceID()
  for _, id in ipairs(lang.HEB_IDS) do
    if curr == id then return true end
  end
  return false
end

local function evaluate()
  if lang.utf8Len(buffer) < math.min(MIN_LEN_HEB, MIN_LEN_ENG) then
    hideHint()
    return
  end

  local isHeb = isHebLayoutNow()
  local converted, suspicious, otherFine

  if isHeb then
    converted   = lang.convertText(buffer, false)  -- HE → EN
    suspicious  = isSuspiciousHebrew(buffer)
    otherFine   = looksFineEnglish(converted)
  else
    converted   = lang.convertText(buffer, true)   -- EN → HE
    suspicious  = isSuspiciousEnglish(buffer)
    otherFine   = looksFineHebrew(converted)
  end

  if suspicious and otherFine then
    currentSuggestion = { buffer = buffer, converted = converted, isHebLayout = isHeb }
    log("suggest", isHeb and "HE→EN" or "EN→HE", buffer, "→", converted)
    showHint(converted)
  else
    hideHint()
  end
end

------------------------------------------------------------
-- Tab-to-swap
------------------------------------------------------------
local function performSwap()
  local sug = currentSuggestion
  if not sug then return end
  hideHint()
  local n = lang.utf8Len(sug.buffer)
  hs.timer.doAfter(0.05, function()
    if sug.isHebLayout then
      lang.switchToEnglish()
    else
      lang.switchToHebrew()
    end
    hs.hid.capslock.set(false)
    for _ = 1, n do
      hs.eventtap.keyStroke({}, "delete", 0)
    end
    hs.eventtap.keyStrokes(sug.converted)
    buffer = sug.converted
  end)
end

------------------------------------------------------------
-- Eventtap
------------------------------------------------------------
local function inTerminal()
  local app = hs.application.frontmostApplication()
  return app and lang.TERMINAL_BUNDLES[app:bundleID()] == true
end

local KEY_TAB       = 48
local KEY_SPACE     = 49
local KEY_RETURN    = 36
local KEY_ESC       = 53
local KEY_DELETE    = 51  -- backspace
local KEY_FWD_DEL   = 117
local KEY_LEFT      = 123
local KEY_RIGHT     = 124
local KEY_DOWN      = 125
local KEY_UP        = 126
local KEY_HOME      = 115
local KEY_END       = 119
local KEY_PGUP      = 116
local KEY_PGDN      = 121

local function onKeyDown(event)
  if inTerminal() then
    clearBuffer(); hideHint()
    return false
  end

  local flags  = event:getFlags()
  local kc     = event:getKeyCode()

  if kc == KEY_TAB then
    if currentSuggestion and not (flags.cmd or flags.ctrl or flags.alt) then
      performSwap()
      return true
    end
    clearBuffer(); hideHint()
    return false
  end

  if flags.cmd or flags.ctrl then
    clearBuffer(); hideHint()
    return false
  end

  if kc == KEY_SPACE or kc == KEY_RETURN or kc == KEY_ESC
     or kc == KEY_LEFT or kc == KEY_RIGHT or kc == KEY_UP or kc == KEY_DOWN
     or kc == KEY_HOME or kc == KEY_END or kc == KEY_PGUP or kc == KEY_PGDN
     or kc == KEY_FWD_DEL then
    clearBuffer(); hideHint()
    return false
  end

  if kc == KEY_DELETE then
    popLastUtf8()
    evaluate()
    return false
  end

  local chars = event:getCharacters(false) or ""
  if chars == "" then return false end
  local cp = utf8.codepoint(chars)
  local isLatin  = (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
  local isHebrew = cp >= 0x05D0 and cp <= 0x05F4
  if isLatin or isHebrew then
    appendChar(chars)
    evaluate()
  else
    clearBuffer(); hideHint()
  end
  return false
end

local function onMouseDown()
  clearBuffer(); hideHint()
  return false
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------
function M.start()
  if keyTap then return end
  keyTap   = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKeyDown)
  mouseTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.rightMouseDown,
  }, onMouseDown)
  keyTap:start()
  mouseTap:start()

  appWatcher = hs.application.watcher.new(function(_, evType)
    if evType == hs.application.watcher.activated
       or evType == hs.application.watcher.deactivated then
      clearBuffer(); hideHint()
    end
  end)
  appWatcher:start()
end

function M.stop()
  if keyTap then keyTap:stop(); keyTap = nil end
  if mouseTap then mouseTap:stop(); mouseTap = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  hideHint()
  clearBuffer()
end

function M.setDebug(b) DEBUG = b and true or false end

return M
