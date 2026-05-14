-- ~/.hammerspoon/clipboard_manager.lua
-- Two-column clipboard manager: Recent (left) and Pinned (right).
-- Open with: alt+Z. Navigate with arrows; Enter to paste; Esc to close.
-- Spawns by the mouse on its current screen (smart flip + clamp) and floats above full-screen apps.

local M = {}

local storeDir = os.getenv("HOME") .. "/.hammerspoon"
local pinnedPath = storeDir .. "/clipboard-pinned.json"
local recentPath = storeDir .. "/clipboard-recent.json"
local legacyPath = storeDir .. "/clipboard.json"  -- For migration
local imageDir = storeDir .. "/clipboard-images"
local settingsPath = storeDir .. "/clipboard-settings.json"
local maxRecent = 100
local MAX_RECENT_MIN, MAX_RECENT_MAX = 5, 1000

local function loadSettings()
  local f = io.open(settingsPath, "r")
  if not f then return end
  local data = f:read("*a"); f:close()
  local ok, parsed = pcall(hs.json.decode, data)
  if ok and type(parsed) == "table" and type(parsed.maxRecent) == "number" then
    local n = math.floor(parsed.maxRecent)
    if n >= MAX_RECENT_MIN and n <= MAX_RECENT_MAX then maxRecent = n end
  end
end

local function saveSettings()
  local f = io.open(settingsPath, "w")
  if f then f:write(hs.json.encode({ maxRecent = maxRecent }, true)); f:close() end
end

loadSettings()
local store = { pinned = {}, recent = {} }
local watcher, panel, clickWatcher, keyWatcher = nil, nil, nil, nil
local savedPanelFrame = nil  -- remembers panel size before image preview enlargement
local fullyLoaded = false
local pinnedHotkeys = {}  -- active hs.hotkey objects, keyed by pinned array index
local saveRecentTimer = nil
local lastClipboardContent = nil
local lastClipboardType = nil
local lastChangeCount = 0
local panelUCC = nil        -- persistent usercontent controller
local previousWindow = nil  -- window that had focus before panel opened
local hotkeyManagerRef = nil  -- reference to hotkey_manager for config lookup

------------------------------------------------------------
-- Input source helpers (reliable Cmd+V regardless of layout)
------------------------------------------------------------
local ENG_IDS = { "com.apple.keylayout.ABC", "com.apple.keylayout.US" }

local function setInputSourceByList(list)
  for _, id in ipairs(list) do
    if hs.keycodes.currentSourceID() == id then return true end
    if hs.keycodes.currentSourceID(id) then return true end
  end
  return false
end

local function pasteWithCmdV()
  local prev = hs.keycodes.currentSourceID()
  local capsWasOn = hs.hid.capslock.get()
  setInputSourceByList(ENG_IDS)           -- temporary switch to English so 'v' is mapped
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
  if prev then hs.keycodes.currentSourceID(prev) end
  if capsWasOn then hs.hid.capslock.set(true) end
end

------------------------------------------------------------
-- Image disk storage helpers
------------------------------------------------------------
local function ensureImageDir()
  os.execute('mkdir -p "' .. imageDir .. '"')
end

-- Save a base64 data URL to disk as a PNG file, returns the file path
local function saveImageToDisk(dataUrl)
  ensureImageDir()
  local filename = "img_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999)) .. ".png"
  local filePath = imageDir .. "/" .. filename

  -- Decode the data URL: strip "data:image/png;base64," prefix
  local base64Data = dataUrl:match("base64,(.+)")
  if not base64Data then
    print("[ERR] Could not extract base64 data from URL")
    return nil
  end

  -- Use hs.image to decode and save as PNG
  local img = hs.image.imageFromURL(dataUrl)
  if not img then
    print("[ERR] Could not decode image from data URL")
    return nil
  end

  -- Save as PNG using hs.image:saveToFile
  local ok = img:saveToFile(filePath, "PNG")
  if not ok then
    print("[ERR] Could not save image to " .. filePath)
    return nil
  end

  return filePath
end

-- Generate a small thumbnail data URL from a full image
local function generateThumbnail(img)
  local size = img:size()
  local maxDim = 80
  local scale = math.min(maxDim / size.w, maxDim / size.h, 1)
  local newW = math.floor(size.w * scale)
  local newH = math.floor(size.h * scale)

  local thumbImg = img:copy():setSize({w = newW, h = newH})
  if not thumbImg then return nil end
  return thumbImg:encodeAsURLString()
end

-- Load the full image from disk for pasting
local function loadImageFromDisk(path)
  if not path or path == "" then return nil end
  return hs.image.imageFromPath(path)
end

------------------------------------------------------------
-- Storage
------------------------------------------------------------
local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- JSON-encode a single scalar (string/number/bool) for embedding in a JS call.
-- hs.json.encode requires a table, so we wrap and strip the brackets.
local function jsonScalar(v)
  return hs.json.encode({v}):sub(2, -2)
end

local function savePinned()
  local f = io.open(pinnedPath, "w")
  if not f then return end
  f:write(hs.json.encode(store.pinned, true))
  f:close()
end

local function saveRecent()
  local f = io.open(recentPath, "w")
  if not f then return end
  f:write(hs.json.encode(store.recent, true))
  f:close()
end

-- Debounced save: wait 1 second after last clipboard change before saving
local function saveRecentDebounced()
  if saveRecentTimer then
    saveRecentTimer:stop()
  end
  saveRecentTimer = hs.timer.doAfter(1.0, function()
    saveRecent()
    saveRecentTimer = nil
  end)
end

local function saveStore()
  savePinned()
  saveRecent()
end

-- Migrate from old single-file format if needed
local function migrateIfNeeded()
  if not fileExists(legacyPath) then return end
  if fileExists(pinnedPath) and fileExists(recentPath) then
    -- Already migrated, remove legacy file
    os.remove(legacyPath)
    return
  end

  -- Read legacy file
  local f = io.open(legacyPath, "r")
  if not f then return end
  local data = f:read("*a")
  f:close()

  local ok, parsed = pcall(hs.json.decode, data)
  if ok and type(parsed) == "table" then
    store.pinned = parsed.pinned or {}
    store.recent = parsed.recent or {}
    saveStore()  -- Save to new split format
    os.remove(legacyPath)  -- Remove legacy file
  end
end

-- Migrate old text-only format to new type+content format
local function migrateDataFormat(items)
  if not items or type(items) ~= "table" then return items end

  local migrated = {}
  for _, item in ipairs(items) do
    if item.text and not item.content then
      -- Old format: { text = "...", title = "..." }
      -- New format: { type = "text", content = "...", title = "..." }
      table.insert(migrated, {
        type = "text",
        content = item.text,
        title = item.title or titleForContent("text", item.text),
        ts = item.ts
      })
    else
      -- Already new format
      table.insert(migrated, item)
    end
  end
  return migrated
end

-- Migrate inline base64 images to disk storage
local function migrateImagesToDisk(items)
  if not items or type(items) ~= "table" then return items end
  ensureImageDir()

  local migrated = {}
  local migratedCount = 0
  for _, item in ipairs(items) do
    if item.type == "image" and item.content and not item.imagePath then
      -- Has inline base64 data, needs migration to disk
      local content = item.content
      if content:match("^data:image") then
        local filePath = saveImageToDisk(content)
        if filePath then
          -- Generate thumbnail for display
          local img = hs.image.imageFromURL(content)
          local thumbnail = img and generateThumbnail(img) or ""

          table.insert(migrated, {
            type = "image",
            content = thumbnail,  -- small thumbnail for display
            imagePath = filePath,  -- full image on disk
            title = item.title,
            ts = item.ts
          })
          migratedCount = migratedCount + 1
        else
          -- Failed to save, keep as-is
          table.insert(migrated, item)
        end
      else
        table.insert(migrated, item)
      end
    else
      table.insert(migrated, item)
    end
  end

  if migratedCount > 0 then
    print("[OK] Migrated " .. migratedCount .. " inline images to disk")
  end
  return migrated
end

-- Clean up orphaned image files that are not referenced by any item
local function cleanOrphanedImages()
  ensureImageDir()

  -- Collect all referenced image paths
  local referencedPaths = {}
  for _, item in ipairs(store.recent) do
    if item.imagePath then referencedPaths[item.imagePath] = true end
  end
  for _, item in ipairs(store.pinned) do
    if item.imagePath then referencedPaths[item.imagePath] = true end
  end

  -- List all files in image directory
  local handle = io.popen('ls "' .. imageDir .. '/" 2>/dev/null')
  if not handle then return end
  local output = handle:read("*a")
  handle:close()

  local removedCount = 0
  for filename in output:gmatch("[^\n]+") do
    local fullPath = imageDir .. "/" .. filename
    if not referencedPaths[fullPath] then
      os.remove(fullPath)
      removedCount = removedCount + 1
    end
  end

  if removedCount > 0 then
    print("[OK] Cleaned " .. removedCount .. " orphaned image files")
  end
end

-- Fast load: only load pinned items on startup
local function loadStore()
  -- Check for migration first
  migrateIfNeeded()

  -- Load only pinned items (small file, fast)
  if fileExists(pinnedPath) then
    local f = io.open(pinnedPath, "r")
    if f then
      local data = f:read("*a")
      f:close()
      local ok, parsed = pcall(hs.json.decode, data)
      if ok and type(parsed) == "table" then
        store.pinned = migrateDataFormat(parsed)
        store.pinned = migrateImagesToDisk(store.pinned)
        savePinned()
      end
    end
  end

  -- Recent items will be loaded lazily when panel opens
  store.recent = {}
end

-- Load full recent history (called when panel opens)
local function ensureFullyLoaded()
  if fullyLoaded then return end

  -- Load recent history from separate file
  if fileExists(recentPath) then
    local f = io.open(recentPath, "r")
    if f then
      local data = f:read("*a")
      f:close()
      local ok, parsed = pcall(hs.json.decode, data)
      if ok and type(parsed) == "table" then
        store.recent = migrateDataFormat(parsed)
        -- Migrate inline images to disk if any
        store.recent = migrateImagesToDisk(store.recent)
        saveRecent()
      end
    end
  end

  -- Clean orphaned images after full load
  cleanOrphanedImages()

  fullyLoaded = true
end

local function titleForContent(contentType, content)
  if contentType == "image" then
    return "Image " .. os.date("%m/%d/%y %H:%M")
  else
    local s = (content or ""):gsub("%s+", " ")
    if #s > 60 then s = s:sub(1,57) .. "..." end
    return s ~= "" and s or "(empty)"
  end
end

local function pushRecent(contentType, content, imagePath)
  contentType = contentType or "text"
  content = content or ""

  if content == "" then
    return
  end

  local finalImagePath = imagePath

  -- For images: save full image to disk, keep only thumbnail in content
  if contentType == "image" and not imagePath then
    -- content is a full base64 data URL — save to disk
    finalImagePath = saveImageToDisk(content)
    if finalImagePath then
      -- Generate a small thumbnail for the JSON/display
      local img = hs.image.imageFromURL(content)
      if img then
        local thumb = generateThumbnail(img)
        content = thumb or ""
      else
        content = ""
      end
    end
  end

  -- Skip expensive deduplication if not fully loaded (fast startup)
  if fullyLoaded then
    -- Remove ALL existing occurrences of this content (deduplication)
    local i = 1
    while i <= #store.recent do
      local existing = store.recent[i]
      local isMatch = false
      if contentType == "image" and finalImagePath then
        -- For images with disk storage, deduplicate by imagePath
        isMatch = existing.imagePath == finalImagePath
      elseif contentType == "image" then
        -- For images without disk storage, deduplicate by thumbnail content
        isMatch = existing.type == "image" and existing.content == content
      else
        isMatch = existing.content == content and existing.type == contentType
      end

      if isMatch then
        -- If removing an item with an image on disk, keep the path for reuse
        if existing.imagePath and not finalImagePath then
          finalImagePath = existing.imagePath
        end
        table.remove(store.recent, i)
      else
        i = i + 1
      end
    end
  end

  -- Add as most recent
  local title = titleForContent(contentType, content)
  local entry = {
    type = contentType,
    content = content,
    title = title,
    ts = hs.timer.secondsSinceEpoch()
  }
  if finalImagePath then
    entry.imagePath = finalImagePath
  end
  table.insert(store.recent, 1, entry)

  -- Enforce limit by removing oldest items
  while #store.recent > maxRecent do
    local removed = table.remove(store.recent)
    -- Clean up disk image if the oldest item being removed has one
    if removed and removed.imagePath then
      os.remove(removed.imagePath)
    end
  end

  saveRecentDebounced()  -- Debounced save to reduce disk I/O
end

local function addPinned(title, contentType, content, imagePath)
  if not content or content == "" then return false end
  contentType = contentType or "text"
  local entry = {
    title = title or titleForContent(contentType, content),
    type = contentType,
    content = content
  }
  if imagePath then
    entry.imagePath = imagePath
  end
  table.insert(store.pinned, entry)
  savePinned()  -- Only save pinned file, not recent
  return true
end

------------------------------------------------------------
-- Paste pinned item by index (for global hotkeys)
------------------------------------------------------------
local function pastePinnedItem(index)
  if index < 1 or index > #store.pinned then return end

  local item = store.pinned[index]
  local contentType = item.type or "text"
  local content = item.content or ""
  local imgPath = item.imagePath

  if content == "" and not imgPath then return end

  hs.timer.doAfter(0.05, function()
    if contentType == "image" then
      local img = nil
      if imgPath then
        img = loadImageFromDisk(imgPath)
      end
      if not img and content ~= "" then
        img = hs.image.imageFromURL(content)
      end
      if img then
        local size = img:size()
        lastClipboardContent = tostring(size.w) .. "x" .. tostring(size.h)
        lastClipboardType = "image"
        hs.pasteboard.writeObjects(img)
        hs.timer.doAfter(0.1, function()
          pasteWithCmdV()
        end)
      end
    else
      lastClipboardContent = content
      lastClipboardType = "text"
      hs.pasteboard.setContents(content)
      pasteWithCmdV()
    end
  end)
end

------------------------------------------------------------
-- Pinned hotkey registration
------------------------------------------------------------
local function unregisterAllPinnedHotkeys()
  for i, hk in pairs(pinnedHotkeys) do
    pcall(function() hk:delete() end)
  end
  pinnedHotkeys = {}
end

local function registerPinnedHotkeys()
  unregisterAllPinnedHotkeys()
  for i, item in ipairs(store.pinned) do
    if item.hotkey then
      local mods = item.hotkey.mods or {}
      local key = item.hotkey.key or ""
      if key ~= "" then
        local idx = i  -- capture for closure
        local ok, hk = pcall(hs.hotkey.bind, mods, key, function()
          pastePinnedItem(idx)
        end)
        if ok and hk then
          pinnedHotkeys[i] = hk
        else
          print("[WARN] Could not bind hotkey for pinned item " .. i .. ": " .. tostring(hk))
        end
      end
    end
  end
end

local function deletePinned(index)
  if index < 1 or index > #store.pinned then return false end
  table.remove(store.pinned, index)
  savePinned()  -- Only save pinned file, not recent
  hs.timer.doAfter(0, registerPinnedHotkeys)  -- Defer out of WKWebView callback
  return true
end

------------------------------------------------------------
-- Heroicons SVG (thin outline, 20x20)
------------------------------------------------------------
local ICON = {
  clock = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="16" height="16"><path stroke-linecap="round" stroke-linejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/></svg>',
  pin = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="16" height="16"><path stroke-linecap="round" stroke-linejoin="round" d="m18.375 12.739-7.693 7.693a4.5 4.5 0 0 1-6.364-6.364l10.94-10.94A3 3 0 1 1 19.5 7.372L8.552 18.32m.009-.01-.01.01m5.699-9.941-7.81 7.81a1.5 1.5 0 0 0 2.112 2.13"/></svg>',
  trash = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="16" height="16"><path stroke-linecap="round" stroke-linejoin="round" d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0"/></svg>',
  plus = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="16" height="16"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15"/></svg>',
  xMark = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="14" height="14"><path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12"/></svg>',
  clipboard = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="16" height="16"><path stroke-linecap="round" stroke-linejoin="round" d="M15.666 3.888A2.25 2.25 0 0 0 13.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 0 1-.75.75H9.75a.75.75 0 0 1-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 0 1-2.25 2.25H6.75A2.25 2.25 0 0 1 4.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 0 1 1.927-.184"/></svg>',
  arrowLeft = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="14" height="14"><path stroke-linecap="round" stroke-linejoin="round" d="M10.5 19.5 3 12m0 0 7.5-7.5M3 12h18"/></svg>',
  bolt = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="14" height="14"><path stroke-linecap="round" stroke-linejoin="round" d="m3.75 13.5 10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75Z"/></svg>',
  eye = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="14" height="14"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>',
  pencil = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="14" height="14"><path stroke-linecap="round" stroke-linejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L6.832 19.82a4.5 4.5 0 0 1-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 0 1 1.13-1.897L16.863 4.487Zm0 0L19.5 7.125"/></svg>',
  check = '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" width="14" height="14"><path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5"/></svg>',
}

------------------------------------------------------------
-- HTML UI
------------------------------------------------------------

-- Prepare data for the webview (strip imagePath for security, add fileUrl for images)
local function prepareItemsForWeb(items)
  local webItems = {}
  for _, item in ipairs(items) do
    local webItem = {
      type = item.type,
      content = item.content or "",
      title = item.title or "",
      ts = item.ts,
      imagePath = item.imagePath or nil
    }
    -- For images with disk storage, provide a file:// URL for the detail view
    if item.imagePath and fileExists(item.imagePath) then
      webItem.fileUrl = "file://" .. item.imagePath
    end
    -- Pass through hotkey data for pinned items
    if item.hotkey then
      webItem.hotkey = item.hotkey
    end
    table.insert(webItems, webItem)
  end
  return webItems
end

local function buildHTML()
  local pinnedWeb = prepareItemsForWeb(store.pinned)
  local recentWeb = prepareItemsForWeb(store.recent)
  local pinnedJSON = hs.json.encode(pinnedWeb)
  local recentJSON = hs.json.encode(recentWeb)
  return [[
<!doctype html><html><head><meta charset="utf-8">
<style>
html,body{margin:0;padding:0;font-family:-apple-system,Helvetica,Arial;background:#111;color:#eee;border-radius:12px;overflow:hidden;color-scheme:dark}
.container{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px;height:100vh;box-sizing:border-box;background:#111;border-radius:12px}
.column{display:flex;flex-direction:column;border:1px solid #333;border-radius:10px;overflow:hidden}
.header{background:#1c1c1c;padding:8px 10px;font-weight:600;letter-spacing:.3px;display:flex;justify-content:space-between;align-items:center}
.header-title{flex:1;display:flex;align-items:center;gap:6px}
.header-title svg{opacity:0.7}
.header-actions{display:flex;gap:6px}
.header-btn{background:#333;border:none;color:#eee;padding:4px 8px;border-radius:6px;cursor:pointer;font-size:16px;line-height:1;transition:background .2s;display:flex;align-items:center;justify-content:center}
.header-btn:hover{background:#444}
.header-btn svg{width:16px;height:16px}
.list{flex:1;overflow:auto;outline:none}

/* Filter tabs (Recent column) */
.filter-tabs{display:flex;gap:4px;padding:6px 8px;background:#161616;border-bottom:1px solid #222}
.filter-tab{flex:1;background:transparent;border:1px solid #2a2a2a;color:#aaa;padding:4px 8px;border-radius:6px;cursor:pointer;font-size:11px;transition:background .15s,color .15s,border-color .15s,box-shadow .15s}
.filter-tab:hover{background:#222;color:#ddd}
.filter-tab.active{background:#1a2a3a;color:#4a9eff;border-color:#4a9eff}
.filter-tab.focused{box-shadow:0 0 0 2px #4a9eff;outline:none}

/* List items — always compact */
.item{padding:7px 10px;border-bottom:1px solid #1a1a1a;cursor:pointer;display:flex;align-items:center;gap:8px;position:relative;transition:background .15s ease}
.item:last-child{border-bottom:none}
.item:hover{background:#1e1e1e}
.item.sel{background:#1a2a3a;border-left:3px solid #4a9eff;padding-left:7px}

/* Title — always single line */
.item .title{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;font-size:13px;line-height:1.3}

/* Thumbnail — always small */
.item-img{width:36px;height:36px;object-fit:cover;border-radius:4px;flex-shrink:0}

/* Action buttons */
.item .actions{display:flex;gap:4px;align-items:center;flex-shrink:0}
.item .delete-btn{background:transparent;border:none;color:#c44;padding:4px;border-radius:4px;cursor:pointer;opacity:0;transition:opacity .15s;display:flex;align-items:center}
.item .pin-btn{background:transparent;border:none;color:#4a8;padding:4px;border-radius:4px;cursor:pointer;opacity:0;transition:opacity .15s;display:flex;align-items:center}
.item .eye-btn{background:transparent;border:none;color:#7ab;padding:4px;border-radius:4px;cursor:pointer;opacity:0;transition:opacity .15s;display:flex;align-items:center}
.item .bolt-btn{background:transparent;border:none;color:#e0b94a;padding:4px;border-radius:4px;cursor:pointer;opacity:0;transition:opacity .15s;display:flex;align-items:center}
.item .bolt-btn.has-hotkey{opacity:0.85}
.item:hover .delete-btn,.item:hover .pin-btn,.item:hover .eye-btn,.item:hover .bolt-btn,.item.sel .delete-btn,.item.sel .pin-btn,.item.sel .eye-btn,.item.sel .bolt-btn{opacity:0.6}
.item:hover .bolt-btn.has-hotkey,.item.sel .bolt-btn.has-hotkey{opacity:0.95}
.item .delete-btn:hover,.item .pin-btn:hover,.item .eye-btn:hover,.item .bolt-btn:hover{opacity:1}
.item.dragging{opacity:.35}
.item.drop-before{box-shadow:inset 0 2px 0 0 #4a9eff}
.item.drop-after{box-shadow:inset 0 -2px 0 0 #4a9eff}
.item.reorderable{cursor:grab}
.item.reorderable:active{cursor:grabbing}

/* Search bar */
.search{grid-column:1 / span 2;padding:8px 10px;background:#1c1c1c;border-radius:10px;margin-bottom:-6px;display:flex;gap:10px;align-items:center}
.search input{flex:1;background:#111;border:1px solid #333;color:#eee;padding:8px 10px;border-radius:8px;font-size:13px}
.hint{font-size:11px;opacity:.6;direction:rtl;text-align:right;white-space:nowrap}
.limit-wrap{display:flex;align-items:center;gap:6px;font-size:11px;color:#aaa;white-space:nowrap}
.limit-wrap label{opacity:.75}
.limit-wrap input{width:60px;background:#111;border:1px solid #333;color:#eee;padding:6px 8px;border-radius:6px;font-size:12px;text-align:center;-moz-appearance:textfield}
.limit-wrap input::-webkit-outer-spin-button,.limit-wrap input::-webkit-inner-spin-button{-webkit-appearance:none;margin:0}
.limit-wrap input:focus{border-color:#4a9eff;outline:none}

/* Detail view overlay */
.detail-overlay{position:fixed;top:0;left:0;right:0;bottom:0;background:#111;z-index:1000;display:flex;flex-direction:column;opacity:0;transition:opacity .15s ease;pointer-events:none;border-radius:12px}
.detail-overlay.active{opacity:1;pointer-events:auto}
.detail-header{padding:12px 16px;display:flex;align-items:center;gap:12px;border-bottom:1px solid #333;flex-shrink:0}
.detail-back{background:transparent;border:none;color:#4a9eff;cursor:pointer;display:flex;align-items:center;gap:4px;font-size:13px;padding:4px 8px;border-radius:6px;transition:background .15s}
.detail-back:hover{background:#1a2a3a}
.detail-back svg{width:14px;height:14px}
.detail-title{flex:1;font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.detail-content{flex:1;overflow:auto;padding:16px}
.detail-text{white-space:pre-wrap;word-break:break-word;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:13px;line-height:1.6;color:#ddd;background:#0a0a0a;padding:16px;border-radius:8px;min-height:100px}
.detail-edit{width:100%;min-height:300px;background:#0a0a0a;color:#ddd;border:1px solid #333;border-radius:8px;padding:16px;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:13px;line-height:1.6;resize:vertical;outline:none;box-sizing:border-box}
.detail-edit:focus{border-color:#2563eb}
.detail-image{display:flex;align-items:center;justify-content:center;height:100%}
.detail-image img{max-width:95%;max-height:90vh;object-fit:contain;border-radius:8px;image-rendering:high-quality;image-rendering:-webkit-optimize-contrast}
.detail-actions{padding:12px 16px;display:flex;gap:8px;border-top:1px solid #333;flex-shrink:0;justify-content:flex-end}
.detail-btn{border:none;color:#eee;padding:8px 16px;border-radius:8px;cursor:pointer;font-size:13px;font-weight:500;display:flex;align-items:center;gap:6px;transition:background .15s}
.detail-btn.primary{background:#2563eb}
.detail-btn.primary:hover{background:#3b82f6}
.detail-btn.secondary{background:#333}
.detail-btn.secondary:hover{background:#444}
.detail-btn svg{width:14px;height:14px}

/* Hotkey badges */
.hotkey-badge{display:inline-flex;align-items:center;gap:4px;background:#333;color:#aaa;font-size:10px;padding:2px 6px;border-radius:4px;margin-left:4px;white-space:nowrap;flex-shrink:0;font-family:'SF Mono',Menlo,monospace;letter-spacing:.3px}
.hotkey-badge-x{cursor:pointer;color:#888;font-family:-apple-system,Helvetica,Arial;font-size:12px;line-height:1;padding:0 2px;border-radius:3px;transition:color .15s,background .15s}
.hotkey-badge-x:hover{color:#fff;background:#c44}

/* Capture overlay */
.capture-overlay{position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.85);z-index:2000;display:flex;flex-direction:column;align-items:center;justify-content:center;opacity:0;transition:opacity .15s ease;pointer-events:none;border-radius:12px}
.capture-overlay.active{opacity:1;pointer-events:auto}
.capture-prompt{font-size:20px;font-weight:600;color:#eee;margin-bottom:12px}
.capture-hint{font-size:12px;color:#888;margin-bottom:16px}
.capture-status{font-size:14px;color:#4a9eff;min-height:20px}
.capture-status.error{color:#e55}
</style></head><body>
<div class="container">
  <div class="search">
    <input id="q" type="text" placeholder="Search...">
    <div class="limit-wrap" title="Max recent copies kept before auto-delete">
      <label for="maxRecentInput">Limit:</label>
      <input id="maxRecentInput" type="number" min="]] .. MAX_RECENT_MIN .. [[" max="]] .. MAX_RECENT_MAX .. [[" step="1" value="]] .. maxRecent .. [[">
    </div>
  </div>
  <div class="column" id="recentCol" tabindex="0" aria-label="Recent">
    <div class="header">
      <span class="header-title">]] .. ICON.clock .. [[ Recent</span>
      <div class="header-actions">
        <button class="header-btn" onclick="clearRecent()" title="Clear all recent items">]] .. ICON.trash .. [[</button>
        <button class="header-btn" onclick="pinSelected()" title="Pin selected item">]] .. ICON.pin .. [[</button>
      </div>
    </div>
    <div class="filter-tabs" id="filterTabs">
      <button class="filter-tab active" data-tf="all" onclick="setTypeFilter('all')">All</button>
      <button class="filter-tab" data-tf="images" onclick="setTypeFilter('images')">Images</button>
      <button class="filter-tab" data-tf="text" onclick="setTypeFilter('text')">Text</button>
    </div>
    <div class="list" id="recentList"></div>
  </div>
  <div class="column" id="pinnedCol" tabindex="0" aria-label="Pinned">
    <div class="header">
      <span class="header-title">]] .. ICON.pin .. [[ Pinned</span>
      <div class="header-actions">
        <button class="header-btn" onclick="addNewPinned()" title="Add new pinned item">]] .. ICON.plus .. [[</button>
      </div>
    </div>
    <div class="list" id="pinnedList"></div>
  </div>
</div>

<!-- Detail view overlay -->
<div class="detail-overlay" id="detailOverlay">
  <div class="detail-header">
    <button class="detail-back" onclick="closeDetail()">]] .. ICON.arrowLeft .. [[ Back</button>
    <div class="detail-title" id="detailTitle"></div>
  </div>
  <div class="detail-content" id="detailContent"></div>
  <div class="detail-actions" id="detailActions"></div>
</div>

<!-- Hotkey capture overlay -->
<div class="capture-overlay" id="captureOverlay">
  <div class="capture-prompt">Press desired shortcut...</div>
  <div class="capture-hint">Esc to cancel | Backspace to remove current</div>
  <div class="capture-status" id="captureStatus"></div>
</div>

<script>
let pinned=]] .. pinnedJSON .. [[, recent=]] .. recentJSON .. [[;
let selCol='recent', selIdx=0, filter='', hasInteracted=false, detailMode=false, editMode=false;
let captureMode=false, captureIndex=-1;
let typeFilter='all';
const FILTER_ORDER=['all','images','text'];
let dragFromIdx=-1, dragHoverIdx=-1, dragHoverBefore=true;
let dragStartX=0, dragStartY=0, dragActiveEl=null, dragPending=false, dragMoved=false, suppressClick=false;
const norm=s=>(s||'').toLowerCase();
const esc=s=>{const d=document.createElement('div');d.textContent=s;return d.innerHTML;};
const filtered=arr=>{
  let out=!filter?arr:arr.filter(it=>norm(it.content||'').includes(filter)||norm(it.title||'').includes(filter));
  if(arr===recent && typeFilter!=='all'){
    out=out.filter(it=>typeFilter==='images' ? it.type==='image' : it.type!=='image');
  }
  return out;
};
function setTypeFilter(name){
  if(!FILTER_ORDER.includes(name)) return;
  typeFilter=name;
  selIdx=0;
  render();
}
function cyclePicker(d){
  const i=FILTER_ORDER.indexOf(typeFilter);
  const n=FILTER_ORDER.length;
  setTypeFilter(FILTER_ORDER[((i+d)%n+n)%n]);
}
function updatePickerUI(){
  document.querySelectorAll('#filterTabs .filter-tab').forEach(el=>{
    el.classList.toggle('active', el.dataset.tf===typeFilter);
    el.classList.toggle('focused', selCol==='picker' && el.dataset.tf===typeFilter);
  });
}

const pinIcon=']] .. ICON.pin:gsub("'", "\\'") .. [[';
const xIcon=']] .. ICON.xMark:gsub("'", "\\'") .. [[';
const eyeIcon=']] .. ICON.eye:gsub("'", "\\'") .. [[';
const boltIcon=']] .. ICON.bolt:gsub("'", "\\'") .. [[';

function formatHotkey(hk){
  if(!hk||!hk.key) return '';
  const mods=(hk.mods||[]).map(m=>m.charAt(0).toUpperCase()+m.slice(1));
  return mods.concat([hk.key.toUpperCase()]).join('+');
}

function captureForRow(idx){
  selCol='pinned';
  selIdx=idx;
  hasInteracted=true;
  renderSelection();
  openCapture();
}
function removeHotkeyForRow(idx){
  const arr=filtered(pinned);
  const it=arr[idx]; if(!it||!it.hotkey) return;
  const actualIdx=pinned.findIndex(p=>p.content===it.content&&p.title===it.title);
  if(actualIdx===-1) return;
  if(!confirm('Remove hotkey '+formatHotkey(it.hotkey)+'?')) return;
  delete pinned[actualIdx].hotkey;
  render();
  try{window.webkit.messageHandlers.clips.postMessage({action:'removeHotkey',index:actualIdx});}catch(e){}
}
function openCapture(){
  const arr=filtered(pinned);
  if(selCol!=='pinned'||!arr[selIdx]) return;
  captureMode=true;
  captureIndex=selIdx;
  const statusEl=document.getElementById('captureStatus');
  statusEl.textContent='';
  statusEl.className='capture-status';
  document.getElementById('captureOverlay').classList.add('active');
}

function closeCapture(){
  captureMode=false;
  captureIndex=-1;
  document.getElementById('captureOverlay').classList.remove('active');
}

function hotkeyResult(success, message){
  if(success){
    // Update local data and close overlay
    const arr=filtered(pinned);
    const actualIdx=pinned.findIndex(p=>p.content===arr[captureIndex].content&&p.title===arr[captureIndex].title);
    if(actualIdx!==-1){
      // Parse the display string back to hotkey object for local state
      const parts=message.split('+');
      const key=parts.pop().toLowerCase();
      const mods=parts.map(m=>m.toLowerCase());
      pinned[actualIdx].hotkey={mods:mods,key:key};
      // Also clear this hotkey from any other pinned item
      pinned.forEach((p,i)=>{
        if(i!==actualIdx&&p.hotkey&&p.hotkey.key===key){
          const sameMods=JSON.stringify((p.hotkey.mods||[]).sort())===JSON.stringify(mods.sort());
          if(sameMods) delete p.hotkey;
        }
      });
    }
    closeCapture();
    render();
  } else {
    const statusEl=document.getElementById('captureStatus');
    statusEl.textContent=message;
    statusEl.className='capture-status error';
    setTimeout(()=>{
      statusEl.textContent='';
      statusEl.className='capture-status';
    },2000);
  }
}

function render(){
  updatePickerUI();
  const r=filtered(recent), p=filtered(pinned);
  const rList=document.getElementById('recentList'), pList=document.getElementById('pinnedList');
  rList.innerHTML=''; pList.innerHTML='';
  r.forEach((it,i)=>{
    const el=document.createElement('div');
    el.className='item'+(selCol==='recent'&&selIdx===i?' sel':'');
    let inner='';
    if(it.type==='image'){
      inner+='<img src="'+(it.content||'')+'" class="item-img" loading="lazy">';
    }
    inner+='<div class="title">'+esc(it.title||it.content||'(empty)')+'</div>';
    inner+='<div class="actions"><button class="eye-btn" onclick="event.stopPropagation();previewItem(\'recent\','+i+')" title="Preview">'+eyeIcon+'</button><button class="pin-btn" onclick="event.stopPropagation();quickPinRecent('+i+')">'+pinIcon+'</button></div>';
    el.innerHTML=inner;
    el.onclick=()=>{selCol='recent';selIdx=i;hasInteracted=true;selectAndCommit('recent',i);};
    rList.appendChild(el);
  });
  p.forEach((it,i)=>{
    const el=document.createElement('div');
    el.className='item'+(selCol==='pinned'&&selIdx===i?' sel':'');
    let inner='';
    if(it.type==='image'){
      inner+='<img src="'+(it.content||'')+'" class="item-img" loading="lazy">';
    }
    inner+='<div class="title">'+esc(it.title||it.content||'(empty)')+'</div>';
    if(it.hotkey){inner+='<span class="hotkey-badge">'+esc(formatHotkey(it.hotkey))+'<span class="hotkey-badge-x" onclick="event.stopPropagation();removeHotkeyForRow('+i+')" title="Remove hotkey">×</span></span>';}
    const hkTitle=it.hotkey?'Edit hotkey ('+esc(formatHotkey(it.hotkey))+')':'Assign hotkey';
    const hkClass='bolt-btn'+(it.hotkey?' has-hotkey':'');
    inner+='<div class="actions"><button class="'+hkClass+'" onclick="event.stopPropagation();captureForRow('+i+')" title="'+hkTitle+'">'+boltIcon+'</button><button class="eye-btn" onclick="event.stopPropagation();previewItem(\'pinned\','+i+')" title="Preview">'+eyeIcon+'</button><button class="delete-btn" onclick="event.stopPropagation();deletePinned('+i+')">'+xIcon+'</button></div>';
    el.innerHTML=inner;
    el.onclick=()=>{
      if(suppressClick){suppressClick=false;return;}
      selCol='pinned';selIdx=i;hasInteracted=true;selectAndCommit('pinned',i);
    };
    // Drag-to-reorder (only when no search filter is active)
    if(!filter){
      el.classList.add('reorderable');
      el.dataset.pidx=i;
      el.addEventListener('mousedown',ev=>{
        if(ev.button!==0) return;
        if(ev.target.closest('button')) return;
        dragFromIdx=i;
        dragHoverIdx=-1;
        dragHoverBefore=true;
        dragStartX=ev.clientX;
        dragStartY=ev.clientY;
        dragActiveEl=el;
        dragPending=true;
        dragMoved=false;
      });
    }
    pList.appendChild(el);
  });
}
function clearDropIndicators(){
  document.querySelectorAll('.item.drop-before,.item.drop-after').forEach(e=>e.classList.remove('drop-before','drop-after'));
}
function clearDragState(){
  if(dragActiveEl) dragActiveEl.classList.remove('dragging');
  clearDropIndicators();
  dragFromIdx=-1;
  dragHoverIdx=-1;
  dragHoverBefore=true;
  dragActiveEl=null;
  dragPending=false;
  dragMoved=false;
}
function reorderPinned(from,to){
  if(from===to||from<0||from>=pinned.length||to<0||to>=pinned.length) return;
  const item=pinned.splice(from,1)[0];
  pinned.splice(to,0,item);
  if(selCol==='pinned'){
    if(selIdx===from) selIdx=to;
    else if(from<selIdx&&to>=selIdx) selIdx-=1;
    else if(from>selIdx&&to<=selIdx) selIdx+=1;
  }
  render();
  try{window.webkit.messageHandlers.clips.postMessage({action:'reorderPinned',from:from,to:to});}catch(e){}
}
document.addEventListener('mousemove',ev=>{
  if(!dragPending||dragFromIdx<0) return;
  const dx=ev.clientX-dragStartX, dy=ev.clientY-dragStartY;
  if(!dragMoved){
    if((dx*dx+dy*dy)<25) return;
    dragMoved=true;
    if(dragActiveEl) dragActiveEl.classList.add('dragging');
  }
  const target=ev.target.closest ? ev.target.closest('#pinnedList .item') : null;
  clearDropIndicators();
  if(!target){
    dragHoverIdx=-1;
    return;
  }
  const hoverIdx=Number(target.dataset.pidx);
  if(!Number.isFinite(hoverIdx)||hoverIdx===dragFromIdx){
    dragHoverIdx=-1;
    return;
  }
  const r=target.getBoundingClientRect();
  const before=(ev.clientY-r.top)<r.height/2;
  dragHoverIdx=hoverIdx;
  dragHoverBefore=before;
  target.classList.add(before?'drop-before':'drop-after');
});
document.addEventListener('mouseup',()=>{
  if(!dragPending){clearDragState();return;}
  const wasDragging=dragMoved;
  const from=dragFromIdx, hoverIdx=dragHoverIdx, before=dragHoverBefore;
  clearDragState();
  if(!wasDragging||hoverIdx<0||from<0||from===hoverIdx) return;
  let toIdx=before?hoverIdx:hoverIdx+1;
  if(from<toIdx) toIdx-=1;
  suppressClick=true;
  reorderPinned(from,toIdx);
});

// Fast path: only update selection classes without rebuilding DOM
function renderSelection(){
  updatePickerUI();
  const rList=document.getElementById('recentList'), pList=document.getElementById('pinnedList');
  Array.from(rList.children).forEach((el,i)=>{
    el.classList.toggle('sel', selCol==='recent'&&selIdx===i);
  });
  Array.from(pList.children).forEach((el,i)=>{
    el.classList.toggle('sel', selCol==='pinned'&&selIdx===i);
  });
  if(selCol==='recent'||selCol==='pinned') ensureVisible();
}

function clampSel(){
  const len=(selCol==='recent'?filtered(recent).length:filtered(pinned).length);
  if(len===0){selIdx=0;return;} if(selIdx<0)selIdx=0; if(selIdx>len-1)selIdx=len-1;
}
function move(d){hasInteracted=true;selIdx+=d;clampSel();renderSelection();}
function ensureVisible(){
  const list=document.getElementById(selCol==='recent'?'recentList':'pinnedList');
  const item=list.children[selIdx];
  if(!item)return;
  const r=item.getBoundingClientRect(), lr=list.getBoundingClientRect();
  if(r.top<lr.top) list.scrollTop-=(lr.top-r.top+8);
  if(r.bottom>lr.bottom) list.scrollTop+=(r.bottom-lr.bottom+8);
}
function switchCol(){
  hasInteracted=true;
  const r=filtered(recent), p=filtered(pinned);
  if(selCol==='recent'){selCol='pinned'; selIdx=Math.min(selIdx, Math.max(p.length-1,0));}
  else{selCol='recent'; selIdx=Math.min(selIdx, Math.max(r.length-1,0));}
  renderSelection();
}

function selectAndCommit(col, idx){
  hasInteracted=true;selCol=col;selIdx=idx;clampSel();renderSelection();
  const arr=(col==='recent'?filtered(recent):filtered(pinned));
  const it=arr[selIdx]; if(!it) return;
  try{window.webkit.messageHandlers.clips.postMessage({
    action:'select', type:it.type||'text', content:it.content||'',
    title:it.title||'', imagePath:it.imagePath||''
  });}catch(e){}
}

// Open preview/detail view from action button
// For text items, jump straight into edit mode; for images, just preview.
function previewItem(col, idx){
  selCol=col;selIdx=idx;hasInteracted=true;renderSelection();
  const arr=(col==='recent'?filtered(recent):filtered(pinned));
  const it=arr[selIdx];
  openDetail();
  if(it && it.type !== 'image'){startEdit();}
}

// Detail view
function openDetail(){
  const arr=(selCol==='recent'?filtered(recent):filtered(pinned));
  const it=arr[selIdx]; if(!it) return;
  detailMode=true;
  const overlay=document.getElementById('detailOverlay');
  const titleEl=document.getElementById('detailTitle');
  const contentEl=document.getElementById('detailContent');
  const actionsEl=document.getElementById('detailActions');

  titleEl.textContent=it.title||'(empty)';

  if(it.type==='image'){
    contentEl.innerHTML='<div class="detail-image"><img id="detailImg" src="" style="opacity:0"></div>';
    const fullList=(selCol==='recent'?recent:pinned);
    const actualIdx=fullList.indexOf(it);
    try{window.webkit.messageHandlers.clips.postMessage({action:'expandForImage'});}catch(e){}
    if(actualIdx>=0){
      try{window.webkit.messageHandlers.clips.postMessage({action:'loadFullImage',index:actualIdx,col:selCol});}catch(e){}
    }
  } else {
    const text=it.content||it.title||'';
    contentEl.innerHTML='<div class="detail-text">'+esc(text)+'</div>';
  }

  // Action buttons with Heroicons
  let actions='';
  actions+='<button class="detail-btn secondary" onclick="closeDetail()">]] .. ICON.arrowLeft:gsub("'", "\\'") .. [[ Back (Esc)</button>';
  if(it.type!=='image'){
    actions+='<button class="detail-btn secondary" onclick="startEdit()">]] .. ICON.pencil:gsub("'", "\\'") .. [[ Edit (E)</button>';
  }
  if(selCol==='recent'){
    actions+='<button class="detail-btn secondary" onclick="pinFromDetail()">]] .. ICON.pin:gsub("'", "\\'") .. [[ Pin (P)</button>';
  }
  if(selCol==='pinned'){
    const hkLabel=it.hotkey?formatHotkey(it.hotkey)+' (H to change)':'Set Hotkey (H)';
    actions+='<button class="detail-btn secondary" onclick="openCapture()">]] .. ICON.bolt:gsub("'", "\\'") .. [[ '+esc(hkLabel)+'</button>';
  }
  actions+='<button class="detail-btn primary" onclick="pasteFromDetail()">]] .. ICON.clipboard:gsub("'", "\\'") .. [[ Paste (Enter)</button>';
  actionsEl.innerHTML=actions;

  overlay.classList.add('active');
}

function startEdit(){
  const arr=(selCol==='recent'?filtered(recent):filtered(pinned));
  const it=arr[selIdx]; if(!it||it.type==='image') return;
  editMode=true;
  const contentEl=document.getElementById('detailContent');
  const actionsEl=document.getElementById('detailActions');
  const text=it.content||'';
  contentEl.innerHTML='<textarea id="editArea" class="detail-edit" spellcheck="false"></textarea>';
  const ta=document.getElementById('editArea');
  ta.value=text;
  ta.focus();
  ta.setSelectionRange(text.length,text.length);
  try{window.webkit.messageHandlers.clips.postMessage({action:'enableTextEntry'});}catch(e){}
  actionsEl.innerHTML=
    '<button class="detail-btn secondary" onclick="cancelEdit()">]] .. ICON.arrowLeft:gsub("'", "\\'") .. [[ Cancel (Esc)</button>'+
    '<button class="detail-btn primary" onclick="saveEdit()">]] .. ICON.check:gsub("'", "\\'") .. [[ Save (Cmd+S)</button>';
}

function cancelEdit(){
  editMode=false;
  try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}
  openDetail();
}

function reopenDetailAfterEdit(){
  if(detailMode){openDetail();}
}

function setFullImage(dataUrl){
  const img=document.getElementById('detailImg');
  if(img&&dataUrl){img.src=dataUrl;img.style.opacity='1';}
}

// Replace data, close detail/edit, return to main list with the edited item selected at top.
function applyEditAndClose(newPinned, newRecent, col, newIdx){
  pinned.length=0; pinned.push(...newPinned);
  recent.length=0; recent.push(...newRecent);
  editMode=false;
  detailMode=false;
  document.getElementById('detailOverlay').classList.remove('active');
  try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}
  try{window.webkit.messageHandlers.clips.postMessage({action:'restorePanel'});}catch(e){}
  selCol=col||'recent';
  selIdx=newIdx||0;
  render();
}

function saveEdit(){
  const ta=document.getElementById('editArea'); if(!ta) return;
  const arr=(selCol==='recent'?filtered(recent):filtered(pinned));
  const it=arr[selIdx]; if(!it) return;
  const fullList=(selCol==='recent'?recent:pinned);
  const actualIdx=fullList.indexOf(it);
  if(actualIdx<0) return;
  const newContent=ta.value;
  editMode=false;
  try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}
  try{window.webkit.messageHandlers.clips.postMessage({
    action:'editItem', col:selCol, index:actualIdx, content:newContent
  });}catch(e){}
}

function closeDetail(){
  detailMode=false;
  document.getElementById('detailOverlay').classList.remove('active');
  try{window.webkit.messageHandlers.clips.postMessage({action:'restorePanel'});}catch(e){}
}

function pasteFromDetail(){
  closeDetail();
  selectAndCommit(selCol,selIdx);
}

function pinFromDetail(){
  const arr=filtered(recent); const it=arr[selIdx];
  if(!it||selCol!=='recent') return;
  const title=(it.title||it.content||'').slice(0,60)||'(empty)';
  try{window.webkit.messageHandlers.clips.postMessage({
    action:'addPinned', type:it.type||'text', content:it.content||'',
    title:title, imagePath:it.imagePath||''
  });}catch(e){}
}

function pinSelected(){
  try{window.webkit.messageHandlers.clips.postMessage({action:'enableTextEntry'});}catch(e){}
  const arr=filtered(recent); const it=arr[selIdx]; if(!it||selCol!=='recent') return;
  const title=prompt('Name for pinned item:', (it.title||it.content||'').slice(0,60));
  try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}
  if(title===null) return;
  try{window.webkit.messageHandlers.clips.postMessage({
    action:'addPinned', type:it.type||'text', content:it.content||'',
    title:title||'', imagePath:it.imagePath||''
  });}catch(e){}
}
function addNewPinned(){
  try{window.webkit.messageHandlers.clips.postMessage({action:'enableTextEntry'});}catch(e){}
  const content=prompt('Paste text:');
  if(!content){try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}return;}
  const title=prompt('Name:', content.slice(0,60));
  try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}
  if(title===null) return;
  try{window.webkit.messageHandlers.clips.postMessage({action:'addPinned', type:'text', content:content, title:title||content.slice(0,60)});}catch(e){}
}
function quickPinRecent(idx){
  const arr=filtered(recent); const it=arr[idx]; if(!it) return;
  const title=(it.title||it.content||'').replace(/\s+/g,' ').slice(0,60)||'(empty)';
  try{window.webkit.messageHandlers.clips.postMessage({
    action:'addPinned', type:it.type||'text', content:it.content||'',
    title:title, imagePath:it.imagePath||''
  });}catch(e){}
}
function deletePinned(idx){
  const arr=filtered(pinned); const it=arr[idx]; if(!it) return;
  const actualIdx=pinned.findIndex(p=>p.content===it.content&&p.title===it.title);
  if(actualIdx===-1) return;
  if(!confirm('Delete "'+((it.title||it.content||'').slice(0,40))+'"?')) return;
  try{window.webkit.messageHandlers.clips.postMessage({action:'deletePinned', index:actualIdx});}catch(e){}
}
function clearRecent(){
  if(!confirm('Clear all clipboard history? (pinned items are kept)')) return;
  try{window.webkit.messageHandlers.clips.postMessage({action:'clearRecent'});}catch(e){}
}

// Update data in-place (used by persistent webview)
function updateData(newPinned, newRecent){
  pinned.length=0; pinned.push(...newPinned);
  recent.length=0; recent.push(...newRecent);
  selIdx=0; selCol='recent'; filter=''; hasInteracted=false; detailMode=false;
  captureMode=false; captureIndex=-1;
  document.getElementById('detailOverlay').classList.remove('active');
  document.getElementById('captureOverlay').classList.remove('active');
  const q=document.getElementById('q'); if(q) q.value='';
  render();
}

document.addEventListener('keydown',e=>{
  const searchFocused=document.activeElement===searchInput;

  // Capture mode: intercept all keys for hotkey assignment
  if(captureMode){
    e.preventDefault();
    if(e.key==='Escape'){closeCapture();return;}
    if(e.key==='Backspace'||e.key==='Delete'){
      // Remove hotkey from this pinned item
      const arr=filtered(pinned);
      const it=arr[captureIndex];
      if(it){
        const actualIdx=pinned.findIndex(p=>p.content===it.content&&p.title===it.title);
        if(actualIdx!==-1){
          try{window.webkit.messageHandlers.clips.postMessage({action:'removeHotkey',index:actualIdx});}catch(ex){}
        }
      }
      closeCapture();
      return;
    }
    // Ignore modifier-only presses
    if(['Shift','Control','Alt','Meta','CapsLock','Tab'].includes(e.key)) return;
    // Require at least one modifier
    if(!e.metaKey&&!e.altKey&&!e.ctrlKey&&!e.shiftKey) return;
    // Build mods array
    const mods=[];
    if(e.metaKey) mods.push('cmd');
    if(e.altKey) mods.push('alt');
    if(e.ctrlKey) mods.push('ctrl');
    if(e.shiftKey) mods.push('shift');
    // Get key name
    let key=e.key.toLowerCase();
    // For digits, use e.code to get the actual digit
    if(e.code&&e.code.startsWith('Digit')) key=e.code.charAt(5);
    else if(e.code&&e.code.startsWith('Key')) key=e.code.charAt(3).toLowerCase();
    // Get the actual pinned index
    const arr=filtered(pinned);
    const it=arr[captureIndex];
    if(!it) return;
    const actualIdx=pinned.findIndex(p=>p.content===it.content&&p.title===it.title);
    if(actualIdx===-1) return;
    // Show verifying state
    const statusEl=document.getElementById('captureStatus');
    statusEl.textContent='Verifying...';
    statusEl.className='capture-status';
    try{window.webkit.messageHandlers.clips.postMessage({action:'assignHotkey',index:actualIdx,mods:mods,key:key});}catch(ex){}
    return;
  }

  if(editMode){
    if(e.key==='Escape'){e.preventDefault();cancelEdit();}
    else if((e.key==='s'||e.key==='S')&&(e.metaKey||e.ctrlKey)){e.preventDefault();saveEdit();}
    return;
  }

  if(detailMode){
    // In detail mode, only specific keys work
    if(e.key==='Escape'||e.key===' '){e.preventDefault();closeDetail();}
    else if(e.key==='Enter'){e.preventDefault();pasteFromDetail();}
    else if(e.key==='p'||e.key==='P'){e.preventDefault();pinFromDetail();}
    else if(e.key==='e'||e.key==='E'){e.preventDefault();startEdit();}
    else if((e.key==='h'||e.key==='H')&&selCol==='pinned'){e.preventDefault();openCapture();}
    return;
  }

  if(e.key==='ArrowDown'){
    e.preventDefault();
    if(selCol==='picker'){selCol='recent';selIdx=0;hasInteracted=true;renderSelection();}
    else{move(1);}
  }
  else if(e.key==='ArrowUp'){
    e.preventDefault();
    if(selCol==='picker'){/* already at top */}
    else if(selCol==='recent'&&selIdx===0){selCol='picker';hasInteracted=true;renderSelection();}
    else{move(-1);}
  }
  else if(e.key==='ArrowLeft'||e.key==='ArrowRight'){
    e.preventDefault();
    if(selCol==='picker'){cyclePicker(e.key==='ArrowLeft'?-1:1);}
    else{switchCol();}
  }
  else if(e.key===' '&&!searchFocused){
    e.preventDefault();
    if(selCol!=='picker') openDetail();
  }
  else if((e.key==='h'||e.key==='H')&&selCol==='pinned'&&!searchFocused){e.preventDefault();openCapture();}
  else if(e.key==='Enter'){
    e.preventDefault();
    if(selCol==='picker'){selCol='recent';selIdx=0;hasInteracted=true;renderSelection();}
    else{selectAndCommit(selCol,selIdx);}
  }
  else if(e.key==='Escape'){
    e.preventDefault();
    if(searchFocused&&searchInput.value){searchInput.value='';filter='';selIdx=0;render();}
    else{try{window.webkit.messageHandlers.clips.postMessage({action:'close'});}catch(e){}}
  }
});
const searchInput=document.getElementById('q');
searchInput.addEventListener('focus',()=>{try{window.webkit.messageHandlers.clips.postMessage({action:'enableTextEntry'});}catch(e){}});
searchInput.addEventListener('blur',()=>{try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}});
const maxRecentInput=document.getElementById('maxRecentInput');
const MAX_LO=]] .. MAX_RECENT_MIN .. [[, MAX_HI=]] .. MAX_RECENT_MAX .. [[;
let maxRecentDebounce=null;
function commitMaxRecent(){
  let v=parseInt(maxRecentInput.value,10);
  if(!Number.isFinite(v)) return;
  if(v<MAX_LO) v=MAX_LO;
  if(v>MAX_HI) v=MAX_HI;
  maxRecentInput.value=String(v);
  try{window.webkit.messageHandlers.clips.postMessage({action:'setMaxRecent',value:v});}catch(e){}
}
maxRecentInput.addEventListener('focus',()=>{try{window.webkit.messageHandlers.clips.postMessage({action:'enableTextEntry'});}catch(e){}});
maxRecentInput.addEventListener('blur',()=>{try{window.webkit.messageHandlers.clips.postMessage({action:'disableTextEntry'});}catch(e){}commitMaxRecent();});
maxRecentInput.addEventListener('input',()=>{clearTimeout(maxRecentDebounce);maxRecentDebounce=setTimeout(commitMaxRecent,400);});
maxRecentInput.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();commitMaxRecent();maxRecentInput.blur();}});
searchInput.addEventListener('input',e=>{hasInteracted=true;filter=norm(e.target.value||'');selIdx=0;render();});
window.addEventListener('load',()=>{render();});
</script></body></html>
]]
end

------------------------------------------------------------
-- Smart anchor near mouse (flip + clamp into the mouse's screen)
------------------------------------------------------------
local function computeSmartRect(w, h)
  local mouseAbs = hs.mouse.absolutePosition() or hs.mouse.getAbsolutePosition()
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local sf = screen:fullFrame()  -- use fullFrame for absolute coordinates
  local margin, offset = 8, 16

  local x = mouseAbs.x + offset
  local y = mouseAbs.y + offset

  -- flip horizontally if crossing right edge
  if x + w > sf.x + sf.w - margin then
    x = mouseAbs.x - w - offset
  end
  -- flip vertically if crossing bottom edge
  if y + h > sf.y + sf.h - margin then
    y = mouseAbs.y - h - offset
  end

  -- final clamp to the current screen frame
  if x < sf.x + margin then x = sf.x + margin end
  if y < sf.y + margin then y = sf.y + margin end
  if x + w > sf.x + sf.w - margin then x = sf.x + sf.w - w - margin end
  if y + h > sf.y + sf.h - margin then y = sf.y + sf.h - h - margin end

  return hs.geometry.rect(x, y, w, h), screen, {x = x, y = y}
end

------------------------------------------------------------
-- Elevate panel above full-screen & join all spaces
------------------------------------------------------------
local function elevatePanel(p)
  if hs.webview and hs.webview.windowBehaviors then
    pcall(function()
      local behaviors = hs.webview.windowBehaviors
      if behaviors.canJoinAllSpaces and behaviors.fullScreenAuxiliary then
        p:behavior(behaviors.canJoinAllSpaces + behaviors.fullScreenAuxiliary)
      end
    end)
  end

  pcall(function()
    if hs.drawing and hs.drawing.windowLevels and hs.drawing.windowLevels.mainMenu then
      p:level(hs.drawing.windowLevels.mainMenu)
    end
  end)

  p:bringToFront(true)
end

------------------------------------------------------------
-- Close panel helper (hide instead of delete for persistent webview)
------------------------------------------------------------
local function closePanel()
  -- Flush any pending saves before closing
  if saveRecentTimer then
    saveRecentTimer:stop()
    saveRecentTimer = nil
    saveRecent()
  end

  if keyWatcher then
    keyWatcher:stop()
    keyWatcher = nil
  end
  if clickWatcher then
    clickWatcher:stop()
    clickWatcher = nil
  end
  if panel and savedPanelFrame then
    pcall(function()
      panel:topLeft({ x = savedPanelFrame.x, y = savedPanelFrame.y })
      panel:size({ w = savedPanelFrame.w, h = savedPanelFrame.h })
    end)
    savedPanelFrame = nil
  end
  if panel then
    panel:hide()
  end
  hs.dockicon.show()
end

-- Fully destroy the panel (used for cleanup/recreation)
local function destroyPanel()
  if panel then
    pcall(function() panel:delete() end)
    panel = nil
    panelUCC = nil
  end
end

------------------------------------------------------------
-- Hotkey conflict detection (blocklist approach)
------------------------------------------------------------
local function makeHotkeyKey(mods, key)
  local sorted = {}
  for _, m in ipairs(mods) do table.insert(sorted, m:lower()) end
  table.sort(sorted)
  return table.concat(sorted, "+") .. "+" .. key:lower()
end

local function getReservedHotkeys()
  local reserved = {}

  -- Block ALL Cmd+key combos (used by every macOS app)
  local letters = "abcdefghijklmnopqrstuvwxyz"
  for i = 1, #letters do
    local ch = letters:sub(i, i)
    reserved[makeHotkeyKey({"cmd"}, ch)] = "macOS / apps"
  end
  for i = 0, 9 do
    reserved[makeHotkeyKey({"cmd"}, tostring(i))] = "macOS / apps"
  end

  -- Common Cmd+Shift combos
  local cmdShiftReserved = {
    {{"cmd","shift"}, "z"}, {{"cmd","shift"}, "s"}, {{"cmd","shift"}, "tab"},
    {{"cmd","shift"}, "3"}, {{"cmd","shift"}, "4"}, {{"cmd","shift"}, "5"},
    {{"cmd","shift"}, "q"}, {{"cmd","shift"}, "h"}, {{"cmd","shift"}, "d"},
    {{"cmd","shift"}, "g"}, {{"cmd","shift"}, "n"},
  }
  for _, sc in ipairs(cmdShiftReserved) do
    reserved[makeHotkeyKey(sc[1], sc[2])] = "macOS"
  end

  -- System ctrl combos
  local ctrlReserved = {
    {{"ctrl"}, "up"}, {{"ctrl"}, "down"}, {{"ctrl"}, "left"}, {{"ctrl"}, "right"},
    {{"ctrl"}, "space"},
    {{"ctrl","cmd"}, "q"}, {{"ctrl","cmd"}, "f"},
  }
  for _, sc in ipairs(ctrlReserved) do
    reserved[makeHotkeyKey(sc[1], sc[2])] = "macOS"
  end

  -- Hammerspoon clipboard manager shortcuts
  reserved[makeHotkeyKey({"alt"}, "z")] = "Clipboard Manager"
  reserved[makeHotkeyKey({"alt","shift"}, "z")] = "Quick Pin"
  for i = 1, 9 do
    reserved[makeHotkeyKey({"ctrl"}, tostring(i))] = "Paste #" .. i
  end

  -- Hotkeys from hotkey_manager config (other Hammerspoon tools)
  if hotkeyManagerRef then
    local ok, cfg = pcall(function() return hotkeyManagerRef.getConfig() end)
    if ok and cfg then
      for name, entry in pairs(cfg) do
        if type(entry) == "table" and entry.mods and entry.key then
          reserved[makeHotkeyKey(entry.mods, entry.key)] = name
        end
      end
    end
  end

  -- Other pinned item hotkeys (to show which item has it)
  for i, item in ipairs(store.pinned) do
    if item.hotkey and item.hotkey.key then
      reserved[makeHotkeyKey(item.hotkey.mods or {}, item.hotkey.key)] = "Pinned: " .. (item.title or "#" .. i)
    end
  end

  return reserved
end

------------------------------------------------------------
-- Message handler callback (shared between panel creations)
------------------------------------------------------------
local function handleWebMessage(msg)
  if not msg or not msg.body then return end
  local body = msg.body
  if body.action == "select" then
    local contentType = body.type or "text"
    local content = body.content or ""
    local imgPath = body.imagePath or ""
    if content ~= "" or imgPath ~= "" then
      -- Deduplicate: move selected item to the top of recent list
      pushRecent(contentType, content, imgPath ~= "" and imgPath or nil)

      -- Ensure focus is on the original window before pasting
      if previousWindow and previousWindow:isVisible() then
        previousWindow:focus()
      end
      -- Wait a moment for focus to settle, then paste
      hs.timer.doAfter(0.05, function()
        if contentType == "image" then
          -- For images: load full image from disk if available
          local img = nil
          if imgPath ~= "" then
            img = loadImageFromDisk(imgPath)
          end
          if not img and content ~= "" then
            -- Fallback: try loading from thumbnail/content
            img = hs.image.imageFromURL(content)
          end
          if img then
            hs.pasteboard.writeObjects(img)
            print("[OK] Image written to pasteboard, pasting...")
            hs.timer.doAfter(0.1, function()
              pasteWithCmdV()
            end)
          else
            print("[ERR] Failed to load image for pasting")
          end
        else
          hs.pasteboard.setContents(content)
          pasteWithCmdV()
        end
        -- Close panel after paste completes
        hs.timer.doAfter(0.2, function()
          closePanel()
        end)
      end)
    else
      closePanel()
    end
  elseif body.action == "close" then
    closePanel()
  elseif body.action == "debug" then
    print("[clipboard] DEBUG: " .. tostring(body.msg))
  elseif body.action == "expandForImage" then
    if panel then
      pcall(function()
        if not savedPanelFrame then
          savedPanelFrame = panel:frame()
        end
        local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
        local sf = screen:fullFrame()
        local margin = 0.05
        local w = math.floor(sf.w * (1 - 2 * margin))
        local h = math.floor(sf.h * (1 - 2 * margin))
        local x = sf.x + math.floor(sf.w * margin)
        local y = sf.y + math.floor(sf.h * margin)
        panel:topLeft({ x = x, y = y })
        panel:size({ w = w, h = h })
      end)
    end
  elseif body.action == "restorePanel" then
    if panel and savedPanelFrame then
      pcall(function()
        panel:topLeft({ x = savedPanelFrame.x, y = savedPanelFrame.y })
        panel:size({ w = savedPanelFrame.w, h = savedPanelFrame.h })
      end)
      savedPanelFrame = nil
    end
  elseif body.action == "loadFullImage" then
    local ok, err = pcall(function()
      local col = body.col or "recent"
      local index = body.index
      local list = (col == "pinned") and store.pinned or store.recent
      local item = (index and list[index + 1]) or nil
      local imgPath = item and item.imagePath or nil
      print(string.format("[clipboard] loadFullImage col=%s index=%s path=%s exists=%s",
        tostring(col), tostring(index), tostring(imgPath),
        tostring(imgPath and fileExists(imgPath))))
      if not (imgPath and fileExists(imgPath) and panel) then return end
      local f = io.open(imgPath, "rb")
      if not f then print("[clipboard] open failed"); return end
      local raw = f:read("*all"); f:close()
      print(string.format("[clipboard] read %d bytes", raw and #raw or 0))
      if not raw or #raw == 0 then return end
      local b64 = hs.base64.encode(raw)
      print(string.format("[clipboard] b64 len=%d", b64 and #b64 or 0))
      if not b64 or #b64 == 0 then return end
      local mime = imgPath:lower():match("%.jpe?g$") and "image/jpeg" or "image/png"
      local dataUrl = "data:" .. mime .. ";base64," .. b64
      local js = 'setFullImage("' .. dataUrl .. '");'
      print(string.format("[clipboard] sending JS, length=%d", #js))
      panel:evaluateJavaScript(js)
    end)
    if not ok then print("[clipboard] loadFullImage error: " .. tostring(err)) end
  elseif body.action == "editItem" then
    local col = body.col or "recent"
    local index = body.index
    local newContent = body.content or ""
    local list = (col == "pinned") and store.pinned or store.recent
    local luaIdx = (index and (index + 1)) or nil
    local found = luaIdx and list[luaIdx] or nil
    if found and found.type ~= "image" then
      found.content = newContent
      found.title = titleForContent(found.type or "text", newContent)
      found.ts = hs.timer.secondsSinceEpoch()
      if col == "recent" and luaIdx and luaIdx > 1 then
        table.remove(store.recent, luaIdx)
        table.insert(store.recent, 1, found)
      end
      local newIdx = (col == "recent") and 0 or (luaIdx - 1)
      if col == "pinned" then savePinned() else saveRecent() end
      if panel then
        local pinnedWeb = prepareItemsForWeb(store.pinned)
        local recentWeb = prepareItemsForWeb(store.recent)
        local js = string.format(
          "applyEditAndClose(%s,%s,%s,%d);",
          hs.json.encode(pinnedWeb), hs.json.encode(recentWeb), jsonScalar(col), newIdx)
        panel:evaluateJavaScript(js)
      end
    end
  elseif body.action == "addPinned" then
    local contentType = body.type or "text"
    local content = body.content or ""
    local title = body.title or titleForContent(contentType, content)
    local imgPath = body.imagePath or ""
    if addPinned(title, contentType, content, imgPath ~= "" and imgPath or nil) then
      if panel then
        local pinnedWeb = prepareItemsForWeb(store.pinned)
        local recentWeb = prepareItemsForWeb(store.recent)
        local js = string.format("updateData(%s,%s);", hs.json.encode(pinnedWeb), hs.json.encode(recentWeb))
        panel:evaluateJavaScript(js)
      end
    end
  elseif body.action == "deletePinned" then
    local index = body.index
    if index and deletePinned(index + 1) then
      if panel then
        local pinnedWeb = prepareItemsForWeb(store.pinned)
        local recentWeb = prepareItemsForWeb(store.recent)
        local js = string.format("updateData(%s,%s);", hs.json.encode(pinnedWeb), hs.json.encode(recentWeb))
        panel:evaluateJavaScript(js)
      end
    end
  elseif body.action == "reorderPinned" then
    local from = body.from
    local to = body.to
    if type(from) == "number" and type(to) == "number" then
      local fromIdx = from + 1
      local toIdx = to + 1
      local n = #store.pinned
      if fromIdx >= 1 and fromIdx <= n and toIdx >= 1 and toIdx <= n and fromIdx ~= toIdx then
        local item = table.remove(store.pinned, fromIdx)
        table.insert(store.pinned, toIdx, item)
        savePinned()
        hs.timer.doAfter(0, registerPinnedHotkeys)
      end
    end
  elseif body.action == "clearRecent" then
    -- Clean up disk images for all recent items
    for _, item in ipairs(store.recent) do
      if item.imagePath then
        os.remove(item.imagePath)
      end
    end
    store.recent = {}
    saveRecent()
    if panel then
      local pinnedWeb = prepareItemsForWeb(store.pinned)
      local recentWeb = prepareItemsForWeb(store.recent)
      local js = string.format("updateData(%s,%s);", hs.json.encode(pinnedWeb), hs.json.encode(recentWeb))
      panel:evaluateJavaScript(js)
    end
  elseif body.action == "assignHotkey" then
    local index = body.index  -- 0-based from JS
    -- Normalize mods: JS array may arrive as table; ensure it's a proper list of strings
    local rawMods = body.mods or {}
    local mods = {}
    if type(rawMods) == "table" then
      for _, m in pairs(rawMods) do table.insert(mods, tostring(m)) end
    end
    local key = tostring(body.key or "")

    if not index or key == "" then return end
    local luaIdx = index + 1
    if luaIdx < 1 or luaIdx > #store.pinned then return end

    -- Check against blocklist (macOS system + Hammerspoon hotkeys)
    local combo = makeHotkeyKey(mods, key)
    local reserved = getReservedHotkeys()
    -- Allow re-assigning the same item's own hotkey
    local currentHk = store.pinned[luaIdx].hotkey
    local selfKey = currentHk and makeHotkeyKey(currentHk.mods or {}, currentHk.key) or nil

    local conflict = reserved[combo]
    if conflict and combo ~= selfKey then
      -- Check if conflict is another pinned item — reassign instead of block
      local isPinnedConflict = false
      for i, item in ipairs(store.pinned) do
        if i ~= luaIdx and item.hotkey then
          if makeHotkeyKey(item.hotkey.mods or {}, item.hotkey.key) == combo then
            isPinnedConflict = true
            item.hotkey = nil  -- Remove from other pinned item
            break
          end
        end
      end
      if not isPinnedConflict then
        if panel then
          local errMsg = "Already used by: " .. tostring(conflict)
          panel:evaluateJavaScript(string.format('hotkeyResult(false,"%s");', errMsg:gsub('"', '\\"')))
        end
        return
      end
    end

    -- Assign the hotkey
    store.pinned[luaIdx].hotkey = { mods = mods, key = key }
    savePinned()

    -- Build display string and respond to JS FIRST (before hotkey binding)
    local display = ""
    for _, m in ipairs(mods) do
      display = display .. m:sub(1,1):upper() .. m:sub(2) .. "+"
    end
    display = display .. key:upper()
    if panel then
      panel:evaluateJavaScript(string.format('hotkeyResult(true,"%s");', display))
    end
    -- Defer hotkey registration out of WKWebView callback
    hs.timer.doAfter(0, registerPinnedHotkeys)
  elseif body.action == "removeHotkey" then
    local index = body.index  -- 0-based from JS
    if index then
      local luaIdx = index + 1
      if luaIdx >= 1 and luaIdx <= #store.pinned then
        store.pinned[luaIdx].hotkey = nil
        savePinned()
        if panel then
          local pinnedWeb = prepareItemsForWeb(store.pinned)
          local recentWeb = prepareItemsForWeb(store.recent)
          local js = string.format("updateData(%s,%s);", hs.json.encode(pinnedWeb), hs.json.encode(recentWeb))
          panel:evaluateJavaScript(js)
        end
        hs.timer.doAfter(0, registerPinnedHotkeys)
      end
    end
  elseif body.action == "enableTextEntry" then
    -- No-op, text entry always enabled
  elseif body.action == "disableTextEntry" then
    -- No-op, text entry always enabled
  elseif body.action == "setMaxRecent" then
    local v = tonumber(body.value)
    if v then
      v = math.floor(v)
      if v < MAX_RECENT_MIN then v = MAX_RECENT_MIN end
      if v > MAX_RECENT_MAX then v = MAX_RECENT_MAX end
      if v ~= maxRecent then
        maxRecent = v
        saveSettings()
        local trimmed = false
        while #store.recent > maxRecent do
          table.remove(store.recent)
          trimmed = true
        end
        if trimmed then
          saveRecent()
          if panel then
            local pinnedWeb = prepareItemsForWeb(store.pinned)
            local recentWeb = prepareItemsForWeb(store.recent)
            local js = string.format("updateData(%s,%s);", hs.json.encode(pinnedWeb), hs.json.encode(recentWeb))
            panel:evaluateJavaScript(js)
          end
        end
      end
    end
  end
end

------------------------------------------------------------
-- Panel
------------------------------------------------------------
local function openPanel()
  -- Load full clipboard history on first panel open (lazy loading)
  ensureFullyLoaded()

  -- Save the window in focus before opening the panel
  previousWindow = hs.window.focusedWindow()

  -- CRITICAL: hide dock icon before showing the panel
  -- Required for the panel to appear above Full Screen apps
  hs.dockicon.hide()
  hs.timer.usleep(50000)  -- 50ms

  local w, h = 760, 520
  local rect, screen, tl = computeSmartRect(w, h)

  -- Try to reuse existing panel
  local reusePanel = false
  if panel then
    local ok = pcall(function()
      -- Test if the panel is still valid
      panel:frame()
    end)
    if ok then
      reusePanel = true
    else
      -- Panel is stale, destroy and recreate
      destroyPanel()
    end
  end

  if reusePanel then
    -- Reuse: update data, reposition, show
    local pinnedWeb = prepareItemsForWeb(store.pinned)
    local recentWeb = prepareItemsForWeb(store.recent)
    local js = string.format("updateData(%s,%s);", hs.json.encode(pinnedWeb), hs.json.encode(recentWeb))
    panel:evaluateJavaScript(js)
    panel:topLeft({ x = tl.x, y = tl.y })
    panel:size({ w = w, h = h })
    panel:show()
    elevatePanel(panel)
  else
    -- Create new panel
    panelUCC = hs.webview.usercontent.new("clips")
    panelUCC:setCallback(handleWebMessage)

    panel = hs.webview.new(rect, panelUCC)
             :windowStyle({"borderless"})
             :allowTextEntry(true)
             :allowNewWindows(false)
             :shadow(true)

    panel:html(buildHTML())
    panel:topLeft({ x = tl.x, y = tl.y })
    panel:show()
    elevatePanel(panel)
  end

  -- Double-check position after elevation
  hs.timer.doAfter(0.01, function()
    if panel then
      pcall(function()
        panel:topLeft({ x = tl.x, y = tl.y })
        panel:bringToFront(true)
      end)
    end
  end)

  -- Key watcher for CMD+W close
  hs.timer.doAfter(0.05, function()
    if not panel then return end

    if keyWatcher then keyWatcher:stop(); keyWatcher = nil end
    keyWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
      if not panel then
        if keyWatcher then keyWatcher:stop(); keyWatcher = nil end
        return false
      end

      local keyCode = event:getKeyCode()
      local key = hs.keycodes.map[keyCode]
      local flags = event:getFlags()

      if flags.cmd and key == "w" then
        closePanel()
        return true
      end

      return false
    end)
    keyWatcher:start()
  end)

  -- Click-outside-to-close watcher
  hs.timer.doAfter(0.1, function()
    if not panel then return end

    if clickWatcher then clickWatcher:stop(); clickWatcher = nil end
    clickWatcher = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(event)
      if not panel then
        if clickWatcher then clickWatcher:stop(); clickWatcher = nil end
        return false
      end

      local mousePos = hs.mouse.absolutePosition()
      local ok, panelFrame = pcall(function() return panel:frame() end)
      if not ok then return false end

      if mousePos.x < panelFrame.x or mousePos.x > panelFrame.x + panelFrame.w or
         mousePos.y < panelFrame.y or mousePos.y > panelFrame.y + panelFrame.h then
        closePanel()
        return false
      end

      return false
    end)
    clickWatcher:start()
  end)
end

------------------------------------------------------------
-- Clipboard watcher with polling (supports both text and images)
------------------------------------------------------------
local function readAndStoreClipboard()
  local types = hs.pasteboard.typesAvailable()

  -- Check for images first (higher priority)
  if types and types.image then
    local img = hs.pasteboard.readImage()
    if img then
      local size = img:size()
      local sizeKey = tostring(size.w) .. "x" .. tostring(size.h)

      if lastClipboardType ~= "image" or lastClipboardContent ~= sizeKey then
        local encoded = img:encodeAsURLString()
        lastClipboardContent = sizeKey
        lastClipboardType = "image"
        pushRecent("image", encoded)
      end
    end
  else
    local text = hs.pasteboard.getContents()
    if text and type(text) == "string" and text ~= "" then
      if text ~= lastClipboardContent or lastClipboardType ~= "text" then
        lastClipboardContent = text
        lastClipboardType = "text"
        pushRecent("text", text)
      end
    end
  end
end

local function startWatcher()
  if watcher then watcher:stop() end

  lastChangeCount = hs.pasteboard.changeCount()

  -- Poll clipboard every 0.8 seconds, but only read when changeCount changes
  watcher = hs.timer.doEvery(0.8, function()
    local cc = hs.pasteboard.changeCount()
    if cc == lastChangeCount then return end
    lastChangeCount = cc
    readAndStoreClipboard()
  end)

  print("[OK] Clipboard watcher started (polling every 0.8s)")
end

------------------------------------------------------------
-- Paste by index: Ctrl+1-9 for direct paste from recent history
------------------------------------------------------------
local function pasteByIndex(index)
  -- Ensure clipboard history is loaded
  ensureFullyLoaded()

  -- Check if index is valid
  if index < 1 or index > #store.recent then
    hs.alert.show("No clipboard item at position " .. index)
    return
  end

  local item = store.recent[index]
  local contentType = item.type or "text"
  local content = item.content or ""
  local imgPath = item.imagePath

  if content == "" and not imgPath then
    hs.alert.show("Clipboard item is empty")
    return
  end

  -- Wait a moment for focus to settle, then paste
  hs.timer.doAfter(0.05, function()
    if contentType == "image" then
      -- For images: load full image from disk if available
      local img = nil
      if imgPath then
        img = loadImageFromDisk(imgPath)
      end
      if not img and content ~= "" then
        img = hs.image.imageFromURL(content)
      end
      if img then
        local size = img:size()
        local sizeKey = tostring(size.w) .. "x" .. tostring(size.h)
        lastClipboardContent = sizeKey
        lastClipboardType = "image"

        hs.pasteboard.writeObjects(img)
        hs.timer.doAfter(0.1, function()
          pasteWithCmdV()
        end)
      else
        hs.alert.show("Failed to load image")
      end
    else
      lastClipboardContent = content
      lastClipboardType = "text"

      hs.pasteboard.setContents(content)
      pasteWithCmdV()
    end
  end)
end

------------------------------------------------------------
-- Extra hotkey: pin current clipboard (alt+shift+Z)
------------------------------------------------------------
local function addPinnedFromClipboard()
  local types = hs.pasteboard.typesAvailable()
  local contentType, content, title, imgPath

  if types and types.image then
    local img = hs.pasteboard.readImage()
    if img then
      contentType = "image"
      local encoded = img:encodeAsURLString()
      -- Save to disk and get thumbnail
      imgPath = saveImageToDisk(encoded)
      content = generateThumbnail(img) or ""
      title = titleForContent("image", content)
    else
      hs.alert.show("Failed to read image from clipboard")
      return
    end
  else
    local text = hs.pasteboard.getContents() or ""
    if text == "" then hs.alert.show("Clipboard is empty"); return end
    contentType = "text"
    content = text
    title = titleForContent("text", text)
  end

  local ok, dlg = pcall(function()
    return hs.dialog.textPrompt("Add Pinned", "Title for this snippet:", title, "Save", "Cancel")
  end)
  if ok and dlg and dlg.text and dlg.button == "Save" then
    title = dlg.text
  end
  if addPinned(title, contentType, content, imgPath) then
    hs.alert.show("Pinned: " .. title)
  else
    hs.alert.show("Failed to pin")
  end
end

------------------------------------------------------------
-- API
------------------------------------------------------------
function M.start(hotkeyManager)
  hotkeyManagerRef = hotkeyManager
  loadStore()
  registerPinnedHotkeys()
  startWatcher()

  local mods, key = {"alt"}, "Z"
  if hotkeyManager and hotkeyManager.getConfig then
    local ok, cfg = pcall(hotkeyManager.getConfig)
    if ok and cfg and cfg.clipboardManager then
      mods = cfg.clipboardManager.mods or mods
      key  = cfg.clipboardManager.key  or key
    end
  end

  hs.hotkey.bind(mods, key, function()
    if hotkeyManager then hotkeyManager.incrementUsage('clipboardManager') end
    openPanel()
  end)
  -- Add-to-pinned uses the same key with Shift added on top of the configured mods.
  local addMods = { "shift" }
  for _, m in ipairs(mods) do if m ~= "shift" then table.insert(addMods, m) end end
  hs.hotkey.bind(addMods, key, addPinnedFromClipboard)

  -- Bind Ctrl+1 through Ctrl+9 for direct paste
  for i = 1, 9 do
    hs.hotkey.bind({"ctrl"}, tostring(i), function()
      pasteByIndex(i)
    end)
  end
end

-- Manually check clipboard for new content (called by screenshot capture)
function M.checkClipboard()
  local types = hs.pasteboard.typesAvailable()

  if types and types.image then
    local img = hs.pasteboard.readImage()
    if img then
      local size = img:size()
      local sizeKey = tostring(size.w) .. "x" .. tostring(size.h)

      local ok, encoded = pcall(function()
        return img:encodeAsURLString()
      end)

      if ok and encoded then
        if lastClipboardType ~= "image" or lastClipboardContent ~= sizeKey then
          print("[OK] New image added to clipboard history: " .. sizeKey)
          lastClipboardContent = sizeKey
          lastClipboardType = "image"
          pushRecent("image", encoded)
          return true
        end
      else
        print("[ERR] Failed to encode image")
      end
    end
  else
    local text = hs.pasteboard.getContents()
    if text and type(text) == "string" and text ~= "" then
      if text ~= lastClipboardContent or lastClipboardType ~= "text" then
        lastClipboardContent = text
        lastClipboardType = "text"
        pushRecent("text", text)
        return true
      end
    end
  end

  return false
end

return M
