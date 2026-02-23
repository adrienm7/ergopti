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

-- Récupère le chemin POSIX de la sélection dans le Finder (string) ou nil
local function get_selection_path()
    local front = hs.application.frontmostApplication()
    local name = (front and front:name()) or "Finder"

    local function try_app(appname)
        local script = string.format([[
            tell application "%s"
                try
                    set sel to selection
                    if sel = {} then return "" end if
                    set pths to {}
                    repeat with i from 1 to count of sel
                        set theItem to item i of sel
                        set end of pths to POSIX path of (theItem as alias)
                    end repeat
                    return pths as string
                on error
                    return ""
                end try
            end tell
        ]], appname)
        local ok, result = hs.osascript.applescript(script)
        if ok and result and result ~= "" then return result end
        return nil
    end

    -- Try the frontmost app first (works if it implements Finder-like selection API)
    local res = try_app(name)
    if res then return res end

    -- Try using Accessibility API to extract selected items (works for some file managers)
    local function try_ax(app)
        if not app then return nil end
        local ok, axapp = pcall(hs.axuielement.applicationElement, app:pid())
        if not ok or not axapp then return nil end
        local win = axapp:attributeValue("AXFocusedWindow") or axapp:attributeValue("AXMainWindow")
        if not win then return nil end
        local sel = win:attributeValue("AXSelectedRows") or win:attributeValue("AXSelectedChildren") or win:attributeValue("AXSelectedItems")
        if not sel or type(sel) ~= "table" then return nil end
        local paths = {}
        for _, item in ipairs(sel) do
            if item then
                local p = item:attributeValue("AXDocument") or item:attributeValue("AXURL") or item:attributeValue("AXTitle") or item:attributeValue("AXValue")
                if p and type(p) == "string" then
                    if p:match("^file://") then
                        p = p:gsub("^file://", "")
                        p = p:gsub("%%20", " ")
                    end
                    table.insert(paths, p)
                end
            end
        end
        if #paths > 0 then return table.concat(paths, ", ") end
        return nil
    end

    local axres = try_ax(front)
    if axres then return axres end

    -- Fallback to Finder selection if front app didn't respond
    if name ~= "Finder" then
        local res2 = try_app("Finder")
        if res2 then return res2 end
    end

    return nil
end

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

    -- Ctrl + D : ouvrir le dossier Téléchargements
    hotkeys.ctrl_d = hs.hotkey.bind({"ctrl"}, "d", function()
        local home = os.getenv("HOME") or "~"
        hs.execute('open "' .. home .. '/Downloads"')
        center_frontmost_after(0.3)
    end)

    -- Ctrl + E : ouvrir le Finder
    hotkeys.ctrl_e = hs.hotkey.bind({"ctrl"}, "e", function()
        hs.application.launchOrFocus("Finder")
        center_frontmost_after(0.3)
    end)

    -- Ctrl + H : capture d'écran interactive (enregistre sur le Bureau)
    hotkeys.ctrl_h = hs.hotkey.bind({"ctrl"}, "h", function()
        local home = os.getenv("HOME") or "~"
        local filename = string.format('%s/Desktop/screenshot_%s.png', home, os.date('%Y%m%d%H%M%S'))
        local cmd = 'screencapture -i "' .. filename .. '"'
        hs.execute(cmd)
    end)
    
    -- Ctrl + I : ouvrir les Réglages macOS (System Settings / Preferences)
    hotkeys.ctrl_i = hs.hotkey.bind({"ctrl"}, "i", function()
        if not hs.application.launchOrFocus("System Settings") then
            hs.application.launchOrFocus("System Preferences")
        end
        center_frontmost_after(0.3)
    end)

    -- Ctrl + S : ouvrir la sélection
    -- - si c'est une URL probable, l'ouvre directement
    -- - sinon ouvre une recherche Google de la sélection
    hotkeys.ctrl_s = hs.hotkey.bind({"ctrl"}, "s", function()
        local path = get_selection_path()
        if path then
            pasteboard.setContents(path)
            hs.alert.show("Chemin copié dans le presse-papiers")
            return
        end

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
