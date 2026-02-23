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
-- API: `M.start()` active les raccourcis, `M.stop()` les désactive.
-- Les handlers utilisent `hs.eventtap` pour copier/coller la sélection
-- et `hs.pasteboard` pour préserver/restaurer le presse-papiers.
local M = {}
local hotkeys = {}
local started = false

function M.start()
    if started then return end
    started = true

    -- Ctrl + A : sélectionner toute la ligne (début -> fin)
    hotkeys.ctrl_a = hs.hotkey.bind({"ctrl"}, "a", function()
        eventtap.keyStroke({"cmd"}, "left")
        eventtap.keyStroke({"cmd", "shift"}, "right")
    end)

    -- Ctrl + H : capture d'écran interactive (enregistre sur le Bureau)
    hotkeys.ctrl_h = hs.hotkey.bind({"ctrl"}, "h", function()
        local home = os.getenv("HOME") or "~"
        local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
        local cmd = 'screencapture -i "' .. filename .. '"'
        hs.execute(cmd)
    end)

    -- Ctrl + S : ouvrir la sélection
    -- - si c'est une URL probable, l'ouvre directement
    -- - sinon ouvre une recherche Google de la sélection
    hotkeys.ctrl_s = hs.hotkey.bind({"ctrl"}, "s", function()
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

    -- Ctrl + T : bascule Title Case / lowercase pour la sélection
    hotkeys.ctrl_t = hs.hotkey.bind({"ctrl"}, "t", function()
        do_transform(function(sel)
            local t = titlecase(sel)
            return (sel == t) and sel:lower() or t
        end)
    end)

    -- Ctrl + U : bascule Majuscules / Minuscules pour la sélection
    hotkeys.ctrl_u = hs.hotkey.bind({"ctrl"}, "u", function()
        do_transform(function(sel)
            local has_lower = sel:match("%l") ~= nil
            return has_lower and sel:upper() or sel:lower()
        end)
    end)
end

function M.stop()
    if not started then return end
    for k, v in pairs(hotkeys) do
        if v and v.delete then v:delete() end
    end
    hotkeys = {}
    started = false
end

return M
