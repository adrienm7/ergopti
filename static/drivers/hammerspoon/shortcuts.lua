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

-- get_selection_path removed: simplified approach uses Cmd+Option+C for Finder-like apps

-- Centre les fenêtres standard visibles d'une application
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

--------------------------------------------------------------------------------
-- HOTKEYS (Classés par ordre alphabétique)
--------------------------------------------------------------------------------
-- API: `M.start()` active les raccourcis, `M.stop()` les désactive.
-- Les handlers utilisent `hs.eventtap` pour copier/coller la sélection
-- et `hs.pasteboard` pour préserver/restaurer le presse-papiers.
local M = {}
local hotkeys = {}
local hotkey_defs = {}
local hotkey_labels = {}
local started = false

-- Definitions des raccourcis (créent et retournent l'objet hotkey quand appelés)
hotkey_labels.ctrl_a = "Sélectionner la ligne (Ctrl+A)"
hotkey_defs.ctrl_a = function()
    return hs.hotkey.bind({"ctrl"}, "a", function()
        eventtap.keyStroke({"cmd"}, "left")
        eventtap.keyStroke({"cmd", "shift"}, "right")
    end)
end

hotkey_labels.ctrl_h = "Capture interactive (Ctrl+H)"
hotkey_defs.ctrl_h = function()
    return hs.hotkey.bind({"ctrl"}, "h", function()
        local home = os.getenv("HOME") or "~"
        local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
        local cmd = 'screencapture -i "' .. filename .. '"'
        hs.execute(cmd)
    end)
end

hotkey_labels.ctrl_e = "Ouvrir Finder (Ctrl+E)"
hotkey_defs.ctrl_e = function()
    return hs.hotkey.bind({"ctrl"}, "e", function()
        hs.application.launchOrFocus("Finder")
        center_frontmost_after(0.3)
    end)
end

hotkey_labels.ctrl_d = "Ouvrir Téléchargements (Ctrl+D)"
hotkey_defs.ctrl_d = function()
    return hs.hotkey.bind({"ctrl"}, "d", function()
        local home = os.getenv("HOME") or "~"
        hs.execute('open "' .. home .. '/Downloads"')
        center_frontmost_after(0.3)
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

hotkey_labels.ctrl_t = "Title Case toggle (Ctrl+T)"
hotkey_defs.ctrl_t = function()
    return hs.hotkey.bind({"ctrl"}, "t", function()
        do_transform(function(sel)
            local t = titlecase(sel)
            return (sel == t) and sel:lower() or t
        end)
    end)
end

hotkey_labels.ctrl_u = "Upper/Lower toggle (Ctrl+U)"
hotkey_defs.ctrl_u = function()
    return hs.hotkey.bind({"ctrl"}, "u", function()
        do_transform(function(sel)
            local has_lower = sel:match("%l") ~= nil
            return has_lower and sel:upper() or sel:lower()
        end)
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
                    hs.alert.show("Chemin [" .. p .. "] copié dans le presse-papiers")
                    return
                end
                -- fallback: copier la sélection et faire une recherche
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

        -- Par défaut: copier la sélection et lancer la recherche/URL
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
    -- bindings created from hotkey_defs above
end

function M.stop()
    if not started then return end
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
