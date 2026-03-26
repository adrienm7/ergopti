-- ui/prompt_editor/init.lua

-- ===========================================================================
-- Prompt Editor UI Module.
--
-- Provides a clean webview-based interface for users to create and edit
-- custom LLM prompt profiles. Employs a content-editable block to visually
-- render the "{context}" token as a chip.
-- 
-- Uses ui/ui_builder.lua to inject CSS and JS content directly into the 
-- HTML template, bypassing path resolution and sandbox issues.
-- ===========================================================================

local M = {}

local hs         = hs
local ui_builder = require("ui.ui_builder")





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _webview     = nil
local _usercontent = nil

local WINDOW_WIDTH  = 550
local WINDOW_HEIGHT = 480

-- Determine absolute path to the assets directory
local _src  = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the Prompt Editor window
--- @param existing table|nil An existing profile to edit, or nil for a new one
--- @param on_save function Callback invoked when the user clicks "Save"
function M.open(existing, on_save)
    -- Close any existing instance before reopening
    if _webview then 
        if type(_webview.delete) == "function" then pcall(function() _webview:delete() end) end
        _webview = nil 
    end

    -- Prepare default values for the JS frontend
    local default_name   = type(existing) == "table" and type(existing.label) == "string" and existing.label or ""
    local default_batch  = (existing == nil) or (type(existing) == "table" and existing.batch ~= false)
    local default_prompt = type(existing) == "table" and type(existing.raw_prompt) == "string" and existing.raw_prompt or "Voici un texte, continue-le : {context}"

    -- Configure the Javascript bridge
    local ok_uc, uc = pcall(hs.webview.usercontent.new, "prompt_bridge")
    if not ok_uc or not uc then
        print("[prompt_editor] Error creating usercontent bridge.")
        return
    end
    
    _usercontent = uc
    _usercontent:setCallback(function(msg)
        if type(msg) ~= "table" then return end
        local body = msg.body
        
        if type(body) == "table" then
            if body.action == "cancel" then
                M.close()
                
            elseif body.action == "save" then
                -- Generate a unique ID if this is a new profile
                local id = (type(existing) == "table" and type(existing.id) == "string") 
                           and existing.id 
                           or ("custom_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)))
                           
                if type(on_save) == "function" then
                    pcall(on_save, {
                        id          = id,
                        label       = type(body.name) == "string" and body.name or "Profil Sans Nom",
                        description = "Profil personnalisé",
                        batch       = (body.batch == true),
                        raw_prompt  = type(body.prompt) == "string" and body.prompt or "",
                    })
                end
                M.close()
            end
        end
    end)

    -- Calculate window position (centered on main screen)
    local screen = hs.screen.mainScreen()
    local f = screen and type(screen.frame) == "function" and screen:frame() or {x = 0, y = 0, w = 1920, h = 1080}
    
    local x = f.x + (f.w - WINDOW_WIDTH) / 2
    local y = f.y + (f.h - WINDOW_HEIGHT) / 2

    local ok_wv, wv = pcall(hs.webview.new, {x = x, y = y, w = WINDOW_WIDTH, h = WINDOW_HEIGHT}, { developerExtrasEnabled = false }, _usercontent)
    if not ok_wv or not wv then
        print("[prompt_editor] Error creating webview.")
        return
    end
    
    _webview = wv
    pcall(function() _webview:windowStyle({"titled", "closable", "utility"}) end)
    pcall(function() _webview:windowTitle(existing and "Modifier le profil" or "Nouveau profil") end)
    pcall(function() _webview:level(hs.drawing.windowLevels.normal) end)
    pcall(function() _webview:allowTextEntry(true) end)

    -- Logic to initialize data once the DOM is ready
    pcall(function()
        _webview:navigationCallback(function(action)
            if action == "didFinishNavigation" then
                local payload = {
                    title  = existing and "Modifier le profil" or "Nouveau profil",
                    name   = default_name,
                    mode   = default_batch and "batch" or "parallel",
                    prompt = default_prompt
                }
                local ok_enc, js_data = pcall(hs.json.encode, payload)
                if ok_enc and js_data then
                    pcall(function() _webview:evaluateJavaScript("init(" .. js_data .. ")") end)
                end
            end
            return true
        end)
    end)

    -- INJECTION: Generate standalone HTML using the ui/ui_builder library
    local final_html = ui_builder.build_injected_html(ASSETS_DIR)
    pcall(function() _webview:html(final_html) end)
    pcall(function() _webview:show() end)
    
    -- Focus management
    pcall(hs.focus)
    hs.timer.doAfter(0.1, function()
        if _webview and type(_webview.hswindow) == "function" then
            local ok_win, win = pcall(function() return _webview:hswindow() end)
            if ok_win and win and type(win.focus) == "function" then 
                pcall(function() win:focus() end)
            end
        end
    end)
end

--- Closes and destroys the Prompt Editor window
function M.close()
    if _webview and type(_webview.delete) == "function" then 
        pcall(function() _webview:delete() end)
    end
    _webview = nil 
end

return M
