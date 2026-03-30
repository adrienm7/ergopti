--- modules/dynamic_hotstrings/personal_info.lua

--- ==============================================================================
--- MODULE: Personal Info Tracker
--- DESCRIPTION:
--- Monitors typed characters and expands  @<letters><trigger>  into
--- tab-separated personal-information values.
---
--- FEATURES & RATIONALE:
--- 1. Single Tap Integration: Registers an interceptor directly inside keymap's keyDown tap.
--- 2. Conflict Avoidance: Runs BEFORE backspace, escape, and hotstring matching.
--- ==============================================================================

local M = {}

local hs       = hs
local eventtap = hs.eventtap
local timer    = hs.timer

local ok_editor, ui_editor = pcall(require, "ui.personal_info_editor")
if not ok_editor then ui_editor = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local STATE_IDLE       = "idle"
local STATE_COLLECTING = "collecting"

local _enabled   = false
local _replacing = false
local _state     = STATE_IDLE
local _combo     = ""

local _trigger   = "★"
local _info      = {}
local _letters   = {}
local _base_dir  = ""

local _keymap    = nil

local DEFAULT_CONFIG = {
    trigger_char = "★",
    info = {
        FirstName            = "Prénom",
        LastName             = "Nom",
        DateOfBirth          = "01/01/1990",
        EmailAddress         = "prenom.nom@exemple.fr",
        WorkEmailAddress     = "prenom.nom@entreprise.fr",
        PhoneNumber          = "0600000000",
        PhoneNumberFormatted = "06 00 00 00 00",
        StreetAddress        = "1 Rue de la Paix",
        City                 = "Paris",
        Country              = "France",
        PostalCode           = "75001",
        IBAN                 = "FR00 0000 0000 0000 0000 0000 000",
        BIC                  = "ABCDFRPP",
        CreditCard           = "0000 0000 0000 0000",
        SocialSecurityNumber = "0 00 00 00 000 000 00",
    },
    letters = {
        a = "StreetAddress",
        b = "BIC",
        c = "CreditCard",
        d = "DateOfBirth",
        e = "EmailAddress",
        f = "PhoneNumberFormatted",
        i = "IBAN",
        m = "EmailAddress",
        n = "LastName",
        p = "FirstName",
        s = "SocialSecurityNumber",
        t = "PhoneNumber",
        w = "WorkEmailAddress",
    },
}





-- ===========================================
-- ===========================================
-- ======= 2/ Configuration Management =======
-- ===========================================
-- ===========================================

--- Reads the "personal_info_config" key from config.json.
--- @param base_dir string Base directory where config.json resides.
--- @return table The loaded or default configuration.
local function load_config(base_dir)
    local path = base_dir .. "config.json"
    local ok, raw = pcall(hs.json.read, path)
    
    if ok and type(raw) == "table" and type(raw["personal_info_config"]) == "table" then
        return raw["personal_info_config"]
    end
    
    print("[personal_info] No personal_info_config in config.json — using defaults")
    return DEFAULT_CONFIG
end

--- Persists updated info fields into config.json.
--- @param new_info table The updated fields to save.
function M.save_info(new_info)
    if type(new_info) ~= "table" then return end
    
    local path = _base_dir .. "config.json"
    local ok, raw = pcall(hs.json.read, path)
    
    if not ok or type(raw) ~= "table" then raw = {} end
    if type(raw["personal_info_config"]) ~= "table" then
        raw["personal_info_config"] = {
            trigger_char = _trigger,
            letters      = _letters,
            info         = {},
        }
    end
    
    for k, v in pairs(new_info) do
        raw["personal_info_config"]["info"][k] = v
    end
    
    local ok_enc, encoded = pcall(function() return hs.json.encode(raw) end)
    if ok_enc and encoded then
        local fh = io.open(path, "w")
        if fh then fh:write(encoded); fh:close() end
    end
    
    _info = raw["personal_info_config"]["info"]
    print("[personal_info] Config saved")
end





-- ====================================
-- ====================================
-- ======= 3/ Engine Operations =======
-- ====================================
-- ====================================

--- Resolves accumulated letters into actual mapped strings.
--- @param combo string Sequence of typed letters.
--- @return table List of strings resolved from the letters.
local function resolve_combo(combo)
    local parts = {}
    if type(combo) ~= "string" then return parts end
    
    for i = 1, #combo do
        local letter = combo:sub(i, i)
        local key    = _letters[letter]
        if key and _info[key] then
            table.insert(parts, _info[key])
        end
    end
    return parts
end

--- Performs the actual injection of the requested data.
--- @param combo string Sequence of typed letters corresponding to the data.
local function do_expand(combo)
    local n_back = 1 + #combo
    local parts  = resolve_combo(combo)

    _replacing = true

    if _keymap and type(_keymap.suppress_rescan) == "function" then
        _keymap.suppress_rescan()
    end

    for _ = 1, n_back do
        eventtap.keyStroke({}, "delete", 0)
    end
    
    for i, value in ipairs(parts) do
        eventtap.keyStrokes(value)
        if i < #parts then
            eventtap.keyStroke({}, "tab", 0)
        end
    end

    timer.doAfter(0.15, function()
        _replacing = false
    end)
end





-- =========================================
-- =========================================
-- ======= 4/ Key Interceptor Engine =======
-- =========================================
-- =========================================

--- Intercepts keystrokes to detect prefix + trigger combinations for dynamic resolution.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param _km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or "suppress" to block hotstrings.
local function interceptor(event, _km_buffer)
    if not _enabled then return nil end
    if _replacing then return nil end

    local flags = event:getFlags()
    if flags.cmd or flags.ctrl then
        _state = STATE_IDLE
        _combo = ""
        return nil
    end

    local kc = event:getKeyCode()

    if kc == 53 or kc == 36 or kc == 76 or (kc >= 123 and kc <= 126) then
        _state = STATE_IDLE
        _combo = ""
        return nil
    end

    if kc == 51 then
        if _state == STATE_COLLECTING then
            if #_combo > 0 then
                _combo = _combo:sub(1, -2)
            else
                _state = STATE_IDLE
            end
        end
        return nil
    end

    local char = event:getCharacters(false) or ""
    if char == "" then return nil end

    if _state == STATE_IDLE then
        if char == "@" then
            local full_trigger = (_km_buffer or "") .. "@"
            if _keymap then
                local exact = (_keymap.has_exact_trigger and _keymap.has_exact_trigger(full_trigger)) or false
                local pref  = (_keymap.has_trigger_prefix and _keymap.has_trigger_prefix(full_trigger)) or false
                local suff  = (_keymap.has_trigger_suffix and _keymap.has_trigger_suffix(full_trigger)) or false
                
                if exact or pref or suff then
                    return nil
                end
            end

            _state = STATE_COLLECTING
            _combo = ""
            return nil
        end
        return nil
    end

    if _state == STATE_COLLECTING then
        if char == _trigger then
            if #_combo > 0 and #resolve_combo(_combo) > 0 then
                local combo = _combo
                
                local full_trigger = "@" .. combo .. _trigger
                if _keymap and _keymap.has_exact_trigger
                        and _keymap.has_exact_trigger(full_trigger)
                        and full_trigger:sub(1, 1) == "@" then
                    _state = STATE_IDLE
                    _combo = ""
                    return nil
                end
                
                _state = STATE_IDLE
                _combo = ""
                
                timer.doAfter(0, function() do_expand(combo) end)
                return "consume"
            end
            
            _state = STATE_IDLE
            _combo = ""
            return nil
        end

        if char:match("^[a-z]$") then
            _combo = _combo .. char
            return nil
        end

        _state = STATE_IDLE
        _combo = ""
        return nil
    end

    return nil
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

function M.get_info()         return _info    end
function M.get_trigger_char() return _trigger end

--- Opens the browser-based HTML form using the extracted UI module.
function M.open_editor()
    if ui_editor and type(ui_editor.open) == "function" then
        ui_editor.open(_info, M.save_info)
    else
        print("[personal_info] Error: UI editor module is not available")
    end
end

--- Initializes the module, wiring it into the keymap engine.
--- @param base_dir string Base configuration directory.
--- @param keymap_module table The active keymap module reference.
function M.start(base_dir, keymap_module)
    if type(base_dir) == "string" then _base_dir = base_dir end

    local config = load_config(_base_dir)
    if type(config) ~= "table" then
        print("[personal_info] Module disabled (config missing or invalid)")
        return
    end

    _trigger = tostring(config.trigger_char or "★")
    _info    = type(config.info) == "table" and config.info or {}
    _letters = type(config.letters) == "table" and config.letters or {}

    _state     = STATE_IDLE
    _combo     = ""
    _replacing = false
    _enabled   = true
    
    if type(keymap_module) == "table" then
        _keymap = keymap_module
    end

    if _keymap and type(_keymap.register_interceptor) == "function" then
        _keymap.register_interceptor(interceptor)
    end

    if _keymap and type(_keymap.register_preview_provider) == "function" then
        _keymap.register_preview_provider(function(buf)
            if not _enabled or type(buf) ~= "string" then return nil end
            
            local match = buf:match("@([a-z]+)$")
            if match then
                local parts = resolve_combo(match)
                if #parts > 0 then
                    return table.concat(parts, " ⇥ ")
                end
            end
            return nil
        end)
    end
end

function M.enable()  _enabled = true; _state = STATE_IDLE; _combo = "" end
function M.disable() _enabled = false; _state = STATE_IDLE; _combo = "" end

return M
