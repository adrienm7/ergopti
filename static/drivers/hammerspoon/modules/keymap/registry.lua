--- modules/keymap/registry.lua

--- ==============================================================================
--- MODULE: Keymap Registry
--- DESCRIPTION:
--- Handles the storage, sorting, and lookup of hotstring mappings, groups,
--- terminators, and sections. All persistent enable/disable state is stored
--- in hs.settings so it survives Hammerspoon reloads without writing to disk.
---
--- FEATURES & RATIONALE:
--- 1. Data Isolation: Keeps heavy lookup tables and file-loading logic out of
---    the main event loop in init.lua.
--- 2. File Loading: Parses both TOML and Lua files to populate the mapping
---    database at startup and whenever a group is toggled.
--- 3. Smart Casing: Auto-generates lowercase, Title Case, and UPPERCASE
---    variants for every hotstring so the expansion matches the user's casing.
--- ==============================================================================

local M = {}

local hs         = hs
local text_utils = require("lib.text_utils")
local km_utils   = require("modules.keymap.utils")
local Logger     = require("lib.logger")

local LOG    = "keymap.registry"
local _state = nil  -- Injected via M.init(); required before all public functions.

-- Deferred-sort machinery. When _sort_deferred is true, sort_mappings() becomes
-- a no-op that only sets _sort_pending; flush_sort() then performs exactly one
-- final sort. Used at startup so the 6 TOML loads sort only once together.
local _sort_deferred = false
local _sort_pending  = false


--- Guard: verifies that M.init() was called before any public function that
--- accesses _state. Logs an error and returns false when the guard fails.
--- @param func_name string Name of the calling function (for error messages).
--- @return boolean True if _state is ready, false otherwise.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end


--- Returns the last UTF-8 codepoint of a string, used to bucket mappings by
--- tail character for O(1) lookup on keystroke. Falls back to the last byte
--- on malformed UTF-8 so the resulting index is always non-empty.
--- @param s string The input string.
--- @return string The last UTF-8 character, or "" when s is empty.
local function tail_codepoint(s)
	if type(s) ~= "string" or s == "" then return "" end
	local ok, off = pcall(utf8.offset, s, -1)
	if ok and off then return s:sub(off) end
	return s:sub(-1)
end




-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

--- Built-in terminator definitions. Each entry with a key produces one entry
--- in the enable/disable table. Separators (type = "separator") are UI-only.
M.TERMINATOR_DEFS = {
	{ key = "space",                chars = { " " },          label = "␣ : Espace",                   default_enabled = true },
	{ key = "nbsp",                 chars = { "\u{00A0}" },   label = "⍽ : Espace insécable",         default_enabled = true },
	{ key = "nnbsp",                chars = { "\u{202F}" },   label = "⍽ : Espace fine insécable",    default_enabled = true },
	{ key = "minus",                chars = { "-" },          label = "- : Tiret",                    default_enabled = false },
	{ key = "underscore",           chars = { "_" },          label = "_ : Tiret bas",                default_enabled = false },
	{ type = "separator" },
	{ key = "tab",                  chars = { "\t" },         label = "⇥ : Tabulation",               default_enabled = false },
	{ key = "enter",                chars = { "\r", "\n" },   label = "⏎ : Entrée",                   default_enabled = false },
	{ key = "star",                 chars = { "★" },          label = "★ : Touche magique",           default_enabled = true, consume = true },
	{ type = "separator" },
	{ key = "comma",                chars = { "," },          label = ", : Virgule",                  default_enabled = true },
	{ key = "period",               chars = { "." },          label = ". : Point",                    default_enabled = false },
	{ key = "exclam",               chars = { "!" },          label = "! : Point d'exclamation",      default_enabled = false },
	{ key = "question",             chars = { "?" },          label = "? : Point d'interrogation",    default_enabled = false },
	{ key = "colon",                chars = { ":" },          label = ": : Deux-points",              default_enabled = false },
	{ type = "separator" },
	{ key = "parenright",           chars = { ")" },          label = ") : Parenthèse fermante",      default_enabled = false },
	{ key = "braceright",           chars = { "}" },          label = "} : Accolade fermante",        default_enabled = false },
	{ key = "bracketright",         chars = { "]" },          label = "] : Crochet fermant",          default_enabled = false },
	{ key = "anglebracketright",    chars = { ">" },          label = "> : Guillemet fermant",        default_enabled = false },
	{ type = "separator" },
	{ key = "apostrophe_typo",      chars = { "'" },          label = "' : Apostrophe typographique", default_enabled = false },
	{ key = "apostrophe_straight",  chars = { "'" },          label = "' : Apostrophe droite",        default_enabled = false },
	{ key = "quote",                chars = { '"' },          label = '" : Guillemet double',         default_enabled = false },
	{ key = "equal",                chars = { "=" },          label = "= : Égal",                     default_enabled = false },
	{ key = "slash",                chars = { "/" },          label = "/ : Slash",                    default_enabled = false },
	{ key = "backslash",            chars = { "\\" },         label = "\\ : Backslash",               default_enabled = false },
}

-- Flat enable/disable table keyed by terminator key, seeded from default_enabled.
local _terminator_enabled = {}
for _, def in ipairs(M.TERMINATOR_DEFS) do
	if def.key then
		_terminator_enabled[def.key] = (def.default_enabled ~= false)
	end
end




-- =======================================
-- =======================================
-- ======= 2/ Terminator Utilities =======
-- =======================================
-- =======================================

--- Updates the magic-key label in the terminator definitions.
--- Called whenever the user changes the trigger character.
--- @param magic_key string The new trigger character.
local function update_terminator_magic_key(magic_key)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == "star" then
			def.chars = { magic_key }
			def.label = magic_key .. " : Touche magique"
		end
	end
end

--- Returns true if `chars` matches an enabled terminator.
--- @param chars string The typed character(s) to check.
--- @return boolean
function M.is_terminator(chars)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key and _terminator_enabled[def.key] and def.chars then
			for _, c in ipairs(def.chars) do
				if chars == c then return true end
			end
		end
	end
	return false
end

--- Returns true if `chars` matches an enabled terminator that should be consumed
--- (i.e., not re-typed after the expansion fires).
--- @param chars string The typed character(s) to check.
--- @return boolean
function M.terminator_is_consumed(chars)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key and _terminator_enabled[def.key] and def.consume and def.chars then
			for _, c in ipairs(def.chars) do
				if chars == c then return true end
			end
		end
	end
	return false
end

--- Enables or disables a terminator by key.
--- @param key string The terminator key identifier.
--- @param en boolean True to enable, false to disable.
function M.set_terminator_enabled(key, en)
	_terminator_enabled[key] = (en ~= false)
	Logger.debug(LOG, "Terminator '%s': %s.", key, en and "enabled" or "disabled")
end

--- Returns true if the given terminator key is currently enabled.
--- @param key string The terminator key identifier.
--- @return boolean
function M.is_terminator_enabled(key)
	return _terminator_enabled[key] ~= false
end

--- Returns the full terminator definitions table (by reference — do not mutate).
--- @return table
function M.get_terminator_defs()
	return M.TERMINATOR_DEFS
end

--- Adds or updates a user-defined terminator.
--- Idempotent: calling with the same key updates the existing definition in place.
--- @param key string Unique identifier (e.g. "custom_dot").
--- @param char string The trigger character.
--- @param label string Human-readable label shown in the menu.
--- @param consume boolean Whether to swallow the character after expansion.
function M.add_custom_terminator(key, char, label, consume)
	if type(key) ~= "string" or type(char) ~= "string" then
		Logger.error(LOG, "add_custom_terminator: invalid key or char (key='%s', char='%s').",
			tostring(key), tostring(char))
		return
	end
	-- Update in place if the key already exists (idempotent on reload).
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == key then
			def.chars   = { char }
			def.label   = label
			def.consume = consume or false
			Logger.debug(LOG, "Custom terminator '%s' updated.", key)
			return
		end
	end
	table.insert(M.TERMINATOR_DEFS, {
		key             = key,
		chars           = { char },
		label           = label,
		consume         = consume or false,
		default_enabled = true,
		custom          = true,
	})
	_terminator_enabled[key] = true
	Logger.info(LOG, "Custom terminator '%s' added.", key)
end

--- Removes a user-defined terminator (no-op on built-in terminators).
--- @param key string The unique identifier of the terminator to remove.
function M.remove_custom_terminator(key)
	for i, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == key and def.custom then
			table.remove(M.TERMINATOR_DEFS, i)
			_terminator_enabled[key] = nil
			Logger.info(LOG, "Custom terminator '%s' removed.", key)
			return
		end
	end
	Logger.warn(LOG, "remove_custom_terminator: key '%s' not found or not custom.", tostring(key))
end




-- ======================================
-- ======================================
-- ======= 3/ Database Management =======
-- ======================================
-- ======================================

--- Rebuilds the O(1) lookup dictionary from the flat mappings list.
--- Must be called after any structural change to _state.mappings.
local function rebuild_lookup()
	if not _state then return end
	_state.mappings_lookup = {}
	for _, m in ipairs(_state.mappings) do
		local k = m.trigger .. "\0" .. tostring(m.is_word) .. "\0" .. tostring(m.auto)
		_state.mappings_lookup[k] = m
	end
end

--- Sorts the mappings list: longest trigger first, then word-boundary, then insertion order.
--- Longer triggers must be tested before shorter prefixes to prevent premature matches.
--- While a defer_sort() is active, the actual sort is postponed until flush_sort().
function M.sort_mappings()
	if not require_state("sort_mappings") then return end
	if _sort_deferred then
		_sort_pending = true
		return
	end
	Logger.trace(LOG, "Sorting %d mapping(s)…", #_state.mappings)
	table.sort(_state.mappings, function(a, b)
		if a.tlen ~= b.tlen then return a.tlen > b.tlen end
		if a.is_word ~= b.is_word then return a.is_word end
		return a.seq < b.seq
	end)
	Logger.done(LOG, "Mappings sorted.")
end

--- Suspends automatic re-sorting. Every subsequent call to sort_mappings() becomes
--- a no-op that only marks a sort as pending. Paired with flush_sort() at the end
--- of a batch (e.g. the initial TOML load loop) to avoid 6+ O(N log N) passes.
function M.defer_sort()
	_sort_deferred = true
	_sort_pending  = false
	Logger.debug(LOG, "Sort deferred.")
end

--- Resumes automatic sorting and performs one final sort if one was requested
--- while sorting was deferred. Safe to call even when defer_sort() was not used.
function M.flush_sort()
	_sort_deferred = false
	if _sort_pending then
		_sort_pending = false
		M.sort_mappings()
	end
	Logger.debug(LOG, "Sort flushed.")
end

--- Records the sequence numbers belonging to the current group after a load.
--- @param name string Group identifier.
--- @param path string|nil File path (nil for programmatic groups).
--- @param kind string "lua" or "toml".
local function record_group(name, path, kind)
	local seqs = {}
	for _, m in ipairs(_state.mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	_state.groups[name] = { path = path, seqs = seqs, enabled = true, kind = kind or "lua" }
end

--- Registers a mapping entry with smart case-variant generation.
---
--- For case-insensitive triggers, this function registers:
---   - lowercase trigger → lowercase replacement
---   - Title Case trigger → Title Case replacement
---   - UPPERCASE trigger  → UPPERCASE replacement
---
--- For triggers starting with ",", a ";" alias is also generated.
---
--- @param trigger string The sequence to monitor.
--- @param replacement string The resulting expansion string.
--- @param opts table Optional flags: is_word, auto_expand, is_case_sensitive, final_result.
function M.add(trigger, replacement, opts)
	if not require_state("add") then return end
	if type(trigger) ~= "string" or trigger == "" then
		Logger.error(LOG, "add: trigger must be a non-empty string (got '%s').", tostring(trigger))
		return
	end
	if type(replacement) ~= "string" then
		Logger.error(LOG, "add: replacement must be a string (got '%s').", type(replacement))
		return
	end

	-- Substitute the canonical magic-key when a non-default trigger char is configured.
	if _state.magic_key ~= "★" then
		trigger = trigger:gsub("★", _state.magic_key)
	end

	opts = type(opts) == "table" and opts or {}
	local is_word           = opts.is_word           == true
	local is_auto           = opts.auto_expand        == true
	local is_case_sensitive = opts.is_case_sensitive  == true
	local is_final          = opts.final_result       == true

	-- Replacements containing newlines or key directives are always "final" so
	-- the engine does not attempt to chain another expansion on top of them.
	if replacement:match("\n") or replacement:match("{Tab}") or replacement:match("{Enter}") or replacement:match("{Return}") then
		is_final = true
	end

	--- Appends or updates a single mapping entry in the database.
	--- @param t string The trigger.
	--- @param r string The replacement.
	--- @param a boolean True for auto-expand mode.
	--- @param plain_r string Precomputed plain_text(tokens_from_repl(r)). The
	---   caller computes this once per replacement variant and threads it
	---   through all space-variant calls, so we never tokenize the same
	---   replacement 3-4× at load time.
	local function add_raw(t, r, a, plain_r)
		local k        = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a)
		local existing = _state.mappings_lookup[k]
		if existing then
			-- Update replacement in place so re-loading a file refreshes the database.
			existing.repl       = r
			existing.plain_repl = plain_r
			if _state.current_group then existing.group = _state.current_group end
			return
		end
		_state.seq_counter = _state.seq_counter + 1
		-- Precompute magic-key membership so the main event loop does not have to
		-- recompute it on every keystroke; invalidated by update_trigger_char()
		local mk        = _state.magic_key
		local mkl       = #mk
		local has_magic = mkl > 0 and t:sub(-mkl) == mk
		local star_base = has_magic and t:sub(1, #t - mkl) or nil
		local entry = {
			trigger      = t,
			repl         = r,
			-- Precomputed once at load time; avoids tokens_from_repl() + plain_text()
			-- being called on every keystroke in update_preview() and the expander
			plain_repl   = plain_r,
			is_word      = is_word,
			auto         = a,
			seq          = _state.seq_counter,
			tlen         = text_utils.utf8_len(t),
			-- Byte-length cache: the main event loop compares buffer suffixes
			-- byte-by-byte, so #m.trigger is needed on every frame — caching saves
			-- one C call per mapping per keystroke
			trigger_bytes = #t,
			-- Last UTF-8 codepoint of the trigger, used later to bucket mappings
			-- by tail character so run_trigger_checks can skip any mapping whose
			-- last char does not match the just-typed character
			tail_char    = tail_codepoint(t),
			final_result = is_final,
			has_magic    = has_magic,
			star_base    = star_base,
			-- Matching metadata for the preview path, where matches are tested
			-- against star_base rather than the full trigger
			star_base_bytes     = star_base and #star_base or nil,
			star_base_tail_char = star_base and tail_codepoint(star_base) or nil,
		}
		if _state.current_group then entry.group = _state.current_group end
		table.insert(_state.mappings, entry)
		_state.mappings_lookup[k] = entry
	end

	--- Adds the trigger and its space-normalized variants (nbsp, nnbsp). The
	--- caller precomputes plain_r so it is not recomputed per space variant.
	--- @param t string The trigger.
	--- @param r string The replacement.
	--- @param plain_r string Precomputed plain_text of r.
	local function add_with_space_variants(t, r, plain_r)
		add_raw(t, r, is_auto, plain_r)
		-- Only generate space variants for triggers that contain spaces but do not
		-- *start* with a space (starting-space triggers are word-boundary guards).
		local starts_with_space = t:match("^[ \194\160\226\128\175]") ~= nil
		if not starts_with_space and t:match(" ") then
			add_raw((t:gsub(" ", "\194\160")),   r, is_auto, plain_r)  -- regular nbsp
			add_raw((t:gsub(" ", "\226\128\175")), r, is_auto, plain_r) -- narrow nbsp
		end
	end

	-- Tokenize+plaintext each distinct replacement exactly once per M.add call.
	-- Without this cache the same replacement text is re-tokenized for every
	-- case and space variant (3-4× per entry × ~3.3k TOML rows at startup).
	local lower_trig       = text_utils.trig_lower(trigger)
	local title_repl       = text_utils.repl_title(replacement)
	local upper_repl       = text_utils.repl_upper(replacement)
	local plain_repl_base  = km_utils.plain_text(km_utils.tokens_from_repl(replacement))
	local plain_repl_title = km_utils.plain_text(km_utils.tokens_from_repl(title_repl))
	local plain_repl_upper = km_utils.plain_text(km_utils.tokens_from_repl(upper_repl))

	if is_case_sensitive then
		add_with_space_variants(trigger, replacement, plain_repl_base)
	else
		local title_trigs = text_utils.trig_title(lower_trig)
		local upper_trigs = text_utils.trig_upper(lower_trig)

		add_with_space_variants(lower_trig, replacement, plain_repl_base)

		for _, tt in ipairs(title_trigs) do
			if tt ~= lower_trig then add_with_space_variants(tt, title_repl, plain_repl_title) end
		end

		for _, ut in ipairs(upper_trigs) do
			-- Skip the upper variant if it is identical to a title variant already added.
			local is_title = false
			for _, tt in ipairs(title_trigs) do
				if ut == tt then is_title = true; break end
			end
			if ut ~= lower_trig and not is_title then
				add_with_space_variants(ut, upper_repl, plain_repl_upper)
			end
		end
	end

	-- Generate a ";" alias for triggers that start with ",".
	-- On the Ergopti layout ";" is in the comma layer, so both keys should fire.
	local first_char_src = is_case_sensitive and trigger or lower_trig
	local first_char     = first_char_src:match("^[%z\1-\127\194-\244][\128-\191]*")
	if first_char == "," then
		local rest = lower_trig:sub(#first_char + 1)
		if rest ~= "" then
			add_with_space_variants(";" .. text_utils.trig_lower(rest), title_repl, plain_repl_title)
			for _, ru in ipairs(text_utils.trig_upper(rest)) do
				local alias = ";" .. ru
				if alias ~= ";" .. text_utils.trig_lower(rest) then
					add_with_space_variants(alias, upper_repl, plain_repl_upper)
				end
			end
		end
	end

    -- Log disabled because we have thousands of mappings
	-- Logger.debug(LOG, "Mapping added: '%s' → '%s'%s.",
	-- 	trigger, replacement, is_auto and " [auto]" or "")
end




-- ================================
-- ================================
-- ======= 4/ Group Loaders =======
-- ================================
-- ================================

--- Loads mappings from a Lua file via dofile and records the group.
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the Lua hotstring file.
function M.load_file(name, path)
	if not require_state("load_file") then return end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "load_file: name must be a non-empty string."); return
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "load_file: path must be a non-empty string."); return
	end

	Logger.start(LOG, "Loading Lua mapping file '%s'…", name)
	_state.current_group = name

	local ok, err = pcall(dofile, path)
	if not ok then
		Logger.error(LOG, "Error loading '%s': %s.", path, tostring(err))
	end

	_state.current_group = nil
	record_group(name, path, "lua")
	M.sort_mappings()

	if ok then
		Logger.success(LOG, "Lua mapping file '%s' loaded (%d total mapping(s)).", name, #_state.mappings)
	end
end

--- Loads and parses mappings from a TOML configuration file.
--- Respects per-section enable/disable state stored in hs.settings.
--- @param name string Group identifier used as the key in _state.groups.
--- @param path string Absolute path to the TOML file.
function M.load_toml(name, path)
	if not require_state("load_toml") then return end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "load_toml: name must be a non-empty string."); return
	end
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "load_toml: path must be a non-empty string."); return
	end

	Logger.start(LOG, "Loading TOML mapping file '%s'…", name)

	local toml_reader  = require("lib.toml_reader")
	local ok, data     = pcall(toml_reader.parse, path)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Failed to parse TOML '%s': %s.", path, tostring(data))
		return
	end

	_state.current_group = name
	local sections_info  = {}

	for _, sec_name in ipairs(data.sections_order or {}) do
		if sec_name == "-" then
			table.insert(sections_info, { name = "-", description = "-", count = 0 })
			goto continue_sec
		end

		local sec = data.sections and data.sections[sec_name]
		if not sec then goto continue_sec end

		if sec.is_placeholder then
			table.insert(sections_info, {
				name                = sec_name,
				description         = sec.description,
				count               = 0,
				is_module_placeholder = true,
			})
			goto continue_sec
		end

		if M.is_section_enabled(name, sec_name) then
			for _, entry in ipairs(sec.entries or {}) do
				M.add(entry.trigger, entry.output, {
					is_word           = entry.is_word,
					auto_expand       = entry.auto_expand,
					is_case_sensitive = entry.is_case_sensitive,
					final_result      = entry.final_result,
				})
			end
		end

		table.insert(sections_info, {
			name        = sec_name,
			description = sec.description,
			count       = #(sec.entries or {}),
		})

		::continue_sec::
	end

	_state.current_group = nil
	M.sort_mappings()

	local seqs = {}
	for _, m in ipairs(_state.mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	_state.groups[name] = {
		path             = path,
		seqs             = seqs,
		enabled          = true,
		kind             = "toml",
		meta_description = data.meta and data.meta.description or nil,
		sections         = sections_info,
	}

	Logger.success(LOG, "TOML mapping file '%s' loaded (%d total mapping(s)).", name, #_state.mappings)
end




-- =====================================
-- =====================================
-- ======= 5/ Section Management =======
-- =====================================
-- =====================================

--- Returns true when the section is not explicitly disabled.
--- hs.settings stores `false` when the user disables it; nil means enabled.
--- @param group_name string
--- @param section_name string
--- @return boolean
function M.is_section_enabled(group_name, section_name)
	return hs.settings.get("hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name)) ~= false
end

--- Returns true when the "repeat" section is present and enabled in any active group.
--- Used to gate the magic-key repeat feature.
--- @return boolean
function M.is_repeat_feature_enabled()
	if not _state then return false end
	for name, g in pairs(_state.groups) do
		if g.enabled and g.sections then
			for _, sec in ipairs(g.sections) do
				if sec.name == "repeat" then return M.is_section_enabled(name, "repeat") end
			end
		end
	end
	return false
end

--- Disables a section and reloads its group so the mapping database reflects the change.
--- @param gn string Group name.
--- @param sn string Section name.
function M.disable_section(gn, sn)
	Logger.debug(LOG, "Disabling section '%s/%s'.", gn, sn)
	hs.settings.set("hotstrings_section_" .. tostring(gn) .. "_" .. tostring(sn), false)
	if M.is_group_enabled(gn) then
		M.disable_group(gn)
		M.enable_group(gn)
	end
end

--- Enables a section (removes the explicit false, restoring the default-enabled state)
--- and reloads its group so the mapping database reflects the change.
--- @param gn string Group name.
--- @param sn string Section name.
function M.enable_section(gn, sn)
	Logger.debug(LOG, "Enabling section '%s/%s'.", gn, sn)
	hs.settings.set("hotstrings_section_" .. tostring(gn) .. "_" .. tostring(sn), nil)
	if M.is_group_enabled(gn) then
		M.disable_group(gn)
		M.enable_group(gn)
	end
end

--- Returns the sections table for a group, or nil if the group is unknown.
--- @param name string Group identifier.
--- @return table|nil
function M.get_sections(name)
	return _state and _state.groups[name] and _state.groups[name].sections or nil
end

--- Returns the prose description from the TOML [_meta] block, or nil.
--- @param name string Group identifier.
--- @return string|nil
function M.get_meta_description(name)
	return _state and _state.groups[name] and _state.groups[name].meta_description or nil
end

--- Manually sets the current group context used by M.add() to tag new entries.
--- Must be reset to nil after the relevant block of M.add() calls.
--- @param name string|nil Group name.
function M.set_group_context(name)
	if not require_state("set_group_context") then return end
	_state.current_group = name
end

--- Registers a callback invoked after a group is enabled or re-loaded.
--- @param name string Group identifier.
--- @param f function The post-load hook.
function M.set_post_load_hook(name, f)
	if not require_state("set_post_load_hook") then return end
	if type(f) ~= "function" then
		Logger.error(LOG, "set_post_load_hook: f must be a function."); return
	end
	_state.group_post_load_hooks[name] = f
end

--- Disables a group: removes its mappings from the live database.
--- No-op when the group is already disabled or unknown.
--- @param name string Group identifier.
function M.disable_group(name)
	if not require_state("disable_group") then return end
	local g = _state.groups[name]
	if not g or not g.enabled then return end

	g.enabled = false

	-- Purge all mappings belonging to this group from the live list.
	if g.path ~= nil then
		local kept = {}
		for _, m in ipairs(_state.mappings) do
			if m.group ~= name then table.insert(kept, m) end
		end
		_state.mappings = kept
		rebuild_lookup()
	end

	Logger.debug(LOG, "Group '%s' disabled (%d mapping(s) remaining).", name, #_state.mappings)
end

--- Returns true when the named group exists and is currently enabled.
--- @param name string Group identifier.
--- @return boolean
function M.is_group_enabled(name)
	return _state and _state.groups[name] ~= nil and _state.groups[name].enabled or false
end

--- Returns a flat table of {name → enabled} for all registered groups.
--- @return table
function M.list_groups()
	if not _state then return {} end
	local out = {}
	for name, g in pairs(_state.groups) do out[name] = g.enabled end
	return out
end

--- Registers a programmatic (non-file) group with an optional metadata block.
--- Used by Lua modules that call M.add() directly instead of loading a file.
--- @param name string Group identifier.
--- @param meta_description string|nil Prose description for the menu.
--- @param sections table|nil Array of section descriptor tables.
function M.register_lua_group(name, meta_description, sections)
	if not require_state("register_lua_group") then return end
	if type(name) ~= "string" or name == "" then
		Logger.error(LOG, "register_lua_group: name must be a non-empty string."); return
	end
	_state.groups[name] = {
		path             = nil,
		seqs             = {},
		enabled          = true,
		kind             = "lua",
		meta_description = meta_description,
		sections         = type(sections) == "table" and sections or {},
	}
	Logger.debug(LOG, "Lua group '%s' registered.", name)
end

--- Enables a previously disabled group by reloading its file (or re-running its hook).
--- No-op when the group is already enabled.
--- @param name string Group identifier.
function M.enable_group(name)
	if not require_state("enable_group") then return end
	local g = _state.groups[name]
	if not g then
		Logger.warn(LOG, "enable_group: unknown group '%s'.", tostring(name))
		return
	end
	if g.enabled then return end

	Logger.debug(LOG, "Enabling group '%s' (kind: %s)…", name, g.kind or "?")

	if g.path == nil then
		-- Programmatic group: mark enabled and run the post-load hook if any.
		g.enabled = true
		local hook = _state.group_post_load_hooks[name]
		if type(hook) == "function" then hook() end
		M.sort_mappings()
		return
	end

	if g.kind == "toml" then
		M.load_toml(name, g.path)
	else
		M.load_file(name, g.path)
	end

	local hook = _state.group_post_load_hooks[name]
	if type(hook) == "function" then hook() end
	M.sort_mappings()
end




-- =============================
-- =============================
-- ======= 6/ Module API =======
-- =============================
-- =============================

--- Injects the shared CoreState from keymap/init.lua.
--- Must be called exactly once before any other function in this module.
--- @param core_state table The shared state object.
function M.init(core_state)
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table (got %s).", type(core_state))
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state = core_state
	Logger.debug(LOG, "Registry initialized.")
end

--- Synchronizes the magic-key character in the terminator definitions and
--- recomputes the per-mapping has_magic / star_base precomputed fields.
--- Called by keymap/init.lua whenever the trigger char is changed.
--- @param char string The new trigger character.
function M.update_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.error(LOG, "update_trigger_char: char must be a non-empty string."); return
	end
	update_terminator_magic_key(char)
	-- Recompute precomputed magic-key fields for all existing mappings so that
	-- the event loop and preview scanner continue to see correct values
	if _state then
		local mkl = #char
		for _, m in ipairs(_state.mappings) do
			m.has_magic = mkl > 0 and m.trigger:sub(-mkl) == char
			m.star_base = m.has_magic and m.trigger:sub(1, #m.trigger - mkl) or nil
		end
		Logger.debug(LOG, "Recomputed has_magic/star_base for %d mapping(s).", #_state.mappings)
	end
end

return M
