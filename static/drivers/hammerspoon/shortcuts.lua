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
    -- 1. Sauvegarder l'ancien contenu
    local prior = pasteboard.getContents()
    
    -- 2. Vider le presse-papiers pour être sûr de détecter la nouvelle copie
    pasteboard.clearContents()
    
    -- 3. Lancer la copie
    eventtap.keyStroke({"cmd"}, "c")
    
    -- 4. Attendre que le presse-papiers se remplisse (max ~0.25 seconde)
    local sel = nil
    for i = 1, 25 do
        timer.usleep(10000) -- 10ms
        sel = pasteboard.getContents()
        if sel then break end
    end
    
    return sel or "", prior
end

local function paste_and_restore(newtext, prior)
    -- Mettre le nouveau texte dans le presse-papiers
    pasteboard.setContents(newtext)
    timer.usleep(50000) -- Attendre 50ms que le système enregistre le presse-papiers
    
    -- Coller (cela écrase automatiquement le texte sélectionné, pas besoin de "delete")
    eventtap.keyStroke({"cmd"}, "v")
    timer.usleep(50000) -- Attendre 50ms que l'action de coller s'effectue
    
    -- Restaurer l'ancien presse-papiers
    if prior then 
        pasteboard.setContents(prior) 
    else
        pasteboard.clearContents()
    end
end

local function notify_short(msg)
    notify.new({title = "Shortcuts", informativeText = msg}):send()
end

-- Ctrl + a : select entire line
hs.hotkey.bind({"ctrl"}, "a", function()
    eventtap.keyStroke({"cmd"}, "left") -- Aller au début de la ligne (sur Mac c'est Cmd+Left, pas Home)
    eventtap.keyStroke({"cmd", "shift"}, "right") -- Sélectionner jusqu'à la fin
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
    
    -- Utilisation de paste_and_restore au lieu de keyStrokes
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
    
    -- Utilisation de paste_and_restore au lieu de keyStrokes
    paste_and_restore(transformed, prior)
    notify_short('Transformé')
end)

-- Ctrl + H : interactive screenshot
hs.hotkey.bind({"ctrl"}, "h", function()
    local home = os.getenv("HOME") or "~"
    local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
    local cmd = 'screencapture -i "' .. filename .. '"'
    hs.execute(cmd)
    notify_short('Capture enregistrée')
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
    
    -- On restaure le presse-papiers car on a juste fait une recherche
    if prior then pasteboard.setContents(prior) end
end)
