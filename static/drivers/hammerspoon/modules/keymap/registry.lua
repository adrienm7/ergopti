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

local hs          = hs
local text_utils  = require("lib.text_utils")
local km_utils    = require("modules.keymap.utils")
local Logger      = require("lib.logger")
local Terminators = require("modules.keymap.terminators")

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

--- @class Mapping
--- Single hotstring entry stored in _state.mappings. Every field is populated
--- once in add_raw() so the per-keystroke hot path (expander + llm_bridge
--- preview) does no allocation and no string math on already-known metadata.
---
--- @field trigger             string  UTF-8 hotstring the user types.
--- @field repl                string  Raw replacement, possibly containing tokens.
--- @field plain_repl          string  Replacement with tokens resolved to literal text; precomputed to skip tokens_from_repl() per keystroke.
--- @field is_word             boolean True when the trigger must match only at a word boundary.
--- @field auto                boolean True for auto-expansion triggers (fire without a terminator).
--- @field seq                 integer Monotonic counter assigned at insertion; used as a stable tiebreaker in the sort.
--- @field tlen                integer UTF-8 codepoint length of `trigger`.
--- @field trigger_bytes       integer Byte length of `trigger`; replaces repeated `#trigger` calls in the hot path.
--- @field tail_char           string  Last UTF-8 codepoint of `trigger`; keys into _state.mappings_by_tail_char.
--- @field final_result        boolean True when the replacement is a finalized string (skip further substitution passes).
--- @field has_magic           boolean True when `trigger` ends with the magic key.
--- @field star_base           string|nil When has_magic, `trigger` minus the trailing magic key; nil otherwise.
--- @field star_base_bytes     integer|nil Byte length of `star_base`; nil when not magic.
--- @field star_base_tail_char string|nil Last UTF-8 codepoint of `star_base`; keys into _state.mappings_by_star_tail_char.
--- @field group               string|nil Name of the owning group, when registered inside a load_file/load_toml scope.
--- @field group_order         integer Load-order rank of the owning group; acts as the primary sort tiebreaker after trigger length.




-- ==============================
-- ==============================
-- ======= 1/ Terminators =======
-- ==============================
-- ==============================

-- The catalogue, the O(1) lookup sets, and the enable/disable API all live in
-- modules/keymap/terminators.lua — see that module for the full implementation
-- and the rationale behind the hot-path caches. Registry re-exports the public
-- surface under its historical names so the menu and expander callers keep
-- working unchanged.

M.TERMINATOR_DEFS          = Terminators.TERMINATOR_DEFS
M.is_terminator            = Terminators.is_terminator
M.terminator_is_consumed   = Terminators.terminator_is_consumed
M.set_terminator_enabled   = Terminators.set_terminator_enabled
M.is_terminator_enabled    = Terminators.is_terminator_enabled
M.get_terminator_defs      = Terminators.get_terminator_defs
M.add_custom_terminator    = Terminators.add_custom_terminator
M.remove_custom_terminator = Terminators.remove_custom_terminator




-- ======================================
-- ======================================
-- ======= 2/ Database Management =======
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

--- Rebuilds the per-tail-char bucket indexes from the (already sorted)
--- _state.mappings list. Each mapping appears in mappings_by_tail_char
--- under its last UTF-8 codepoint; has_magic mappings additionally appear
--- in mappings_by_star_tail_char under their star_base's last codepoint.
---
--- Buckets preserve the insertion order, which matches the sort order of
--- _state.mappings (longest trigger first). Callers iterate a single bucket
--- per keystroke instead of the full list, collapsing the hot-path scan
--- from ~10-15k entries to a handful.
local function rebuild_tail_indexes()
	if not _state then return end
	local tail_idx = {}
	local star_idx = {}
	for _, m in ipairs(_state.mappings) do
		local tc = m.tail_char
		local bucket = tail_idx[tc]
		if not bucket then
			bucket = {}
			tail_idx[tc] = bucket
		end
		bucket[#bucket + 1] = m
		if m.has_magic and m.star_base_tail_char then
			local sc = m.star_base_tail_char
			local sbucket = star_idx[sc]
			if not sbucket then
				sbucket = {}
				star_idx[sc] = sbucket
			end
			sbucket[#sbucket + 1] = m
		end
	end
	_state.mappings_by_tail_char      = tail_idx
	_state.mappings_by_star_tail_char = star_idx
end

--- Sorts the mappings list: longest trigger first, then word-boundary, then insertion order.
--- Longer triggers must be tested before shorter prefixes to prevent premature matches.
--- While a defer_sort() is active, the actual sort is postponed until flush_sort().
--- Rebuilds the tail-char bucket indexes at the end so they stay in sync.
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
		-- Stable cross-reload priority: groups keep their original insertion
		-- order across disable/enable cycles, so two same-length triggers
		-- cannot flip relative priority after a hot-reload (B3.6). `seq`
		-- within a group stays monotonic by design.
		local ao = a.group_order or 0
		local bo = b.group_order or 0
		if ao ~= bo then return ao < bo end
		return a.seq < b.seq
	end)
	rebuild_tail_indexes()
	Logger.done(LOG, "Mappings sorted.")
end

--- Returns the bucket of mappings whose trigger ends with `tail_char`, in
--- sort order (longest trigger first). Returns nil when the bucket is empty
--- or the registry is not yet initialized; callers must handle that case.
--- @param tail_char string Single-codepoint UTF-8 string.
--- @return table|nil Array of mapping entries, or nil.
function M.mappings_for_tail(tail_char)
	if not _state then return nil end
	return _state.mappings_by_tail_char[tail_char]
end

--- Returns the bucket of has_magic mappings whose star_base ends with
--- `tail_char`, in sort order. Used by the LLM preview's star_base match path.
--- @param tail_char string Single-codepoint UTF-8 string.
--- @return table|nil Array of mapping entries, or nil.
function M.mappings_for_star_tail(tail_char)
	if not _state then return nil end
	return _state.mappings_by_star_tail_char[tail_char]
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
--- Preserves the group's existing `group_order` across reloads so the sort
--- tiebreaker stays stable (B3.6): disable_group + enable_group must not
--- change the relative priority of same-length triggers.
--- @param name string Group identifier.
--- @param path string|nil File path (nil for programmatic groups).
--- @param kind string "lua" or "toml".
local function record_group(name, path, kind)
	local seqs = {}
	for _, m in ipairs(_state.mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	local existing = _state.groups[name]
	local group_order = (existing and existing.group_order)
		or (_state.group_order_counter or 0) + 1
	if not existing or not existing.group_order then
		_state.group_order_counter = group_order
	end
	_state.groups[name] = {
		path        = path,
		seqs        = seqs,
		enabled     = true,
		kind        = kind or "lua",
		group_order = group_order,
	}
end

--- Ensures a group entry exists with a stable `group_order` before any of
--- its mappings are added via add_raw. Called from the start of load_file /
--- load_toml so that each entry can store the stable order at insertion time
--- instead of having to back-fill it after record_group runs. Preserves any
--- existing group_order on reload.
--- @param name string Group identifier.
local function ensure_group_order(name)
	if not _state or not name or name == "" then return end
	_state.group_order_counter = _state.group_order_counter or 0
	local g = _state.groups[name]
	if g and g.group_order then return end
	_state.group_order_counter = _state.group_order_counter + 1
	if g then
		g.group_order = _state.group_order_counter
	else
		_state.groups[name] = {
			path        = nil,
			seqs        = {},
			enabled     = true,
			kind        = "pending",
			group_order = _state.group_order_counter,
		}
	end
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
		if _state.current_group then
			entry.group = _state.current_group
			local g = _state.groups[_state.current_group]
			-- group_order is 0 for mappings added outside a load_file/load_toml
			-- scope (e.g. ad-hoc M.add calls with no active group), which keeps
			-- them at the head of the tiebreaker — same as before this change.
			entry.group_order = (g and g.group_order) or 0
		else
			entry.group_order = 0
		end
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
-- ======= 3/ Group Loaders =======
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
	ensure_group_order(name)
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

	ensure_group_order(name)
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
-- ======= 4/ Section Management =======
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
--- Must be reset to nil after the relevant block of M.add() calls. When a
--- non-nil group name is supplied, ensure_group_order stamps a stable
--- group_order on the group so subsequent add_raw calls tag their entries
--- with the same priority value that would survive a later reload.
--- @param name string|nil Group name.
function M.set_group_context(name)
	if not require_state("set_group_context") then return end
	if name and name ~= "" then ensure_group_order(name) end
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
-- ======= 5/ Module API =======
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

--- Reassigns the magic-key character across the terminator definitions AND
--- every affected mapping. Triggers whose last character was the previous
--- magic key are renamed, and every precomputed field (trigger_bytes,
--- tail_char, star_base, star_base_bytes, star_base_tail_char, tlen) is
--- recomputed so the event loop and preview scanner remain consistent.
---
--- Because trigger keys in _state.mappings_lookup embed m.trigger, the lookup
--- is rebuilt after renaming. A final sort is issued because the byte length
--- of the magic key (and therefore tlen) may have changed.
---
--- The write to _state.magic_key happens inside this function so that the
--- old value is available during the rename pass. Callers must not pre-set
--- _state.magic_key before invoking update_trigger_char.
---
--- @param char string The new trigger character.
function M.update_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.error(LOG, "update_trigger_char: char must be a non-empty string."); return
	end
	if not require_state("update_trigger_char") then return end

	local old_char = _state.magic_key
	Terminators.update_magic_key(char)

	if old_char == char then
		Logger.debug(LOG, "update_trigger_char: key unchanged ('%s') — skipping rename.", char)
		return
	end

	Logger.start(LOG, "Renaming magic key '%s' → '%s' across %d mapping(s)…", old_char, char, #_state.mappings)

	local old_len = #old_char
	local new_len = #char
	local renamed = 0
	for _, m in ipairs(_state.mappings) do
		-- A mapping carried the old magic key iff its trigger ended with it.
		-- This check must use the OLD key (via m.trigger) before we rename, so
		-- we never rely on the stale m.has_magic flag.
		local had_magic = old_len > 0 and m.trigger:sub(-old_len) == old_char
		if had_magic then
			local base   = m.trigger:sub(1, #m.trigger - old_len)
			local new_tr = base .. char
			m.trigger             = new_tr
			m.trigger_bytes       = #new_tr
			m.tail_char           = tail_codepoint(new_tr)
			m.tlen                = text_utils.utf8_len(new_tr)
			m.has_magic           = true
			m.star_base           = base
			m.star_base_bytes     = #base
			m.star_base_tail_char = tail_codepoint(base)
			renamed = renamed + 1
		else
			-- Previously non-magic mappings must not suddenly gain has_magic
			-- just because their trigger happens to end with the new key
			-- (we cannot rewrite their replacement anyway). Keep them untouched.
			m.has_magic = false
			m.star_base = nil
			m.star_base_bytes     = nil
			m.star_base_tail_char = nil
		end
	end

	_state.magic_key = char
	rebuild_lookup()
	M.sort_mappings()
	-- Byte length of the magic key may have changed (★ is 3 bytes, § is 2),
	-- so triggers shift in both byte length and tlen — resorting preserves
	-- the longest-first invariant that the event loop depends on.
	if new_len ~= old_len then
		Logger.debug(LOG, "Magic-key byte length changed (%d → %d) — lookup rebuilt and mappings re-sorted.", old_len, new_len)
	end
	Logger.success(LOG, "Magic-key rename complete (%d mapping(s) renamed).", renamed)
end

return M
