--- modules/shortcuts/helpers.lua

--- ==============================================================================
--- MODULE: Shortcuts Helpers
--- DESCRIPTION:
--- Extracts the complex logic behind productivity shortcuts to keep the registry clean.
--- Includes text transformers, system utilities, and complex eventtap bindings.
---
--- FEATURES & RATIONALE:
--- 1. Separation of Concerns: Keeps business logic away from key bindings.
--- 2. Reusability: Allows other modules to reuse text or window navigation utilities.
--- ==============================================================================

local M = {}

local hs            = hs
local timer         = hs.timer
local eventtap      = hs.eventtap
local pasteboard    = hs.pasteboard
local http          = hs.http
local urlevent      = hs.urlevent
local notifications = require("lib.notifications")

local ok_gestures, gestures = pcall(require, "modules.gestures")
if not ok_gestures then gestures = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local fm_list          = {"qspace", "path finder", "forklift", "commander one", "totalfinder", "xtrafinder", "finder"}

local awake_timer      = nil
local awake_alert_id   = nil
local awake_active     = false
local awake_origin_pos = nil

-- Forward declaration for recursive keep-awake function
local schedule_awake_tick





-- ========================================
-- ========================================
-- ======= 2/ Text & String Helpers =======
-- ========================================
-- ========================================

--- Trims whitespace from the beginning and end of a string.
--- @param s string The input string.
--- @return string The trimmed string.
function M.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Checks if a string looks like a valid URL and prepends http:// if necessary.
--- @param s string The input string.
--- @return string|nil The formatted URL, or nil if not a URL.
function M.is_probable_url(s)
    local x = M.trim(s)
    if x:match("^https?://") then return x end
    if x:match("^www%.") or (x:match("%.%a%a") and not x:match("%s")) then 
        return "http://" .. x 
    end
    return nil
end

--- Converts a string to Title Case.
--- @param s string The input string.
--- @return string The Title Case string.
function M.titlecase(s)
    if type(s) ~= "string" then return "" end
    s = s:lower()
    s = s:gsub("(%S+)", function(word)
        return word:sub(1,1):upper() .. word:sub(2)
    end)
    return s
end

--- Asynchronous text transformer engine.
--- Copies selection, applies function, pastes result.
--- @param transform_func function The text manipulation callback.
function M.do_transform(transform_func)
    local prior = pasteboard.getContents()
    pasteboard.clearContents()

    eventtap.keyStroke({"cmd"}, "c")

    timer.doAfter(0.2, function()
        local sel = pasteboard.getContents()

        if not sel or sel == "" then
            if prior then pcall(function() pasteboard.setContents(prior) end) end
            return
        end

        local ok, transformed = pcall(transform_func, sel)
        if not ok or not transformed then
            if prior then pcall(function() pasteboard.setContents(prior) end) end
            return
        end

        pcall(function() pasteboard.setContents(transformed) end)

        timer.doAfter(0.08, function()
            -- Paste the transformed text
            eventtap.keyStroke({"cmd"}, "v", 0.02)

            -- Shortly after pasting, re-select the inserted text so
            -- repeated transforms don’t require re-selection
            timer.doAfter(0.08, function()
                local len_ok, ulen = pcall(function() return utf8.len(transformed) end)
                local n = (len_ok and ulen and ulen > 0) and ulen or #transformed

                -- Safety cap to avoid extremely long loops freezing the system
                local MAX = 5000
                if n > MAX then n = MAX end

                if n > 0 then
                    -- Move caret left `n` times to reach the start
                    for _ = 1, n do
                        eventtap.keyStroke({}, "left", 0.001)
                    end
                    -- Select right `n` times to reselect the pasted text
                    for _ = 1, n do
                        eventtap.keyStroke({"shift"}, "right", 0.001)
                    end
                end

                -- Restore prior clipboard safely
                timer.doAfter(0.15, function()
                    pcall(function()
                        if prior and prior ~= "" then
                            pasteboard.setContents(prior)
                        else
                            pasteboard.clearContents()
                        end
                    end)
                end)
            end)
        end)
    end)
end





-- =======================================
-- =======================================
-- ======= 3/ App & Window Helpers =======
-- =======================================
-- =======================================

--- Centers all visible standard windows of a given application.
--- @param app userdata The hs.application object.
function M.center_windows_of_app(app)
    if not app or type(app.allWindows) ~= "function" then return end
    
    local ok, wins = pcall(function() return app:allWindows() end)
    if not ok or not wins then return end
    
    for _, w in ipairs(wins) do
        if w:isStandard() and w:isVisible() then
            local screen = w:screen()
            if screen then
                local sf = screen:frame()
                local wf = w:frame()
                local nx = sf.x + math.floor((sf.w - wf.w) / 2)
                local ny = sf.y + math.floor((sf.h - wf.h) / 2)
                pcall(function() w:setFrame({x = nx, y = ny, w = wf.w, h = wf.h}) end)
            end
        end
    end
end

--- Centers the frontmost application after a slight delay.
--- @param delay number Delay in seconds.
function M.center_frontmost_after(delay)
    timer.doAfter(tonumber(delay) or 0.2, function()
        local ok, f = pcall(hs.application.frontmostApplication)
        if ok and f then M.center_windows_of_app(f) end
    end)
end

--- Checks if a given app name belongs to a known file manager.
--- @param appname string Name of the application.
--- @return boolean True if it matches a file manager.
function M.is_finder_like(appname)
    if type(appname) ~= "string" then return false end
    local ln = appname:lower()
    for _, v in ipairs(fm_list) do
        if ln:find(v, 1, true) then return true end
    end
    return false
end

--- Attempts to launch or focus the first available application from a list.
--- @param apps table List of application names.
--- @return boolean True if an application was successfully activated.
function M.launch_first_available(apps)
    if type(apps) ~= "table" then return false end
    
    local ok_run, running = pcall(hs.application.runningApplications)
    running = ok_run and running or {}
    
    for _, name in ipairs(apps) do
        local lname = name:lower()
        
        -- Try to focus a running app whose name contains the candidate
        for _, a in ipairs(running) do
            local ok_name, an = pcall(function() return a:name() end)
            if ok_name and an and an:lower():find(lname, 1, true) then
                pcall(function() a:activate() end)
                return true
            end
        end
        
        -- Try to launch/focus by exact name
        local ok_launch, success = pcall(hs.application.launchOrFocus, name)
        if ok_launch and success then
            return true
        end
    end
    
    return false
end





-- ======================================
-- ======================================
-- ======= 4/ System & OS Helpers =======
-- ======================================
-- ======================================

--- Reads hex color (#rrggbb) of the pixel at the given screen position.
--- Captures a 3x3 region and samples the center pixel via Python3.
--- @param x number X coordinate.
--- @param y number Y coordinate.
--- @return string|nil The hex color code, or nil if reading failed.
function M.pixel_hex_at(x, y)
    local tmpfile = "/tmp/_hs_pixel_cap.png"
    local safe_x  = math.floor(tonumber(x) or 0) - 1
    local safe_y  = math.floor(tonumber(y) or 0) - 1
    
    local cap_cmd = string.format("screencapture -x -R \"%d,%d,3,3\" \"%s\"", safe_x, safe_y, tmpfile)
    local ok_cap = pcall(hs.execute, cap_cmd)
    if not ok_cap then return nil end

    local py = string.format([[
python3 -c "
import struct,zlib
try:
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
except Exception:
  pass
"
]], tmpfile)
    
    local ok_py, out = pcall(hs.execute, py)
    if ok_py and out then
        local hex = out:match("(#%x%x%x%x%x%x)")
        if hex then return hex end
    end
    
    return nil
end

--- Reads the chatgpt_url from config.json (falls back to default if missing/invalid).
--- @param default_url string The fallback URL to use.
--- @return string The URL.
function M.read_chatgpt_url(default_url)
    local cfg_path = hs.configdir .. "/config.json"
    local ok, fh = pcall(io.open, cfg_path, "r")
    if not ok or not fh then return default_url end
    
    local content = fh:read("*a")
    pcall(function() fh:close() end)
    
    local dec_ok, tbl = pcall(hs.json.decode, content)
    if dec_ok and type(tbl) == "table" and type(tbl.chatgpt_url) == "string" and tbl.chatgpt_url ~= "" then
        return tbl.chatgpt_url
    end
    
    return default_url
end

--- Schedules the next keep-awake tick after a random delay (between 1s and 5s).
schedule_awake_tick = function()
    if not awake_active then return end
    
    -- Stop any existing scheduled timer
    if awake_timer and type(awake_timer.stop) == "function" then 
        pcall(function() awake_timer:stop() end)
        awake_timer = nil 
    end
    
    -- Schedule next action at a random interval
    local interval = math.random(1, 5)
    awake_timer = timer.doAfter(interval, function()
        if not awake_active then return end
        
        -- Ensure we have an origin to orbit around
        local origin = awake_origin_pos
        if not origin then
            local ok, p = pcall(hs.mouse.absolutePosition)
            if ok and p then origin = {x = p.x, y = p.y} end
        end
        
        if origin then
            -- Pick a random offset around the origin and move there
            local ox = math.random(-120, 120)
            local oy = math.random(-80, 80)
            local tx = origin.x + ox
            local ty = origin.y + oy
            
            -- Clamp to screen if possible
            local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
            if screen and type(screen.frame) == "function" then
                local frame = screen:frame()
                if tx < frame.x then tx = frame.x end
                if tx > frame.x + frame.w - 1 then tx = frame.x + frame.w - 1 end
                if ty < frame.y then ty = frame.y end
                if ty > frame.y + frame.h - 1 then ty = frame.y + frame.h - 1 end
            end
            
            pcall(hs.mouse.absolutePosition, {x = tx, y = ty})
            
            -- Short delay then return to origin
            timer.doAfter(0.2, function()
                if origin then pcall(hs.mouse.absolutePosition, {x = origin.x, y = origin.y}) end
            end)
            
            -- Send an unmapped F18 keystroke as an extra activity signal to the OS
            pcall(function() eventtap.keyStroke({}, "f18", 0) end)
        end
        
        -- Loop
        schedule_awake_tick()
    end)
end

--- Toggles the physical mouse jiggler to keep the Mac awake.
function M.toggle_awake()
    if awake_active then
        -- Disable keep-awake
        awake_active = false
        if awake_timer and type(awake_timer.stop) == "function" then 
            pcall(function() awake_timer:stop() end)
            awake_timer = nil 
        end
        if awake_alert_id then
            pcall(hs.alert.closeSpecific, awake_alert_id)
            awake_alert_id = nil
        end
        pcall(hs.alert.show, "☕ Keep-awake désactivé", 2)
    else
        -- Enable keep-awake: re-seed and start periodic ticks
        awake_active = true
        math.randomseed(os.time())
        
        local ok, aid = pcall(hs.alert.show, "☕ Keep-awake actif — Ctrl+M pour désactiver", math.huge)
        if ok then awake_alert_id = aid end
        
        -- Record the origin position so periodic moves return here
        local ok_pos, pos = pcall(hs.mouse.absolutePosition)
        if ok_pos and pos then
            awake_origin_pos = {x = pos.x, y = pos.y}
            local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
            
            local frame = nil
            if screen and type(screen.frame) == "function" then frame = screen:frame() end
            
            local dx = (math.random(0,1) == 0) and -80 or 80
            local nx = pos.x + dx
            
            if frame then
                if nx < frame.x then nx = frame.x end
                if nx > frame.x + frame.w - 1 then nx = frame.x + frame.w - 1 end
            end
            pcall(hs.mouse.absolutePosition, {x = nx, y = pos.y})
        end
        
        schedule_awake_tick()
    end
end

--- Ensures the awake function stops cleanly when module stops.
function M.stop_awake()
    awake_active = false
    if awake_timer and type(awake_timer.stop) == "function" then 
        pcall(function() awake_timer:stop() end)
        awake_timer = nil 
    end
    if awake_alert_id then
        pcall(hs.alert.closeSpecific, awake_alert_id)
        awake_alert_id = nil
    end
end





-- =============================================
-- =============================================
-- ======= 5/ Execution Action Functions =======
-- =============================================
-- =============================================



-- ==================================
-- ===== 5.1) Selection Actions =====
-- ==================================

--- Pastes the current clipboard content without any rich text formatting.
function M.paste_as_plain_text()
    local prior = pasteboard.getContents()
    local plain = pasteboard.getContents() or ""
    
    pcall(function()
        pasteboard.clearContents()
        pasteboard.setContents(plain)
    end)
    
    timer.doAfter(0.08, function()
        eventtap.keyStroke({"cmd"}, "v", 0.02)
        timer.doAfter(0.25, function()
            pcall(function()
                if prior and prior ~= "" then 
                    pasteboard.setContents(prior) 
                else 
                    pasteboard.clearContents() 
                end
            end)
        end)
    end)
end

--- Highlights the entire current text line.
function M.select_line()
    eventtap.keyStroke({"cmd"}, "left")
    eventtap.keyStroke({"cmd", "shift"}, "right")
end

--- Wraps the current line in parentheses.
function M.surround_with_parens()
    eventtap.keyStroke({"cmd"}, "left")
    hs.eventtap.keyStrokes("(")
    
    timer.doAfter(0.04, function()
        eventtap.keyStroke({"cmd"}, "right")
        hs.eventtap.keyStrokes(")")
    end)
end

--- Toggles the selection to Title Case.
function M.toggle_titlecase()
    M.do_transform(function(sel)
        local t = M.titlecase(sel)
        return (sel == t) and sel:lower() or t
    end)
end

--- Toggles the selection between ALL CAPS and lowercase.
function M.toggle_uppercase()
    M.do_transform(function(sel)
        local has_lower = sel:match("%l") ~= nil
        return has_lower and sel:upper() or sel:lower()
    end)
end

--- Highlights the current word under the cursor.
function M.select_word()
    eventtap.keyStroke({"alt"}, "right")
    eventtap.keyStroke({"alt", "shift"}, "left")
end



-- ==============================
-- ===== 5.2) App Execution =====
-- ==============================

--- Opens the Downloads folder dynamically.
function M.open_downloads()
    local home = os.getenv("HOME") or "~"
    if not M.launch_first_available(fm_list) then
        pcall(hs.execute, "open \"" .. home .. "/Downloads\"")
    else
        timer.doAfter(0.12, function()
            pcall(hs.execute, "open \"" .. home .. "/Downloads\"")
        end)
    end
    M.center_frontmost_after(0.3)
end

--- Opens the Finder or alternative file manager dynamically.
function M.open_finder()
    local home = os.getenv("HOME") or "~"
    if not M.launch_first_available(fm_list) then
        pcall(hs.execute, "open \"" .. home .. "/Downloads\"")   
    else
        timer.doAfter(0.12, function()
            pcall(hs.execute, "open \"" .. home .. "\"")
        end)
    end
    M.center_frontmost_after(0.3)
end

--- Opens the ChatGPT web interface.
--- @param default_url string The fallback URL if not configured.
function M.open_chatgpt(default_url)
    local url = M.read_chatgpt_url(default_url)
    pcall(urlevent.openURL, url)
end

--- Opens the macOS System Settings application.
function M.open_settings()
    local ok, launched = pcall(hs.application.launchOrFocus, "System Settings")
    if not ok or not launched then
        pcall(hs.application.launchOrFocus, "System Preferences")
    end
    M.center_frontmost_after(0.3)
end

--- Copies the current path if in a file manager, otherwise copies text and searches the web.
function M.copy_or_open_path()
    local ok, front = pcall(hs.application.frontmostApplication)
    local name = (ok and front) and front:name() or ""

    if M.is_finder_like(name) then
        eventtap.keyStroke({"cmd", "alt"}, "c")
        timer.doAfter(0.15, function()
            local ok_p, p = pcall(pasteboard.getContents)
            if ok_p and p and p ~= "" then
                notifications.notify("Chemin copié : " .. p)
                return
            end
            
            local prior = nil
            pcall(function() prior = pasteboard.getContents(); pasteboard.clearContents() end)
            
            eventtap.keyStroke({"cmd"}, "c")
            
            timer.doAfter(0.2, function()
                local sel = nil
                pcall(function() sel = pasteboard.getContents() end)
                
                pcall(function()
                    if prior then pasteboard.setContents(prior) else pasteboard.clearContents() end
                end)
                
                if not sel or sel == "" then return end
                
                local trimmed = M.trim(sel)
                local url = M.is_probable_url(trimmed)
                
                if url then pcall(urlevent.openURL, url)
                else
                    local q = http.encodeForQuery(trimmed)
                    local search = "https://www.google.com/search?q=" .. q
                    pcall(urlevent.openURL, search)
                end
            end)
        end)
        return
    end

    local prior = nil
    pcall(function() prior = pasteboard.getContents(); pasteboard.clearContents() end)
    
    eventtap.keyStroke({"cmd"}, "c")
    
    timer.doAfter(0.2, function()
        local sel = nil
        pcall(function() sel = pasteboard.getContents() end)
        
        pcall(function()
            if prior then pasteboard.setContents(prior) else pasteboard.clearContents() end
        end)
        
        if not sel or sel == "" then return end
        
        local trimmed = M.trim(sel)
        local url = M.is_probable_url(trimmed)
        
        if url then pcall(urlevent.openURL, url)
        else
            local q = http.encodeForQuery(trimmed)
            local search = "https://www.google.com/search?q=" .. q
            pcall(urlevent.openURL, search)
        end
    end)
end

--- Captures the color of the pixel currently under the mouse cursor.
function M.copy_pixel_color()
    local ok, pos = pcall(hs.mouse.absolutePosition)
    if not ok or not pos then return end
    
    local hex = M.pixel_hex_at(math.floor(pos.x), math.floor(pos.y))
    if not hex then
        notifications.notify("Impossible de lire la couleur du pixel")
        return
    end
    
    pcall(function() pasteboard.setContents(hex) end)
    notifications.notify("Couleur copiée : " .. hex)
end

--- Triggers the native macOS interactive screenshot tool.
function M.interactive_screenshot()
    local ok, task = pcall(hs.task.new,
        "/usr/sbin/screencapture",
        function(exit_code, _, _)
            if exit_code == 0 then
                notifications.notify("Capture d’écran copiée dans le presse-papiers")
            end
        end,
        { "-i", "-c" }
    )
    if ok and task then task:start() end
end





-- =========================================
-- =========================================
-- ======= 6/ Complex EventTap Binds =======
-- =========================================
-- =========================================

--- Binds the instant screenshot action on a physical event tap.
--- @return table The event tap object reference with a delete method.
function M.bind_instant_screenshot()
    local tap
    local obj = {}
    tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
        if e:getKeyCode() == 10 then
            local flags = e:getFlags()
            if flags.cmd or flags.alt or flags.ctrl or flags.shift then
                return false
            end
            
            local ok, w = pcall(hs.window.frontmostWindow)
            if not ok or not w then
                notifications.notify("Aucune fenêtre active")
                return true
            end
            
            local id = w:id()
            local home = os.getenv("HOME") or "~"
            local dir = home .. "/Pictures/screenshots"
            pcall(hs.execute, "mkdir -p \"" .. dir .. "\"")
            
            local filename = string.format("%s/screenshot_%s.png", dir, os.date("%Y_%m_%d_%H_%M_%S"))
            local cmd = "screencapture -l " .. id .. " \"" .. filename .. "\""
            pcall(hs.execute, cmd)
            
            notifications.notify("Saved: " .. filename)
            return true
        end
        return false
    end)
    tap:start()
    
    function obj:delete()
        if tap and type(tap.stop) == "function" then
            pcall(function() tap:stop() end)
            tap = nil
        end
    end
    return obj
end

--- Binds the Cmd+Star preservation tap.
--- @return table The event tap object reference with a delete method.
function M.bind_cmd_star()
    local tap
    local obj = {}
    tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
        local flags = e:getFlags()
        if not flags.cmd then return false end
        
        local ok, ch = pcall(function() return e:getCharacters() end)
        if not ok or not ch then return false end
        if ch ~= "★" and ch ~= "*" and ch ~= "✱" then return false end

        local mods = {}
        if flags.cmd then table.insert(mods, "cmd") end
        if flags.shift then table.insert(mods, "shift") end
        if flags.alt then table.insert(mods, "alt") end
        if flags.ctrl then table.insert(mods, "ctrl") end

        if #mods > 0 then
            eventtap.keyStroke(mods, "s")
        end

        return true
    end)
    tap:start()
    
    function obj:delete()
        if tap and type(tap.stop) == "function" then
            pcall(function() tap:stop() end)
            tap = nil
        end
    end
    return obj
end

--- Binds the Layer+Scroll hardware override for volume controls.
--- @return table The event tap object references with a delete method.
function M.bind_layer_scroll()
    local left_cmd_physical = false
    local f19_keycode = hs.keycodes.map["f19"]

    local physical_tap = hs.eventtap.new({hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp}, function(event)
        local kc = event:getKeyCode()
        if kc == f19_keycode then
            if event:getType() == hs.eventtap.event.types.keyDown then
                if gestures and type(gestures.isLeftClickPressed) == "function" then
                    if gestures.isLeftClickPressed() then
                        pcall(function() gestures.forceCleanup() end)
                    end
                end
                left_cmd_physical = true
            else
                left_cmd_physical = false
            end
        end
        return false
    end)

    local scroll_tap = hs.eventtap.new({hs.eventtap.event.types.scrollWheel}, function(event)
        if left_cmd_physical then
            if gestures and type(gestures.isLeftClickPressed) == "function" then
                if gestures.isLeftClickPressed() then
                    pcall(function() gestures.forceCleanup() end)
                end
            end
            
            local scrollY = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
            if type(scrollY) == "number" then
                if scrollY > 0 then
                    for _ = 1, math.max(1, math.floor(scrollY)) do
                        pcall(function() hs.eventtap.event.newSystemKeyEvent("SOUND_UP", true):post() end)
                        pcall(function() hs.eventtap.event.newSystemKeyEvent("SOUND_UP", false):post() end)
                    end
                elseif scrollY < 0 then
                    for _ = 1, math.max(1, math.floor(-scrollY)) do
                        pcall(function() hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", true):post() end)
                        pcall(function() hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", false):post() end)
                    end
                end
            end
            return true
        end
        return false
    end)

    if physical_tap then pcall(function() physical_tap:start() end) end
    if scroll_tap then pcall(function() scroll_tap:start() end) end

    return {
        delete = function()
            if physical_tap and type(physical_tap.stop) == "function" then pcall(function() physical_tap:stop() end) end
            if scroll_tap and type(scroll_tap.stop) == "function" then pcall(function() scroll_tap:stop() end) end
        end
    }
end

return M
