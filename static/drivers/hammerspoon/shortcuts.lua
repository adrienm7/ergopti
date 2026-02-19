-- Shortcuts: selection transforms, screenshot, search
local timer = hs.timer
local eventtap = hs.eventtap
local pasteboard = hs.pasteboard
local notify = hs.notify
local http = hs.http
local urlevent = hs.urlevent

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function copy_selection()
    local ok, old = pcall(pasteboard.getContents)
    local prior = ok and old or nil
    local sel = ""
    -- try copying several times until clipboard changes
    for i = 1, 6 do
        pcall(function() eventtap.keyStroke({"cmd"}, "c", 0) end)
        timer.usleep(100000)
        sel = pasteboard.getContents() or ""
        if sel ~= (prior or "") and sel ~= "" then break end
    end
    return sel, prior
end

local function paste_and_restore(newtext, prior)
    pasteboard.setContents(newtext)
    timer.usleep(120000)
    pcall(function() eventtap.keyStroke({"cmd"}, "v", 0) end)
    timer.usleep(120000)
    if prior then pasteboard.setContents(prior) end
end

local function notify_short(msg)
    notify.new({title = "Shortcuts", informativeText = msg}):send()
end

-- Ctrl + a : select entire line (moved from init.lua)
hs.hotkey.bind({"ctrl"}, "a", function()
    pcall(function()
        eventtap.keyStroke({}, "home", 0)
        eventtap.keyStroke({"shift"}, "end", 0)
    end)
end)

-- Ctrl + U : toggle uppercase / lowercase for selection
hs.hotkey.bind({"ctrl"}, "u", function()
    pcall(function()
        local sel, prior = copy_selection()
        sel = sel or ""
        if sel == "" then notify_short("Aucune sélection"); if prior then pasteboard.setContents(prior) end; return end
        local has_lower = sel:match("%l") ~= nil
        local transformed
        if has_lower then
            transformed = sel:upper()
        else
            transformed = sel:lower()
        end
        pcall(function() eventtap.keyStroke({}, "delete", 0) end)
        timer.usleep(20000)
        pcall(function() eventtap.keyStrokes(transformed) end)
        timer.usleep(60000)
        if prior then pasteboard.setContents(prior) end
        notify_short('Transformé')
    end)
end)

-- Helper: simple Title Case (capitalize first letter of each word)
local function titlecase(s)
    s = s:lower()
    s = s:gsub("(%S+)", function(word)
        local first = word:sub(1,1)
        local rest = word:sub(2)
        return first:upper() .. rest
    end)
    return s
end

-- Ctrl + T : titlecase / lowercase toggle
hs.hotkey.bind({"ctrl"}, "t", function()
    pcall(function()
        local sel, prior = copy_selection()
        sel = sel or ""
        if sel == "" then notify_short("Aucune sélection"); if prior then pasteboard.setContents(prior) end; return end
        local t = titlecase(sel)
        if sel == t then
            pcall(function() eventtap.keyStroke({}, "delete", 0) end)
            timer.usleep(20000)
            pcall(function() eventtap.keyStrokes(sel:lower()) end)
        else
            pcall(function() eventtap.keyStroke({}, "delete", 0) end)
            timer.usleep(20000)
            pcall(function() eventtap.keyStrokes(t) end)
        end
        timer.usleep(60000)
        if prior then pasteboard.setContents(prior) end
        notify_short('Transformé')
    end)
end)

-- Ctrl + H : interactive screenshot (saves to Desktop)
hs.hotkey.bind({"ctrl"}, "h", function()
    pcall(function()
        local home = os.getenv("HOME") or "~"
        local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
        local cmd = 'screencapture -i "' .. filename .. '"'
        hs.execute(cmd)
        notify_short('Capture enregistrée: ' .. filename)
    end)
end)

local function is_probable_url(s)
    local x = trim(s)
    if x:match('^https?://') then return x end
    if x:match('^www%.') or (x:match('%.%a%a') and not x:match('%s')) then return 'http://' .. x end
    return nil
end

-- Ctrl + S : search selection (open URL if URL, else Google search)
hs.hotkey.bind({"ctrl"}, "s", function()
    pcall(function()
        local sel, prior = copy_selection()
        sel = sel or ""
        if sel == "" then notify_short("Aucune sélection"); if prior then pasteboard.setContents(prior) end; return end
        local trimmed = trim(sel)
        local url = is_probable_url(trimmed)
        if url then
            urlevent.openURL(url)
        else
            local q = http.encodeForQuery(trimmed)
            local search = 'https://www.google.com/search?q=' .. q
            urlevent.openURL(search)
        end
        if prior then pasteboard.setContents(prior) end
    end)
end)

-- return nothing; module runs on load
