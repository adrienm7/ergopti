-- Shortcuts: selection transforms, screenshot, search
local timer = hs.timer
local eventtap = hs.eventtap
local pasteboard = hs.pasteboard
local notify = hs.notify
local http = hs.http
local urlevent = hs.urlevent

local function notify_short(msg)
    notify.new({title = "Shortcuts", informativeText = msg}):send()
end

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function titlecase(s)
    s = s:lower()
    s = s:gsub("(%S+)", function(word)
        return word:sub(1,1):upper() .. word:sub(2)
    end)
    return s
end

-- Fonction asynchrone magique pour transformer le texte
local function do_transform(transform_func)
    local prior = pasteboard.getContents()
    pasteboard.clearContents()
    
    -- 1. On envoie Cmd+C
    eventtap.keyStroke({"cmd"}, "c")
    
    -- 2. On rend la main à macOS et on revient dans 0.2s
    timer.doAfter(0.2, function()
        local sel = pasteboard.getContents()
        
        -- Si toujours vide après 0.2s, on abandonne
        if not sel or sel == "" then
            notify_short("Aucune sélection")
            if prior then pasteboard.setContents(prior) end
            return
        end
        
        -- 3. On transforme et on met dans le presse-papiers
        local transformed = transform_func(sel)
        pasteboard.setContents(transformed)
        
        -- 4. On attend 0.1s que le presse-papiers soit bien mis à jour
        timer.doAfter(0.1, function()
            -- 5. On colle
            eventtap.keyStroke({"cmd"}, "v")
            
            -- 6. On attend 0.2s que l'appli ait fini de coller avant de nettoyer
            timer.doAfter(0.2, function()
                if prior then 
                    pasteboard.setContents(prior) 
                else 
                    pasteboard.clearContents() 
                end
                notify_short('Transformé')
            end)
        end)
    end)
end

-- Ctrl + U : toggle uppercase / lowercase
hs.hotkey.bind({"ctrl"}, "u", function()
    do_transform(function(sel)
        local has_lower = sel:match("%l") ~= nil
        return has_lower and sel:upper() or sel:lower()
    end)
end)

-- Ctrl + T : titlecase / lowercase toggle
hs.hotkey.bind({"ctrl"}, "t", function()
    do_transform(function(sel)
        local t = titlecase(sel)
        return (sel == t) and sel:lower() or t
    end)
end)

-- Ctrl + S : search selection
hs.hotkey.bind({"ctrl"}, "s", function()
    local prior = pasteboard.getContents()
    pasteboard.clearContents()
    eventtap.keyStroke({"cmd"}, "c")
    
    timer.doAfter(0.2, function()
        local sel = pasteboard.getContents()
        
        if not sel or sel == "" then
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
end)

-- Ctrl + A : select entire line
hs.hotkey.bind({"ctrl"}, "a", function()
    eventtap.keyStroke({"cmd"}, "left")
    eventtap.keyStroke({"cmd", "shift"}, "right")
end)

-- Ctrl + H : interactive screenshot
hs.hotkey.bind({"ctrl"}, "h", function()
    local home = os.getenv("HOME") or "~"
    local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
    local cmd = 'screencapture -i "' .. filename .. '"'
    hs.execute(cmd)
    notify_short('Capture enregistrée : ' .. filename)
end)
