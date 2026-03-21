-- ===========================================================================
-- Dynamic hotstrings module.
--
-- Centralises two kinds of runtime expansions:
--
--   1. Interceptor rules (trigger-terminated, computed output):
--      A buffer-suffix + trigger -> string produced by a resolver function.
--      Built-in: "dt" -> current date in dd/mm/yyyy.
--      Extensible: M.add_rule(suffix, section, resolver_fn).
--
--   2. Data-dependent prefix expansions (registered at startup):
--      Typing the first digits/chars of a phone number or SSN expands to
--      the full value. Data is supplied by personal_info module via
--      M.register_personal_data() after it loads its config.
--
-- Appears in the menu as the group "dynamichotstrings" with three toggleable
-- sections: "date", "phoneprefixes", "ssnprefixes".
-- ===========================================================================

local M = {}

-- ==========================================
-- ==========================================
-- ==========================================
-- ========== 1. CONSTANTS & STATE ==========
-- ==========================================
-- ==========================================
-- ==========================================

local GROUP_NAME = "dynamichotstrings"

local _km             = nil          -- Reference to the keymap module
local _trigger        = "\u{2605}"   -- Default trigger character ("★")
local _replacing      = false        -- Lock flag to prevent recursive intercepts

-- Interceptor rules: list of { suffix = string, section = string, resolver = function }
-- suffix   : String that the buffer must end with (before the trigger character arrives)
-- section  : Section name (used to check if the feature is currently enabled by the user)
-- resolver : Function returning the string to be inserted
local _rules = {}

-- Personal data stored to allow replay during the post-load hook.
local _personal_data = nil


-- =================================================
-- =================================================
-- =================================================
-- ========== 2. CONFIGURATION MANAGEMENT ==========
-- =================================================
-- =================================================
-- =================================================

--- Sets the dynamic trigger character used for expansions.
--- @param char string The character to use as the trigger instead of the default.
function M.set_trigger_char(char)
    if type(char) == "string" and char ~= "" then
        _trigger = char
    else
        print("[dynamic_hotstrings] Warning: Invalid trigger character provided. Keeping '" .. _trigger .. "'.")
    end
end


-- ==============================================
-- ==============================================
-- ==============================================
-- ========== 3. KEY INTERCEPTOR ENGINE ==========
-- ==============================================
-- ==============================================
-- ==============================================

--- Intercepts keystrokes to detect suffix + trigger combinations for dynamic resolution.
--- Registered into the keymap's interceptor chain.
--- @param event userdata The Hammerspoon hs.eventtap.event object.
--- @param km_buffer string The current typing buffer maintained by the keymap module.
--- @return string|nil Returns "consume" to swallow the event, or nil to pass it through.
local function interceptor(event, km_buffer)
    -- Prevent processing while we are actively injecting text
    if _replacing or not _km then return nil end

    -- Ignore complex key combinations (Cmd, Ctrl)
    local flags = event:getFlags()
    if flags.cmd or flags.ctrl then return nil end

    -- Only react if the user types the exact trigger character
    local char = event:getCharacters(false) or ""
    if char ~= _trigger then return nil end

    -- Check buffer against registered interceptor rules
    for _, rule in ipairs(_rules) do
        if _km.is_section_enabled(GROUP_NAME, rule.section) then
            local suf = rule.suffix
            
            -- If the buffer ends with the required suffix
            if type(km_buffer) == "string" and #suf > 0 and km_buffer:sub(-(#suf)) == suf then
                local result = rule.resolver()
                
                -- If the resolver successfully produced a replacement string
                if type(result) == "string" and result ~= "" then
                    local n_back = #suf
                    
                    -- Defer the injection slightly to ensure the trigger keystroke is fully caught
                    hs.timer.doAfter(0, function()
                        _replacing = true
                        
                        -- Delete the suffix that triggered the rule
                        for _ = 1, n_back do
                            hs.eventtap.keyStroke({}, "delete", 0)
                        end
                        
                        -- Inject the dynamic output
                        hs.eventtap.keyStrokes(result)
                        
                        -- Release the lock after a safe delay
                        hs.timer.doAfter(0.15, function() _replacing = false end)
                    end)
                    
                    return "consume"
                end
            end
        end
    end

    return nil
end


-- ===================================================
-- ===================================================
-- ===================================================
-- ========== 4. DATA-DEPENDENT EXPANSIONS ==========
-- ===================================================
-- ===================================================
-- ===================================================

--- Generates and registers all prefix-based hotstrings based on the user's personal data.
--- This is called during startup and whenever the group is toggled via the UI.
local function register_prefix_entries()
    if not _km or type(_personal_data) ~= "table" then return end

    local opts = { is_word = false, auto_expand = true, is_case_sensitive = true }
    
    -- Safely extract variables, falling back to empty strings if missing
    local phone  = type(_personal_data.PhoneNumber) == "string" and _personal_data.PhoneNumber or ""
    local fphone = type(_personal_data.PhoneNumberFormatted) == "string" and _personal_data.PhoneNumberFormatted or ""
    local ssn    = type(_personal_data.SocialSecurityNumber) == "string" and _personal_data.SocialSecurityNumber or ""

    _km.set_group_context(GROUP_NAME)

    -- ========================================
    -- ======= 4.1 Phone Prefix Entries =======
    -- ========================================
    if _km.is_section_enabled(GROUP_NAME, "phoneprefixes") then
        if #phone >= 2 then
            -- Trigger: First 2 digits + trigger -> full number (e.g. "07★" -> "0706060606")
            _km.add(phone:sub(1, 2) .. _trigger, phone, opts)
            
            -- Trigger: International prefix + first 2 digits (e.g. "+3307" -> "+330706060606")
            _km.add("+33" .. phone:sub(1, 2), "+33" .. phone, opts)
        end
        if #phone >= 4 then
            -- Trigger: First 4 digits -> full number (e.g. "0706" -> "0706060606")
            _km.add(phone:sub(1, 4), phone, opts)
            -- Trigger: International prefix + next 2 digits (e.g. "+33706" -> "+3307060606")
            _km.add("+33" .. phone:sub(2, 4), "+33" .. phone, opts)
        end
        if #phone >= 6 then
            -- Trigger: Digits 2 to 5 -> full number (e.g. "70606" -> "0706060606")
            _km.add(phone:sub(2, 5), phone, opts)
        end
        
        -- Formatted variants (e.g. "07 06" -> "07 06 06 06 06")
        if #fphone >= 5 then
            _km.add(fphone:sub(1, 5), fphone, opts)
        end
    end

    -- ======================================
    -- ======= 4.2 SSN Prefix Entries =======
    -- ======================================
    if _km.is_section_enabled(GROUP_NAME, "ssnprefixes") then
        if #ssn >= 5 then
            -- Trigger: First 5 digits of SSN -> full SSN
            _km.add(ssn:sub(1, 5), ssn, opts)
        end
    end

    -- Clear the context and sort the mappings so longest triggers evaluate first
    _km.set_group_context(nil)
    _km.sort_mappings()
end


-- ====================================
-- ====================================
-- ====================================
-- ========== 5. PUBLIC API ==========
-- ====================================
-- ====================================
-- ====================================

--- Adds a custom interceptor rule for runtime evaluation.
--- @param suffix string The string sequence that must immediately precede the trigger character.
--- @param section string The UI section name linking this rule to a toggleable menu item.
--- @param resolver function A callback function that returns the string to insert.
function M.add_rule(suffix, section, resolver)
    if type(suffix) ~= "string" or type(section) ~= "string" or type(resolver) ~= "function" then
        print("[dynamic_hotstrings] Error: Invalid arguments passed to add_rule.")
        return
    end
    table.insert(_rules, { suffix = suffix, section = section, resolver = resolver })
end

--- Registers personal data required for prefix-based expansions (Phone, SSN, etc.).
--- Called by init.lua to maintain loose coupling between modules.
--- @param personal_data table Dictionary containing personal information.
--- @param trigger_char string|nil The global trigger character to apply.
function M.register_personal_data(personal_data, trigger_char)
    _personal_data = personal_data
    if trigger_char then M.set_trigger_char(trigger_char) end
    register_prefix_entries()
end

--- Initialises the dynamic hotstrings module, wiring it into the keymap engine.
--- @param keymap_module table The active keymap module reference.
function M.start(keymap_module)
    if type(keymap_module) ~= "table" then
        print("[dynamic_hotstrings] Error: keymap_module is required to start.")
        return
    end
    
    _km = keymap_module

    -- Built-in date rule (output computed at expansion time)
    M.add_rule("dt", "date", function() return os.date("%d/%m/%Y") end)

    -- Register the group in the keymap module so the UI menu can build the toggle lists.
    -- Menu labels and descriptions are generated dynamically to display the correct trigger character.
    local sections = {
        { name = "date",          description = "dt" .. _trigger .. " insère la date courante (jj/mm/aaaa)" },
        { name = "phoneprefixes", description = "Saisir les premiers chiffres du numéro de téléphone le complète automatiquement" },
        { name = "ssnprefixes",   description = "Saisir les premiers chiffres du numéro de sécurité sociale le complète automatiquement" },
    }
    
    keymap_module.register_lua_group(
        GROUP_NAME,
        "Hotstrings dynamiques",
        sections
    )

    -- Post-load hook: ensures prefix triggers are injected properly 
    -- if the user toggles the feature off and back on via the menu.
    keymap_module.set_post_load_hook(GROUP_NAME, function()
        register_prefix_entries()
    end)

    -- Register our interceptor function into the keymap's event lifecycle.
    keymap_module.register_interceptor(interceptor)

    -- Provide dynamic preview text for the tooltip UI (if supported by keymap)
    if type(keymap_module.register_preview_provider) == "function" then
        keymap_module.register_preview_provider(function(buf)
            if type(buf) ~= "string" then return nil end
            
            for _, rule in ipairs(_rules) do
                if _km and _km.is_section_enabled(GROUP_NAME, rule.section) then
                    local suf = rule.suffix
                    if #suf > 0 and buf:sub(-(#suf)) == suf then
                        return rule.resolver()
                    end
                end
            end
            return nil
        end)
    end

    print("[dynamic_hotstrings] Started — group: " .. GROUP_NAME)
end

return M
