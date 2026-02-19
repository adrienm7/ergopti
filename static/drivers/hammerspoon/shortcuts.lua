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
    local prior = pasteboard.getContents()
    local marker = "HS_MARK_TXT_" .. timer.secondsSinceEpoch()
    
    -- 1. On injecte le marqueur
    pasteboard.setContents(marker)
    
    -- 2. On attend que le marqueur soit bien en place
    for i = 1, 20 do
        if pasteboard.getContents() == marker then break end
        timer.usleep(10000)
    end
    
    -- 3. On lance la copie
    eventtap.keyStroke({"cmd"}, "c")
    
    -- 4. On attend le nouveau texte
    local sel = ""
    for i = 1, 50 do
        timer.usleep(20000)
        local current = pasteboard.getContents()
        
        -- LA CORRECTION EST ICI : on s'assure que current n'est pas nil (vide)
        if current ~= nil and current ~= marker then
            sel = current
            break
        end
    end
    
    return sel, prior
end

local function paste_and_restore(newtext, prior)
    pasteboard.setContents(newtext)
    
    for i = 1, 20 do
        if pasteboard.getContents() == newtext then break end
        timer.usleep(10000)
    end
    
    eventtap.keyStroke({"cmd"}, "v")
    timer.usleep(200000) 
    
    if prior then 
        pasteboard.setContents(prior) 
    else
        pasteboard.clearContents()
    end
end

local function notify_short(msg)
    notify.new({title = "Shortcuts", informativeText = msg}):send()
end

-- Ctrl + A : select entire line
hs.hotkey.bind({"ctrl"}, "a", function()
    eventtap.keyStroke({"cmd"}, "left")
    eventtap.keyStroke({"cmd", "shift"}, "right")
end)

-- Ctrl + U : toggle uppercase / lowercase for selection
hs.hotkey.bind({"ctrl"}, "u", function()
    local sel, prior = copy_selection()
    
    if sel == "" then 
        notify_short("Aucune sélection")
        if prior then pasteboard.setContents(prior) end
        return 
    end
    
    local has_lower = sel:match("%l") ~= nil
    local transformed = has_lower and sel:upper() or sel:lower()
    
    paste_and_restore(transformed, prior)
    notify_short('Transformé')
end)

-- Helper: simple Title Case
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
    local sel, prior = copy_selection()
    
    if sel == "" then 
        notify_short("Aucune sélection")
        if prior then pasteboard.setContents(prior) end
        return 
    end
    
    local t = titlecase(sel)
    local transformed = (sel == t) and sel:lower() or t
    
    paste_and_restore(transformed, prior)
    notify_short('Transformé')
end)

-- Ctrl + H : interactive screenshot
hs.hotkey.bind({"ctrl"}, "h", function()
    local home = os.getenv("HOME") or "~"
    local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
    local cmd = 'screencapture -i "' .. filename .. '"'
    hs.execute(cmd)
    notify_short('Capture enregistrée : ' .. filename)
end)

local function is_probable_url(s)
    local x = trim(s)
    if x:match('^https?://') then return x end
    if x:match('^www%.') or (x:match('%.%a%a') and not x:match('%s')) then return 'http://' .. x end
    return nil
end

-- Ctrl + S : search selection
hs.hotkey.bind({"ctrl"}, "s", function()
    local sel, prior = copy_selection()
    
    if sel == "" then 
        notify_short("Aucune sélection")
        if prior then pasteboard.setContents(prior) end
        return 
    end
    
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
