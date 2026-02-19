-- Shortcuts: selection transforms, screenshot, search
local timer = hs.timer
local eventtap = hs.eventtap
local pasteboard = hs.pasteboard
local http = hs.http
local urlevent = hs.urlevent

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

-- Fonction asynchrone pour les transformations de texte (T et U)
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
        pasteboard.setContents(transformed)
        
        timer.doAfter(0.1, function()
            eventtap.keyStroke({"cmd"}, "v")
            
            timer.doAfter(0.2, function()
                if prior then 
                    pasteboard.setContents(prior) 
                else 
                    pasteboard.clearContents() 
                end
            end)
        end)
    end)
end

--------------------------------------------------------------------------------
-- HOTKEYS (Classés par ordre alphabétique)
--------------------------------------------------------------------------------

-- Ctrl + A : Sélectionner toute la ligne
hs.hotkey.bind({"ctrl"}, "a", function()
    eventtap.keyStroke({"cmd"}, "left")
    eventtap.keyStroke({"cmd", "shift"}, "right")
end)

-- Ctrl + H : Capture d'écran interactive
hs.hotkey.bind({"ctrl"}, "h", function()
    local home = os.getenv("HOME") or "~"
    local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
    local cmd = 'screencapture -i "' .. filename .. '"'
    hs.execute(cmd)
end)

-- Ctrl + S : Chercher la sélection (URL ou Google)
hs.hotkey.bind({"ctrl"}, "s", function()
    local prior = pasteboard.getContents()
    pasteboard.clearContents()
    
    eventtap.keyStroke({"cmd"}, "c")
    
    timer.doAfter(0.2, function()
        local sel = pasteboard.getContents()
        
        -- On restaure le presse-papiers immédiatement (on ne colle rien)
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

-- Ctrl + T : Basculer entre Title Case et Minuscules
hs.hotkey.bind({"ctrl"}, "t", function()
    do_transform(function(sel)
        local t = titlecase(sel)
        return (sel == t) and sel:lower() or t
    end)
end)

-- Ctrl + U : Basculer entre Majuscules et Minuscules
hs.hotkey.bind({"ctrl"}, "u", function()
    do_transform(function(sel)
        local has_lower = sel:match("%l") ~= nil
        return has_lower and sel:upper() or sel:lower()
    end)
end)
