-- Self-check for the protected-run logic (links, paths, mentions, emails,
-- backtick code). Pure functions only — no keystrokes, nothing touched on
-- screen. No test framework here on purpose — run it with either:
--
--   lua ~/dan-hebrew/src/converter_test.lua        (brew install lua)
--   dofile(os.getenv("HOME") .. "/dan-hebrew/src/converter_test.lua")   (HS console)

local dir  = (os.getenv("HOME") or "") .. "/dan-hebrew/src"
local lang = dofile(dir .. "/language_converter.lua")

local checks, failures = 0, 0
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
  end
end
local function contains(haystack, needle, label)
  checks = checks + 1
  if not string.find(haystack, needle, 1, true) then
    failures = failures + 1
    print(string.format("FAIL %s\n  %q\n  is missing %q", label, haystack, needle))
  end
end

local SAMPLES = {
  "http://localhost:3007/regions/kh7fgmw14rw54dcvv2amcaenfx88aev4?tab=pnl",
  "https://chatgpt.com/c/6a69b2b0-5668-83eb-b8c7-7593a8e73342",
  "https://docs.google.com/document/d/1Uodua7vtTchZjko3nvyjddy7Y8vSt80TuneixT1oSrI/edit?tab=t.0",
  "www.booking.com/hotel/th/villa.html",
  "'/var/folders/2m/t_bx5lcn00s0vhx3rwz478780000gq/T/TemporaryItems/NSIRD_screencaptureui_SdbCG4/Screenshot 2026-07-29 at 12.53.13.png'",
  "/Users/yedidya/Desktop/PMS/docs/sales-agent-runbook.md",
  "/Users/yedidya/Downloads/helmet_spec.md",
  "~/Downloads/helmet_spec.md",
  "@src/components/finance/PnlSummaryTab.tsx",
  "venusdev846@gmail.com",
  "`npm run dev`",
}

-- 1. Survives conversion in both directions, wherever it sits in the line.
for _, s in ipairs(SAMPLES) do
  contains(lang.convertText("akuo " .. s .. " akuo", true),  s, "EN→HE mid-line: " .. s)
  contains(lang.convertText(s .. " akuo", true),             s, "EN→HE line start: " .. s)
  contains(lang.convertText("akuo " .. s, true),             s, "EN→HE line end: " .. s)
  contains(lang.convertText("שלום " .. s .. " עולם", false), s, "HE→EN mid-line: " .. s)
end

-- 2. The text around it really does convert (guards against a pattern that
--    swallowed the whole line).
eq(lang.convertText("akuo /Users/a/b.md akuo", true), "שלום /Users/a/b.md שלום", "surroundings convert")

-- 3. Split into segments: text | protected | text.
for _, s in ipairs(SAMPLES) do
  local segs = lang.parseSegments("akuo " .. s .. " akuo")
  eq(#segs, 3, "segment count: " .. s)
  if #segs == 3 then
    eq(segs[2].kind, "literal", "middle segment kind: " .. s)
    eq(segs[2].s, s, "middle segment text: " .. s)
  end
end

-- 4. Attachment placeholders still win over protected runs, and both coexist.
do
  local segs = lang.parseSegments("akuo [Image #1] /Users/a/b.md akuo")
  local kinds = {}
  for _, seg in ipairs(segs) do table.insert(kinds, seg.kind) end
  eq(table.concat(kinds, ","), "text,placeholder,text,literal,text", "image + path together")
end

-- 5. Everyday text with a slash must NOT be protected.
for _, s in ipairs({ "זה 24/7 בסדר", "או/או", "בתאריך 12/07/2026", "a / b" }) do
  eq(lang.findNextProtected(s, 1), nil, "not a path: " .. s)
end

-- 6. Language detection ignores protected runs — a long English path must not
--    drag a Hebrew line to the wrong direction.
eq(lang.detectEnglish("שלום /Users/yedidya/Desktop/PMS/docs/sales-agent-runbook.md"), false, "path doesn't vote")
eq(lang.detectEnglish("שלום `npm run dev`"), false, "backticks don't vote")
eq(lang.detectEnglish("hello /Users/a/b.md"), true, "english still detected")

-- 7. The visual⇄logical flip keeps protected runs intact and is its own inverse.
do
  local function flatten(segs)
    local parts = {}
    for _, seg in ipairs(segs) do table.insert(parts, seg.s) end
    return table.concat(parts)
  end
  local line  = "שלום /Users/a/b.md עולם"
  local once  = flatten(lang.unbidiSegments(lang.parseSegments(line)))
  local twice = flatten(lang.unbidiSegments(lang.parseSegments(once)))
  contains(once, "/Users/a/b.md", "flip keeps the path forwards")
  eq(twice, line, "flip is its own inverse")
end

print(string.format("converter_test: %d checks, %d failures", checks, failures))
return failures == 0
