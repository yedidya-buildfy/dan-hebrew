-- Hotkey manager: stores user-configurable shortcuts for the two features
-- (language converter + clipboard manager) and exposes a small UI to edit them.
local M = {}

local configPath     = os.getenv("HOME") .. "/.hammerspoon/hotkeys.json"
local usageStatsPath = os.getenv("HOME") .. "/.hammerspoon/hotkey_usage.json"
local managerPanel   = nil
local clickWatcher   = nil

local defaultConfig = {
  convertLanguage  = { mods = {"cmd","alt"}, key = "K" },
  clipboardManager = { mods = {"cmd","alt"}, key = "V" },
}

local function loadConfig()
  local config = {}
  for k, v in pairs(defaultConfig) do
    config[k] = { mods = {}, key = v.key }
    for _, m in ipairs(v.mods) do table.insert(config[k].mods, m) end
  end
  local f = io.open(configPath, "r")
  if f then
    local data = f:read("*a"); f:close()
    local ok, parsed = pcall(hs.json.decode, data)
    if ok and type(parsed) == "table" then
      for k, v in pairs(parsed) do
        if config[k] then config[k] = v end
      end
    end
  end
  return config
end

local function saveConfig(config)
  local f = io.open(configPath, "w")
  if f then f:write(hs.json.encode(config, true)); f:close() end
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function loadUsageStats()
  if fileExists(usageStatsPath) then
    local f = io.open(usageStatsPath, "r")
    local data = f:read("*a"); f:close()
    local ok, parsed = pcall(hs.json.decode, data)
    if ok and type(parsed) == "table" then return parsed end
  end
  return { convertLanguage = 0, clipboardManager = 0 }
end

local function saveUsageStats(stats)
  local f = io.open(usageStatsPath, "w")
  if f then f:write(hs.json.encode(stats, true)); f:close() end
end

function M.incrementUsage(name)
  local stats = loadUsageStats()
  stats[name] = (stats[name] or 0) + 1
  saveUsageStats(stats)
end

function M.getUsageStats()    return loadUsageStats() end
function M.resetUsageStats()  saveUsageStats({ convertLanguage = 0, clipboardManager = 0 }) end
function M.getConfig()        return loadConfig() end

local function buildManagerHTML(config, usage)
  return string.format([==[
<!doctype html>
<html><head><meta charset="utf-8">
<style>
html,body{margin:0;padding:0;font-family:-apple-system,Helvetica,Arial;background:#111;color:#eee;border-radius:12px;overflow:hidden;direction:rtl}
.container{padding:14px}
h2{color:#4a9eff;margin:0 0 12px 0;font-size:16px;font-weight:600;text-align:right}
.row{background:#1c1c1c;padding:12px;margin:8px 0;border-radius:8px;border:1px solid #333;display:grid;grid-template-columns:160px 1fr auto;gap:12px;align-items:center}
.title{font-weight:600;font-size:13px;text-align:right}
.controls{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.controls label{font-size:11px;white-space:nowrap}
input[type="text"]{background:#111;color:#eee;border:1px solid #333;padding:5px 7px;border-radius:6px;width:42px;text-align:center;font-size:12px}
input:focus{border-color:#4a9eff;outline:none}
.checkbox{transform:scale(0.9)}
.buttons{display:flex;gap:8px;margin-top:14px}
button{background:#333;color:#eee;border:none;padding:8px 14px;border-radius:6px;cursor:pointer;font-size:12px;flex:1}
button:hover{background:#444}
button.primary{background:#4a9eff}
button.primary:hover{background:#3a8eef}
.status{padding:10px;margin:8px 0;border-radius:6px;display:none;font-size:12px}
.status.success{background:#2d5}
.status.error{background:#d52}
.usage{background:#333;color:#4a9eff;padding:4px 9px;border-radius:5px;font-size:11px;font-weight:600}
</style></head><body>
<div class="container">
<h2>⌨️ ניהול קיצורי מקלדת</h2>
<div id="status" class="status"></div>

<div class="row">
  <div class="title">המרת שפה (EN ⇄ HE):</div>
  <div class="controls">
    <label><input type="checkbox" class="checkbox" id="cmd_convert"> ⌘ Cmd</label>
    <label><input type="checkbox" class="checkbox" id="alt_convert"> ⌥ Opt</label>
    <label><input type="checkbox" class="checkbox" id="ctrl_convert"> ⌃ Ctrl</label>
    <label><input type="checkbox" class="checkbox" id="shift_convert"> ⇧ Shift</label>
    <input type="text" id="key_convert" maxlength="1" placeholder="K">
  </div>
  <span class="usage" id="usage_convert">0×</span>
</div>

<div class="row">
  <div class="title">מנהל Clipboard:</div>
  <div class="controls">
    <label><input type="checkbox" class="checkbox" id="cmd_clip"> ⌘ Cmd</label>
    <label><input type="checkbox" class="checkbox" id="alt_clip"> ⌥ Opt</label>
    <label><input type="checkbox" class="checkbox" id="ctrl_clip"> ⌃ Ctrl</label>
    <label><input type="checkbox" class="checkbox" id="shift_clip"> ⇧ Shift</label>
    <input type="text" id="key_clip" maxlength="1" placeholder="V">
  </div>
  <span class="usage" id="usage_clip">0×</span>
</div>

<div class="buttons">
  <button class="primary" onclick="saveHotkeys()">💾 שמור</button>
  <button onclick="resetToDefaults()">🔄 ברירת מחדל</button>
  <button onclick="resetStats()">📊 אפס מונים</button>
  <button onclick="closeManager()">✕ סגור</button>
</div>
</div>

<script>
const config = %s;
const usage = %s;

function loadCurrent() {
  for (const [prefix, key] of [['convert','convertLanguage'],['clip','clipboardManager']]) {
    document.getElementById('cmd_'+prefix).checked   = config[key].mods.includes('cmd');
    document.getElementById('alt_'+prefix).checked   = config[key].mods.includes('alt');
    document.getElementById('ctrl_'+prefix).checked  = config[key].mods.includes('ctrl');
    document.getElementById('shift_'+prefix).checked = config[key].mods.includes('shift');
    document.getElementById('key_'+prefix).value     = config[key].key;
  }
  document.getElementById('usage_convert').textContent = (usage.convertLanguage  || 0) + '×';
  document.getElementById('usage_clip').textContent    = (usage.clipboardManager || 0) + '×';
}

function getMods(prefix) {
  const m = [];
  if (document.getElementById('cmd_'+prefix).checked)   m.push('cmd');
  if (document.getElementById('alt_'+prefix).checked)   m.push('alt');
  if (document.getElementById('ctrl_'+prefix).checked)  m.push('ctrl');
  if (document.getElementById('shift_'+prefix).checked) m.push('shift');
  return m;
}

function saveHotkeys() {
  const newConfig = {
    convertLanguage:  { mods: getMods('convert'), key: (document.getElementById('key_convert').value||'K').toUpperCase() },
    clipboardManager: { mods: getMods('clip'),    key: (document.getElementById('key_clip').value||'V').toUpperCase() },
  };
  try {
    window.webkit.messageHandlers.hotkeyManager.postMessage({ action:'save', config:newConfig });
    showStatus('✓ נשמר. טוען מחדש…', 'success');
  } catch(e) { showStatus('✗ שגיאה בשמירה', 'error'); }
}

function resetToDefaults() {
  try {
    window.webkit.messageHandlers.hotkeyManager.postMessage({ action:'reset' });
    showStatus('✓ אופס לברירת מחדל. טוען מחדש…', 'success');
  } catch(e) {}
}

function resetStats() {
  try {
    window.webkit.messageHandlers.hotkeyManager.postMessage({ action:'resetStats' });
    showStatus('✓ מונים אופסו', 'success');
    document.getElementById('usage_convert').textContent = '0×';
    document.getElementById('usage_clip').textContent    = '0×';
  } catch(e) { showStatus('✗ שגיאה', 'error'); }
}

function closeManager() {
  try { window.webkit.messageHandlers.hotkeyManager.postMessage({ action:'close' }); } catch(e) {}
}

function showStatus(msg, type) {
  const s = document.getElementById('status');
  s.textContent = msg; s.className = 'status ' + type; s.style.display = 'block';
  setTimeout(() => s.style.display = 'none', 3000);
}

window.addEventListener('load', loadCurrent);
</script></body></html>
]==], hs.json.encode(config), hs.json.encode(usage))
end

local function computeSmartRect(w, h)
  local mouseAbs = hs.mouse.absolutePosition() or hs.mouse.getAbsolutePosition()
  local screen   = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local sf = screen:fullFrame()
  local margin, offset = 8, 16
  local x, y = mouseAbs.x + offset, mouseAbs.y + offset
  if x + w > sf.x + sf.w - margin then x = mouseAbs.x - w - offset end
  if y + h > sf.y + sf.h - margin then y = mouseAbs.y - h - offset end
  if x < sf.x + margin then x = sf.x + margin end
  if y < sf.y + margin then y = sf.y + margin end
  if x + w > sf.x + sf.w - margin then x = sf.x + sf.w - w - margin end
  if y + h > sf.y + sf.h - margin then y = sf.y + sf.h - h - margin end
  return hs.geometry.rect(x, y, w, h), screen, { x = x, y = y }
end

local function elevatePanel(p)
  if hs.webview and hs.webview.windowBehaviors then
    pcall(function()
      local b = hs.webview.windowBehaviors
      if b.canJoinAllSpaces and b.fullScreenAuxiliary then
        p:behavior(b.canJoinAllSpaces + b.fullScreenAuxiliary)
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

local function closePanel()
  if managerPanel then managerPanel:delete(); managerPanel = nil end
  if clickWatcher then clickWatcher:stop(); clickWatcher = nil end
  hs.dockicon.show()
end

function M.openManager()
  if managerPanel then closePanel() end
  hs.dockicon.hide()
  hs.timer.usleep(50000)

  local w, h = 620, 280
  local rect, _, tl = computeSmartRect(w, h)

  local ucc = hs.webview.usercontent.new("hotkeyManager")
  ucc:setCallback(function(msg)
    if not msg or not msg.body then return end
    if msg.body.action == "save" then
      saveConfig(msg.body.config)
      closePanel()
      hs.alert.show("♻️ Reloading…")
      hs.timer.doAfter(0.5, function() hs.reload() end)
    elseif msg.body.action == "reset" then
      saveConfig(defaultConfig)
      closePanel()
      hs.alert.show("♻️ Reset. Reloading…")
      hs.timer.doAfter(0.5, function() hs.reload() end)
    elseif msg.body.action == "resetStats" then
      M.resetUsageStats()
      if managerPanel then
        managerPanel:html(buildManagerHTML(loadConfig(), loadUsageStats()))
      end
    elseif msg.body.action == "close" then
      closePanel()
    end
  end)

  managerPanel = hs.webview.new(rect, ucc)
                          :windowStyle({"borderless"})
                          :allowTextEntry(true)
                          :shadow(true)
  managerPanel:html(buildManagerHTML(loadConfig(), loadUsageStats()))
  managerPanel:topLeft({ x = tl.x, y = tl.y })
  managerPanel:show()
  elevatePanel(managerPanel)

  hs.timer.doAfter(0.01, function()
    if managerPanel then
      managerPanel:topLeft({ x = tl.x, y = tl.y })
      managerPanel:bringToFront(true)
    end
  end)

  hs.timer.doAfter(0.1, function()
    if not managerPanel then return end
    clickWatcher = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
      if not managerPanel then
        if clickWatcher then clickWatcher:stop(); clickWatcher = nil end
        return false
      end
      local p  = hs.mouse.absolutePosition()
      local fr = managerPanel:frame()
      if p.x < fr.x or p.x > fr.x + fr.w or p.y < fr.y or p.y > fr.y + fr.h then
        closePanel()
      end
      return false
    end)
    clickWatcher:start()
  end)
end

return M
