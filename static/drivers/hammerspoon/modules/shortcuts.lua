-- Shortcuts: selection transforms, screenshot, search
local timer = hs.timer
local eventtap = hs.eventtap
local pasteboard = hs.pasteboard
local http = hs.http
local urlevent = hs.urlevent
local utils = require("lib.utils")

-- Helpers
local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function is_probable_url(s)
    local x = trim(s)
    if x:match('^https?://') then return x end
    if x:match('^www%.') or (x:match('%.%a%a') and not x:match('%s')) then return 'http://' .. x end
    return nil
end

local function titlecase(s)
    s = s:lower()
    s = s:gsub("(%S+)", function(word)
        return word:sub(1,1):upper() .. word:sub(2)
    end)
    return s
end

-- Asynchronous function for text transformations
local function do_transform(transform_func)
    local prior = pasteboard.getContents()
    pasteboard.clearContents()

    eventtap.keyStroke({"cmd"}, "c")

    timer.doAfter(0.2, function()
        local sel = pasteboard.getContents()

        if not sel or sel == "" then
            if prior then pasteboard.setContents(prior) end
            return
        end

        local transformed = transform_func(sel)
        if not transformed then
            if prior then pasteboard.setContents(prior) end
            return
        end

        pasteboard.setContents(transformed)

        timer.doAfter(0.08, function()
            -- paste the transformed text
            eventtap.keyStroke({"cmd"}, "v", 0.02)

            -- shortly after pasting, re-select the inserted text so
            -- repeated transforms don't require re-selection
            timer.doAfter(0.08, function()
                local ok, ulen = pcall(function() return utf8.len(transformed) end)
                local n
                if ok and ulen and ulen > 0 then
                    n = ulen
                else
                    n = #transformed
                end

                -- safety cap to avoid extremely long loops
                local MAX = 5000
                if n > MAX then n = MAX end

                if n > 0 then
                    -- move caret left `n` times to reach the start
                    for i = 1, n do
                        eventtap.keyStroke({}, "left", 0.001)
                    end
                    -- then select right `n` times to reselect the pasted text
                    for i = 1, n do
                        eventtap.keyStroke({"shift"}, "right", 0.001)
                    end
                end

                -- restore prior clipboard shortly after
                timer.doAfter(0.15, function()
                    if prior and prior ~= "" then
                        pasteboard.setContents(prior)
                    else
                        pasteboard.clearContents()
                    end
                end)
            end)
        end)
    end)
end

-- get_selection_path removed: simplified approach uses Cmd+Option+C for Finder-like apps

-- Center an application's visible standard windows
local function center_windows_of_app(app)
    if not app then return end
    local wins = app:allWindows()
    for _, w in ipairs(wins) do
        if w:isStandard() and w:isVisible() then
            local screen = w:screen()
            if screen then
                local sf = screen:frame()
                local wf = w:frame()
                local nx = sf.x + math.floor((sf.w - wf.w) / 2)
                local ny = sf.y + math.floor((sf.h - wf.h) / 2)
                w:setFrame({x = nx, y = ny, w = wf.w, h = wf.h})
            end
        end
    end
end

local function center_frontmost_after(delay)
    timer.doAfter(delay or 0.2, function()
        local f = hs.application.frontmostApplication()
        if f then center_windows_of_app(f) end
    end)
end

-- List of Finder-like file managers and helper to detect them (supports variants like "qspace pro")
local fm_list = {"finder", "qspace", "path finder", "forklift", "commander one", "totalfinder", "xtrafinder"}

local function is_finder_like(appname)
    if not appname then return false end
    local ln = appname:lower()
    for _, v in ipairs(fm_list) do
        if ln:find(v, 1, true) then return true end
    end
    return false
end

-- Prioritized list of apps to try for `Ctrl+E` (Qspace first).
local fm_candidates = {"Qspace", "QSpace", "qspace", "Path Finder", "Forklift", "Commander One", "TotalFinder", "XtraFinder"}

local function launch_first_available(apps)
    for _, name in ipairs(apps) do
        local lname = name:lower()
        -- try to focus a running app whose name contains the candidate
            for _, a in ipairs(hs.application.runningApplications()) do
                local an = a:name()
                if an and an:lower():find(lname, 1, true) then
                    a:activate()
                    utils.notify("Opened: " .. an)
                    return true
                end
            end
            -- try to launch/focus by exact name
            if hs.application.launchOrFocus(name) then
                utils.notify("Opened: " .. name)
                return true
            end
    end
    return false
end

--------------------------------------------------------------------------------
 --------------------------------------------------------------------------------
 -- HOTKEYS (sorted alphabetically)
 --------------------------------------------------------------------------------
 -- API: `M.start()` enables hotkeys, `M.stop()` disables them.
 -- Handlers use `hs.eventtap` to copy/paste the selection
 -- and `hs.pasteboard` to preserve/restore the clipboard.
local M = {}
local hotkeys = {}
local hotkey_defs = {}
local hotkey_labels = {}
local started = false
local awake_timer    = nil
local awake_alert_id = nil
local awake_active   = false

-- Read chatgpt_url from config.json (falls back to default if missing/invalid)
local function read_chatgpt_url()
    local cfg_path = hs.configdir .. "/config.json"
    local fh = io.open(cfg_path, "r")
    if not fh then return "https://chat.openai.com" end
    local content = fh:read("*a"); fh:close()
    local ok, tbl = pcall(function() return hs.json.decode(content) end)
    if ok and type(tbl) == "table" and type(tbl.chatgpt_url) == "string" and tbl.chatgpt_url ~= "" then
        return tbl.chatgpt_url
    end
    return "https://chat.openai.com"
end

-- Read hex color (#rrggbb) of the pixel at the given screen position.
-- Captures a 3×3 region and samples the center pixel with Python3.
local function pixel_hex_at(x, y)
    local tmpfile = "/tmp/_hs_pixel_cap.png"
    local cap_cmd = string.format('screencapture -x -R "%d,%d,3,3" "%s"', x - 1, y - 1, tmpfile)
    hs.execute(cap_cmd)
    local py = string.format([[
python3 -c "
import struct,zlib
data=open('%s','rb').read()
w,h=struct.unpack('>II',data[16:24])
ct=data[25];bpp=4 if ct==6 else 3
i,chunks=8,b''
while i<len(data)-12:
  l=struct.unpack('>I',data[i:i+4])[0];t=data[i+4:i+8]
  if t==b'IDAT':chunks+=data[i+8:i+8+l]
  elif t==b'IEND':break
  i+=l+12
raw=zlib.decompress(chunks)
cx=w//2;cy=h//2;off=cy*(1+w*bpp)+1+cx*bpp
r,g,b=raw[off],raw[off+1],raw[off+2]
print('#%%02x%%02x%%02x' %% (r,g,b))
"]], tmpfile)
    local out = hs.execute(py)
    if out then
        local hex = out:match("(#%x%x%x%x%x%x)")
        if hex then return hex end
    end
    return nil
end

-- Hotkey definitions (create and return the hotkey object when called)
hotkey_labels.at_hash = "Capture d'écran instantanée"
hotkey_defs.at_hash = function()
    local tap
    local obj = {}
    tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
        if e:getKeyCode() == 10 then
            local flags = e:getFlags()
            if flags.cmd or flags.alt or flags.ctrl or flags.shift then
                return false
            end
            local w = hs.window.frontmostWindow()
            if not w then
                utils.notify("Aucune fenêtre active")
                return true
            end
            local id = w:id()
            local home = os.getenv("HOME") or "~"
            local dir = home .. "/Pictures/screenshots"
            hs.execute('mkdir -p "' .. dir .. '"')
            local filename = string.format('%s/screenshot_%s.png', dir, os.date('%Y_%m_%d_%H_%M_%S'))
            local cmd = 'screencapture -l ' .. id .. ' "' .. filename .. '"'
            hs.execute(cmd)
            utils.notify("Saved: " .. filename)
            return true
        end
        return false
    end)
    tap:start()
    function obj:delete()
        if tap then
            tap:stop()
            tap = nil
        end
    end
    return obj
end

hotkey_labels.ctrl_a = "Sélectionner la ligne (Ctrl+A)"
hotkey_defs.ctrl_a = function()
    return hs.hotkey.bind({"ctrl"}, "a", function()
        eventtap.keyStroke({"cmd"}, "left")
        eventtap.keyStroke({"cmd", "shift"}, "right")
    end)
end

hotkey_labels.ctrl_d = "Ouvrir Téléchargements (Ctrl+D)"
hotkey_defs.ctrl_d = function()
    return hs.hotkey.bind({"ctrl"}, "d", function()
        local home = os.getenv("HOME") or "~"
        -- try to bring a preferred file manager forward, then open Downloads
        if not launch_first_available(fm_candidates) then
            -- still open Downloads with system opener
            hs.execute('open "' .. home .. '/Downloads"')
        else
            -- allow the file manager to appear then open Downloads
            timer.doAfter(0.12, function()
                hs.execute('open "' .. home .. '/Downloads"')
            end)
        end
        center_frontmost_after(0.3)
    end)
end

hotkey_labels.ctrl_e = "Ouvrir Finder (Ctrl+E)"
hotkey_defs.ctrl_e = function()
    return hs.hotkey.bind({"ctrl"}, "e", function()
        local home = os.getenv("HOME") or "~"
        -- try to bring a preferred file manager forward, then open Downloads
        if not launch_first_available(fm_candidates) then
            -- still open Downloads with system opener
            hs.execute('open "' .. home .. '/Downloads"')   
        else
            -- allow the file manager to appear then open Downloads
            timer.doAfter(0.12, function()
                hs.execute('open "' .. home .. '"')
            end)
        end
        center_frontmost_after(0.3)
    end)
end

hotkey_labels.ctrl_h = "Capture interactive vers presse-papiers (Ctrl+H)"
hotkey_defs.ctrl_h = function()
    return hs.hotkey.bind({"ctrl"}, "h", function()
        -- interactive capture, saved to clipboard (-c)
        local cmd = 'screencapture -i -c'
        hs.execute(cmd)
        utils.notify("Capture d’écran copiée dans le presse-papiers")
    end)
end

hotkey_labels.ctrl_i = "Ouvrir Réglages (Ctrl+I)"
hotkey_defs.ctrl_i = function()
    return hs.hotkey.bind({"ctrl"}, "i", function()
        if not hs.application.launchOrFocus("System Settings") then
            hs.application.launchOrFocus("System Preferences")
        end
        center_frontmost_after(0.3)
    end)
end

hotkey_labels.ctrl_s = "Ouvrir / Copier chemin (Ctrl+S)"
hotkey_defs.ctrl_s = function()
    return hs.hotkey.bind({"ctrl"}, "s", function()
        local front = hs.application.frontmostApplication()
        local name = front and front:name() or ""

        -- If front app looks like a Finder-like file manager, always send Cmd+Alt+C to copy path
        if is_finder_like(name) then
            eventtap.keyStroke({"cmd", "alt"}, "c")
            timer.doAfter(0.15, function()
                local p = pasteboard.getContents()
                if p and p ~= "" then
                    utils.notify("Chemin copié : " .. p)
                    return
                end
                -- fallback: copy the selection and perform a search
                local prior = pasteboard.getContents()
                pasteboard.clearContents()
                eventtap.keyStroke({"cmd"}, "c")
                timer.doAfter(0.2, function()
                    local sel = pasteboard.getContents()
                    if prior then
                        pasteboard.setContents(prior)
                    else
                        pasteboard.clearContents()
                    end
                    if not sel or sel == "" then return end
                    local trimmed = trim(sel)
                    local url = is_probable_url(trimmed)
                    if url then
                        urlevent.openURL(url)
                    else
                        local q = http.encodeForQuery(trimmed)
                        local search = 'https://www.google.com/search?q=' .. q
                        urlevent.openURL(search)
                    end
                end)
            end)
            return
        end

        -- Default: copy the selection and open search/URL
        local prior = pasteboard.getContents()
        pasteboard.clearContents()
        eventtap.keyStroke({"cmd"}, "c")
        timer.doAfter(0.2, function()
            local sel = pasteboard.getContents()
            if prior then
                pasteboard.setContents(prior)
            else
                pasteboard.clearContents()
            end
            if not sel or sel == "" then return end
            local trimmed = trim(sel)
            local url = is_probable_url(trimmed)
            if url then
                urlevent.openURL(url)
            else
                local q = http.encodeForQuery(trimmed)
                local search = 'https://www.google.com/search?q=' .. q
                urlevent.openURL(search)
            end
        end)
    end)
end

hotkey_labels.ctrl_t = "Casse de titre / minuscules (Ctrl+T)"
hotkey_defs.ctrl_t = function()
    return hs.hotkey.bind({"ctrl"}, "t", function()
        do_transform(function(sel)
            local t = titlecase(sel)
            return (sel == t) and sel:lower() or t
        end)
    end)
end

hotkey_labels.ctrl_u = "Majuscules / minuscules (Ctrl+U)"
hotkey_defs.ctrl_u = function()
    return hs.hotkey.bind({"ctrl"}, "u", function()
        do_transform(function(sel)
            local has_lower = sel:match("%l") ~= nil
            return has_lower and sel:upper() or sel:lower()
        end)
    end)
end

hotkey_labels.ctrl_g = "Ouvrir ChatGPT (Ctrl+G)"
hotkey_defs.ctrl_g = function()
    return hs.hotkey.bind({"ctrl"}, "g", function()
        local url = read_chatgpt_url()
        urlevent.openURL(url)
    end)
end

-- Schedule the next keep-awake tick after a random delay between 1 s and 5 s.
local function schedule_awake_tick()
    if not awake_active then return end
    local interval = math.random(1, 5)  -- seconds
    awake_timer = timer.doAfter(interval, function()
        if not awake_active then return end
        -- Gently jitter the mouse by 1 px then restore (no visible movement)
        local pos = hs.mouse.absolutePosition()
        local dx = (math.random(0, 1) == 0) and 1 or -1
        hs.mouse.absolutePosition({x = pos.x + dx, y = pos.y})
        timer.doAfter(0.05, function()
            hs.mouse.absolutePosition(pos)
        end)
        -- Send a harmless F18 keystroke (unmapped on macOS, keeps Teams green)
        eventtap.keyStroke({}, "f18", 0)
        -- Schedule the next tick recursively
        schedule_awake_tick()
    end)
end

hotkey_labels.ctrl_m = "Anti-veille (Ctrl+M)"
hotkey_defs.ctrl_m = function()
    return hs.hotkey.bind({"ctrl"}, "m", function()
        if awake_active then
            -- Second press: disable keep-awake
            awake_active = false
            if awake_timer then awake_timer:stop(); awake_timer = nil end
            if awake_alert_id then
                hs.alert.closeSpecific(awake_alert_id)
                awake_alert_id = nil
            end
            hs.alert.show("☕ Keep-awake désactivé", 2)
        else
            -- First press: enable keep-awake
            awake_active = true
            math.randomseed(os.time())
            -- Persistent on-screen banner for as long as keep-awake is active
            awake_alert_id = hs.alert.show(
                "☕ Keep-awake actif — Ctrl+M pour désactiver",
                math.huge
            )
            schedule_awake_tick()
        end
    end)
end

hotkey_labels.ctrl_x = "Copier couleur hex du pixel sous le curseur (Ctrl+X)"
hotkey_defs.ctrl_x = function()
    return hs.hotkey.bind({"ctrl"}, "x", function()
        local pos = hs.mouse.absolutePosition()
        local hex = pixel_hex_at(math.floor(pos.x), math.floor(pos.y))
        if not hex then
            utils.notify("Impossible de lire la couleur du pixel")
            return
        end
        pasteboard.setContents(hex)
        utils.notify("Couleur copiée : " .. hex)
    end)
end

hotkey_labels.ctrl_o = "Entourer la ligne de parenthèses (Ctrl+O)"
hotkey_defs.ctrl_o = function()
    return hs.hotkey.bind({"ctrl"}, "o", function()
        -- Move to start of line, insert '(', move to end, insert ')'
        -- hs.eventtap.keyStrokes inserts literal characters regardless of layout
        eventtap.keyStroke({"cmd"}, "left")
        hs.eventtap.keyStrokes("(")
        timer.doAfter(0.04, function()
            eventtap.keyStroke({"cmd"}, "right")
            hs.eventtap.keyStrokes(")")
        end)
    end)
end

hotkey_labels.ctrl_w = "Sélectionner le mot courant (Ctrl+W)"
hotkey_defs.ctrl_w = function()
    return hs.hotkey.bind({"ctrl"}, "w", function()
        -- Move to end of current/next word, then select back to its start
        eventtap.keyStroke({"alt"}, "right")
        eventtap.keyStroke({"alt", "shift"}, "left")
    end)
end

hotkey_labels.cmd_shift_v = "Coller sans mise en forme (Cmd+Shift+V)"
hotkey_defs.cmd_shift_v = function()
    return hs.hotkey.bind({"cmd","shift"}, "v", function()
        local prior = pasteboard.getContents()
        local plain = pasteboard.getContents() or ""
        pasteboard.clearContents()
        pasteboard.setContents(plain)
        timer.doAfter(0.08, function()
            -- perform paste with a small key delay
            eventtap.keyStroke({"cmd"}, "v", 0.02)

            timer.doAfter(0.25, function()
                if prior and prior ~= "" then pasteboard.setContents(prior) else pasteboard.clearContents() end
            end)
        end)
    end)
end

function M.start()
    if started then return end
    started = true
    -- create all bindings from definitions
    for name, def in pairs(hotkey_defs) do
        if not hotkeys[name] then
            hotkeys[name] = def()
        end
    end
    -- Re-seed random for keep-awake jitter
    math.randomseed(os.time())
end

function M.stop()
    if not started then return end
    -- Stop keep-awake if running
    awake_active = false
    if awake_timer then awake_timer:stop(); awake_timer = nil end
    if awake_alert_id then
        hs.alert.closeSpecific(awake_alert_id)
        awake_alert_id = nil
    end
    for k, v in pairs(hotkeys) do
        if v and v.delete then v:delete() end
    end
    hotkeys = {}
    started = false
end

-- Enable a single named hotkey
function M.enable(name)
    if hotkeys[name] then return end
    local def = hotkey_defs[name]
    if def then hotkeys[name] = def() end
end

-- Disable a single named hotkey
function M.disable(name)
    local h = hotkeys[name]
    if h and h.delete then h:delete() end
    hotkeys[name] = nil
end

function M.is_enabled(name)
    return hotkeys[name] ~= nil
end

function M.list_shortcuts()
    local out = {}
    for name, _ in pairs(hotkey_defs) do
        table.insert(out, {id = name, label = hotkey_labels[name] or name, enabled = hotkeys[name] ~= nil})
    end
    table.sort(out, function(a,b) return a.id < b.id end)
    return out
end

return M
