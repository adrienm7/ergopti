--- modules/hotstrings/hotstrings_config.lua

--- ==============================================================================
--- MODULE: Hotstrings Config
--- DESCRIPTION:
--- Resolves the effective delay (in seconds) and tooltip color for any
--- hotstring group/section by merging three layers, in order of decreasing
--- precedence:
---   1. User overrides — `~/.config/ergopti_plus/hotstrings_config.toml`,
---      edited from the "Délais & couleurs hotstrings" window.
---   2. TOML metadata — `delay` / `color` declared in each category TOML
---      under `[_meta]` (file scope) or `[_meta.sections.<name>]` (section).
---   3. Hard fallbacks (`GLOBAL_DEFAULT_DELAY`, `GLOBAL_DEFAULT_COLOR`).
---
--- SUPPORTED CATEGORY NAMESPACES:
---   - Standard categories  : resolve("magickey"), resolve("autocorrection"), …
---   - Extension overrides  : resolve_ext("ergopti-demo", toml_path, section?)
---     The user override key in hotstrings_config.toml is "ext.<id>" so it
---     never collides with a bare category name.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: HS and AHK both read the same TOML metadata,
---    so per-group defaults stop being duplicated across drivers.
--- 2. Cross-driver overrides: the user override file lives at a shared path
---    so changes made from the HS menu show up in AHK (and vice versa).
--- 3. Lazy TOML parsing: each category TOML is parsed at most once per
---    session via the existing `lib.toml.reader` to avoid duplicate I/O.
--- ==============================================================================

local M = {}
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local TomlReader = require("infra.toml.reader")
local TomlScanner = require("toml_codec.record_scanner")
local TomlKeyPath = require("toml_codec.key_path")
local Extensions = require("hotstrings.extensions")
local TomlRecordEditor = require("infra.toml.record_editor")
local FileSystem = require("adapters.file_system")
local ConfigSchema = require("modules.hotstrings.hotstrings_config_schema")
local PersonalFiles = require("hotstrings.personal_files")
local BasicString = require("toml_codec.basic_string")
local TomlCodec = require("toml_codec.codec")
local PublicationRecovery = require("hotstrings.publication_recovery")
-- The five-rung precedence, shared with Linux. It was written once here and
-- once in AutoHotkey and the two had already drifted; the rule is the thing
-- that must not differ, and where the override file lives is the thing that may.
local DelayResolver = require("hotstrings.delay_resolver")
local HotstringPriority = require("hotstring_priority")
local LOG        = "hotstrings_config"


-- =================================
-- =================================
-- ======= 1/ Constants ============
-- =================================
-- =================================

-- Ultimate fallbacks when neither a user override nor a TOML default is set.
-- LOADED AT REQUIRE-TIME from the shared cross-driver canon
-- (_shared/modules/hotstrings/defaults.toml) by load_shared_defaults() below — the
-- SINGLE source shared verbatim with the AutoHotkey driver. They start nil so
-- a missing file/key fails fast (rule 5.3) instead of masking driver drift
-- behind a hardcoded literal (rules 5.2 / 5.4). ``GLOBAL_DEFAULT_COLOR`` remains
-- the single source of truth for "no color set" — every per-category lookup
-- that finds nothing else lands here.
local GLOBAL_DEFAULT_DELAY = nil
local GLOBAL_DEFAULT_COLOR = nil

-- Per-category baseline that overrides ``GLOBAL_DEFAULT_COLOR`` only when no
-- TOML _meta or user override sets a color. Its "personal" entry is populated
-- from the shared canon by load_shared_defaults() — kept in one table so all
-- per-category baselines stay visible in one place.
local CATEGORY_DEFAULT_COLORS = {}

-- =================================
-- =================================
-- ======= 2/ Module State =========
-- =================================
-- =================================

-- Built-in word-delimiter set — mirrors HOTSTRINGS_DEFAULT_WORD_DELIMITERS in AHK.
-- CR and LF are always included; the rest are user-configurable.
local DEFAULT_WORD_DELIMITERS = " \t\r\n.,;:?!'’-=()[]/\\+*"

local _state = nil
local _terminal_owner = nil
local delay_projection

local function personal_override_owner(category, overrides)
	if not PersonalFiles.components(category) or overrides[category] ~= nil then return category end
	local record = require("infra.personal_hotstrings").adoption(category)
	return record and record.admitted == true and record.legacy_name or category
end

local function personal_section_metadata(meta, section)
	local selected = (meta.sections or {})[section]
	local delay = (meta.section_delays or {})[section]
	if delay ~= nil and (type(selected) ~= "table" or selected.delay == nil) then
		local copy = {}
		for key, value in pairs(selected or {}) do copy[key] = value end
		copy.delay = delay
		return copy
	end
	return selected
end

--- Returns the first non-nil argument. Module-level rather than a closure built
--- inside M.resolve: it captures nothing, and the preview path calls resolve once
--- per candidate on every keystroke while a tooltip is eligible, so a fresh
--- closure per call is an allocation on the HID thread for no benefit.
--- @return any|nil The first argument that is not nil.
local function first_set(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil then return v end
	end
	return nil
end

local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Refuses an ordinary override mutation while a scope transaction holds the
--- file: its retained inverse restores exact bytes, which a newer ordinary
--- write would make impossible to put back.
--- @param func_name string Caller name for the diagnostic.
--- @return boolean admitted
local function scope_admits(func_name)
	if _terminal_owner ~= nil then
		Logger.error(LOG, "'%s' refused: controlled termination holds hotstring publication admission.", func_name)
		return false
	end
	if _state.operation_active or (_state.recovery and _state.recovery.has_pending() and func_name ~= "reload") then
		Logger.error(LOG, "'%s' refused: native override publication recovery retains admission.", func_name)
		return false
	end
	if _state.scope_owner ~= nil then
		Logger.error(LOG, "'%s' refused: a hotstrings scope holds the override file.", func_name)
		return false
	end
	return true
end





--- ====================================
--- ====================================
--- ======= 3/ Override File I/O =======
--- ====================================
--- ====================================

--- Advances the small amount of TOML lexical state needed to identify a
--- complete assignment. This is deliberately not a second TOML parser: the
--- module only needs to know whether the next physical line is still part of
--- an array, inline table, or multiline string so it can preserve unowned raw
--- records byte-for-byte.
--- @param raw string One physical source line.
--- @param depth number Current array/inline-table nesting depth.
--- @param multiline_quote string|nil Active triple-quote delimiter.
--- @return number depth Updated nesting depth.
--- @return string|nil multiline_quote Updated triple-quote delimiter.
--- Parses the user override TOML file into two structures:
--- - overrides: { [category] = { delay = n, color = s, sections = { [name] = { delay, color } } } }
--- - global_word_delimiters: string|nil (from [__global__] word_delimiters key)
--- Unknown category keys are ignored. Unowned or unsupported [__global__]
--- records are preserved byte-for-byte because sibling drivers share the file.
--- @param content string Exact override source bytes.
--- @return table overrides The parsed overrides.
--- @return string|nil word_delimiters The optional word-delimiter override.
--- @return string[] global_passthrough Exact raw records for unowned [__global__] keys.
local function parse_override_content(content)
	local result = {}
	local word_delimiters = nil
	local global_passthrough = {}
	local current_cat = nil
	local current_sec = nil
	local in_global   = false
	local global_depth = 0
	local global_multiline_quote = nil
	local global_owned_record = false
	local record_depth, record_quote = 0, nil

	for raw in (content .. "\n"):gmatch("([^\n]*)\n") do
		raw = raw:gsub("\r$", "")
		local line = raw:match("^%s*(.-)%s*$")

		if not in_global and (record_depth > 0 or record_quote ~= nil) then
			record_depth, record_quote = TomlRecordEditor.advance_continuation(raw, record_depth, record_quote)
			goto continue
		end

		-- A line that resembles a section header can legally occur inside an
		-- open multiline global value. Consume continuations before interpreting
		-- any header syntax so such data cannot reset the section state.
		local global_record_open = in_global
			and (global_depth > 0 or global_multiline_quote ~= nil)
		if global_record_open then
			if not global_owned_record then
				global_passthrough[#global_passthrough + 1] = raw
			end
			global_depth, global_multiline_quote = TomlRecordEditor.advance_continuation(
				raw,
				global_depth,
				global_multiline_quote
			)
			if global_depth == 0 and global_multiline_quote == nil then
				global_owned_record = false
			end
			goto continue
		end

		-- [__global__] — script-wide settings (word_delimiters, etc.)
		if line == "[__global__]" then
			in_global = true
			current_cat, current_sec = nil, nil
			global_depth = 0
			global_multiline_quote = nil
			global_owned_record = false
			goto continue
		end

		-- This file is shared with the Windows driver. This module owns
		-- word_delimiters, but sibling drivers may add other global assignments
		-- such as consumed_delimiters. Retain their complete raw records, including
		-- multiline values, comments, and blank lines, instead of silently deleting
		-- fields this parser does not interpret. A '[' only starts a new section
		-- when no value is open; inside an array it is continuation data.
		if in_global then
			if line:sub(1, 1) == "[" then
				in_global = false
				global_owned_record = false
			else
				local global_key = line:match("^([%w_%-]+)%s*=")
				local wd = global_key == "word_delimiters"
					and line:match("^word_delimiters%s*=%s*\"(.-)\"%s*$")
					or nil
				-- Ownership starts only after the value shape is understood. A
				-- hand-edited literal string or trailing comment is valid shared TOML,
				-- but this deliberately narrow parser cannot interpret it. Preserve
				-- that complete record as passthrough instead of claiming and dropping
				-- bytes during an unrelated category save.
				local decoded = wd and BasicString.unescape_body(wd) or nil
				global_owned_record = decoded ~= nil
				if global_owned_record then
					word_delimiters = decoded
				elseif global_key == "word_delimiters" then
					Logger.warn(LOG, "Unsupported word_delimiters representation preserved without applying it.")
				end
				if not global_owned_record then
					global_passthrough[#global_passthrough + 1] = raw
				end
				global_depth, global_multiline_quote = TomlRecordEditor.advance_continuation(
					raw,
					global_depth,
					global_multiline_quote
				)
				if global_depth == 0 and global_multiline_quote == nil then
					global_owned_record = false
				end
				goto continue
			end
		end

		-- Global passthrough keeps its original, narrower lexical ownership.
		-- Standard scalar and header comments belong to the canonical codec.
		line = TomlCodec.strip_inline_comment(raw):match("^%s*(.-)%s*$")
		if not line or line == "" or line:sub(1, 1) == "#" then goto continue end

		-- [ext.name.section] — extension section override (3 dotted segments)
		local ext_name, ext_sec = line:match("^%[ext%.([%w_%-]+)%.([%w_%-]+)%]$")
		if ext_name and ext_sec then
			local key = ConfigSchema.normalize_category("ext." .. ext_name)
			ext_sec = ConfigSchema.normalize_section(ext_sec)
			result[key] = result[key] or { sections = {} }
			result[key].sections = result[key].sections or {}
			result[key].sections[ext_sec] = result[key].sections[ext_sec] or {}
			current_cat, current_sec = key, ext_sec
			goto continue
		end

		-- [ext.name] — extension file-level override (2 dotted segments, "ext." prefix)
		local ext_only = line:match("^%[ext%.([%w_%-]+)%]$")
		if ext_only then
			local key = ConfigSchema.normalize_category("ext." .. ext_only)
			result[key] = result[key] or { sections = {} }
			current_cat, current_sec = key, nil
			goto continue
		end

		-- [category.section] — standard section override (must be tested before plain [category])
		local cat, sec = line:match("^%[([%w_%-]+)%.([%w_%-]+)%]$")
		if cat and sec then
			cat = ConfigSchema.normalize_category(cat)
			sec = ConfigSchema.normalize_section(sec)
			result[cat] = result[cat] or { sections = {} }
			result[cat].sections = result[cat].sections or {}
			result[cat].sections[sec] = result[cat].sections[sec] or {}
			current_cat, current_sec = cat, sec
			goto continue
		end

		-- [category]
		local cat_only = line:match("^%[([%w_%-]+)%]$")
		if cat_only then
			cat_only = ConfigSchema.normalize_category(cat_only)
			result[cat_only] = result[cat_only] or { sections = {} }
			current_cat, current_sec = cat_only, nil
			goto continue
		end

		-- Unowned headers and open values cannot lend their fields to the prior category.
		if line:sub(1, 1) == "[" then
			current_cat, current_sec = nil, nil
			goto continue
		end
		record_depth, record_quote = TomlRecordEditor.advance_continuation(raw, 0, nil)

		-- key = value (delay number, color string)
		if current_cat then
			local target = current_sec
				and result[current_cat].sections[current_sec]
				or result[current_cat]

			local num = line:match("^delay%s*=%s*([%-%d%.]+)%s*$")
			if num then
				local n = tonumber(num)
				if ConfigSchema.is_delay(n) then target.delay = n end
				goto continue
			end

			local col = line:match("^color%s*=%s*\"([^\"]*)\"%s*$")
			if col then
				target.color = col
				goto continue
			end

			-- Lua patterns have no alternation (|); test "true" and "false" separately.
			local bool_val = line:match("^show_tooltip%s*=%s*(true)%s*$")
				or line:match("^show_tooltip%s*=%s*(false)%s*$")
			if bool_val then
				target.show_tooltip = (bool_val == "true")
				goto continue
			end

			local prio = line:match("^priority%s*=%s*(%d+)%s*$")
			if prio then
				local p = tonumber(prio)
				if p then target.priority = p end
				goto continue
			end
		end

		::continue::
	end

	return result, word_delimiters, global_passthrough
end

--- Checks every captured logical field without entering a path callback.
local function same_publication_owner(captured)
	if type(captured) ~= "table" or _state ~= captured.state then return false end
	local state = _state
	if state.path ~= captured.path or state.epoch ~= captured.epoch
		or state.owner_epoch ~= captured.owner_epoch or state.scope_owner ~= captured.scope_owner
		or state.source_snapshot ~= captured.source_object or state.overrides ~= captured.overrides
		or state.word_delimiters ~= captured.word_delimiters then return false end
	local source = state.source_snapshot
	return (source and source.status) == captured.source_status
		and (source and source.content) == captured.source_content
end

--- Captures the exact logical override owner before any native callback.
local function capture_publication_owner(state)
	local source = state.source_snapshot
	local captured = { state = state, path = state.path, epoch = state.epoch,
		owner_epoch = state.owner_epoch, scope_owner = state.scope_owner,
		source_object = source, source_status = source and source.status,
		source_content = source and source.content, overrides = state.overrides,
		word_delimiters = state.word_delimiters }
	if state.current_override_path then
		local called, current = pcall(state.current_override_path)
		if not called or current ~= captured.path then return nil end
	end
	if not same_publication_owner(captured) then return nil end
	return captured
end

local function publication_owner_current(captured)
	if not same_publication_owner(captured) then return false end
	local state = captured.state
	if state.current_override_path then
		local called, path = pcall(state.current_override_path)
		if not called or path ~= captured.path then return false end
	end
	return same_publication_owner(captured)
end

--- Reserves a source attempt before reads, planning or physical publication.
local function begin_publication_attempt()
	if _terminal_owner ~= nil or not _state or _state.operation_active then return false end
	_state.operation_active = true
	_state.common_admitted = false
	_state.writes_blocked = true
	if _state.recovery.has_pending() and _state.recovery.retry() ~= true then
		_state.operation_active = false
		return false
	end
	if _state.recovery.begin() ~= true then
		_state.operation_active = false
		return false
	end
	return true
end

--- Existing ordinary writes keep the native conditional owner's call boundary.
local function publish_native_override(path, content, files, expected, on_error)
	return files.write_if_unchanged(path, content, expected, on_error)
end

local function finish_publication_attempt(accepted)
	local accepted = _state.recovery.finish(accepted)
	_state.operation_active = false
	return accepted == true
end

--- Reads and parses the user override file.
--- @param path string Absolute path to the override file.
--- @return table overrides The parsed overrides.
--- @return string|nil word_delimiters The optional word-delimiter override.
--- @return string status `committed`, `absent`, or `error`.
--- @return table|nil source_snapshot Exact classified bytes used to build the result.
--- @return string[] global_passthrough Exact raw records for unowned [__global__] keys.
--- @return boolean|nil common_admitted Exact common activation admission after migration.
local function parse_overrides(path)
	if not begin_publication_attempt() then return {}, nil, "error", nil, {} end
	local Migration = require("hotstrings.common_autocorrection_migration")
	local read_ok, migrated = pcall(Migration.run, path, Paths.shared(Migration.POLICY_PATH), FileSystem,
		_state.on_publication_error, _state.recovery.publish)
	local accepted = read_ok and type(migrated) == "table"
		and (migrated.status == "absent" or migrated.status == "current" or migrated.status == "migrated")
	if not finish_publication_attempt(accepted) then return {}, nil, "error", nil, {} end
	local content = read_ok and migrated.content or nil
	local read_status = read_ok and migrated.status or "error"
	local read_detail = read_ok and migrated.detail or tostring(migrated)
	if not read_ok or read_status == "error" then
		Logger.error(LOG, "Override source read did not commit: %s.",
			tostring(read_ok and read_detail or content))
		return {}, nil, "error", nil, {}
	end
	if read_status == "absent" then
		return {}, nil, "absent", { status = "absent" }, {}, true
	end
	if (read_status ~= "current" and read_status ~= "migrated") or type(content) ~= "string" then
		Logger.error(LOG, "Override source returned an invalid read status: %s.", tostring(read_status))
		return {}, nil, "error", nil, {}
	end
	local result, word_delimiters, global_passthrough = parse_override_content(content)
	return result, word_delimiters, "committed", { status = "ok", content = content }, global_passthrough, migrated.common_admitted ~= false
end

--- Serializes the in-memory override table back to TOML.
--- @param overrides table The override table (same shape as parse_overrides).
--- @param word_delimiters string|nil The [__global__] word_delimiters value, if set.
--- @param global_passthrough string[] Exact raw records for unowned [__global__] keys.
--- @return string|nil content The serialized TOML content.
--- @return string|nil error_detail Validation failure without untrusted bytes.
local function serialize_overrides(overrides, word_delimiters, global_passthrough)
	if type(overrides) ~= "table" then return nil, "override root must be a table" end
	local out = {
		"# Hotstrings — overrides utilisateur",
		"# Édité depuis la fenêtre « Délais & couleurs hotstrings ».",
		"# Ne pas mélanger les sections : chaque [category] et [category.section]",
		"# ne doit apparaître qu'une seule fois.",
		"",
	}

	-- [__global__] is re-emitted FIRST. parse_overrides returns it as a separate
	-- value from the category table, and this function only ever received the
	-- second — so every save from the delays-and-colours window rewrote the file
	-- without it, silently discarding the word_delimiters the AutoHotkey driver
	-- writes into the very same shared file. A round trip that reads more than it
	-- writes destroys whatever it did not read.
	local has_word_delimiters = type(word_delimiters) == "string" and word_delimiters ~= ""
	local has_passthrough = type(global_passthrough) == "table" and #global_passthrough > 0
	if has_word_delimiters or has_passthrough then
		table.insert(out, "[__global__]")
		-- Written in the shape the PARSER reads: a plain double-quoted string with
		-- only the quote and the backslash escaped. string.format("%q") emits LUA
		-- escapes — a tab becomes \9 — which round-trips through Lua and not
		-- through `word_delimiters%s*=%s*"(.-)"`.
		if has_word_delimiters then
			table.insert(out, "word_delimiters = " .. ConfigSchema.encode_basic_string(word_delimiters))
		end
		for _, assignment in ipairs(global_passthrough or {}) do
			table.insert(out, assignment)
		end
		table.insert(out, "")
	end

	-- Stable ordering: alphabetical category, alphabetical section.
	local cats = {}
	for cat, entry in pairs(overrides) do
		if not ConfigSchema.is_category(cat) then
			return nil, "override category must be a bare supported identifier"
		end
		if type(entry) ~= "table" then return nil, "override category entry must be a table" end
		table.insert(cats, cat)
	end
	table.sort(cats)

	for _, cat in ipairs(cats) do
		local entry = overrides[cat]
		local has_file_level = entry.delay ~= nil or entry.color ~= nil or entry.show_tooltip ~= nil
			or entry.priority ~= nil
		if has_file_level then
			table.insert(out, string.format("[%s]", cat))
			if entry.delay ~= nil then
				if not ConfigSchema.is_delay(entry.delay) then
					return nil, "override delay must be a finite non-negative number"
				end
				table.insert(out, string.format("delay = %s", tostring(entry.delay)))
			end
			if entry.color ~= nil then
				local encoded = ConfigSchema.encode_basic_string(entry.color)
				if not encoded then return nil, "override color must be a string" end
				table.insert(out, "color = " .. encoded)
			end
			if entry.show_tooltip ~= nil then
				table.insert(out, string.format("show_tooltip = %s", entry.show_tooltip and "true" or "false"))
			end
			if entry.priority ~= nil then
				table.insert(out, string.format("priority = %d", math.floor(entry.priority)))
			end
			table.insert(out, "")
		end

		if entry.sections ~= nil and type(entry.sections) ~= "table" then
			return nil, "override sections must be a table"
		end
		if entry.sections then
			local secs = {}
			for sec, section_entry in pairs(entry.sections) do
				if not ConfigSchema.is_section(sec) then
					return nil, "override section must be a bare supported identifier"
				end
				if type(section_entry) ~= "table" then
					return nil, "override section entry must be a table"
				end
				table.insert(secs, sec)
			end
			table.sort(secs)
			for _, sec in ipairs(secs) do
				local s_entry = entry.sections[sec]
				if s_entry.delay ~= nil or s_entry.color ~= nil or s_entry.show_tooltip ~= nil
					or s_entry.priority ~= nil then
					table.insert(out, string.format("[%s.%s]", cat, sec))
					if s_entry.delay ~= nil then
						if not ConfigSchema.is_delay(s_entry.delay) then
							return nil, "override section delay must be a finite non-negative number"
						end
						table.insert(out, string.format("delay = %s", tostring(s_entry.delay)))
					end
					if s_entry.color ~= nil then
						local encoded = ConfigSchema.encode_basic_string(s_entry.color)
						if not encoded then return nil, "override color must be a string" end
						table.insert(out, "color = " .. encoded)
					end
					if s_entry.show_tooltip ~= nil then
						table.insert(out, string.format("show_tooltip = %s", s_entry.show_tooltip and "true" or "false"))
					end
					if s_entry.priority ~= nil then
						table.insert(out, string.format("priority = %d", math.floor(s_entry.priority)))
					end
					table.insert(out, "")
				end
			end
		end
	end

	return table.concat(out, "\n")
end

--- Clones an override tree so a setter can build an unpublished candidate.
--- @param value any Value to clone.
--- @return any clone
local function clone_value(value)
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, child in pairs(value) do clone[key] = clone_value(child) end
	return clone
end

--- Returns whether two classified source snapshots denote identical bytes.
--- @param left table|nil
--- @param right table|nil
--- @return boolean equal
local function source_snapshots_equal(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	if left.status ~= right.status then return false end
	return left.status ~= "ok" or left.content == right.content
end

--- Adopts a newer committed source after a conditional publication conflict.
--- Ordinary I/O failures retain the last committed memo; only a proven source
--- change replaces it. An unreadable revalidation blocks later writes.
local function refresh_after_failed_publication()
	if _state.recovery.has_pending() or _state.operation_active then
		_state.common_admitted = false
		_state.writes_blocked = true
		return false
	end
	local overrides, word_delimiters, read_status, source_snapshot, global_passthrough, common_admitted =
		parse_overrides(_state.path)
	if read_status == "error" then
		_state.common_admitted = false
		_state.writes_blocked = true
		Logger.error(LOG, "Override publication failed and source revalidation did not commit; writes blocked.")
		return
	end
	if source_snapshots_equal(source_snapshot, _state.source_snapshot) then return end
	if _state.delay_transaction
		and _state.delay_transaction(delay_projection(overrides), function() return true end) ~= true then
		_state.writes_blocked = true
		_state.common_admitted = false
		Logger.error(LOG, "Override source adoption refused by the delay owner.")
		return false
	end
	_state.overrides       = overrides
	_state.word_delimiters = word_delimiters
	_state.global_passthrough = global_passthrough
	_state.source_snapshot = source_snapshot
	_state.epoch = _state.epoch + 1
	_state.common_admitted = common_admitted
	_state.writes_blocked  = false
	_state.resolve_cache   = {}
	Logger.warn(LOG, "Override publication lost a source race; newer external bytes were adopted.")
end

--- Preserves every unowned record while publishing only changed override leaves.
--- @param overrides table Candidate known overrides.
--- @param word_delimiters string|nil Candidate global delimiter choice.
--- @return string|nil content Prepared source bytes.
--- @return string|nil detail Refusal reason.
local function prepare_override_content(overrides, word_delimiters)
	local updates = {}
	local function leaves(source)
		local rows = {}
		for category, entry in pairs(source) do
			for _, field in ipairs({ "delay", "color", "show_tooltip", "priority" }) do
				if entry[field] ~= nil then rows[category .. "\0" .. field] = { category, field, entry[field] } end
			end
			for section, values in pairs(entry.sections or {}) do
				for _, field in ipairs({ "delay", "color", "show_tooltip", "priority" }) do
					if values[field] ~= nil then
						local path = category .. "." .. section
						rows[path .. "\0" .. field] = { path, field, values[field] }
					end
				end
			end
		end
		return rows
	end
	local previous, candidate = leaves(_state.overrides), leaves(overrides)
	for id, row in pairs(candidate) do
		if previous[id] == nil or previous[id][3] ~= row[3] then
			updates[#updates + 1] = { section = row[1], key = row[2], value = row[3] }
		end
	end
	for id, row in pairs(previous) do
		if candidate[id] == nil then updates[#updates + 1] = { section = row[1], key = row[2], delete = true } end
	end
	if word_delimiters ~= nil or word_delimiters ~= _state.word_delimiters then
		updates[#updates + 1] = { section = "__global__", key = "word_delimiters",
			value = word_delimiters, delete = word_delimiters == nil }
	end
	local snapshot = _state.source_snapshot
	local content = snapshot.status == "ok" and snapshot.content or ""
	local scan, scan_error = TomlScanner.scan_records(content, { quoted_headers = true })
	if not scan then return nil, scan_error end
	local function prefix(path, ancestor)
		if #path < #ancestor then return false end
		for index, part in ipairs(ancestor) do if path[index]:lower() ~= part:lower() then return false end end
		return true
	end
	for _, row in ipairs(updates) do
		local section = TomlKeyPath.parse(row.section)
		local target = TomlKeyPath.parse(row.section .. "." .. row.key)
		local headers, fields = 0, 0
		for _, header in ipairs(scan.headers) do
			if not header.segments then return nil, "unrecognized TOML table identity" end
			if header.array and prefix(target, header.segments) then return nil, "array element has no override owner" end
			if prefix(header.segments, target) then return nil, "override scalar is already a table" end
			if #header.segments == #section and prefix(section, header.segments) then
				headers = headers + 1
				local raw = scan.lines[header.index].text:match("^%s*(.-)%s*$")
				if raw ~= "[" .. row.section .. "]" then return nil, "override header is not reader-owned" end
			end
		end
		if headers > 1 then return nil, "duplicate override table" end
		for _, record in ipairs(scan.records) do
			local raw = scan.lines[record.first].text
			local key_text = raw:match("^%s*([^=]-)%s*=")
			local key = key_text and TomlKeyPath.parse(key_text)
			if key then
				local path = {}
				for _, part in ipairs(record.header and record.header.segments or {}) do path[#path + 1] = part end
				for _, part in ipairs(key) do path[#path + 1] = part end
				if prefix(target, path) or prefix(path, target) then
					if #path ~= #target or #key ~= 1 or key_text:match("^%s*(.-)%s*$") ~= row.key then
						return nil, "override leaf conflicts with an unowned representation"
					end
					fields = fields + 1
				end
			end
		end
		if fields > 1 then return nil, "duplicate override field" end
		local encoded
		if not row.delete then
			if type(row.value) == "string" then encoded = ConfigSchema.encode_basic_string(row.value)
			elseif row.key == "priority" then encoded = tostring(math.floor(row.value))
			else encoded = tostring(row.value) end
		end
		local detail
		content, detail = TomlRecordEditor.patch_table_field(content, "[" .. row.section .. "]", row.key,
			encoded, { remove_empty_section = true })
		if not content then return nil, detail end
	end
	return content
end


--- Persists a candidate override state through the atomic file-system adapter.
--- @param overrides table Candidate overrides.
--- @param word_delimiters string|nil Candidate delimiter override.
--- @return boolean True on success, false on I/O failure.
local function save_to_disk(overrides, word_delimiters)
	if not _state then return false end
	if _state.writes_blocked then
		Logger.error(LOG, "Override save refused because the source read did not commit.")
		return false
	end
	local content, serialize_err = serialize_overrides(overrides, word_delimiters, _state.global_passthrough)
	if not content then
		Logger.error(LOG, "Override save refused because the candidate schema is invalid: %s.",
			tostring(serialize_err))
		return false
	end
	local prepared, prepare_error = prepare_override_content(overrides, word_delimiters)
	if not prepared then
		Logger.error(LOG, "Override source preparation refused: %s.", tostring(prepare_error))
		refresh_after_failed_publication()
		return false
	end
	content = prepared
	local previous_common_admission = _state.common_admitted
	if not begin_publication_attempt() then return false end
	local function publish()
		return _state.recovery.publish(_state.path, content, FileSystem,
			_state.source_snapshot, _state.on_publication_error, publish_native_override)
	end
	local ok, committed = pcall(function()
		if _state.delay_transaction then
			return _state.delay_transaction(delay_projection(overrides), publish)
		end
		return publish()
	end)
	local accepted = finish_publication_attempt(ok and committed == true)
	if not accepted then
		Logger.error(LOG, "Failed to commit override file against its loaded source snapshot.")
		refresh_after_failed_publication()
		return false
	end
	_state.common_admitted = previous_common_admission
	_state.writes_blocked = false
	Logger.debug(LOG, "Override file written: '%s'.", _state.path)
	return true, content
end


-- ====================================
-- ====================================
-- ======= 4/ TOML Meta Cache =========
-- ====================================
-- ====================================

--- The sections of a category that other files supply: a layout extension binds
--- some sections of a bundled category (the magic key's repeat corrections on
--- Ergopti) to its own file, which carries their entries and their metadata.
--- @param category string Category name.
--- @param toml_path string The category's own file.
--- @return table Array of { name, section, meta } in binding order; section and
---   meta are the bound file's records for that section, nil when it has none.
local function bound_sections(category, toml_path)
	local resolver = _state.section_sources_resolver
	local sources = resolver and resolver(category, toml_path) or nil
	local out = {}
	for _, source in ipairs(type(sources) == "table" and sources or {}) do
		local ok, parsed, committed = pcall(TomlReader.parse, source.path)
		if not ok or committed ~= true or type(parsed) ~= "table" then
			Logger.error(LOG, "Bound section TOML read did not commit: '%s'.", tostring(source.path))
		else
			local meta_sections = type(parsed.meta) == "table" and parsed.meta.sections or nil
			for _, name in ipairs(source.sections) do
				out[#out + 1] = {
					name    = name,
					section = type(parsed.sections) == "table" and parsed.sections[name] or nil,
					meta    = type(meta_sections) == "table" and meta_sections[name] or nil,
				}
			end
		end
	end
	return out
end

--- Returns the meta block for a category, parsing the TOML on first access.
--- Result shape: { delay = n?, color = s?, sections = { [name] = { delay, color, description } } }
--- A section another file supplies takes its metadata from that file.
--- @param category string Category name (lowercase, e.g. "rolls").
--- @return table The meta block (always a table, fields may be nil).
local function get_toml_meta(category)
	local cache = _state.toml_cache
	if cache[category] then return cache[category] end

	local toml_path = _state.toml_resolver(category)
	if type(toml_path) ~= "string" or toml_path == "" then
		cache[category] = { sections = {} }
		return cache[category]
	end

	local parse_ok, parsed, committed = pcall(TomlReader.parse, toml_path)
	if not parse_ok or committed ~= true or type(parsed) ~= "table" then
		Logger.error(LOG, "Category TOML read did not commit: '%s'.", toml_path)
		return { sections = {} }
	end
	-- Copied before merging: the reader may hand back a snapshot other readers share.
	local sections = {}
	for name, meta in pairs(parsed.meta.sections or {}) do sections[name] = meta end
	if PersonalFiles.components(category) then
		for name in pairs(parsed.meta.section_delays or {}) do sections[name] = personal_section_metadata(parsed.meta, name) end
	end
	for _, bound in ipairs(bound_sections(category, toml_path)) do sections[bound.name] = bound.meta end
	cache[category] = {
		delay        = parsed.meta.delay,
		color        = parsed.meta.color,
		show_tooltip = parsed.meta.show_tooltip,
		priority     = parsed.meta.priority,
		sections     = sections,
	}
	return cache[category]
end





--- =============================
--- =============================
--- ======= 5/ Public API =======
--- =============================
--- =============================

--- Initializes the module. Must be called before any resolve/setter.
--- @param opts table { override_path = string, toml_resolver = function(category) -> path,
---   section_sources_resolver = function(category, path) -> { { path, sections } }|nil (optional):
---   the sections other files supply for a category, as the keymap loads them }
function M.init(opts)
	if _terminal_owner ~= nil then return false end
	Logger.start(LOG, "Initializing…")
	if type(opts) ~= "table"
		or type(opts.override_path) ~= "string" or opts.override_path == ""
		or type(opts.toml_resolver) ~= "function"
		or (opts.delay_transaction ~= nil and type(opts.delay_transaction) ~= "function")
		or (opts.section_sources_resolver ~= nil and type(opts.section_sources_resolver) ~= "function")
		or (opts.current_override_path ~= nil and type(opts.current_override_path) ~= "function")
	then
		Logger.error(LOG, "M.init(): opts.override_path and opts.toml_resolver are required.")
		return
	end
	if _state then
		if _state.operation_active or _state.recovery.has_pending() then return false end
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	_state = {
		path            = opts.override_path,
		toml_resolver   = opts.toml_resolver,
		section_sources_resolver = opts.section_sources_resolver,
		delay_transaction = opts.delay_transaction,
		overrides       = {},
		global_passthrough = {},
		common_admitted = false,
		writes_blocked  = true,
		epoch = 1,
		owner_epoch = 0,
		current_override_path = opts.current_override_path,
		toml_cache      = {},
		-- Memo for M.resolve, cleared by the three writers that can change an
		-- answer. Living in _state means M.init() resets it without a separate
		-- lifecycle to remember.
		resolve_cache   = {},
	}
	local state = _state
	state.on_publication_error = function()
		Logger.error(LOG, "Conditional override publication reported a native refusal.")
	end
	state.recovery = PublicationRecovery.new({ files = FileSystem,
		capture = function() return capture_publication_owner(state) end,
		current = publication_owner_current })
	local overrides, word_delimiters, read_status, source_snapshot, global_passthrough, common_admitted =
		parse_overrides(opts.override_path)
	if read_status == "error" then
		Logger.error(LOG, "Initialization degraded: override source is unreadable and writes are blocked.")
		return false
	end
	if _state.delay_transaction
		and _state.delay_transaction(delay_projection(overrides), function() return true end) ~= true then
		_state.writes_blocked = true
		Logger.error(LOG, "Override delay owner initialization was refused.")
		return false
	end
	_state.overrides = overrides
	_state.word_delimiters = word_delimiters
	_state.global_passthrough = global_passthrough
	_state.source_snapshot = source_snapshot
	_state.epoch = _state.epoch + 1
	_state.common_admitted = common_admitted == true
	_state.writes_blocked = false
	Logger.success(LOG, "Initialized (override file: '%s').", opts.override_path)
	return true
end

--- Returns the effective delay (seconds) and color (hex string) for a group.
--- @param category string The TOML file name without extension (e.g. "rolls").
--- @param section string|nil Optional section name within the category.

--- Returns the shared global default expansion delay, in milliseconds.
---
--- Published so consumers read the canon instead of mirroring it. The hotstrings
--- config window carried its own `GLOBAL_DEFAULT_DELAY_MS = 750` with a comment
--- saying the two "must stay in sync" — which is the definition of two sources,
--- and the shared TOML is the one the AutoHotkey driver reads.
--- @return number|nil Milliseconds, or nil before init() has loaded the canon.
function M.get_global_default_delay_ms()
	if type(GLOBAL_DEFAULT_DELAY) ~= "number" then return nil end
	-- GLOBAL_DEFAULT_DELAY is held in seconds; the window speaks milliseconds.
	return math.floor(GLOBAL_DEFAULT_DELAY * 1000 + 0.5)
end

--- Copies one cascade rung while dropping an invalid activation delay.
--- Other independently-resolved fields must remain visible to the resolver.
--- @param entry table|nil Source settings rung.
--- @return table|nil sanitized
local function sanitized_resolution_entry(entry)
	if type(entry) ~= "table" then return nil end
	return {
		delay        = ConfigSchema.is_delay(entry.delay) and entry.delay or nil,
		color        = entry.color,
		show_tooltip = entry.show_tooltip,
		priority     = type(entry.priority) == "number" and entry.priority or nil,
	}
end

--- Builds a pure runtime projection from one unpublished override candidate.
--- Corpus metadata comes from the registry's already committed parse, never I/O
--- on the input path. The shared cascade remains the sole precedence owner.
--- @param overrides table Candidate override tree.
--- @return function resolve Group/section/corpus resolver in seconds.
delay_projection = function(overrides)
	return function(category, section, meta)
		local extension_id = Extensions.parse_category_key(category)
		local source_category = category
		if extension_id then
			source_category = assert(ConfigSchema.normalize_category("ext." .. extension_id),
				"extension has no supported override owner")
		end
		if PersonalFiles.components(category) then
			source_category = personal_override_owner(category, overrides)
		end
		local user = overrides[source_category] or {}
		local user_section = (user.sections or {})[section]
		local meta_section = meta.sections and meta.sections[section]
		if PersonalFiles.components(category) then
			meta_section = personal_section_metadata(meta, section)
		elseif type(meta_section) ~= "table" and meta.section_delays then
			meta_section = { delay = meta.section_delays[section] }
		end
		return DelayResolver.resolve({
			user_category = sanitized_resolution_entry(user),
			user_section = sanitized_resolution_entry(user_section),
			meta_category = sanitized_resolution_entry(meta),
			meta_section = sanitized_resolution_entry(meta_section),
			default_delay = PersonalFiles.components(category) and PersonalFiles.additional_default_delay_seconds
				or GLOBAL_DEFAULT_DELAY,
		}).delay
	end
end


--- @return table { delay, color, show_tooltip, priority, has_override }
function M.resolve(category, section)
	if not require_state("resolve") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil, show_tooltip = true,
			priority = HotstringPriority.source_priority(category), has_override = false }
	end

	-- Memoised, like the AutoHotkey sibling (_HSResolveCache / _HSResolveGen in
	-- infra/hotstrings/hotstrings_config.ahk). The answer for a (category, section)
	-- pair is static between override and TOML changes, and the tooltip preview
	-- resolves it once per CANDIDATE on every keystroke — so the cascade was being
	-- re-walked several times per key on the HID thread. The two drivers were
	-- paying different costs for the same cascade because only one of them had
	-- reached this conclusion.
	--
	-- Invalidated by clearing the table in the three writers that can change the
	-- answer (set_override, clear_override, reload) rather than by a generation
	-- counter: the cache lives in _state, so M.init() resets it for free.
	--
	-- A registered extension pack group (ext:<id>:<stem>) is not a bare category:
	-- its metadata is its own file, which the resolver names, and its overrides
	-- belong to the extension's ext.<id> owner, exactly as resolve_ext reads them.
	local extension_id = Extensions.parse_category_key(category)
	if extension_id then
		local ok_path, pack_path = pcall(_state.toml_resolver, category)
		if ok_path and type(pack_path) == "string" and pack_path ~= "" then
			return M.resolve_ext(extension_id, pack_path, section)
		end
	end
	local personal = PersonalFiles.components(category) ~= nil
	local canonical_category = personal and category or ConfigSchema.normalize_category(category)
	if not canonical_category or (not personal and not ConfigSchema.is_section(section))
		or (personal and section ~= nil and type(section) ~= "string") then
		Logger.error(LOG, "resolve(): category and section must be supported bare identifiers.")
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil, show_tooltip = true,
			priority = HotstringPriority.source_priority(category), has_override = false }
	end
	local requested_section = section
	category = canonical_category
	section = personal and section or ConfigSchema.normalize_section(section)

	local cache_key = category .. "\0" .. tostring(requested_section or "")
	local cached = _state.resolve_cache and _state.resolve_cache[cache_key]
	if cached then return cached end

	local override_category = category
	if personal then
		override_category = personal_override_owner(category, _state.overrides)
	end
	local user = _state.overrides[override_category] or { sections = {} }
	local user_sec = section and (user.sections or {})[section] or nil
	local meta = get_toml_meta(category)
	local meta_sec = requested_section and meta.sections[requested_section] or nil

	-- The cascade itself lives in _shared/lua/hotstrings/delay_resolver.lua.
	-- It was written once here and once in AutoHotkey, and the two had already
	-- drifted on what an explicit `false` means — which matters, because a
	-- category that ships `show_tooltip = false` is the common case and a rung
	-- testing truthiness turns its preview back on.
	local resolved = DelayResolver.resolve({
		user_category  = sanitized_resolution_entry(user),
		user_section   = sanitized_resolution_entry(user_sec),
		meta_category  = sanitized_resolution_entry(meta),
		meta_section   = sanitized_resolution_entry(meta_sec),
		default_delay  = personal and PersonalFiles.additional_default_delay_seconds or GLOBAL_DEFAULT_DELAY,
		default_color  = GLOBAL_DEFAULT_COLOR,
		category_color = CATEGORY_DEFAULT_COLORS[category],
		default_priority = HotstringPriority.source_priority(category),
	})
	if _state.resolve_cache then _state.resolve_cache[cache_key] = resolved end
	return resolved
end

--- Resolves the effective delay and color for an extension hotstring file.
--- Mirrors HotstringsResolveExt() on the AHK side.
--- @param ext_id string Extension identifier (e.g. "ergopti-demo").
--- @param toml_path string Absolute path to the extension TOML file.
--- @param section string|nil Optional section name within the file.
--- @return table { delay, color, show_tooltip, priority, has_override }
function M.resolve_ext(ext_id, toml_path, section)
	if not require_state("resolve_ext") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = GLOBAL_DEFAULT_COLOR, show_tooltip = true,
			priority = HotstringPriority.source_priority("ext." .. tostring(ext_id or "")), has_override = false }
	end

	local override_key = type(ext_id) == "string"
		and ConfigSchema.normalize_category("ext." .. ext_id)
		or nil
	if not override_key or not ConfigSchema.is_section(section) then
		Logger.error(LOG, "resolve_ext(): extension and section must be supported bare identifiers.")
		return { delay = GLOBAL_DEFAULT_DELAY, color = GLOBAL_DEFAULT_COLOR,
			show_tooltip = true, priority = HotstringPriority.source_priority(override_key),
			has_override = false }
	end
	local requested_section = section
	section = ConfigSchema.normalize_section(section)
	local user = _state.overrides[override_key] or { sections = {} }
	local user_sec = section and (user.sections or {})[section] or nil

	-- Read the extension TOML meta directly (bypasses the category-name resolver).
	local cache_key = "ext:" .. toml_path
	if not _state.toml_cache[cache_key] then
		local ok, parsed, committed = pcall(TomlReader.parse, toml_path)
		if ok and committed == true and type(parsed) == "table" then
			_state.toml_cache[cache_key] = {
				delay        = parsed.meta and parsed.meta.delay,
				color        = parsed.meta and parsed.meta.color,
				show_tooltip = parsed.meta and parsed.meta.show_tooltip,
				priority     = parsed.meta and parsed.meta.priority,
				sections     = (parsed.meta and parsed.meta.sections) or {},
			}
		else
			Logger.error(LOG, "Extension TOML read did not commit: '%s'.", toml_path)
			return { delay = GLOBAL_DEFAULT_DELAY, color = GLOBAL_DEFAULT_COLOR,
				show_tooltip = true, priority = HotstringPriority.source_priority(override_key),
				has_override = false }
		end
	end
	local meta     = _state.toml_cache[cache_key]
	local meta_sec = requested_section and meta.sections[requested_section] or nil

	return DelayResolver.resolve({
		user_category = sanitized_resolution_entry(user),
		user_section = sanitized_resolution_entry(user_sec),
		meta_category = sanitized_resolution_entry(meta),
		meta_section = sanitized_resolution_entry(meta_sec),
		default_delay = GLOBAL_DEFAULT_DELAY,
		default_color = GLOBAL_DEFAULT_COLOR,
		default_priority = HotstringPriority.source_priority(override_key),
	})
end

--- Sets a user override for a single field. Pass section=nil for file-level.
--- @param category string
--- @param section string|nil
--- @param field string "delay" or "color"
--- @param value number|string The new value. Use M.clear_override to remove.
--- @return boolean True on success.
function M.set_override(category, section, field, value)
	if not require_state("set_override") or not scope_admits("set_override") then return false end
	if field ~= "delay" and field ~= "color" and field ~= "show_tooltip" and field ~= "priority" then
		Logger.error(LOG, "set_override(): field must be 'delay', 'color', 'show_tooltip', or 'priority', got '%s'.", tostring(field))
		return false
	end
	if not ConfigSchema.is_category(category) or not ConfigSchema.is_section(section) then
		Logger.error(LOG, "set_override(): category and section must be supported bare identifiers.")
		return false
	end
	category = ConfigSchema.normalize_category(category)
	section = ConfigSchema.normalize_section(section)
	if field == "color" and not ConfigSchema.is_color(value) then
		Logger.error(LOG, "set_override(): color must contain 3 to 8 hexadecimal digits.")
		return false
	end
	if field == "delay" and not ConfigSchema.is_delay(value) then
		Logger.error(LOG, "set_override(): delay must be a finite non-negative number.")
		return false
	end

	local candidate = clone_value(_state.overrides)
	candidate[category] = candidate[category] or { sections = {} }
	local entry = candidate[category]
	entry.sections = entry.sections or {}

	if section then
		entry.sections[section] = entry.sections[section] or {}
		entry.sections[section][field] = value
	else
		entry[field] = value
	end

	local committed, content = save_to_disk(candidate, _state.word_delimiters)
	if not committed then return false end
	_state.overrides = candidate
	_state.source_snapshot = { status = "ok", content = content }
	_state.epoch = _state.epoch + 1
	_state.resolve_cache = {}
	Logger.debug(LOG, "Override set: %s%s.%s = %s.",
		category, section and ("." .. section) or "", field, tostring(value))
	return true
end

--- Removes a user override for a field. Reverts to the TOML/global default.
--- @param category string
--- @param section string|nil
--- @param field string|nil "delay", "color", or nil to clear both.
--- @return boolean True on success.
function M.clear_override(category, section, field)
	if not require_state("clear_override") or not scope_admits("clear_override") then return false end
	if _state.writes_blocked then
		Logger.error(LOG, "Override clear refused because the source read did not commit.")
		return false
	end
	if not ConfigSchema.is_category(category) or not ConfigSchema.is_section(section) then
		Logger.error(LOG, "clear_override(): category and section must be supported bare identifiers.")
		return false
	end
	category = ConfigSchema.normalize_category(category)
	section = ConfigSchema.normalize_section(section)
	local candidate = clone_value(_state.overrides)
	local entry = candidate[category]
	if not entry then return true end

	local target = section and (entry.sections or {})[section] or entry
	if not target then return true end

	if field then
		target[field] = nil
	else
		target.delay        = nil
		target.color        = nil
		target.show_tooltip = nil
		target.priority     = nil
	end

	local committed, content = save_to_disk(candidate, _state.word_delimiters)
	if not committed then return false end
	_state.overrides = candidate
	_state.source_snapshot = { status = "ok", content = content }
	_state.epoch = _state.epoch + 1
	_state.resolve_cache = {}
	Logger.debug(LOG, "Override cleared: %s%s%s.",
		category,
		section and ("." .. section) or "",
		field and ("." .. field) or "")
	return true
end

--- Returns the absolute path of the override file (for diagnostics / UI).
--- @return string|nil
function M.get_override_path()
	if not _state then return nil end
	return _state.path
end

--- Re-reads the override file from disk, discarding the in-memory overrides
--- table and rebuilding it from `_state.path`. Intended for the case where the
--- AHK driver has externally rewritten the shared override file while this
--- process is still running.
---
--- Delimiter updates invoke this before building their candidate because the
--- override file is shared with the Windows driver. Conditional publication
--- also adopts a newer external version after detecting a lost race.
--- @return boolean
function M.reload()
	if not require_state("reload") or not scope_admits("reload") then return false end
	local overrides, word_delimiters, read_status, source_snapshot, global_passthrough, common_admitted =
		parse_overrides(_state.path)
	if read_status == "error" then
		_state.common_admitted = false
		_state.writes_blocked = true
		Logger.error(LOG, "Override reload failed; prior memory retained and writes blocked.")
		return false
	end
	if _state.delay_transaction
		and _state.delay_transaction(delay_projection(overrides), function() return true end) ~= true then
		_state.writes_blocked = true
		_state.common_admitted = false
		Logger.error(LOG, "Override source adoption refused by the delay owner.")
		return false
	end
	_state.overrides       = overrides
	_state.word_delimiters = word_delimiters
	_state.global_passthrough = global_passthrough
	_state.source_snapshot = source_snapshot
	_state.epoch = _state.epoch + 1
	_state.common_admitted = common_admitted
	_state.writes_blocked  = false
	_state.resolve_cache   = {}
	Logger.debug(LOG, "Overrides reloaded from disk.")
	return true
end

--- Parses override bytes exactly as the running configuration reads them.
--- @param content string Override source bytes ("" for an absent file).
--- @return table overrides Category key to override entry.
function M.parse_override_content(content)
	assert(type(content) == "string", "override content must be a string")
	return (parse_override_content(content))
end

--- The delay resolver of one override tree, as the registry projection runs it.
--- @param overrides table Reader override tree.
--- @return function resolve (group, section, corpus metadata) -> seconds.
function M.delay_projection(overrides)
	assert(type(overrides) == "table", "delay projection needs an override tree")
	return delay_projection(overrides)
end

--- Holds the override file for one scope transaction; ordinary mutations and
--- reloads are refused until the owner releases it.
--- @param owner table Transaction identity.
--- @return boolean acquired
function M.acquire(owner)
	if _terminal_owner ~= nil or not require_state("acquire") or type(owner) ~= "table" or _state.scope_owner ~= nil
		or _state.operation_active or _state.recovery.has_pending() then return false end
	_state.scope_owner = owner
	_state.owner_epoch = _state.owner_epoch + 1
	return true
end

--- Releases the override file held by an owner.
--- @param owner table Transaction identity.
--- @return boolean released
function M.release(owner)
	if not require_state("release") or type(owner) ~= "table" or _state.scope_owner ~= owner then return false end
	_state.scope_owner = nil
	_state.owner_epoch = _state.owner_epoch + 1
	return true
end

--- Captures one actual held scope and its committed override memo generation.
--- Transient scope_candidate runtime phases remain the holding controller's own.
--- @param owner table Exact admitted scope identity.
--- @return function|nil current Bound strict admission check.
function M.capture_scope_owner(owner)
	if not require_state("capture_scope_owner") or type(owner) ~= "table" or _state.scope_owner ~= owner then return nil end
	local captured = capture_publication_owner(_state)
	if not captured or captured.scope_owner ~= owner then return nil end
	return function() return publication_owner_current(captured) end
end

--- The committed override state a scope may restore, or nil when the source
--- read did not commit and nothing may be written.
--- @return table|nil snapshot { source, overrides } detached from memory.
function M.scope_snapshot()
	if not require_state("scope_snapshot") or _state.writes_blocked then return nil end
	return { source = clone_value(_state.source_snapshot), overrides = clone_value(_state.overrides) }
end

--- Prepares one admitted source edit together with only its masking legacy leaves.
--- The caller holds this override owner until publication or a verified inverse.
function M.prepare_personal_metadata(owner, record, section, field, value)
	if not require_state("prepare_personal_metadata") or _state.scope_owner ~= owner or _state.writes_blocked
		or type(record) ~= "table" or record.admitted ~= true or not PersonalFiles.components(record.owner) then return nil end
	local loader = require("infra.personal_hotstrings")
	if loader.adoption_current(record) ~= true then return nil end
	local overrides = clone_value(_state.overrides)
	local legacy_name = personal_override_owner(record.owner, overrides)
	local legacy = overrides[legacy_name] or {}
	local plan = require("hotstrings.personal_metadata").prepare(record.content, section, field, value, legacy)
	if not plan then return nil end
	if legacy_name and legacy then
		if plan.remove_file then legacy[field] = nil end
		if plan.remove_section then legacy.sections[section][field] = nil end
	end
	local override_content = prepare_override_content(overrides, _state.word_delimiters)
	if not override_content then return nil end
	plan.override_path = _state.path
	plan.override_source = clone_value(_state.source_snapshot)
	plan.override_target = (_state.source_snapshot.status == "absent" and override_content == "")
		and { status = "absent" } or { status = "ok", content = override_content }
	plan.delay_resolver = delay_projection(overrides)
	plan.priority_reader = function(requested)
		local entry = overrides[personal_override_owner(record.owner, overrides)] or {}
		local leaf = requested and (entry.sections or {})[requested] or entry
		return type(leaf) == "table" and leaf.priority or nil
	end
	return plan
end

--- Reads the staged native catalogue and this held override owner, even disabled.
--- @param record table Captured canonical source owner.
--- @param section string|nil Declared literal section or file metadata.
--- @return table|nil effective
function M.personal_catalogue_effective(record, section)
	if not require_state("personal_catalogue_effective") or not _state.scope_owner
		or type(record) ~= "table" or record.admitted ~= true
		or require("infra.personal_hotstrings").adoption_current(record) ~= true then return nil end
	local catalogue = require("modules.keymap").hotstring_delay_inventory()
	local registered = type(catalogue) == "table" and catalogue[record.owner]
	if not registered or type(registered.metadata) ~= "table" then return nil end
	local candidate = _state.scope_candidate
	local overrides = candidate and candidate.owner == _state.scope_owner and candidate.overrides or _state.overrides
	local user = overrides[personal_override_owner(record.owner, overrides)] or {}
	return DelayResolver.resolve({
		user_category = sanitized_resolution_entry(user),
		user_section = sanitized_resolution_entry(section and (user.sections or {})[section] or nil),
		meta_category = sanitized_resolution_entry(registered.metadata),
		meta_section = sanitized_resolution_entry(section and personal_section_metadata(registered.metadata, section) or nil),
		default_delay = PersonalFiles.additional_default_delay_seconds,
		default_color = GLOBAL_DEFAULT_COLOR,
		default_priority = HotstringPriority.source_priority(record.owner),
	})
end

--- Adopts classified override bytes for the scope that holds the file: their
--- delays are projected onto the registry in the same transaction that runs
--- `publish`, and memory follows only once both committed. The same call puts
--- the previous bytes back, with `publish` restoring them.
--- @param owner table The holding transaction identity.
--- @param source table Classified bytes the file holds once `publish` returns true.
--- @param publish function Exact conditional publication, returning true.
--- @return boolean adopted
function M.adopt_scope_source(owner, source, publish)
	if _terminal_owner ~= nil or type(owner) ~= "table" or not require_state("adopt_scope_source")
		or _state.scope_owner ~= owner or _state.writes_blocked then
		return false
	end
	if _state.scope_candidate ~= nil then return false end
	assert(type(source) == "table" and (source.status == "absent"
		or (source.status == "ok" and type(source.content) == "string")), "scope override source is not classified")
	assert(type(publish) == "function", "scope override adoption needs its publication")
	local overrides, word_delimiters, global_passthrough = parse_override_content(source.content or "")
	local candidate = { owner = owner, overrides = overrides }
	_state.scope_candidate = candidate
	local ok, committed = pcall(function()
		if _state.delay_transaction then
			return _state.delay_transaction(delay_projection(overrides), publish)
		end
		return publish()
	end)
	if _state.scope_candidate == candidate then _state.scope_candidate = nil end
	if not ok or committed ~= true then
		Logger.error(LOG, "Scope override adoption did not commit: %s.", tostring(committed))
		return false
	end
	_state.overrides          = overrides
	_state.word_delimiters    = word_delimiters
	_state.global_passthrough = global_passthrough
	_state.source_snapshot    = source.status == "ok" and { status = "ok", content = source.content }
		or { status = "absent" }
	_state.epoch = _state.epoch + 1
	_state.resolve_cache      = {}
	_state.toml_cache         = {}
	Logger.debug(LOG, "Scope override source adopted (%s).", source.status)
	return true
end


-- =================================================
-- =================================================
-- ======= 6/ Introspection helpers (UI) ===========
-- =================================================
-- =================================================

--- Returns the ordered list of sections defined in a category TOML.
--- Each entry is { name = string, description = string }; separators ("-")
--- are filtered out. Used by the configuration window to render the section
--- list under each category, and by « reset all » to clear their overrides.
--- A section another file supplies (the magic key's repeat corrections, bound
--- by the Ergopti extension) is listed with that file's description, at the
--- place the category's declared order gives it, or last when it names none.
--- @param category string Category name (lowercase).
--- @return table List of section descriptors in TOML declaration order.
function M.get_sections(category)
	if not require_state("get_sections") then return {} end
	local toml_path = _state.toml_resolver(category)
	if type(toml_path) ~= "string" or toml_path == "" then return {} end
	local ok, parsed, committed = pcall(TomlReader.parse, toml_path)
	if not ok or committed ~= true or type(parsed) ~= "table" then
		Logger.error(LOG, "Section-list TOML read did not commit: '%s'.", toml_path)
		return {}
	end
	local bound_list, bound = bound_sections(category, toml_path), {}
	for _, entry in ipairs(bound_list) do bound[entry.name] = entry end
	local out, listed = {}, {}
	local function list(name)
		if name == "-" or listed[name] then return end
		local section = bound[name] and bound[name].section or parsed.sections[name]
		if section == nil and bound[name] == nil then return end
		listed[name] = true
		table.insert(out, { name = name, description = (section and section.description) or name })
	end
	-- The declared order first: the reader drops from its own order a name that
	-- neither this file's sections nor its metadata carry, which a bound section is.
	local declared = type(parsed.meta) == "table" and parsed.meta.sections_order or nil
	for _, name in ipairs(type(declared) == "table" and declared or {}) do list(name) end
	for _, name in ipairs(parsed.sections_order or {}) do list(name) end
	for _, entry in ipairs(bound_list) do list(entry.name) end
	return out
end

--- Returns the TOML-default delay/color for a (category, section) pair —
--- the values that would apply if the user override layer were empty.
--- Used by the UI to show "back to default" state and to drive the reset button.
--- @param category string
--- @param section string|nil
--- @return table { delay = number, color = string|nil }
function M.get_toml_defaults(category, section)
	if not require_state("get_toml_defaults") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil }
	end
	local personal = PersonalFiles.components(category) ~= nil
	local canonical_category = personal and category or ConfigSchema.normalize_category(category)
	if not canonical_category or (not personal and not ConfigSchema.is_section(section))
		or (personal and section ~= nil and type(section) ~= "string") then
		return { delay = GLOBAL_DEFAULT_DELAY, color = nil }
	end
	local requested_section = section
	category = canonical_category
	local meta = get_toml_meta(category)
	local meta_sec = requested_section and meta.sections[requested_section] or nil
	return {
		delay = (meta_sec and meta_sec.delay) or meta.delay
			or (personal and PersonalFiles.additional_default_delay_seconds or GLOBAL_DEFAULT_DELAY),
		color = (meta_sec and meta_sec.color) or meta.color,
		priority = (meta_sec and meta_sec.priority) or meta.priority,
	}
end

--- Whether initialized common override data permits native common activation.
--- Nil represents a resolver that has not initialized an override source yet.
--- @return boolean|nil admitted
--- Returns whether this controller still owns an unsettled native publication.
--- The native capability and original source remain private to recovery.
function M.has_pending_publication()
	return _state ~= nil and _state.recovery.has_pending()
end

--- Holds publication admission across a controlled terminal transition.
--- Existing source/scope recovery is never consumed here. An uninitialized
--- controller may grant early-boot recovery, but cannot initialize under that
--- exact token. Only a pre-fence abort may release the same live owner.
--- @return table|nil token Private zero-argument current/abort capabilities.
function M.capture_terminal_admission()
	if _terminal_owner ~= nil then return nil end
	local state = _state
	if state and (state.operation_active or state.recovery.has_pending()
		or state.scope_owner ~= nil or state.scope_candidate ~= nil) then return nil end
	local owner = {}
	_terminal_owner = owner
	local function current()
		return _terminal_owner == owner and _state == state
			and (not state or (not state.operation_active and not state.recovery.has_pending()
				and state.scope_owner == nil and state.scope_candidate == nil))
	end
	return {
		current = current,
		abort = function()
			if current() ~= true then return false end
			_terminal_owner = nil
			return true
		end,
	}
end

function M.common_autocorrection_admitted()
	return _state and _state.common_admitted
end

--- Returns the raw user override entry (or nil) for a (category, section)
--- pair. Distinguishing between "no override" and "override = TOML default"
--- is important for the UI's reset button state.
--- @param category string
--- @param section string|nil
--- @return table|nil { delay = number|nil, color = string|nil }
function M.get_user_override(category, section)
	if not require_state("get_user_override") then return nil end
	local personal = PersonalFiles.components(category) ~= nil
	if personal then
		if section ~= nil and type(section) ~= "string" then return nil end
		local record = require("infra.personal_hotstrings").adoption(category)
		if not record or record.admitted ~= true then return nil end
		category = personal_override_owner(category, _state.overrides)
	else
		category = ConfigSchema.normalize_category(category)
		if not category or not ConfigSchema.is_section(section) then return nil end
		section = ConfigSchema.normalize_section(section)
	end
	local cat = _state.overrides[category]
	if not cat then return nil end
	local target = section and (cat.sections or {})[section] or cat
	if not target then return nil end
	if target.delay == nil and target.color == nil and target.show_tooltip == nil
		and target.priority == nil then return nil end
	return { delay = target.delay, color = target.color, show_tooltip = target.show_tooltip,
		priority = target.priority }
end

-- =================================================
-- =================================================
-- ======= 7/ Word-delimiter API ===================
-- =================================================
-- =================================================

--- Returns the effective word-delimiter string: user override when stored,
--- otherwise the built-in DEFAULT_WORD_DELIMITERS constant (mirrors AHK default).
--- @return string
function M.get_word_delimiters()
	if not require_state("get_word_delimiters") then return DEFAULT_WORD_DELIMITERS end
	return _state.word_delimiters or DEFAULT_WORD_DELIMITERS
end

--- Returns the built-in default word-delimiter string.
--- @return string
function M.get_default_word_delimiters()
	return DEFAULT_WORD_DELIMITERS
end

--- Patches only the shared global delimiter key while preserving other bytes.
--- @param existing string Complete committed source content.
--- @param delimiters string|nil Candidate delimiter value.
--- @return string content Candidate file content.
local function patch_word_delimiters(existing, delimiters)
	local encoded = delimiters and ConfigSchema.encode_basic_string(delimiters) or nil
	return TomlRecordEditor.patch_table_field(
		existing,
		"[__global__]",
		"word_delimiters",
		encoded,
		{ remove_empty_section = true }
	)
end

--- Persists a new word-delimiter string to the [__global__] section of the
--- override file and updates the in-memory value.
--- Pass nil or the default string to clear the override (removes the key).
--- @param delimiters string|nil The new delimiter string, or nil to reset.
--- @return boolean True on success.
function M.set_word_delimiters(delimiters)
	if not require_state("set_word_delimiters") or not scope_admits("set_word_delimiters") then return false end

	local candidate
	if delimiters == nil or delimiters == DEFAULT_WORD_DELIMITERS then
		candidate = nil
	else
		candidate = delimiters
	end

	if _state.writes_blocked then
		Logger.error(LOG, "Delimiter save refused because the source read did not commit.")
		return false
	end
	-- Synchronize the complete shared file before patching one key. This keeps
	-- both the in-memory overrides and the publication precondition on the same
	-- exact cross-driver source version.
	if not M.reload() then return false end
	local snapshot = _state.source_snapshot
	local existing = snapshot.status == "ok" and snapshot.content or ""
	local content, patch_err = patch_word_delimiters(existing, candidate)
	if not content then
		Logger.error(LOG, "Failed to patch word_delimiters: %s.", tostring(patch_err))
		return false
	end
	local previous_common_admission = _state.common_admitted
	if not begin_publication_attempt() then return false end
	local write_ok, committed = pcall(_state.recovery.publish,
		_state.path, content, FileSystem, snapshot, _state.on_publication_error, publish_native_override)
	local accepted = finish_publication_attempt(write_ok and committed == true)
	if not accepted then
		Logger.error(LOG, "Failed to commit word_delimiters against its loaded source snapshot.")
		refresh_after_failed_publication()
		return false
	end
	_state.common_admitted = previous_common_admission
	_state.writes_blocked = false
	_state.word_delimiters = candidate
	_state.source_snapshot = { status = "ok", content = content }
	_state.epoch = _state.epoch + 1
	Logger.debug(LOG, "word_delimiters persisted: %s.", candidate and
		('"' .. tostring(candidate) .. '"') or "(default — key removed)")
	return true
end





-- ==========================================================
-- ==========================================================
-- ======= 8/ Bootstrap: shared cross-driver defaults =======
-- ==========================================================
-- ==========================================================

--- Reads _shared/modules/hotstrings/defaults.toml at require-time and populates the
--- three hard-fallback constants from the single cross-driver source. A missing
--- file, section, or key raises an error (fail fast — no driver-side literal).
--- The path is resolved relative to THIS file (cwd-independent), mirroring
--- ui/tooltip/config.lua, so it behaves identically in production and in the
--- headless unit harness (where the module is re-required per test).
local function load_shared_defaults()
	-- Resolved through the single shared-tree resolver (Paths.shared) so the
	-- shared root lives in exactly one place, cwd-independent in production and
	-- in the headless unit harness.
	local toml_path = Paths.shared("modules/hotstrings/defaults.toml")

	local parsed, committed = TomlReader.parse(toml_path)
	if committed ~= true then
		error("[hotstrings_config] _shared/modules/hotstrings/defaults.toml read did not commit: " .. toml_path)
	end
	local sections = (type(parsed) == "table") and parsed.sections or nil
	if type(sections) ~= "table" then
		error("[hotstrings_config] _shared/modules/hotstrings/defaults.toml not readable: " .. toml_path)
	end

	local function require_key(section, key)
		local s = sections[section]
		if type(s) ~= "table" or s[key] == nil then
			error(string.format("[hotstrings_config] missing key [%s].%s in %s", section, key, toml_path))
		end
		return s[key]
	end

	GLOBAL_DEFAULT_DELAY             = tonumber(require_key("delays", "default_sec"))
	GLOBAL_DEFAULT_COLOR             = require_key("colors", "global_default")
	CATEGORY_DEFAULT_COLORS.personal = require_key("colors", "personal")

	if type(GLOBAL_DEFAULT_DELAY) ~= "number" then
		error("[hotstrings_config] [delays].default_sec must be a number in " .. toml_path)
	end

	Logger.done(LOG, "Shared hotstring defaults loaded (delay=%.2fs color=%s personal=%s).",
		GLOBAL_DEFAULT_DELAY, tostring(GLOBAL_DEFAULT_COLOR), tostring(CATEGORY_DEFAULT_COLORS.personal))
end

load_shared_defaults()

return M
