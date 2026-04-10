--- modules/keymap/registry.lua

--- ==============================================================================
--- MODULE: Keymap Registry
--- DESCRIPTION:
--- Handles the storage, sorting, and lookup of hotstring mappings, groups,
--- and terminators.
---
--- FEATURES & RATIONALE:
--- 1. Data Isolation: Keeps the heavy lookup tables out of the main loop.
--- 2. File Loading: Parses TOML and Lua files to populate the mapping database.
--- ==============================================================================

local M = {}

local hs         = hs
local text_utils = require("lib.text_utils")
local Logger     = require("lib.logger")

local LOG    = "keymap.registry"
local _state = nil





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Terminators Definitions
M.TERMINATOR_DEFS = {
	{ key = "space",                chars  = { " " },             label = "␣ : Espace",                      default_enabled = true },
	{ key = "nbsp",                 chars  = { "\u{00A0}" },      label = "⍽ : Espace insécable",            default_enabled = true },
	{ key = "nnbsp",                chars  = { "\u{202F}" },      label = "⍽ : Espace fine insécable",       default_enabled = true },
	{ key = "minus",                chars  = { "-" },             label = "- : Tiret",                       default_enabled = false },
	{ key = "underscore",           chars  = { "_" },             label = "_ : Tiret bas",                   default_enabled = false },
	{ type = "separator" },
	{ key = "tab",                  chars  = { "\t" },            label = "⇥ : Tabulation",                  default_enabled = false },
	{ key = "enter",                chars  = { "\r", "\n" },      label = "⏎ : Entrée",                      default_enabled = false },
	{ key = "star",                 chars  = { "★" },             label = "★ : Touche magique",              default_enabled = true, consume = true },
	{ type = "separator" },
	{ key = "comma",                chars  = { "," },             label = ", : Virgule",                     default_enabled = true },
	{ key = "period",               chars  = { "." },             label = ". : Point",                       default_enabled = false },
	{ key = "exclam",               chars  = { "!" },             label = "! : Point d’exclamation",         default_enabled = false },
	{ key = "question",             chars  = { "?" },             label = "? : Point d’interrogation",       default_enabled = false },
	{ key = "colon",                chars  = { ":" },             label = ": : Deux-points",                 default_enabled = false },
	{ type = "separator" },
	{ key = "parenright",           chars  = { ")" },             label = ") : Parenthèse fermante",         default_enabled = false },
	{ key = "braceright",           chars  = { "}" },             label = "} : Accolade fermante",           default_enabled = false },
	{ key = "bracketright",         chars  = { "]" },             label = "] : Crochet fermant",             default_enabled = false },
	{ key = "anglebracketright",    chars  = { ">" },             label = "> : Guillemet fermant",           default_enabled = false },
	{ type = "separator" },
	{ key = "apostrophe_typo",      chars  = { "’" },             label = "’ : Apostrophe typographique",    default_enabled = false },
	{ key = "apostrophe_straight",  chars  = { "'" },             label = "' : Apostrophe droite",           default_enabled = false },
	{ key = "quote",                chars  = { '"' },             label = '" : Guillemet double',            default_enabled = false },
	{ key = "equal",                chars  = { "=" },             label = "= : Égal",                        default_enabled = false },
	{ key = "slash",                chars  = { "/" },             label = "/ : Slash",                       default_enabled = false },
	{ key = "backslash",            chars  = { "\\" },            label = "\\ : Backslash",                  default_enabled = false },
}

local _terminator_enabled = {}
for _, def in ipairs(M.TERMINATOR_DEFS) do
	if def.key then
		if def.default_enabled ~= nil then
			_terminator_enabled[def.key] = def.default_enabled
		else
			_terminator_enabled[def.key] = true
		end
	end
end





-- =======================================
-- =======================================
-- ======= 2/ Terminator Utilities =======
-- =======================================
-- =======================================

--- Updates the magic key label in the terminator definitions.
--- @param magic_key string The custom trigger character.
local function update_terminator_magic_key(magic_key)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == "star" then
			def.chars = { magic_key }
			def.label = magic_key .. " : Touche magique"
		end
	end
end

--- Checks if the provided characters constitute an enabled terminator.
--- @param chars string The characters to check.
--- @return boolean True if the characters match an active terminator.
function M.is_terminator(chars)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if _terminator_enabled[def.key] then
			if def.chars then
				for _, c in ipairs(def.chars) do 
					if chars == c then return true end 
				end
			elseif def.prefix then
				if chars:sub(1, #def.prefix) == def.prefix then return true end
			end
		end
	end
	return false
end

--- Checks if the given terminator is meant to be consumed rather than typed.
--- @param chars string The terminator characters.
--- @return boolean True if the terminator should be consumed.
function M.terminator_is_consumed(chars)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if _terminator_enabled[def.key] and def.consume then
			if def.chars then
				for _, c in ipairs(def.chars) do 
					if chars == c then return true end 
				end
			elseif def.prefix then
				if chars:sub(1, #def.prefix) == def.prefix then return true end
			end
		end
	end
	return false
end

function M.set_terminator_enabled(key, en) _terminator_enabled[key] = (en ~= false) end
function M.is_terminator_enabled(key)      return _terminator_enabled[key] ~= false  end
function M.get_terminator_defs()           return M.TERMINATOR_DEFS                  end

--- Adds a user-created terminator to the live definitions table.
--- @param key string  Unique identifier (e.g. "custom_1").
--- @param char string The trigger character.
--- @param label string Human-readable label shown in the menu.
--- @param consume boolean Whether the character is consumed on expansion.
function M.add_custom_terminator(key, char, label, consume)
	-- Update in place if the key already exists (idempotent on reload)
	for _, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == key then
			def.chars   = { char }
			def.label   = label
			def.consume = consume or false
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
	Logger.info(LOG, string.format("Custom terminator '%s' added successfully.", key))
end

--- Removes a user-created terminator from the live definitions table.
--- @param key string The unique identifier of the terminator to remove.
function M.remove_custom_terminator(key)
	for i, def in ipairs(M.TERMINATOR_DEFS) do
		if def.key == key and def.custom then
			table.remove(M.TERMINATOR_DEFS, i)
			break
		end
	end
	_terminator_enabled[key] = nil
	Logger.info(LOG, string.format("Custom terminator '%s' removed successfully.", key))
end





-- ======================================
-- ======================================
-- ======= 3/ Database Management =======
-- ======================================
-- ======================================

--- Rebuilds the fast lookup dictionary for mappings.
local function rebuild_lookup()
	_state.mappings_lookup = {}
	for _, m in ipairs(_state.mappings) do
		local k = m.trigger .. "\0" .. tostring(m.is_word) .. "\0" .. tostring(m.auto)
		_state.mappings_lookup[k] = m
	end
end

--- Sorts mappings prioritizing length, full words, and chronological order.
function M.sort_mappings()
	table.sort(_state.mappings, function(a, b)
		if a.tlen ~= b.tlen then return a.tlen > b.tlen end
		if a.is_word ~= b.is_word then return a.is_word end
		return a.seq < b.seq
	end)
end

--- Appends a new mapping into the engine's database with smart casing support.
--- @param trigger string The sequence to monitor.
--- @param replacement string The resulting replacement string.
--- @param opts table The configuration options for the expansion.
function M.add(trigger, replacement, opts)
	if type(trigger) ~= "string" or type(replacement) ~= "string" then return end
	
	if _state.magic_key ~= "★" then
		trigger = trigger:gsub("★", _state.magic_key)
	end
	
	opts = type(opts) == "table" and opts or {}
	local is_word           = opts.is_word            == true
	local is_auto           = opts.auto_expand        == true
	local is_case_sensitive = opts.is_case_sensitive  == true
	local is_final          = opts.final_result       == true

	if replacement:match("\n") or replacement:match("{Tab}") or replacement:match("{Enter}") or replacement:match("{Return}") then
		is_final = true
	end

	local function add_raw(t, r, a)
		local k = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a)
		local existing = _state.mappings_lookup[k]
		if existing then
			existing.repl = r
			if _state.current_group then existing.group = _state.current_group end
			return
		end
		_state.seq_counter = _state.seq_counter + 1
		local entry = {
			trigger = t, repl = r, is_word = is_word, auto = a,
			seq = _state.seq_counter, tlen = text_utils.utf8_len(t), final_result = is_final,
		}
		if _state.current_group then entry.group = _state.current_group end
		table.insert(_state.mappings, entry)
		_state.mappings_lookup[k] = entry
	end

	local function add_with_space_variants(t, r)
		add_raw(t, r, is_auto)
		local starts_with_space = t:match("^[ \194\160\226\128\175]") ~= nil
		if not starts_with_space and t:match(" ") then
			add_raw((t:gsub(" ", " ")), r, is_auto)
			add_raw((t:gsub(" ", " ")), r, is_auto)
		end
	end

	local lower_trig = text_utils.trig_lower(trigger)
	local title_repl = text_utils.repl_title(replacement)
	local upper_repl = text_utils.repl_upper(replacement)

	if is_case_sensitive then
		add_with_space_variants(trigger, replacement)
	else
		local title_trigs = text_utils.trig_title(lower_trig)
		local upper_trigs = text_utils.trig_upper(lower_trig)
		add_with_space_variants(lower_trig, replacement)
		
		for _, tt in ipairs(title_trigs) do
			if tt ~= lower_trig then add_with_space_variants(tt, title_repl) end
		end
		
		for _, ut in ipairs(upper_trigs) do
			local is_title = false
			for _, tt in ipairs(title_trigs) do
				if ut == tt then is_title = true; break end
			end
			if ut ~= lower_trig and not is_title then
				add_with_space_variants(ut, upper_repl)
			end
		end
	end

	local first_char_src = is_case_sensitive and trigger or lower_trig
	local first_char = first_char_src:match("^[%z\1-\127\194-\244][\128-\191]*")
	if first_char == "," then
		local rest = lower_trig:sub(#first_char + 1)
		if rest ~= "" then
			add_with_space_variants(";" .. text_utils.trig_lower(rest), title_repl)
			for _, ru in ipairs(text_utils.trig_upper(rest)) do
				local alias = ";" .. ru
				if alias ~= ";" .. text_utils.trig_lower(rest) then
					add_with_space_variants(alias, upper_repl)
				end
			end
		end
	end
end





-- ================================
-- ================================
-- ======= 4/ Group Loaders =======
-- ================================
-- ================================

local function record_group(name, path, kind)
	local seqs = {}
	for _, m in ipairs(_state.mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	_state.groups[name] = { path = path, seqs = seqs, enabled = true, kind = kind or "lua" }
end

--- Loads mappings from a raw Lua file.
--- @param name string Group identifier.
--- @param path string File path.
function M.load_file(name, path)
	if type(name) ~= "string" or type(path) ~= "string" then return end
	
	Logger.debug(LOG, string.format("Loading Lua mapping file: %s…", path))
	_state.current_group = name
	local ok, err = pcall(dofile, path)
	if not ok then 
		Logger.error(LOG, string.format("Error loading mapping file \"%s\": %s.", path, tostring(err)))
	else
		Logger.info(LOG, string.format("Lua mapping file loaded successfully: %s.", name))
	end
	_state.current_group = nil
	record_group(name, path, "lua")
	M.sort_mappings()
end

--- Loads and parses mappings from a TOML configuration file.
--- @param name string Group identifier.
--- @param path string File path.
function M.load_toml(name, path)
	if type(name) ~= "string" or type(path) ~= "string" then return end
	
	Logger.debug(LOG, string.format("Loading TOML mapping file: %s…", path))
	local toml_reader = require("lib.toml_reader")
	local ok, data = pcall(toml_reader.parse, path)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, string.format("Failed to parse TOML \"%s\": %s.", path, tostring(data)))
		return
	end
	
	_state.current_group = name
	local sections_info = {}
	
	for _, sec_name in ipairs(data.sections_order or {}) do
		if sec_name == "-" then
			table.insert(sections_info, { name = "-", description = "-", count = 0 })
			goto continue_sec
		end
		local sec = data.sections and data.sections[sec_name]
		if sec then
			if sec.is_placeholder then
				table.insert(sections_info, {
					name = sec_name, description = sec.description,
					count = 0, is_module_placeholder = true,
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
				name = sec_name, description = sec.description, count = #(sec.entries or {}),
			})
		end
		::continue_sec::
	end
	
	_state.current_group = nil
	M.sort_mappings()
	
	local seqs = {}
	for _, m in ipairs(_state.mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	_state.groups[name] = {
		path = path, seqs = seqs, enabled = true, kind = "toml",
		meta_description = data.meta and data.meta.description or nil,
		sections = sections_info,
	}
	Logger.info(LOG, string.format("TOML mapping file loaded successfully: %s.", name))
end





-- =====================================
-- =====================================
-- ======= 5/ Section Management =======
-- =====================================
-- =====================================

function M.is_section_enabled(group_name, section_name)
	return hs.settings.get("hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name)) ~= false
end

function M.is_repeat_feature_enabled()
	for name, g in pairs(_state.groups) do
		if g.enabled and g.sections then
			for _, sec in ipairs(g.sections) do
				if sec.name == "repeat" then return M.is_section_enabled(name, "repeat") end
			end
		end
	end
	return false
end

function M.disable_section(gn, sn)
	hs.settings.set("hotstrings_section_" .. tostring(gn) .. "_" .. tostring(sn), false)
	if M.is_group_enabled(gn) then 
		M.disable_group(gn)
		M.enable_group(gn) 
	end
end

function M.enable_section(gn, sn)
	hs.settings.set("hotstrings_section_" .. tostring(gn) .. "_" .. tostring(sn), nil)
	if M.is_group_enabled(gn) then 
		M.disable_group(gn)
		M.enable_group(gn) 
	end
end

function M.get_sections(n)          return _state.groups[n] and _state.groups[n].sections or nil        end
function M.get_meta_description(n)  return _state.groups[n] and _state.groups[n].meta_description or nil end
function M.set_group_context(n)     _state.current_group = n                                      end
function M.set_post_load_hook(n, f) if type(f) == "function" then _state.group_post_load_hooks[n] = f end end

function M.disable_group(name)
	if not _state.groups[name] or not _state.groups[name].enabled then return end
	_state.groups[name].enabled = false
	if _state.groups[name].path ~= nil then
		local kept = {}
		for _, m in ipairs(_state.mappings) do 
			if m.group ~= name then table.insert(kept, m) end 
		end
		_state.mappings = kept
		rebuild_lookup()
	end
end

function M.is_group_enabled(name) return _state.groups[name] and _state.groups[name].enabled or false end

function M.list_groups()
	local out = {}
	for name, g in pairs(_state.groups) do out[name] = g.enabled end
	return out
end

function M.register_lua_group(name, meta_description, sections)
	_state.groups[name] = {
		path = nil, seqs = {}, enabled = true, kind = "lua",
		meta_description = meta_description, sections = type(sections) == "table" and sections or {},
	}
end

function M.enable_group(name)
	local g = _state.groups[name]
	if not g or g.enabled then return end
	
	if g.path == nil then
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

--- Mounts the shared state to the registry module.
--- @param core_state table The shared state object.
function M.init(core_state)
	_state = core_state
end

--- Exposes a utility function to update the trigger char visually in the registry.
--- @param char string The new trigger character.
function M.update_trigger_char(char)
	if type(char) == "string" and char ~= "" then
		update_terminator_magic_key(char)
	end
end

return M
