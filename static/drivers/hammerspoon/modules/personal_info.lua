-- modules/personal_info.lua

-- ===========================================================================
-- Personal information shortcuts for Hammerspoon.
--
-- Monitors typed characters and expands  @<letters><trigger>  into
-- tab-separated personal-information values.
--
-- Architecture: instead of a separate eventtap (which would compete with
-- keymap’s tap for event ordering), this module registers an *interceptor*
-- directly inside keymap’s single keyDown tap via keymap.register_interceptor().
-- The interceptor runs BEFORE backspace, escape, getCharacters(false) and all
-- hotstring matching — ensuring that Unicode trigger chars like ★ are caught
-- even when getCharacters(false) returns "".
--
-- Interceptor return values:
--   "consume"  → keymap returns true  (★ is consumed, suppresses apps + hotstrings)
--   "suppress" → keymap returns false (letter appears in field, hotstrings skipped)
--   nil        → normal keymap processing
--
-- Example (default config):
--   @np★  →  Nom [Tab] Prénom
--   @e★   →  prenom.nom@mail.fr
--   @npa★ →  Nom [Tab] Prénom [Tab] 1 Rue de la Paix
-- ===========================================================================

local M = {}

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
local STATE_COLLECTING = "collecting"  -- after @ has been typed

local _enabled   = false
local _replacing = false
local _state     = STATE_IDLE
local _combo     = ""   -- letters accumulated after @

-- Config (populated by start()).
local _trigger   = "★"
local _info      = {}
local _letters   = {}
local _base_dir  = ""

-- Reference to the keymap module, stored at start() time so that the
-- interceptor can query M.has_exact_trigger() and yield priority to
-- explicitly registered TOML shortcuts (e.g. "@am★").
local _keymap    = nil



-- ===============================
-- ===== 1.1) Default Config =====
-- ===============================

-- Built-in defaults — used when config.json has no "personal_info_config" key.
-- Users can override by adding a "personal_info_config" section to config.json.
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

--- Reads the "personal_info_config" key from config.json (shared config file).
--- Falls back to DEFAULT_CONFIG so the module always starts with sensible values.
--- @param base_dir string Base directory where config.json resides
--- @return table The loaded or default configuration
local function load_config(base_dir)
    local path = base_dir .. "config.json"
    local raw  = hs.json.read(path)
    
    if type(raw) == "table" and type(raw["personal_info_config"]) == "table" then
        return raw["personal_info_config"]
    end
    
    -- config.json absent or has no personal_info_config key: use built-in defaults.
    print("[personal_info] No personal_info_config in config.json — using defaults.")
    return DEFAULT_CONFIG
end





-- ====================================
-- ====================================
-- ======= 3/ Engine Operations =======
-- ====================================
-- ====================================

--- Resolves accumulated letters into actual mapped strings
--- @param combo string Sequence of typed letters
--- @return table List of strings resolved from the letters
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

--- Performs the actual injection of the requested data
--- Runs asynchronously so keymap’s tap can return immediately
--- @param combo string Sequence of typed letters corresponding to the data
local function do_expand(combo)
    -- At expansion time, the field contains: ...@<combo>
    -- The ★ was consumed by the interceptor so it is NOT in the field.
    -- We delete: @ (1) + #combo ASCII letters.
    local n_back = 1 + #combo
    local parts  = resolve_combo(combo)

    _replacing = true

    -- Suppress keymap hotstring re-scanning before emitting synthetic events,
    -- so the expanded text (e.g. an e-mail containing "axa") is never
    -- re-matched by another hotstring during or after the emission.
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
--- Registered into the keymap’s interceptor chain.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param _km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or "suppress" to block hotstrings.
local function interceptor(event, _km_buffer)
    -- Module disabled (toggled off from menu): pass everything through.
    if not _enabled then return nil end
    
    -- While we are sending synthetic events, pass everything through.
    if _replacing then return nil end

    local flags = event:getFlags()
    if flags.cmd or flags.ctrl then
        _state = STATE_IDLE
        _combo = ""
        return nil
    end

    local kc = event:getKeyCode()

    -- Esc / Return / Enter / arrows → abort combo.
    if kc == 53 or kc == 36 or kc == 76 or (kc >= 123 and kc <= 126) then
        _state = STATE_IDLE
        _combo = ""
        return nil
    end

    -- Backspace: pop last accumulated letter, or cancel @ if combo is empty.
    if kc == 51 then
        if _state == STATE_COLLECTING then
            if #_combo > 0 then
                _combo = _combo:sub(1, -2)
            else
                _state = STATE_IDLE
            end
        end
        return nil  -- keymap handles backspace normally
    end

    -- Use getCharacters(false) as primary source — this mirrors what keymap
    -- uses to build its buffer and correctly resolves Karabiner-remapped
    -- Unicode characters like ★ (where getCharacters(true) would return
    -- the underlying physical key name "j" instead of "★").
    local char = event:getCharacters(false) or ""
    if char == "" then return nil end



    -- =====================================
    -- ===== 4.1) IDLE: watch for "@" ======
    -- =====================================
    
    -- Return "suppress" when @ is typed so no hotstring can ever fire on @.
    if _state == STATE_IDLE then
        if char == "@" then
            -- If an explicit TOML trigger matches the buffer + "@",
            -- yield to keymap so that exact shortcuts like "<@" are
            -- handled by the TOML mapping instead of starting a
            -- personal-info combo collection.
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
            return "suppress"  -- @ appears in field, hotstrings blocked
        end
        return nil
    end



    -- ========================================================
    -- ===== 4.2) COLLECTING: watch for letters & trigger =====
    -- ========================================================
    
    -- While collecting a combo, ALL characters suppress hotstring matching
    -- so the accumulated @<letters> never accidentally triggers an expansion.
    if _state == STATE_COLLECTING then
        
        -- Trigger character → attempt expansion.
        if char == _trigger then
            if #_combo > 0 and #resolve_combo(_combo) > 0 then
                local combo = _combo
                
                -- Check whether an explicit TOML shortcut covers this exact
                -- trigger (e.g. "@am★").  Only yield when the TOML trigger
                -- starts with "@" so that bare hotstrings like "am★" can never
                -- steal priority from an @-combo expansion.
                -- NOTE: the chars @<combo> were already added to keymap’s buffer
                -- by the earlier "suppress" returns, so NO injection is needed.
                -- Returning nil lets keymap append ★ and match "@am★" directly.
                local full_trigger = "@" .. combo .. _trigger
                if _keymap and _keymap.has_exact_trigger
                        and _keymap.has_exact_trigger(full_trigger)
                        and full_trigger:sub(1, 1) == "@" then
                    _state = STATE_IDLE
                    _combo = ""
                    return nil  -- let TOML @-mapping win
                end
                
                _state = STATE_IDLE
                _combo = ""
                
                -- Defer so keymap’s tap finishes returning "consume" first.
                timer.doAfter(0, function() do_expand(combo) end)
                return "consume"  -- swallow ★, prevent hotstring matching
            end
            
            -- Trigger with no matching combo → let it pass and reset.
            _state = STATE_IDLE
            _combo = ""
            return nil
        end

        -- Lowercase ASCII letter → accumulate.
        if char:match("^[a-z]$") then
            _combo = _combo .. char
            return "suppress"  -- letter appears in field, hotstrings blocked
        end

        -- Anything else → abort combo; suppress to prevent the accumulated
        -- @<letters> from feeding a deferred hotstring expansion.
        _state = STATE_IDLE
        _combo = ""
        return "suppress"
    end

    return nil
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

--- Returns the loaded info table (used by init.lua to pass data to dynamic_hotstrings)
function M.get_info()
    return _info
end

--- Returns the trigger character loaded from config.
function M.get_trigger_char()
    return _trigger
end

--- Persists updated info fields into config.json under "personal_info_config.info".
--- Only the keys present in new_info are updated; other keys are preserved.
--- @param new_info table The updated fields to save
function M.save_info(new_info)
    if type(new_info) ~= "table" then return end
    
    local path = _base_dir .. "config.json"
    local raw  = hs.json.read(path)
    
    if type(raw) ~= "table" then raw = {} end
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
    
    local ok, encoded = pcall(function() return hs.json.encode(raw) end)
    if ok and encoded then
        local fh = io.open(path, "w")
        if fh then fh:write(encoded); fh:close() end
    end
    
    -- Update live state so expansions use the new values immediately.
    _info = raw["personal_info_config"]["info"]
    print("[personal_info] Config saved.")
end

--- Opens the browser-based HTML form using the extracted UI module
function M.open_editor()
    if ui_editor and type(ui_editor.open) == "function" then
        ui_editor.open(_info, M.save_info)
    else
        print("[personal_info] Error: UI editor module is not available.")
    end
end

--- Initializes the module, wiring it into the keymap engine.
--- @param base_dir string Base configuration directory
--- @param keymap_module table The active keymap module reference
function M.start(base_dir, keymap_module)
    if type(base_dir) == "string" then _base_dir = base_dir end

    local config = load_config(_base_dir)
    if type(config) ~= "table" then
        print("[personal_info] Module disabled (config missing or invalid).")
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
        _keymap = keymap_module  -- Store for TOML-priority lookup
    end

    -- Register interceptor once; subsequent enable/disable only flip _enabled.
    if _keymap and type(_keymap.register_interceptor) == "function" then
        _keymap.register_interceptor(interceptor)
        print("[personal_info] Interceptor registered in keymap.")
    else
        print("[personal_info] WARNING: keymap_module not provided or missing register_interceptor.")
    end

    if _keymap and type(_keymap.register_preview_provider) == "function" then
        _keymap.register_preview_provider(function(buf)
            if not _enabled or type(buf) ~= "string" then return nil end
            
            -- Search for "@" followed by ascii letters at the very end of the buffer
            local match = buf:match("@([a-z]+)$")
            if match then
                local parts = resolve_combo(match)
                if #parts > 0 then
                    -- Use a visual symbol to represent tabulations (\t) in the preview
                    return table.concat(parts, " ⇥ ")
                end
            end
            return nil
        end)
    end

    local letter_count = 0
    for _ in pairs(_letters) do letter_count = letter_count + 1 end
    print(string.format("[personal_info] Started — trigger: %s, %d letter(s) mapped.", _trigger, letter_count))
end

--- Enables interceptor processing (used by menu UI toggles)
function M.enable()
    _state     = STATE_IDLE
    _combo     = ""
    _replacing = false
    _enabled   = true
    print("[personal_info] Enabled.")
end

--- Disables interceptor processing (used by menu UI toggles)
function M.disable()
    _enabled   = false
    _state     = STATE_IDLE
    _combo     = ""
    _replacing = false
    print("[personal_info] Disabled.")
end

function M.stop()
    M.disable()
end

function M.is_enabled()
    return _enabled
end

return M
