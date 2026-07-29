-- Self-check for the terminal-copy un-flip. Pure functions only — nothing is
-- read from or written to the real clipboard. Run it with either:
--
--   lua ~/dan-hebrew/src/bidi_clipboard_test.lua        (brew install lua)
--   dofile(os.getenv("HOME") .. "/dan-hebrew/src/bidi_clipboard_test.lua")   (HS console)

local dir  = (os.getenv("HOME") or "") .. "/dan-hebrew/src"
local bidi = dofile(dir .. "/bidi_clipboard.lua")

local checks, failures = 0, 0
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
  end
end

------------------------------------------------------------
-- 1. Real lines captured off the clipboard after a terminal copy.
------------------------------------------------------------
eq(bidi.unflip("⏺ .)םח תרשה — ןנער( http://localhost:3007/finance לע ץרו ןכומ לוכה"),
   "⏺ הכול מוכן ורץ על http://localhost:3007/finance (רענן — השרת חם).",
   "hebrew line with a url and parentheses")

eq(bidi.unflip('.הלמע 2,856 ,וטורב "19,221 ,moshe gliksman" םשר יטסג'),
   'גסטי רשם "moshe gliksman, 19,221" ברוטו, 2,856 עמלה.',
   "hebrew line with quoted english and thousands separators")

eq(bidi.unflip("❯ '/Users/yedidya/Desktop/PMS/docs/sales-agent-test-plan.md' הליוש השענ אב"),
   "❯ '/Users/yedidya/Desktop/PMS/docs/sales-agent-test-plan.md' בא נעשה שוילה",
   "line that starts with a path — order stays, only the hebrew flips")

eq(bidi.unflip(":הארתש המ הז ןורחאה טפשמה תא קיתעמ ינא םא אמגודל"),
   "לדוגמא אם אני מעתיק את המשפט האחרון זה מה שתראה:",
   "plain hebrew sentence")

------------------------------------------------------------
-- 2. Things it must leave completely alone.
------------------------------------------------------------
eq(bidi.unflip("Claude Code v2.1.220"), "Claude Code v2.1.220", "english-only line untouched")
eq(bidi.fix("Claude Code v2.1.220"), nil, "english-only never triggers")
eq(bidi.fix("שלום, מה נשמע? הכול טוב היום"), nil, "correct hebrew never triggers")
eq(bidi.fix("הזמנה חדשה נכנסה למערכת"), nil, "correct hebrew with finals at word end never triggers")
eq(bidi.fix(""), nil, "empty string")
eq(bidi.fix(nil), nil, "nil")

------------------------------------------------------------
-- 3. Multi-line: line order is kept, each line decided on its own.
------------------------------------------------------------
eq(bidi.unflip("Claude Code v2.1.220\n:הארתש המ הז\nOpus 5"),
   "Claude Code v2.1.220\nזה מה שתראה:\nOpus 5",
   "mixed block keeps line order")

------------------------------------------------------------
-- 4. Running it on already-fixed text must not break it again.
------------------------------------------------------------
do
  local once = bidi.unflip("⏺ .)םח תרשה — ןנער( http://localhost:3007/finance לע ץרו ןכומ לוכה")
  eq(bidi.fix(once), nil, "fixed text is not re-flipped")
end


------------------------------------------------------------
-- 5. Short copies must be caught too — a single give-away word is enough,
--    and a leading punctuation mark must not hide it.
------------------------------------------------------------
eq(bidi.unflip(":םולש הז"), "זה שלום:", "short line behind a colon")
eq(bidi.unflip("בוט םוי"), "יום טוב", "two words, one give-away")
eq(bidi.unflip('"םולש"'), '"שלום"', "single word inside quotes")


------------------------------------------------------------
-- 6. The cases the log caught in the wild: short phrases whose words carry
--    no give-away letter at either edge.
------------------------------------------------------------
eq(bidi.unflip("לנימרטהמ"), "מהטרמינל", "single word, no give-away letter")
eq(bidi.unflip("ינאו"), "ואני", "short word settled by vocabulary")
eq(bidi.unflip("סרדנ רוקמהש תרחב"), "בחרת שהמקור נדרס", "short phrase")

-- and the same words the right way round must survive, terminal or not
for _, w in ipairs({ "מהטרמינל", "ואני", "בחרת שהמקור נדרס", "אדמין" }) do
  eq(bidi.fix(w, false), nil, "correct outside a terminal: " .. w)
  eq(bidi.fix(w, true),  nil, "correct inside a terminal: " .. w)
end

------------------------------------------------------------
-- 7. Where the source app decides: no evidence either way.
------------------------------------------------------------
do
  local neutral = "רבד"                         -- דבר: no give-away letter, not a listed word
  eq(bidi.reversalScore(neutral), 0, "neutral word really is evidence-free")
  eq(bidi.fix(neutral, false), nil, "left alone when it did not come from a terminal")
  eq(bidi.fix(neutral, true), "דבר", "flipped when it came from a terminal")

  -- an abbreviation is evidence-free too, so it follows the same rule
  eq(bidi.fix("סה\u{05F4}כ 1,200", false), nil, "abbreviation survives outside a terminal")
end


------------------------------------------------------------
-- 8. Holding off, so the language converter's own Cmd+C is never rewritten.
------------------------------------------------------------
do
  local reversed = "לנימרטהמ"
  eq(bidi.isHeld(), false, "nothing held to start with")
  eq(bidi.fix(reversed, true), "מהטרמינל", "corrects while free")

  bidi.hold(30)
  eq(bidi.isHeld(), true, "hold is in force")
  eq(bidi.fix(reversed, true), nil, "leaves the clipboard alone while held")

  bidi.release()
  eq(bidi.fix(reversed, true), "מהטרמינל", "corrects again once released")

  -- a hold never shortens one already in force
  bidi.hold(30); bidi.hold(1)
  eq(bidi.isHeld(), true, "a shorter hold cannot cut a longer one short")
  bidi.release()
end

print(string.format("bidi_clipboard_test: %d checks, %d failures", checks, failures))
return failures == 0
