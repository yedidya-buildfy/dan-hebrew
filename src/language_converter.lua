-- Language converter (EN ⇄ HE) for Hammerspoon.
-- Two paths:
--   GUI       → Cmd+V replaces the selection atomically.
--   Terminal  → walk-back from end-of-line until a Shift+Left selection matches
--               the copied target, then delete + inject Unicode.
local M = {}

local DEBUG = false
local function log(...) if DEBUG then print("[lang]", ...) end end
-- Always-on diagnostic for the placeholder walk (temporary; remove once stable).
local function wlog(...) print("[lang/walk]", ...) end

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

local PROMPT_GLYPH        = "❯"
local MAX_TERMINAL_DELETE = 500
local DIVIDER_MIN_RUN     = 5  -- a line counts as a box border if it has >= this many ─ in a row

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
  -- URLs are never converted, so they shouldn't vote on the detected language.
  text = text:gsub("%a[%w+.%-]*://%S+", ""):gsub("%f[%w]www%.%S+", "")
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

-- URLs must never be converted: scheme://… , www.… (frontier so "awww." doesn't match).
local URL_PATTERNS = {
  "%a[%w+.%-]*://%S+",
  "%f[%w]www%.%S+",
}
local function findNextUrl(text, from)
  local bestS, bestE = nil, nil
  for _, pat in ipairs(URL_PATTERNS) do
    local s, e = string.find(text, pat, from)
    if s and (not bestS or s < bestS) then bestS, bestE = s, e end
  end
  return bestS, bestE
end

local function convertChars(text, fromEng)
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

local function convertText(text, fromEng)
  local out = {}
  local i = 1
  while i <= #text do
    local s, e = findNextUrl(text, i)
    if not s then
      table.insert(out, convertChars(text:sub(i), fromEng))
      break
    end
    if s > i then
      table.insert(out, convertChars(text:sub(i, s - 1), fromEng))
    end
    table.insert(out, text:sub(s, e))
    i = e + 1
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

-- Narrow a Cmd+A-style selection down to just the text inside the active
-- prompt input box: everything after the LAST ❯, cut at the next ───── border,
-- trimmed. Returns nil if ❯ is absent OR extraction produced empty/oversized.
local function extractPromptInput(selected)
  if not selected or selected == "" then return nil end
  local idx = nil
  local i = 1
  while true do
    local s, e = string.find(selected, PROMPT_GLYPH, i, true)
    if not s then break end
    idx = e
    i = e + 1
  end
  if not idx then return nil end
  local after = string.sub(selected, idx + 1)
  -- Cut at first line that's a box border (run of ─, possibly with whitespace).
  local cut
  for line in after:gmatch("[^\n]*\n?") do
    local stripped = line:gsub("[%s\n]", "")
    local _, count = stripped:gsub("─", "")
    if count >= DIVIDER_MIN_RUN and count == utf8Len(stripped) then
      cut = line
      break
    end
  end
  if cut then
    local p = string.find(after, cut, 1, true)
    if p then after = string.sub(after, 1, p - 1) end
  end
  after = after:gsub("^[%s\n]+", ""):gsub("[%s\n]+$", "")
  if after == "" then return nil end
  if utf8Len(after) > MAX_TERMINAL_DELETE then return nil end
  return after
end

local function countLines(s)
  local n = 1
  for _ in s:gmatch("\n") do n = n + 1 end
  return n
end

-- Parse a string into alternating { text | placeholder } segments.
-- Placeholders are atomic Claude Code attachment tokens that must not be
-- touched: backspace deletes the whole token and breaks the attachment.
-- Match both the canonical placeholder shape and the bidi-mirrored variant
-- the terminal/Cmd+C returns when the surrounding paragraph is RTL Hebrew.
local PLACEHOLDER_PATTERNS = {
  "%[Image #%d+%]",
  "%]Image #%d+%[",
  "%[Pasted text #%d+%]",
  "%]Pasted text #%d+%[",
}
local function findNextPlaceholder(text, from)
  local bestS, bestE = nil, nil
  for _, pat in ipairs(PLACEHOLDER_PATTERNS) do
    local s, e = string.find(text, pat, from)
    if s and (not bestS or s < bestS) then bestS, bestE = s, e end
  end
  return bestS, bestE
end

local function parseSegments(text)
  local segments = {}
  local i = 1
  while i <= #text do
    local s, e = findNextPlaceholder(text, i)
    if not s then
      local rest = text:sub(i)
      if #rest > 0 then
        table.insert(segments, { kind = "text", s = rest, len = utf8Len(rest) })
      end
      return segments
    end
    if s > i then
      local pre = text:sub(i, s - 1)
      table.insert(segments, { kind = "text", s = pre, len = utf8Len(pre) })
    end
    local ph = text:sub(s, e)
    table.insert(segments, { kind = "placeholder", s = ph, len = utf8Len(ph) })
    i = e + 1
  end
  return segments
end

local function segmentsHavePlaceholder(segments)
  for _, seg in ipairs(segments) do
    if seg.kind == "placeholder" then return true end
  end
  return false
end

-- Detect RTL paragraph by looking for the bidi-mirrored placeholder bracket.
local function segmentsAreVisualRTL(segments)
  for _, seg in ipairs(segments) do
    if seg.kind == "placeholder" and seg.s:sub(1, 1) == "]" then
      return true
    end
  end
  return false
end

local function hasHebrew(s)
  for _, cp in utf8.codes(s or "") do
    if cp >= 0x05D0 and cp <= 0x05F4 then return true end
  end
  return false
end

-- For a Latin-only segment in an RTL paragraph, bidi puts the LTR letters in
-- their normal order but moves the adjacent space from one edge to the other.
-- e.g. logical " hello" renders visually as "hello ".
local function flipEdgeSpaces(s)
  local leading  = s:match("^(%s*)") or ""
  local trailing = s:match("(%s*)$") or ""
  local middle   = s:sub(#leading + 1, #s - #trailing)
  return trailing .. middle .. leading
end

-- Convert segments from Cmd+C visual order into the logical/buffer order the
-- cursor actually moves through. Called only when the paragraph is RTL.
local function unbidiSegments(segments)
  local result = {}
  for i = #segments, 1, -1 do
    local seg = segments[i]
    if seg.kind == "placeholder" then
      local body = seg.s:sub(2, -2)  -- strip mirrored brackets
      table.insert(result, { kind = "placeholder", s = "[" .. body .. "]", len = seg.len })
    elseif hasHebrew(seg.s) then
      -- Hebrew run is reversed visually; full-reverse recovers logical order.
      table.insert(result, { kind = "text", s = utf8Reverse(seg.s), len = seg.len })
    else
      -- Latin/neutral run keeps char order; only the edge spaces swap sides.
      table.insert(result, { kind = "text", s = flipEdgeSpaces(seg.s), len = seg.len })
    end
  end
  return result
end

-- Busy-wait until all modifier keys are physically released. The hotkey
-- handler often fires while the user is still holding Cmd+Alt, which would
-- turn subsequent plain Right/Left into Cmd+Right/Cmd+Left.
local function waitNoMods(timeoutSec)
  timeoutSec = timeoutSec or 1.0
  local deadline = hs.timer.secondsSinceEpoch() + timeoutSec
  while hs.timer.secondsSinceEpoch() < deadline do
    local m = hs.eventtap.checkKeyboardModifiers()
    if not (m.cmd or m.alt or m.ctrl or m.shift) then return true end
    hs.timer.usleep(10000)
  end
  return false
end

-- Move the cursor to the logical start of the input and clear any active
-- selection. Plain Left collapses a selection to its left edge in most text
-- fields; Ctrl+A then nudges to the actual line start in TUIs.
local function collapseToStart()
  hs.eventtap.keyStroke({}, "left", 20000)
  hs.timer.usleep(80000)
  hs.eventtap.keyStroke({"ctrl"}, "a", 20000)
  hs.timer.usleep(80000)
end

-- Left-to-right walk that replaces text segments by forward-deleting them
-- and typing the converted text at the same cursor position. Placeholders
-- are skipped with a single Right Arrow (atomic). Cursor only ever moves
-- rightward across the input, so the placeholder boundary on the LEFT side
-- of the cursor is never disturbed by destructive operations.
local function replaceInTerminalWalk(segments, fromEng, prevSnap)
  local expectedParts = {}
  for _, seg in ipairs(segments) do
    if seg.kind == "text" then
      table.insert(expectedParts, convertText(seg.s, fromEng))
    else
      table.insert(expectedParts, seg.s)
    end
  end
  local expected = table.concat(expectedParts)

  wlog("expected after walk: " .. expected)
  hs.timer.doAfter(TIMING.modReleaseSec, function()
    waitNoMods(1.0)
    hs.hid.capslock.set(false)

    collapseToStart()
    wlog("collapsed to start; walking left-to-right with forward-delete + type")

    for idx, seg in ipairs(segments) do
      if seg.kind == "text" then
        wlog(string.format("seg %d text len=%d : forwardDelete + type", idx, seg.len))
        for _ = 1, seg.len do
          hs.eventtap.keyStroke({}, "forwarddelete", 8000)
          hs.timer.usleep(10000)
        end
        hs.timer.usleep(50000)
        local conv = convertText(seg.s, fromEng)
        hs.eventtap.keyStrokes(conv)
        hs.timer.usleep(60000 + seg.len * 4000)
      else
        wlog(string.format("seg %d placeholder %q : single rightArrow", idx, seg.s))
        hs.eventtap.keyStroke({}, "right", 8000)
        hs.timer.usleep(80000)
      end
    end
    wlog("walk done; scheduling verify")

    hs.timer.doAfter(0.3, function()
      hs.pasteboard.setContents("")
      hs.eventtap.keyStroke({"cmd"}, "a", 0)
      hs.timer.usleep(80000)
      hs.eventtap.keyStroke({"cmd"}, "c", 0)
      hs.timer.usleep(TIMING.clipboardWaitUs)
      local got = hs.pasteboard.getContents() or ""
      local gotExtracted = extractPromptInput(got) or got

      -- The TUI displays Hebrew in one direction but Cmd+C returns the
      -- bidi-reversed form, so a full string match would always fail when
      -- Hebrew is involved. The only thing we actually need to verify is
      -- that every original [Image #N] / [Pasted text #N] placeholder
      -- still appears in the buffer with its number intact — that's what
      -- proves the underlying attachment binding survived.
      local function collectPlaceholderNumbers(text)
        local nums = {}
        for _, pat in ipairs(PLACEHOLDER_PATTERNS) do
          for n in text:gmatch(pat:gsub("%%d%+", "(%%d+)")) do
            table.insert(nums, n)
          end
        end
        table.sort(nums)
        return nums
      end
      local origNums = {}
      for _, seg in ipairs(segments) do
        if seg.kind == "placeholder" then
          local n = seg.s:match("#(%d+)")
          if n then table.insert(origNums, n) end
        end
      end
      table.sort(origNums)
      local gotNums = collectPlaceholderNumbers(gotExtracted)

      local function sameNumbers(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do if a[i] ~= b[i] then return false end end
        return true
      end

      if sameNumbers(origNums, gotNums) then
        wlog(string.format("verify OK — %d placeholder(s) preserved", #origNums))
      else
        wlog("verify FAILED — placeholder mismatch")
        wlog("  original numbers: [" .. table.concat(origNums, ",") .. "]")
        wlog("  got numbers:      [" .. table.concat(gotNums, ",") .. "]")
        wlog("  got buffer:       " .. gotExtracted)
        hs.alert.show("Convert: image attachment lost", 2.0)
      end

      hs.eventtap.keyStroke({"cmd"}, "right", 5000)
      hs.timer.usleep(20000)
      if fromEng then switchToHebrew() else switchToEnglish() end
      restoreClipboard(prevSnap)
    end)
  end)
end

-- Terminal path: shell caret is decoupled from mouse selection, so we can
-- only reliably replace text that ends at the line's end. Switch input source
-- BEFORE injecting so RTL terminals don't visually reverse Latin output.
local function replaceInTerminal(target, converted, fromEng, prevSnap)
  local hasPrompt = string.find(target, PROMPT_GLYPH, 1, true) ~= nil
  local fastPath  = false
  local lines     = 1
  local sourceText = target  -- text we use for placeholder detection
  wlog("replaceInTerminal entry: hasPrompt=" .. tostring(hasPrompt) .. " targetBytes=" .. #target)

  if hasPrompt then
    local trimmed = extractPromptInput(target)
    if not trimmed then
      wlog("ABORT: ❯ present but extraction empty/oversized")
      restoreClipboard(prevSnap)
      return
    end
    wlog(string.format("trimmed input (utf8Len=%d): %q", utf8Len(trimmed), trimmed))
    local promptFromEng = detectEnglish(trimmed)
    if promptFromEng == nil then
      wlog("ABORT: extracted input has no detectable script")
      restoreClipboard(prevSnap)
      return
    end
    fromEng = promptFromEng
    sourceText = trimmed
  end

  wlog("about to parse segments. sourceText utf8Len=" .. utf8Len(sourceText))

  -- Placeholder branch runs whether or not the selection included ❯ — a
  -- mouse-selected input still has [Image #N] tokens we must skip.
  local segments = parseSegments(sourceText)
  wlog(string.format("parseSegments: %d segs, hasPlaceholder=%s",
    #segments, tostring(segmentsHavePlaceholder(segments))))
  for i, seg in ipairs(segments) do
    wlog(string.format("  parsed seg %d: %s len=%d %q", i, seg.kind, seg.len, seg.s))
  end
  if segmentsHavePlaceholder(segments) then
    -- If the paragraph is RTL (mirrored brackets), Cmd+C returned chars in
    -- bidi-visual order but the cursor moves logically — un-bidi before
    -- walking so segment boundaries align with cursor positions.
    if segmentsAreVisualRTL(segments) then
      wlog("RTL paragraph detected; converting visual segments to logical order")
      segments = unbidiSegments(segments)
      for i, seg in ipairs(segments) do
        wlog(string.format("  logical seg %d: %s len=%d %q", i, seg.kind, seg.len, seg.s))
      end
    end

    -- Re-detect direction on text segments only — placeholder bodies
    -- ("Image", "Pasted") would otherwise bias the Latin count.
    local textOnly = {}
    for _, seg in ipairs(segments) do
      if seg.kind == "text" then table.insert(textOnly, seg.s) end
    end
    local segFromEng = detectEnglish(table.concat(textOnly))
    if segFromEng == nil then
      wlog("text-only detection inconclusive, using current fromEng=" .. tostring(fromEng))
    else
      fromEng = segFromEng
    end
    wlog("walk start. fromEng=" .. tostring(fromEng) .. " segs=" .. #segments)
    for i, seg in ipairs(segments) do
      wlog(string.format("  seg %d: %s len=%d %q", i, seg.kind, seg.len, seg.s))
    end
    replaceInTerminalWalk(segments, fromEng, prevSnap)
    return
  end

  if hasPrompt then
    target    = sourceText
    converted = convertText(sourceText, fromEng)
    lines     = countLines(sourceText)
    fastPath  = true
  end

  local n = utf8Len(target)
  if n > MAX_TERMINAL_DELETE then
    log("terminal: selection exceeds delete cap ("..n.."), aborting")
    restoreClipboard(prevSnap)
    return
  end

  restoreClipboard(prevSnap)
  hs.timer.doAfter(TIMING.modReleaseSec, function()
    if fromEng then switchToHebrew() else switchToEnglish() end
    hs.hid.capslock.set(false)
    if fastPath then
      for _ = 1, lines do
        hs.eventtap.keyStroke({"cmd"}, "delete", 0)
      end
    else
      for _ = 1, n do
        hs.eventtap.keyStroke({}, "delete", 0)
      end
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

-- Exports for sibling modules (wrong_layout_watcher).
M.convertText        = convertText
M.utf8Len            = utf8Len
M.utf8Reverse        = utf8Reverse
M.engToHeb           = engToHeb
M.hebToEng           = hebToEng
M.ENG_IDS            = ENG_IDS
M.HEB_IDS            = HEB_IDS
M.TERMINAL_BUNDLES   = TERMINAL_BUNDLES
M.switchToEnglish    = switchToEnglish
M.switchToHebrew     = switchToHebrew

return M
