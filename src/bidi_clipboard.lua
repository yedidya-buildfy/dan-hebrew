-- Un-reverse Hebrew copied out of a terminal.
--
-- Claude Code (and any TUI that lays out its own bidi) writes each line to the
-- screen buffer already mirrored, because xterm.js does no reordering of its
-- own. What you see is right; what Cmd+C hands you is the mirrored buffer, so
-- pasting anywhere else shows the sentence backwards.
--
-- This turns the visual order back into logical order, in place on the
-- clipboard, right after a copy.

local M = {}

------------------------------------------------------------
-- Character classes
------------------------------------------------------------
local function isHeb(cp) return (cp >= 0x0590 and cp <= 0x05FF) or (cp >= 0xFB1D and cp <= 0xFB4F) end
local function isLat(cp)
  return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)   -- A-Z a-z
      or (cp >= 0x30 and cp <= 0x39)                                   -- 0-9
      or (cp >= 0xC0 and cp <= 0x24F)                                  -- latin-1 + latin extended
end

-- Punctuation that belongs to a latin run rather than to the sentence around
-- it: the separators inside urls, paths, versions and numbers. Needs a latin
-- neighbour on at least one side. `.` and `,` need one on both, otherwise an
-- end-of-sentence period would be dragged into the run.
local STICKY_ONE  = { ["/"] = true, [":"] = true, ["-"] = true, ["_"] = true, ["~"] = true,
                      ["@"] = true, ["#"] = true, ["?"] = true, ["&"] = true, ["="] = true,
                      ["+"] = true, ["%"] = true }
local STICKY_BOTH = { ["."] = true, [","] = true }

-- Gutter marks Claude Code draws to the left of its output. They are painted
-- outside the bidi run, so they must stay on the left when the rest flips.
local GUTTER = { ["⏺"] = true, ["⎿"] = true, ["❯"] = true, [">"] = true, ["│"] = true,
                 ["✻"] = true, ["·"] = true, ["•"] = true, [" "] = true, ["\t"] = true }

------------------------------------------------------------
-- utf8 helpers
------------------------------------------------------------
local function chars(s)
  local out = {}
  for _, cp in utf8.codes(s) do out[#out + 1] = utf8.char(cp) end
  return out
end

local function cpOf(ch) return utf8.codepoint(ch) end

local function join(t, from, to)
  return table.concat(t, "", from or 1, to or #t)
end

local function reversed(t, from, to)
  local out = {}
  for i = to, from, -1 do out[#out + 1] = t[i] end
  return table.concat(out)
end

------------------------------------------------------------
-- The flip
------------------------------------------------------------

-- Reverse every latin/digit run inside `t` back to reading order. `t` is the
-- already-reversed line, so its latin runs came out backwards.
--
-- A run stops at anything the renderer would have treated as belonging to the
-- Hebrew around it. That is why `moshe gliksman, 19,221` is two runs and not
-- one: the comma-then-space between them sat at Hebrew level, so it kept its
-- place while each name and number flipped on its own.
local function unreverseLatinRuns(t)
  local n, out, i = #t, {}, 1
  local function latAt(k) return k >= 1 and k <= n and isLat(cpOf(t[k])) end

  while i <= n do
    if not latAt(i) then
      out[#out + 1] = t[i]
      i = i + 1
    else
      local j = i
      while j < n do
        local c = t[j + 1]
        local glued = latAt(j + 1)
          -- separators chain, so the `//` in an address survives
          or (STICKY_ONE[c]  and (latAt(j) or STICKY_ONE[t[j]] or latAt(j + 2)))
          or (STICKY_BOTH[c] and latAt(j) and latAt(j + 2))
          or (c == " "       and latAt(j) and latAt(j + 2))
        if not glued then break end
        j = j + 1
      end
      out[#out + 1] = reversed(t, i, j)
      i = j + 1
    end
  end
  return table.concat(out)
end

-- Reverse every Hebrew run in place, leaving everything else where it is.
-- This is the left-to-right case: the line's overall order is already right.
local function unreverseHebrewRuns(t)
  local n, out, i = #t, {}, 1
  while i <= n do
    if isHeb(cpOf(t[i])) then
      local j = i
      -- a Hebrew word run, including the spaces and punctuation between words
      local lastHeb = i
      while j <= n and not isLat(cpOf(t[j])) do
        if isHeb(cpOf(t[j])) then lastHeb = j end
        j = j + 1
      end
      out[#out + 1] = reversed(t, i, lastHeb)
      i = lastHeb + 1
    else
      out[#out + 1] = t[i]
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.unflipLine(line)
  local t = chars(line)

  local hasHeb = false
  for _, ch in ipairs(t) do
    if isHeb(cpOf(ch)) then hasHeb = true break end
  end
  if not hasHeb then return line end   -- pure latin line: the terminal never reordered it

  -- A terminal pads each line out to the window width. That padding is not
  -- content, and flipping the line would turn it into a giant indent.
  local trailing = line:match("%s*$")
  if #trailing > 0 then
    line = line:sub(1, #line - #trailing)
    t = chars(line)
  end

  -- peel the gutter; it is drawn outside the bidi run and stays on the left
  local g = 1
  while g <= #t and GUTTER[t[g]] do g = g + 1 end
  local head = join(t, 1, g - 1)
  local body = {}
  for k = g, #t do body[#body + 1] = t[k] end

  -- base direction = the first strong letter, same rule the renderer used
  local baseLatin = false
  for _, ch in ipairs(body) do
    local cp = cpOf(ch)
    if isHeb(cp) then break end
    if isLat(cp) then baseLatin = true break end
  end

  if baseLatin then
    return head .. unreverseHebrewRuns(body)
  end

  local rev = {}
  for k = #body, 1, -1 do rev[#rev + 1] = body[k] end
  return head .. unreverseLatinRuns(rev)
end

function M.unflip(text)
  local out, first = {}, true
  -- keep the line order; only what is inside each line was mirrored
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if not first then out[#out + 1] = "\n" end
    out[#out + 1] = M.unflipLine(line)
    first = false
  end
  return table.concat(out)
end

------------------------------------------------------------
-- Detection
------------------------------------------------------------

-- Hebrew spelling gives away which way round a word is written.
--
--   ם ן ך ף ץ  may only END a word — seeing one open a word means reversed.
--   כ מ נ פ צ  may never end one    — seeing one close a word means reversed.
--
-- Both are absolute rules of the language, not statistics. What they are not
-- is universal: plenty of words contain none of these letters at either edge
-- (מהטרמינל, ואני), so a vocabulary check carries whatever they miss.
local FINAL_ONLY  = { [0x05DD] = true, [0x05DF] = true, [0x05DA] = true, [0x05E3] = true, [0x05E5] = true }
local NEVER_FINAL = { [0x05DB] = true, [0x05DE] = true, [0x05E0] = true, [0x05E4] = true, [0x05E6] = true }

-- Everyday words, common enough that a handful of them settle the direction of
-- any real sentence. Only ones whose reverse is not itself a word.
local COMMON = {}
for w in ([[
של את זה לא על אני אתה הוא היא אנחנו מה מי יש אין גם כל רק אבל כי אם או עם כמו
יותר מאוד טוב ואני ואת וזה שלי שלך שלו לי לך לו לה הזה הזאת בכל אחרי לפני עכשיו
אפשר צריך רוצה עושה להיות כבר עוד פה שם כאן איך למה מתי כמה בגלל ככה אותו אותה
היה הייתי צריכה יכול תודה בסדר נכון ממש הרבה קצת שוב אולי בדיוק כדי בשביל
]]):gmatch("%S+") do COMMON[w] = true end

local function utf8Rev(w)
  local out = {}
  for _, cp in utf8.codes(w) do table.insert(out, 1, utf8.char(cp)) end
  return table.concat(out)
end

-- Positive score means the text reads better backwards than forwards. Each
-- spelling rule is worth as much backwards as forwards, so a passage that is
-- genuinely fine can never drift into being rewritten.
function M.reversalScore(text)
  if type(text) ~= "string" or text == "" then return 0 end
  local score, word = 0, {}

  local function weigh()
    if #word >= 2 then
      local first, last = word[1], word[#word]
      if FINAL_ONLY[first]  then score = score + 2 end   -- opens with a closing letter
      if NEVER_FINAL[last]  then score = score + 2 end   -- closes with a letter that never closes
      if FINAL_ONLY[last]   then score = score - 2 end
      if NEVER_FINAL[first] then score = score - 2 end
      local parts = {}
      for i = 1, #word do parts[i] = utf8.char(word[i]) end
      local w = table.concat(parts)
      if COMMON[w]            then score = score - 2 end
      if COMMON[utf8Rev(w)]   then score = score + 2 end
    end
    word = {}
  end

  -- Only the alphabet itself builds a word. Gershayim and geresh end one, so
  -- an abbreviation like סה״כ is not read as a word closing on a כ.
  for _, cp in utf8.codes(text) do
    if cp >= 0x05D0 and cp <= 0x05EA then word[#word + 1] = cp else weigh() end
  end
  weigh()
  return score
end

function M.looksReversed(text)
  return M.reversalScore(text) > 0
end

------------------------------------------------------------
-- Holding off
------------------------------------------------------------
-- The other tools here drive the clipboard themselves: the language converter
-- presses Cmd+C to grab your selection, the history panel writes an entry out
-- before pasting it. Those copies are not yours, and rewriting one mid-flight
-- corrupts whatever that tool was doing. They claim the clipboard for a moment
-- by calling hold(). It lapses on its own, so a tool that dies half way through
-- can never switch the correction off for good.
local heldUntil = 0

local function now()
  if hs and hs.timer and hs.timer.secondsSinceEpoch then return hs.timer.secondsSinceEpoch() end
  return os.time()
end

function M.hold(seconds) heldUntil = math.max(heldUntil, now() + (seconds or 3)) end
function M.isHeld()      return now() < heldUntil end
function M.release()     heldUntil = 0 end

-- True when the app you copied from lays out its own bidi, i.e. everything
-- Hebrew it puts on screen is in visual order.
function M.fromTerminal()
  local ok, lang = pcall(require, "language_converter")
  if not ok then return false end
  local app = hs.application.frontmostApplication()
  return app ~= nil and lang.TERMINAL_BUNDLES[app:bundleID()] == true
end

-- Returns the corrected text, or nil when there was nothing to correct.
--
-- The spelling rules settle most text on their own. What they cannot settle is
-- a short phrase whose words happen to carry no give-away letter — מהטרמינל,
-- ואני — and there the source app decides: inside a terminal, Hebrew that
-- offers no evidence either way is visual, because that is all a terminal
-- produces. Text that argues it is already correct is never touched, wherever
-- it came from.
function M.fix(text, fromTerminal)
  if type(text) ~= "string" or text == "" then return nil end
  if M.isHeld() then return nil end   -- another tool is mid-way through its own clipboard work
  local score = M.reversalScore(text)
  local floor = fromTerminal and 0 or 1
  if score < floor then return nil end
  local fixed = M.unflip(text)
  if fixed == text then return nil end
  return fixed
end

-- No keyboard watcher here, on purpose. An earlier version listened for Cmd+C
-- to shave the delay down, and it broke both language-converter hotkeys: the
-- converter presses Cmd+C itself, and a tap sitting on every keystroke threw
-- off the timing of the synthetic keys it sends. The clipboard poll in the
-- history manager sees every copy anyway, whatever key or menu made it.

return M
