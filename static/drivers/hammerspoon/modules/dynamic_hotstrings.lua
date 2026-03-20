-- Dynamic hotstrings module.
--
-- Centralises two kinds of runtime expansions:
--
--   1. Interceptor rules (★-terminated, computed output):
--      A buffer-suffix + ★ → string produced by a resolver function.
--      Built-in: "dt" → current date in dd/mm/yyyy.
--      Extensible: M.add_rule(suffix, section, resolver_fn).
--
--   2. Data-dependent prefix expansions (keymap.add at startup):
--      Typing the first digits/chars of a phone number or SSN expands to
--      the full value.  Data is supplied by personal_info via
--      M.register_personal_data() after it loads its config.
--
-- Appears in the menu as the group "dynamichotstrings" with three toggleable
-- sections: "date", "phoneprefixes", "ssnprefixes".

local M = {}

local GROUP_NAME = "dynamichotstrings"

-- Section descriptors (defines menu order and labels).
local SECTIONS = {
	{ name = "date",          description = "dt★ insère la date courante (jj/mm/aaaa)" },
	{ name = "phoneprefixes", description = "Saisir les premiers chiffres du numéro de téléphone le complète automatiquement" },
	{ name = "ssnprefixes",   description = "Saisir les premiers chiffres du numéro de sécurité sociale le complète automatiquement" },
}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local _km             = nil   -- keymap module reference
local _trigger        = "\u{2605}"
local _replacing      = false

-- Interceptor rules: list of { suffix, section, resolver }.
-- suffix   : string that the buffer must end with (before ★ arrives)
-- section  : section name in SECTIONS (used to check enable state)
-- resolver : function() → string to insert
local _rules = {}

-- Personal data stored for post_load_hook replay.
local _personal_data = nil

-- ---------------------------------------------------------------------------
-- Interceptor (registered into keymap's chain via register_interceptor)
-- ---------------------------------------------------------------------------
local function interceptor(event, km_buffer)
	if _replacing then return nil end

	local flags = event:getFlags()
	if flags.cmd or flags.ctrl then return nil end

	local char = event:getCharacters(false) or ""
	if char ~= _trigger then return nil end

	for _, rule in ipairs(_rules) do
		if _km.is_section_enabled(GROUP_NAME, rule.section) then
			local suf = rule.suffix
			if #suf > 0 and km_buffer:sub(-(#suf)) == suf then
				local result = rule.resolver()
				if result then
					local n_back = #suf
					hs.timer.doAfter(0, function()
						_replacing = true
						for _ = 1, n_back do
							hs.eventtap.keyStroke({}, "delete", 0)
						end
						hs.eventtap.keyStrokes(result)
						hs.timer.doAfter(0.15, function() _replacing = false end)
					end)
					return "consume"
				end
			end
		end
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Phone / SSN prefix registration (called both on start and from hook)
-- ---------------------------------------------------------------------------
local function register_prefix_entries()
	if not _km or not _personal_data then return end

	local opts  = { is_word = false, auto_expand = true, is_case_sensitive = true }
	local phone  = _personal_data.PhoneNumber          or ""
	local fphone = _personal_data.PhoneNumberFormatted  or ""
	local ssn    = _personal_data.SocialSecurityNumber  or ""

	_km.set_group_context(GROUP_NAME)

	-- ── Phone prefix expansions ──────────────────────────────────────────────
	if _km.is_section_enabled(GROUP_NAME, "phoneprefixes") then
		if #phone >= 2 then
			-- XX★ → full number  (e.g. "07★" → "0706060606")
			_km.add(phone:sub(1, 2) .. _trigger, phone, opts)
			-- International-prefix variant  (e.g. "+3307" → "+330706060606")
			_km.add("+33" .. phone:sub(1, 2), "+33" .. phone, opts)
		end
		if #phone >= 4 then
			_km.add(phone:sub(1, 4), phone, opts)                          -- "0706"
			_km.add("+33" .. phone:sub(2, 4), "+33" .. phone, opts)       -- "+33706"
		end
		if #phone >= 6 then
			_km.add(phone:sub(2, 5), phone, opts)                          -- "70606"
		end
		-- Formatted variants (e.g. "07 06" → "07 06 06 06 06")
		if #fphone >= 5 then
			_km.add(fphone:sub(1, 5), fphone, opts)
		end
	end

	-- ── SSN prefix expansion ─────────────────────────────────────────────────
	if _km.is_section_enabled(GROUP_NAME, "ssnprefixes") then
		if #ssn >= 5 then
			_km.add(ssn:sub(1, 5), ssn, opts)
		end
	end

	_km.set_group_context(nil)
	_km.sort_mappings()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Add a custom interceptor rule (for future extensibility).
-- suffix   : string that must appear at end of buffer before ★ is pressed
-- section  : section name in GROUP_NAME (must already exist in SECTIONS or
--            added before M.start() via a custom sections list)
-- resolver : function() → string   (called at expansion time)
function M.add_rule(suffix, section, resolver)
	table.insert(_rules, { suffix = suffix, section = section, resolver = resolver })
end

-- Register personal data used for phone / SSN prefix expansions.
-- Called by init.lua after personal_info.start() to keep the two modules
-- decoupled (dynamic_hotstrings does not import personal_info).
-- personal_data : table with at least PhoneNumber, PhoneNumberFormatted,
--                 SocialSecurityNumber keys.
-- trigger_char  : the ★ character from personal_info_config (default "★").
function M.register_personal_data(personal_data, trigger_char)
	_personal_data = personal_data
	_trigger       = trigger_char or "\u{2605}"
	register_prefix_entries()
end

-- Initialise the module.
-- keymap_module : the loaded keymap module (required).
function M.start(keymap_module)
	_km = keymap_module

	-- Built-in date rule (output computed at expansion time).
	M.add_rule("dt", "date", function() return os.date("%d/%m/%Y") end)

	-- Register the group in keymap so the menu can display and toggle it.
	local sections = {}
	for _, s in ipairs(SECTIONS) do
		-- count is intentionally omitted: these sections are generated at runtime
		-- so no static count is available; menu.lua will hide the "(N)" badge.
		table.insert(sections, { name = s.name, description = s.description })
	end
	keymap_module.register_lua_group(
		GROUP_NAME,
		"Hotstrings dynamiques",
		sections
	)

	-- Post-load hook: re-register prefix entries when the group is re-enabled
	-- after a disable_group() / enable_group() cycle (e.g. section toggle).
	keymap_module.set_post_load_hook(GROUP_NAME, function()
		register_prefix_entries()
	end)

	-- Register the interceptor into keymap's chain.
	keymap_module.register_interceptor(interceptor)

    if keymap_module.register_preview_provider then
            keymap_module.register_preview_provider(function(buf)
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
