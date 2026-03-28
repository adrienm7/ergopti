-- modules/keymap.lua

-- ===========================================================================
-- Keymap Module
--
-- Core engine for Ergopti+. Intercepts keystrokes, manages the typing buffer,
-- and triggers text expansions, autocorrection, and LLM predictions.
--
-- Features:
--   - Dynamic hotstring execution (auto-expand or terminator-based).
--   - Custom tolerance delays for rolls, corrections, and magic keys.
--   - Zero-latency buffer synchronization avoiding synthetic keystroke echo.
--   - LLM text prediction engine integration.
-- ===========================================================================

local hs         = hs
local eventtap   = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke  = hs.eventtap.keyStroke

local text_utils = require("lib.text_utils")
local km_utils   = require("lib.keymap_utils")
local llm        = require("modules.llm")

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then
	hs.printf("[keymap] WARNING: ui.tooltip failed to load (%s)", tostring(tooltip))
	tooltip = { 
		show = function() end, 
		hide = function() end,
		show_predictions = function() end, 
		navigate = function() end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		set_timeout = function() end,
		set_navigate_callback = function() end,
		set_accept_callback = function() end
	}
end

local ok_vsb, vscode_bridge = pcall(require, "lib.vscode_bridge")
if ok_vsb and vscode_bridge and type(vscode_bridge.setup) == "function" then 
	pcall(vscode_bridge.setup) 
end

-- Optional keylogger integration: syncs its buffer after each text replacement
-- so that logged text reflects what is on screen, not raw keystrokes.
local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- LLM prediction defaults
M.LLM_NAV_MODIFIERS_DEFAULT   = {}
M.LLM_VAL_MODIFIERS_DEFAULT   = {"alt"}
M.LLM_DEBOUNCE_DEFAULT        = 0.5
M.LLM_CONTEXT_LENGTH_DEFAULT  = 500
M.LLM_TEMPERATURE_DEFAULT     = 0.1
M.LLM_MAX_PREDICT_DEFAULT     = 40
M.LLM_MAX_WORDS_DEFAULT       = 10
M.LLM_NUM_PREDICTIONS_DEFAULT = 5
M.LLM_PRED_INDENT_DEFAULT     = -3

M.BASE_DELAY_SEC_DEFAULT = 0.75

-- Allowed time gap between two keystrokes (in seconds) depending on the feature
M.DELAYS_DEFAULT = {
	STAR_TRIGGER       = 2.0,  -- Manual expansions with ★ (Magickey)
	dynamichotstrings  = 2.0,  -- Phone numbers, SSN, dates...
	autocorrection     = 0.5,  -- Spell checking
	rolls              = 0.25, -- Rolls (e.g. sx -> sk)
	sfbsreduction      = 0.25, -- Comma combos (e.g. ,t -> pt)
	distancesreduction = 0.25, -- Dead keys and suffixes
}

M.DELAYS = {}
for k, v in pairs(M.DELAYS_DEFAULT) do M.DELAYS[k] = v end

--- Auto-calculates the timeout to reset the word buffer based on max delays
function M._recalc_word_timeout()
	local max_delay = 0
	for _, v in pairs(M.DELAYS) do
		if type(v) == "number" and v > max_delay then max_delay = v end
	end
	-- Add a 0.5s margin, and cap it at 5.0 seconds to prevent infinite buffers from invalid configs
	M.WORD_TIMEOUT_SEC = math.min(5.0, max_delay + 0.5)
	-- Set tooltip timeout slightly below the word timeout to ensure it hides before the buffer is reset
	if tooltip.set_timeout then tooltip.set_timeout(M.WORD_TIMEOUT_SEC - 0.3) end
end
M._recalc_word_timeout()

local NUM_KEYCODES = {
	[18]=1, [19]=2, [20]=3, [21]=4, [23]=5,
	[22]=6, [26]=7, [28]=8, [25]=9, [29]=10,
}

local groups                   = {}
local current_group            = nil
local mappings                 = {}
local mappings_lookup          = {}
local _interceptors            = {}
local _preview_providers       = {}
local magic_key                = "★"
local group_post_load_hooks    = {}

local _ignored_window_titles   = {}
local _ignored_window_patterns = {}

local BASE_DELAY_SEC           = M.BASE_DELAY_SEC_DEFAULT
local buffer                   = ""
local last_key_time            = 0
local last_key_was_complex     = false
local seq_counter              = 0
local processing_paused        = false
local _no_rescan_until         = 0

-- Asynchronous synchronization variables for synthetic typing
local _expected_synthetic_chars   = ""
local _expected_synthetic_deletes = 0

local _pending_predictions     = {}
local _predictions_active      = false
local _enter_validates_pred    = false 

local _llm_request_id          = 0
local _shift_side              = nil

local current_llm_model        = llm.DEFAULT_LLM_MODEL
local llm_enabled              = llm.DEFAULT_LLM_ENABLED
local preview_enabled          = true

local llm_debounce_time        = M.LLM_DEBOUNCE_DEFAULT
local llm_context_length       = M.LLM_CONTEXT_LENGTH_DEFAULT
local llm_reset_on_nav         = true
local llm_temperature          = M.LLM_TEMPERATURE_DEFAULT
local llm_max_predict          = M.LLM_MAX_PREDICT_DEFAULT
local llm_max_words            = M.LLM_MAX_WORDS_DEFAULT
local llm_num_predictions      = M.LLM_NUM_PREDICTIONS_DEFAULT
local llm_pred_indent          = M.LLM_PRED_INDENT_DEFAULT
local llm_val_modifiers        = M.LLM_VAL_MODIFIERS_DEFAULT
local llm_nav_modifiers        = M.LLM_NAV_MODIFIERS_DEFAULT

local llm_excluded_apps        = {}
local llm_show_info_bar        = true
local llm_sequential_mode      = llm.DEFAULT_LLM_SEQUENTIAL_MODE or false

if tooltip.set_navigate_callback then
	tooltip.set_navigate_callback(function(_) end)
end





-- ===========================================
-- ===========================================
-- ======= 2/ Configuration Management =======
-- ===========================================
-- ===========================================

--- Parses modifier keys into a structured table
--- @param mod_input string|table The modifier string or table
--- @param default table The fallback table
--- @return table The resolved modifier table
local function parse_mods(mod_input, default)
	if type(mod_input) == "string" then return {mod_input} end
	if type(mod_input) == "table" then return mod_input end
	return default
end

function M.set_llm_model(m)               current_llm_model      = tostring(m) end
function M.set_llm_context_length(l)      llm_context_length     = math.max(1, tonumber(l) or M.LLM_CONTEXT_LENGTH_DEFAULT) end
function M.set_llm_reset_on_nav(r)        llm_reset_on_nav       = (r == true) end
function M.set_llm_temperature(t)         llm_temperature        = math.max(0, tonumber(t) or M.LLM_TEMPERATURE_DEFAULT) end
function M.set_llm_max_predict(p)         llm_max_predict        = math.max(1, tonumber(p) or M.LLM_MAX_PREDICT_DEFAULT) end
function M.set_llm_max_words(w)           llm_max_words          = math.max(0, tonumber(w) or M.LLM_MAX_WORDS_DEFAULT) end
function M.set_llm_num_predictions(n)     llm_num_predictions    = math.max(1, tonumber(n) or M.LLM_NUM_PREDICTIONS_DEFAULT) end
function M.set_llm_show_info_bar(v)       llm_show_info_bar      = (v == true) end
function M.set_llm_pred_indent(v)         llm_pred_indent        = math.floor(tonumber(v) or M.LLM_PRED_INDENT_DEFAULT) end
function M.set_llm_sequential_mode(v)     llm_sequential_mode    = (v == true) end
function M.set_llm_val_modifiers(mods)    llm_val_modifiers      = parse_mods(mods, M.LLM_VAL_MODIFIERS_DEFAULT) end
function M.set_llm_nav_modifiers(mods)    llm_nav_modifiers      = parse_mods(mods, M.LLM_NAV_MODIFIERS_DEFAULT) end
function M.get_llm_enabled()              return llm_enabled end
function M.set_llm_show_model_name(v)     llm_show_info_bar      = (v == true) end

function M.ignore_window_title(title)     
	if type(title) == "string" then _ignored_window_titles[title] = true end 
end

function M.ignore_window_pattern(pattern) 
	if type(pattern) == "string" then table.insert(_ignored_window_patterns, pattern) end 
end

function M.set_llm_excluded_apps(apps)
	llm_excluded_apps = type(apps) == "table" and apps or {}
end

--- Toggles the LLM prediction state safely
--- @param enabled boolean Whether to enable the engine
function M.set_llm_enabled(enabled)
	llm_enabled = (enabled == true)
	if not llm_enabled then
		if tooltip.hide then tooltip.hide() end
		_pending_predictions  = {}
		_predictions_active   = false
		_enter_validates_pred = false
		_llm_request_id       = _llm_request_id + 1
		if M._llm_timer and type(M._llm_timer.running) == "function" and M._llm_timer:running() then 
			M._llm_timer:stop() 
		end
	end
end

function M.set_preview_enabled(enabled)
	preview_enabled = (enabled == true)
	if not preview_enabled and tooltip.hide then tooltip.hide() end
end

--- Updates the debounce timer for the LLM request
--- @param seconds number The debounce delay in seconds
function M.set_llm_debounce(seconds)
	llm_debounce_time = math.max(0, tonumber(seconds) or M.LLM_DEBOUNCE_DEFAULT)
	if M._llm_timer and type(M._llm_timer.stop) == "function" then M._llm_timer:stop() end
	M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)
end

function M.get_base_delay()       return BASE_DELAY_SEC end
function M.set_base_delay(secs)   BASE_DELAY_SEC = math.max(0, tonumber(secs) or M.BASE_DELAY_SEC_DEFAULT) end

function M.set_delay(key, val)
	if M.DELAYS_DEFAULT[key] ~= nil then
		M.DELAYS[key] = tonumber(val) or M.DELAYS_DEFAULT[key]
		M._recalc_word_timeout()
	end
end

function M.pause_processing()     processing_paused = true end
function M.resume_processing()    processing_paused = false end
function M.is_processing_paused() return processing_paused end

function M.suppress_rescan(duration)
	_no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or 0.5)
	buffer = ""
end

local function suppress_rescan_keep_buffer(duration)
	_no_rescan_until = hs.timer.secondsSinceEpoch() + (tonumber(duration) or 0.3)
end

local function rescan_suppressed()
	return hs.timer.secondsSinceEpoch() < _no_rescan_until
end





-- =============================================
-- =============================================
-- ======= 3/ Group & Mapping Management =======
-- =============================================
-- =============================================

local function rebuild_lookup()
	mappings_lookup = {}
	for _, m in ipairs(mappings) do
		local k = m.trigger .. "\0" .. tostring(m.is_word) .. "\0" .. tostring(m.auto)
		mappings_lookup[k] = m
	end
end

function M.sort_mappings()
	table.sort(mappings, function(a, b)
		if a.tlen ~= b.tlen then return a.tlen > b.tlen end
		if a.is_word ~= b.is_word then return a.is_word end
		return a.seq < b.seq
	end)
end

function M.register_interceptor(fn)      
	if type(fn) == "function" then table.insert(_interceptors, fn) end      
end

function M.register_preview_provider(fn) 
	if type(fn) == "function" then table.insert(_preview_providers, fn) end 
end

local function record_group(name, path, kind)
	local seqs = {}
	for _, m in ipairs(mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	groups[name] = { path = path, seqs = seqs, enabled = true, kind = kind or "lua" }
end

function M.load_file(name, path)
	if type(name) ~= "string" or type(path) ~= "string" then return end
	current_group = name
	local ok, err = pcall(dofile, path)
	if not ok then hs.printf("[keymap] Error loading \"%s\": %s", path, tostring(err)) end
	current_group = nil
	record_group(name, path, "lua")
	M.sort_mappings()
end

function M.load_toml(name, path)
	if type(name) ~= "string" or type(path) ~= "string" then return end
	local toml_reader = require("lib.toml_reader")
	local ok, data = pcall(toml_reader.parse, path)
	if not ok or type(data) ~= "table" then
		hs.printf("[keymap] Failed to parse TOML \"%s\": %s", path, tostring(data))
		return
	end
	
	current_group = name
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
	
	current_group = nil
	M.sort_mappings()
	
	local seqs = {}
	for _, m in ipairs(mappings) do
		if m.group == name then table.insert(seqs, m.seq) end
	end
	groups[name] = {
		path = path, seqs = seqs, enabled = true, kind = "toml",
		meta_description = data.meta and data.meta.description or nil,
		sections = sections_info,
	}
end

function M.is_section_enabled(group_name, section_name)
	return hs.settings.get("hotstrings_section_" .. tostring(group_name) .. "_" .. tostring(section_name)) ~= false
end

function M.is_repeat_feature_enabled()
	for name, g in pairs(groups) do
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

function M.get_sections(n)          return groups[n] and groups[n].sections or nil        end
function M.get_meta_description(n)  return groups[n] and groups[n].meta_description or nil end
function M.set_group_context(n)     current_group = n                                      end
function M.set_post_load_hook(n, f) if type(f) == "function" then group_post_load_hooks[n] = f end end

function M.disable_group(name)
	if not groups[name] or not groups[name].enabled then return end
	groups[name].enabled = false
	if groups[name].path ~= nil then
		local kept = {}
		for _, m in ipairs(mappings) do 
			if m.group ~= name then table.insert(kept, m) end 
		end
		mappings = kept
		rebuild_lookup()
	end
end

function M.is_group_enabled(name) return groups[name] and groups[name].enabled or false end

function M.list_groups()
	local out = {}
	for name, g in pairs(groups) do out[name] = g.enabled end
	return out
end

function M.register_lua_group(name, meta_description, sections)
	groups[name] = {
		path = nil, seqs = {}, enabled = true, kind = "lua",
		meta_description = meta_description, sections = type(sections) == "table" and sections or {},
	}
end

function M.enable_group(name)
	local g = groups[name]
	if not g or g.enabled then return end
	
	if g.path == nil then
		g.enabled = true
		local hook = group_post_load_hooks[name]
		if type(hook) == "function" then hook() end
		M.sort_mappings()
		return
	end
	
	if g.kind == "toml" then 
		M.load_toml(name, g.path) 
	else 
		M.load_file(name, g.path) 
	end
	
	local hook = group_post_load_hooks[name]
	if type(hook) == "function" then hook() end
	M.sort_mappings()
end





-- ==============================
-- ==============================
-- ======= 4/ Terminators =======
-- ==============================
-- ==============================

-- UI Labels remain in French for user display
local TERMINATOR_DEFS = {
	{ key = "space",                chars  = { " " },             label = "␣ : Espace",                       default_enabled = true },
	{ key = "nbsp",                 chars  = { "\u{00A0}" },      label = "⍽ : Espace insécable",            default_enabled = true },
	{ key = "nnbsp",                chars  = { "\u{202F}" },      label = "⍽ : Espace fine insécable",       default_enabled = true },
	{ key = "minus",                chars  = { "-" },             label = "- : Tiret",                        default_enabled = false },
	{ key = "underscore",           chars  = { "_" },             label = "_ : Tiret bas",                    default_enabled = false },
	{ type = "separator" },
	{ key = "tab",                  chars  = { "\t" },            label = "⇥ : Tabulation",                  default_enabled = false },
	{ key = "enter",                chars  = { "\r", "\n" },      label = "⏎ : Entrée",                      default_enabled = false },
	{ key = "star",                 chars  = { magic_key },       label = (magic_key .. " : Touche magique"), default_enabled = true, consume = true },
	{ type = "separator" },
	{ key = "comma",                chars  = { "," },             label = ", : Virgule",                      default_enabled = true },
	{ key = "period",               chars  = { "." },             label = ". : Point",                        default_enabled = false },
	{ key = "exclam",               chars  = { "!" },             label = "! : Point d’exclamation",          default_enabled = false },
	{ key = "question",             chars  = { "?" },             label = "? : Point d’interrogation",        default_enabled = false },
	{ key = "colon",                chars  = { ":" },             label = ": : Deux-points",                  default_enabled = false },
	{ type = "separator" },
	{ key = "parenright",           chars  = { ")" },             label = ") : Parenthèse fermante",          default_enabled = false },
	{ key = "bracketright",         chars  = { "]" },             label = "] : Crochet fermant",              default_enabled = false },
	{ key = "braceright",           chars  = { "}" },             label = "} : Accolade fermante",            default_enabled = false },
	{ key = "anglebracketright",    chars  = { ">" },             label = "> : Guillemets fermants",          default_enabled = false },
	{ type = "separator" },
	{ key = "apostrophe_typo",      chars  = { "’" },             label = "’ : Apostrophe typographique",     default_enabled = false },
	{ key = "apostrophe_straight",  chars  = { "'" },             label = "' : Apostrophe droite",            default_enabled = false },
	{ key = "quote",                chars  = { '"' },             label = '" : Guillemet double',             default_enabled = false },
	{ key = "equal",                chars  = { "=" },             label = "= : Égal",                         default_enabled = false },
	{ key = "slash",                chars  = { "/" },             label = "/ : Slash",                        default_enabled = false },
	{ key = "backslash",            chars  = { "\\" },            label = "\\ : Backslash",                   default_enabled = false },
}

local _terminator_enabled = {}
for _, def in ipairs(TERMINATOR_DEFS) do
	if def.key then
		if def.default_enabled ~= nil then
			_terminator_enabled[def.key] = def.default_enabled
		else
			_terminator_enabled[def.key] = true
		end
	end
end

local function is_terminator(chars)
	for _, def in ipairs(TERMINATOR_DEFS) do
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

local function terminator_is_consumed(chars)
	for _, def in ipairs(TERMINATOR_DEFS) do
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
function M.get_terminator_defs()           return TERMINATOR_DEFS                    end

function M.set_trigger_char(char)
	if type(char) ~= "string" or char == "" then return end
	magic_key = char
end





-- =========================================
-- =========================================
-- ======= 5/ Hotstring Registration =======
-- =========================================
-- =========================================

function M.add(trigger, replacement, opts)
	if type(trigger) ~= "string" or type(replacement) ~= "string" then return end
	
	if magic_key ~= "★" then
		trigger = trigger:gsub("★", magic_key)
	end
	
	opts = type(opts) == "table" and opts or {}
	local is_word           = opts.is_word            == true
	local is_auto           = opts.auto_expand        == true
	local is_case_sensitive = opts.is_case_sensitive  == true
	local is_final          = opts.final_result       == true

	-- Force final result if replacement contains line breaks or specific control tokens
	if replacement:match("\n") or replacement:match("{Tab}") or replacement:match("{Enter}") or replacement:match("{Return}") then
		is_final = true
	end

	local function add_raw(t, r, a)
		local k = t .. "\0" .. tostring(is_word) .. "\0" .. tostring(a)
		local existing = mappings_lookup[k]
		if existing then
			existing.repl = r
			if current_group then existing.group = current_group end
			return
		end
		seq_counter = seq_counter + 1
		local entry = {
			trigger = t, repl = r, is_word = is_word, auto = a,
			seq = seq_counter, tlen = text_utils.utf8_len(t), final_result = is_final,
		}
		if current_group then entry.group = current_group end
		table.insert(mappings, entry)
		mappings_lookup[k] = entry
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





-- =======================================
-- =======================================
-- ======= 6/ Preview & LLM Engine =======
-- =======================================
-- =======================================

--- Safely resets the prediction engine state and invalidates any pending API request
local function reset_predictions()
	_pending_predictions  = {}
	_predictions_active   = false
	_enter_validates_pred = false
	
	_llm_request_id       = _llm_request_id + 1
	
	if tooltip.hide then tooltip.hide() end
	if M._llm_timer and type(M._llm_timer.stop) == "function" then
		M._llm_timer:stop()
	end
end

--- Validates and applies the selected LLM prediction with robust fail-safes
--- @param idx number The index of the prediction to apply
--- @return boolean True if applied, false otherwise
local function apply_prediction(idx)
	local pred = _pending_predictions[idx]
	if not pred then return false end
	reset_predictions()

	local original_deletes = pred.deletes or 0
	local original_to_type = pred.to_type or ""
	
	local deletes = original_deletes
	local to_type = original_to_type

	-- Pcall to ensure overlap logic never crashes the sequence
	local ok_overlap, res_deletes, res_to = pcall(function()
		if km_utils and type(km_utils.resolve_prediction_overlap) == "function" then
			return km_utils.resolve_prediction_overlap(buffer, original_deletes, original_to_type)
		end
		return original_deletes, original_to_type
	end)
	
	if ok_overlap then
		deletes = res_deletes
		to_type = res_to
		
		-- ULTIMATE SPACE PRESERVATION (Solver Bug Fix)
		-- The overlap solver sometimes incorrectly strips leading spaces from the prediction 
		-- without accounting for the buffer’s tail. We force-restore them if needed.
		local function starts_with_space(s)
			return s:match("^%s") or s:sub(1, 2) == "\194\160" or s:sub(1, 3) == "\226\128\175"
		end
		local function ends_with_space(s)
			return s:match("%s$") or s:sub(-2) == "\194\160" or s:sub(-3) == "\226\128\175"
		end

		local orig_started_with_space = starts_with_space(original_to_type)
		local new_starts_with_space   = starts_with_space(to_type)
		
		if orig_started_with_space and not new_starts_with_space then
			local buffer_kept = ""
			if deletes == 0 then
				buffer_kept = buffer
			else
				local start_del = utf8.offset(buffer, -deletes)
				if start_del and start_del > 1 then
					buffer_kept = buffer:sub(1, start_del - 1)
				end
			end
			
			if not ends_with_space(buffer_kept) then
				to_type = " " .. to_type
			end
		end
	else
		print("Erreur solveur : " .. tostring(res_deletes)) -- UI Log
		deletes = original_deletes
		to_type = original_to_type
	end

	-- BUFFER SYNCHRONIZATION
	-- Safely deletes existing overlapping characters before typing the prediction
	_expected_synthetic_deletes = _expected_synthetic_deletes + deletes
	for _ = 1, deletes do keyStroke({}, "delete", 0) end
	
	local emitted_str = ""
	local ok_emit = pcall(function()
		if km_utils and type(km_utils.emit_text) == "function" then
			_, emitted_str = km_utils.emit_text(to_type)
		else
			keyStrokes(to_type)
			emitted_str = to_type
		end
	end)
	
	if not ok_emit then
		keyStrokes(to_type)
		emitted_str = to_type
	end
	
	-- Queueing generated characters to prevent buffer duplication
	_expected_synthetic_chars = _expected_synthetic_chars .. emitted_str

	if deletes == 0 then
		buffer = buffer .. to_type
	else
		-- Safely substr avoiding out-of-bounds offset errors
		local ok_offset, start = pcall(function()
			-- If deletes is greater than buffer length, this handles it cleanly
			if deletes >= #buffer then return 1 end
			local o = utf8.offset(buffer, -deletes)
			return o or 1
		end)
		if not ok_offset then start = 1 end
		buffer = (start and buffer:sub(1, start - 1) or "") .. to_type
	end

	-- Sync keylogger so its logged text matches actual on-screen content
	if keylogger and type(keylogger.set_buffer) == "function" then
		keylogger.set_buffer(buffer)
	end

	suppress_rescan_keep_buffer(0.3)
	if llm_enabled and M._llm_timer and type(M._llm_timer.start) == "function" then
		M._llm_timer:start()
	end
	return true
end

if tooltip.set_accept_callback then
	tooltip.set_accept_callback(function(idx)
		apply_prediction(idx)
	end)
end

--- Truncates text output based on word count limitations.
--- @param text string The raw output to limit.
--- @param max_w number Max allowed words.
--- @return string The truncated text.
local function truncate_words(text, max_w)
	if max_w <= 0 then return text end
	local words = {}
	for w in text:gmatch("%S+%s*") do
		table.insert(words, w)
		if #words >= max_w then break end
	end
	local res = table.concat(words)
	if #words >= max_w then res = res:gsub("%s+$", "") end
	return res
end

--- Verifies if the active window is blacklisted from generating LLM predictions
--- @return boolean True if excluded, false otherwise
local function llm_suppressed_for_app()
	if km_utils and type(km_utils.is_ignored_window) == "function" then
		if km_utils.is_ignored_window(_ignored_window_titles, _ignored_window_patterns) then return true end
	end

	local frontApp = hs.application.frontmostApplication()
	if not frontApp then return false end
	
	local appName = frontApp:name() or ""
	for _, excluded in ipairs(llm_excluded_apps) do
		if excluded == appName then return true end
	end
	return false
end

--- Generates the string for the information bar tooltip
--- @param model_name string Model identifier
--- @param elapsed_ms number Milliseconds taken for generation
--- @return string Formatted string
local function build_info_bar(model_name, elapsed_ms)
	if not model_name or model_name == "" then return nil end
	if elapsed_ms and elapsed_ms > 0 then
		local secs = elapsed_ms / 1000
		local time_str = secs < 10 and string.format("%.1fs", secs) or string.format("%ds", math.floor(secs + 0.5))
		return model_name .. " · " .. time_str
	end
	return model_name
end

--- Core routine to evaluate buffer state and dispatch API calls if suitable
function M._perform_llm_check()
	if not llm_enabled or llm_suppressed_for_app() then return end

	local clean_buffer = buffer
	local words = {}
	for w in clean_buffer:gmatch("%S+%s*") do table.insert(words, w) end
	if #words == 0 then return end
	
	local tail = table.concat(words, "", math.max(1, #words - 4))
	if not tail or #tail < 2 then return end

	if tooltip.show then tooltip.show("⏳ Génération en cours...", true, preview_enabled) end

	local num_pred = llm_num_predictions

	_llm_request_id = _llm_request_id + 1
	local my_request_id = _llm_request_id

	if type(llm.fetch_llm_prediction) == "function" then
		llm.fetch_llm_prediction(
			clean_buffer, tail,
			current_llm_model, llm_temperature, llm_max_predict, num_pred,
			function(predictions, elapsed_ms)
				if _llm_request_id ~= my_request_id then return end
				
				local valid_preds = {}
				for _, p in ipairs(predictions) do
					if p.to_type then
						local tt = p.to_type
						
						-- Apply truncation if max_words constraint is defined
						if llm_max_words > 0 then
							tt = truncate_words(tt, llm_max_words)
							if p.nw then
								p.nw = truncate_words(p.nw, llm_max_words)
							end
						end
						
						if tt:gsub("[%s%.…]", "") ~= "" then
							p.to_type = tt
							
							-- Prevent empty visual predictions displaying as "..."
							local has_visual = true
							if type(tooltip.make_diff_styled) == "function" then
								has_visual = (tooltip.make_diff_styled(p.chunks, p.nw) ~= nil)
							end
							
							if has_visual then
								table.insert(valid_preds, p)
							end
						end
					end
				end

				if #valid_preds == 0 then reset_predictions(); return end
				
				_pending_predictions = valid_preds
				_predictions_active  = true
				local info = llm_show_info_bar and build_info_bar(current_llm_model, elapsed_ms) or nil
				
				local val_mods = llm_val_modifiers
				local val_mod_str = "none"
				if llm_num_predictions > 1 and not (#val_mods == 1 and val_mods[1] == "none") then
					val_mod_str = (#val_mods == 0) and "\226\128\139" or table.concat(val_mods, "+")
				end
				
				local nav_mods = llm_nav_modifiers
				local nav_mod_str = "none"
				if #nav_mods > 0 and not (#nav_mods == 1 and nav_mods[1] == "none") then
					nav_mod_str = table.concat(nav_mods, "+")
					nav_mod_str = nav_mod_str:gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
				elseif #nav_mods == 0 then
					nav_mod_str = ""
				end

				if tooltip.show_predictions then
					tooltip.show_predictions(valid_preds, 1, preview_enabled, info, val_mod_str, llm_pred_indent, nav_mod_str)
				end
			end,
			function()
				if _llm_request_id ~= my_request_id then return end
				reset_predictions()
			end,
			llm_sequential_mode
		)
	end
end

M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)

--- Synchronizes state and invalidates previews when typing alters context
--- @param buf string The current buffer context
local function update_preview(buf)
	if M._llm_timer and type(M._llm_timer.running) == "function" and M._llm_timer:running() then 
		M._llm_timer:stop() 
	end
	reset_predictions()

	if not buf or #buf == 0 then 
		if tooltip.hide then tooltip.hide() end
		return 
	end
	
	local last_word = buf:match("([^%s]+)$")
	if not last_word then 
		if tooltip.hide then tooltip.hide() end
		if llm_enabled and M._llm_timer and type(M._llm_timer.start) == "function" then 
			M._llm_timer:start() 
		end
		return 
	end

	local match_repl = nil
	for _, provider in ipairs(_preview_providers) do
		local ok, res = pcall(provider, buf)
		if ok and res then match_repl = res; break end
	end
	
	if not match_repl then
		for _, m in ipairs(mappings) do
			local group_active = not m.group or not groups[m.group] or groups[m.group].enabled
			if group_active then
				if m.trigger == last_word .. magic_key then
					local clean = km_utils and type(km_utils.tokens_from_repl) == "function" 
						and km_utils.plain_text(km_utils.tokens_from_repl(m.repl)) or m.repl
					if clean ~= last_word then match_repl = m.repl; break end
				elseif m.trigger == last_word then
					if not (m.is_word == false and m.auto == true) then
						local clean = km_utils and type(km_utils.tokens_from_repl) == "function" 
							and km_utils.plain_text(km_utils.tokens_from_repl(m.repl)) or m.repl
						if clean ~= last_word then match_repl = m.repl; break end
					end
				end
			end
		end
	end

	local is_fallback_repetition = false
	if match_repl and M.is_repeat_feature_enabled() then
		local clean = km_utils and type(km_utils.tokens_from_repl) == "function" 
			and km_utils.plain_text(km_utils.tokens_from_repl(match_repl)) or match_repl
		local last_char_offset = utf8.offset(last_word, -1)
		if last_char_offset then
			local last_char = last_word:sub(last_char_offset)
			if clean == last_word .. last_char then is_fallback_repetition = true end
		end
	end

	if match_repl and not is_fallback_repetition then
		_llm_request_id = _llm_request_id + 1
		local display_text = km_utils and type(km_utils.tokens_from_repl) == "function" 
			and km_utils.plain_text(km_utils.tokens_from_repl(match_repl)) or match_repl
		if tooltip.show then tooltip.show(display_text, false, preview_enabled) end
		if llm_enabled and M._llm_timer and type(M._llm_timer.start) == "function" then 
			M._llm_timer:start(math.max(0.1, M.WORD_TIMEOUT_SEC - 0.3))
		end
	else
		if tooltip.hide then tooltip.hide() end
		if llm_enabled and M._llm_timer and type(M._llm_timer.start) == "function" then 
			M._llm_timer:start() 
		end
	end
end





-- =================================================
-- =================================================
-- ======= 7/ Typing Expansion & Replacement =======
-- =================================================
-- =================================================

--- Internal helper executing character manipulation via backspaces and pasting
--- @param deletes number Quantity of backspaces to issue
--- @param emit_action function Routine to fire the text replacement
--- @param buffer_action function Routine syncing the internal tracker logic
--- @param is_final boolean Whether to pause predictions temporarily post execution
--- @param is_ignored boolean Disables tooltip and AI reactions
local function perform_text_replacement(deletes, emit_action, buffer_action, is_final, is_ignored)
	_expected_synthetic_deletes = _expected_synthetic_deletes + deletes
	if not is_ignored and tooltip.hide then tooltip.hide() end
	
	for _ = 1, deletes do keyStroke({}, "delete", 0) end
	local ok, _, emitted_str = pcall(emit_action)
	if not ok then emitted_str = "" end
	
	_expected_synthetic_chars = _expected_synthetic_chars .. (emitted_str or "")
	
	if type(buffer_action) == "function" then pcall(buffer_action) end

	-- Sync keylogger so its logged text matches actual on-screen content
	if keylogger and type(keylogger.set_buffer) == "function" then
		keylogger.set_buffer(buffer)
	end

	if is_final then M.suppress_rescan(1.0) end

	-- Triggers an AI prediction as soon as the hotstring is expanded
	if not is_ignored and llm_enabled and M._llm_timer and type(M._llm_timer.start) == "function" then
		M._llm_timer:start()
	end
end

--- Attempts to resolve and execute an auto-expanding hotstring sequence
--- @param m table The dictionary mapping matched sequence
--- @param char_len number Byte length of the latest character
--- @param is_ignored boolean Silences auxiliary systems like the LLM when active
--- @return boolean True if sequence resolved successfully
local function try_auto_expand(m, char_len, is_ignored)
	local trigger = m.trigger
	if not text_utils.utf8_ends_with(buffer, trigger) then return false end
	
	if m.is_word and text_utils.utf8_len(buffer) > text_utils.utf8_len(trigger)
		and not trigger:match("^[ \194\160\226\128\175]") then
		local tstart  = utf8.offset(buffer, -text_utils.utf8_len(trigger))
		local before  = tstart and buffer:sub(1, tstart - 1) or ""
		local last_ch = utf8.offset(before, -1)
		if text_utils.is_letter_char(last_ch and before:sub(last_ch) or "") then
			return false
		end
	end

	local tokens    = km_utils and type(km_utils.tokens_from_repl) == "function" and km_utils.tokens_from_repl(m.repl) or {}
	local repl_text = km_utils and type(km_utils.plain_text) == "function" and km_utils.plain_text(tokens) or m.repl
	
	if repl_text == trigger then
		if m.final_result then M.suppress_rescan() end
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return true
	end

	local char_offset = is_ignored and 0 or char_len
	local deletes, to_type = text_utils.utf8_len(trigger) - char_offset, repl_text

	if repl_text == m.repl then
		local screen = text_utils.utf8_sub(trigger, 1, text_utils.utf8_len(trigger) - char_offset)
		local common = text_utils.get_common_prefix_utf8(screen, repl_text)
		deletes = text_utils.utf8_len(screen) - common
		to_type = text_utils.utf8_sub(repl_text, common + 1)
	end

	perform_text_replacement(deletes, 
		function() 
			if repl_text == m.repl and km_utils and type(km_utils.emit_text) == "function" then
				return km_utils.emit_text(to_type)
			elseif km_utils and type(km_utils.emit_tokens) == "function" then
				return km_utils.emit_tokens(tokens) 
			end
			return 0, ""
		end,
		function()
			local tstart = utf8.offset(buffer, -text_utils.utf8_len(trigger))
			buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. repl_text
		end,
		m.final_result,
		is_ignored
	)
	return true
end

--- Attempts to resolve a non-automatic hotstring sequence triggered by a special trailing terminator
--- @param m table The mapping dictionary entry to resolve against
--- @param chars string The specific trailing trigger sequence injected
--- @param char_len number UTF-8 token length of the trailing sequence
--- @param is_ignored boolean Disables LLM AI checks for current context
--- @return boolean True if triggered successfully, false otherwise
local function try_terminator_expand(m, chars, char_len, is_ignored)
	if not is_terminator(chars) then return false end

	local trigger = m.trigger
	local buf_end   = utf8.offset(buffer, -char_len) or (#buffer + 1)
	local trig_len  = text_utils.utf8_len(trigger)
	local buf_start = utf8.offset(buffer, -(char_len + trig_len))
	local segment   = (buf_start and buf_start <= buf_end - 1) and buffer:sub(buf_start, buf_end - 1) or nil
	
	if segment ~= trigger then return false end

	if m.is_word and not trigger:match("^[ \194\160\226\128\175]") then
		local before  = buf_start and buffer:sub(1, buf_start - 1) or ""
		local last_ch = utf8.offset(before, -1)
		if text_utils.is_letter_char(last_ch and before:sub(last_ch) or "") then
			return false
		end
	end

	local consume_term = terminator_is_consumed(chars)
	
	if m.repl == trigger then
		if m.final_result then M.suppress_rescan() end
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return true
	end

	local function do_expansion()
		local tokens    = km_utils and type(km_utils.tokens_from_repl) == "function" and km_utils.tokens_from_repl(m.repl) or {}
		local repl_text = km_utils and type(km_utils.plain_text) == "function" and km_utils.plain_text(tokens) or m.repl
		local deletes, to_type = trig_len, repl_text
		
		if repl_text == m.repl then
			local common = text_utils.get_common_prefix_utf8(trigger, repl_text)
			deletes = trig_len - common
			to_type = text_utils.utf8_sub(repl_text, common + 1)
		end
		
		if is_ignored then deletes = deletes + char_len end

		perform_text_replacement(deletes, 
			function()
				local emitted_count, emitted_str = 0, ""
				if repl_text == m.repl and km_utils and type(km_utils.emit_text) == "function" then
					emitted_count, emitted_str = km_utils.emit_text(to_type)
				elseif km_utils and type(km_utils.emit_tokens) == "function" then
					emitted_count, emitted_str = km_utils.emit_tokens(tokens)
				end
				
				if not consume_term then
					if chars == "\r" or chars == "\n" then keyStroke({}, "return", 0)
					elseif chars == "\t" then keyStroke({}, "tab", 0)
					else 
						keyStrokes(chars) 
						emitted_str = emitted_str .. chars
					end
					emitted_count = emitted_count + text_utils.utf8_len(chars)
				end
				return emitted_count, emitted_str
			end,
			function()
				local tstart = utf8.offset(buffer, -(char_len + trig_len))
				buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. repl_text .. (consume_term and "" or chars)
			end,
			m.final_result,
			is_ignored
		)
	end

	if is_ignored then do_expansion() else hs.timer.doAfter(0, do_expansion) end
	return true
end

--- Validates and manages immediate repetition hotstrings natively
--- @param chars string Keystroke trailing trigger
--- @param is_ignored boolean Skips notification propagation on match
--- @return boolean Valid repetition fired flag
local function try_repeat_feature(chars, is_ignored)
	if not M.is_repeat_feature_enabled() or chars ~= magic_key then return false end

	local char_len = text_utils.utf8_len(chars)
	local buf_len  = text_utils.utf8_len(buffer)
	if buf_len <= char_len then return false end

	local before = buffer:sub(1, utf8.offset(buffer, -char_len) - 1)
	local last_char_offset = utf8.offset(before, -1)
	if not last_char_offset then return false end

	local last_char = before:sub(last_char_offset)
	if last_char == "" or last_char:match("^%s$") then return false end

	if not is_ignored and tooltip.hide then tooltip.hide() end
	if is_ignored then 
		_expected_synthetic_deletes = _expected_synthetic_deletes + 1
		keyStroke({}, "delete", 0) 
	end
	
	_expected_synthetic_chars = _expected_synthetic_chars .. last_char
	keyStrokes(last_char)

	local tstart = utf8.offset(buffer, -char_len)
	buffer = (tstart and buffer:sub(1, tstart - 1) or "") .. last_char
	
	if not is_ignored and llm_enabled and M._llm_timer and type(M._llm_timer.start) == "function" then
		M._llm_timer:start()
	end
	
	return true
end





-- =========================================
-- =========================================
-- ======= 8/ Keyboard Event Handler =======
-- =========================================
-- =========================================

--- Helper to split modifier strings like {"cmd+shift"} into {"cmd", "shift"}
--- @param mod_array table A table of strings representing key modifiers
--- @return table An exploded array of individual key modifiers
local function split_mods(mod_array)
	local res = {}
	if type(mod_array) ~= "table" then return res end
	for _, m in ipairs(mod_array) do
		for p in m:gmatch("[^+]+") do table.insert(res, p) end
	end
	return res
end

--- Master keyboard loop interceptor wrapped internally by eventtap
--- @param e table The MacOS keystroke event entity payload
--- @return boolean Always returns false to fall back out gracefully on system error
local function onKeyDownRaw(e)
	if processing_paused then return false end

	local now   = hs.timer.secondsSinceEpoch()
	local dt    = now - last_key_time
	last_key_time = now

	-- Automatically clean waiting lists to prevent deadlocks
	if dt > 0.5 then
		_expected_synthetic_deletes = 0
		_expected_synthetic_chars = ""
	end

	-- Word timeout: clear the buffer if the user took a long pause
	-- Give more time if LLM prediction is actively displayed
	local timeout = _predictions_active and 12.0 or M.WORD_TIMEOUT_SEC
	if dt > timeout then
		buffer = ""
		reset_predictions()
	end

	local keyCode = e:getKeyCode()
	local flags   = e:getFlags()
	
	local is_ignored = false
	local frontApp = hs.application.frontmostApplication()
	
	-- Global exclusion of all windows owned by Hammerspoon (UIs, console)
	-- This prevents latency issues when typing inside custom webviews or dialogs.
	if frontApp and frontApp:name() == "Hammerspoon" then
		is_ignored = true
	elseif km_utils and type(km_utils.is_ignored_window) == "function" then
		is_ignored = km_utils.is_ignored_window(_ignored_window_titles, _ignored_window_patterns)
	end

	-- 1. Ignore our own synthetic "Delete" keystrokes
	if keyCode == 51 and _expected_synthetic_deletes > 0 then
		_expected_synthetic_deletes = _expected_synthetic_deletes - 1
		return false 
	end

	-- 2. Handles LLM Prediction Execution (Enter / Numbers / Tab / Arrows)
	if not is_ignored and _predictions_active then
		
		-- Enter to validate immediately
		if keyCode == 36 then
			if _enter_validates_pred then
				local idx = tooltip.get_current_index and tooltip.get_current_index() or 1
				return apply_prediction(idx)
			else
				reset_predictions()
			end
		end

		-- Numeric validation logic
		local val_mods = split_mods(llm_val_modifiers)
		if #_pending_predictions > 1 and llm.check_modifiers(flags, val_mods) then
			local n = NUM_KEYCODES[keyCode]
			if n and n <= #_pending_predictions then return apply_prediction(n) end
		end

		-- Arrow navigation logic
		local nav_mods = split_mods(llm_nav_modifiers)
		if #_pending_predictions > 1 and (keyCode >= 123 and keyCode <= 126) and llm.check_modifiers(flags, nav_mods) then
			_enter_validates_pred = true
			local nav_dir = (keyCode == 123 or keyCode == 126) and -1 or 1
			if tooltip.navigate then tooltip.navigate(nav_dir) end
			return true
		end

		-- Tab fallback logic
		if keyCode == 48 and #_pending_predictions > 0 then
			if flags.shift then
				if #_pending_predictions > 1 then
					_enter_validates_pred = true 
					local nav_dir = (_shift_side == "right") and 1 or -1
					if tooltip.navigate then tooltip.navigate(nav_dir) end
					return true
				end
				return false
			else
				local idx = tooltip.get_current_index and tooltip.get_current_index() or 1
				local applied = apply_prediction(idx)
				return applied
			end
		end
	end

	-- 3. Pass event through custom interceptors
	local suppress_triggers = false
	for _, interceptor in ipairs(_interceptors) do
		local ok, result = pcall(interceptor, e, buffer)
		if ok then
			if result == "consume" then return true end
			if result == "suppress" then suppress_triggers = true; break end
		end
	end

	-- Ignore Karabiner layer and modified keys (F13-F20)
	if keyCode == 105 or keyCode == 107 or keyCode == 113 or keyCode == 106 or keyCode == 64 or keyCode == 79 or keyCode == 80 or keyCode == 90 then
		return false
	end

	-- 4. Clear states on escape, navigation and modifications shortcuts
	if keyCode == 53 then
		if not is_ignored and _predictions_active then reset_predictions(); return true end
		if llm_reset_on_nav then buffer = "" end
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return false
	end

	if flags.cmd or flags.ctrl then
		buffer = ""
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return false
	end

	-- Handle standard Backspace
	if keyCode == 51 then
		if flags.cmd or flags.alt then
			buffer = ""
			if not is_ignored and tooltip.hide then tooltip.hide() end
			return false
		end
		if #buffer > 0 then
			local offset = utf8.offset(buffer, -1)
			buffer = offset and buffer:sub(1, offset - 1) or ""
			if not is_ignored then update_preview(buffer) end
		end
		return false
	end

	-- Handle Arrow Keys
	if keyCode == 117 or keyCode == 115 or keyCode == 116 or keyCode == 119 or keyCode == 121
		or (keyCode >= 123 and keyCode <= 126) then

		if llm_reset_on_nav then buffer = "" end
		if not is_ignored and tooltip.hide then tooltip.hide() end
		return false
	end

	-- 5. Gather character
	local chars = e:getCharacters(false)
	if not chars or chars == "" then return false end

	-- CRUCIAL SYNTHETIC FILTER:
	-- Ignore the character if it is part of our requested synthetic typing.
	-- It is emitted to the screen, BUT not added twice to the buffer.
	if #_expected_synthetic_chars > 0 then
		if _expected_synthetic_chars:sub(1, #chars) == chars then
			_expected_synthetic_chars = _expected_synthetic_chars:sub(#chars + 1)
			return false
		elseif dt < 0.02 then
			-- Tolerance for macOS UTF-8 decomposition (e.g., 'é' becomes 'e' + '´')
			-- If exact match fails but the keystroke arrives at a synthetic speed
			-- (impossible for a human), we ignore it from the buffer.
			return false
		end
	end

	buffer = buffer .. chars
	if #buffer > llm_context_length then
		buffer = buffer:sub(utf8.offset(buffer, -llm_context_length) or 1)
	end

	if not is_ignored then update_preview(buffer) end

	-- 6. Trigger Checks
	if suppress_triggers or rescan_suppressed() then return false end
	
	local is_complex    = flags.shift or flags.alt
	local complex_mult  = (is_complex or last_key_was_complex) and 2 or 1
	last_key_was_complex = is_complex

	local function run_trigger_checks()
		local char_len = text_utils.utf8_len(chars)
		
		for _, m in ipairs(mappings) do
			local group_active = not m.group or not groups[m.group] or groups[m.group].enabled
			if group_active then
				
				-- A. Determine the maximum allowed delay for this specific shortcut
				local specific_delay = BASE_DELAY_SEC
				
				-- If the trigger ends with ★ (regardless of its source file)
				if m.trigger:sub(-#magic_key) == magic_key then
					specific_delay = M.DELAYS.STAR_TRIGGER
				-- Otherwise, if a custom rule is defined for this file/group name
				elseif m.group and M.DELAYS[m.group] then
					specific_delay = M.DELAYS[m.group]
				end
				
				local allowed_delay = specific_delay * complex_mult

				-- B. Check if the time gap (dt) with the previous key is valid
				if dt <= allowed_delay then
					if m.auto and try_auto_expand(m, char_len, is_ignored) then return true end
					if not m.auto and try_terminator_expand(m, chars, char_len, is_ignored) then return true end
				end
			end
		end
		
        -- The quick repeat key benefits from the star’s permissive delay
		if dt <= (M.DELAYS.STAR_TRIGGER * complex_mult) then
			if try_repeat_feature(chars, is_ignored) then return true end
		end
		
		return false
	end

	if is_ignored then
		hs.timer.doAfter(0, run_trigger_checks)
	else
		if run_trigger_checks() then return true end
	end

	if keyCode == 36 or keyCode == 48 then
		if llm_reset_on_nav then buffer = "" end
	end

	return false
end

--- Wrapper for raw key intercept catching arbitrary native OS errors cleanly
--- @param e table Event parameters
--- @return boolean Return flag logic passed from raw
local function onKeyDown(e)
	local ok, result = pcall(onKeyDownRaw, e)
	if not ok then
		print("Erreur d’interception clavier : " .. tostring(result)) -- UI output
		return false
	end
	return result
end





-- ===================================
-- ===================================
-- ======= 9/ Module Lifecycle =======
-- ===================================
-- ===================================

local tap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)

local shift_tap = eventtap.new(
	{ eventtap.event.types.flagsChanged },
	function(e)
		local ok, result = pcall(function()
			local kc = e:getKeyCode()
			local f  = e:getFlags()
			if not f.shift then
				_shift_side = nil
			elseif kc == 56 then
				_shift_side = "left"
			elseif kc == 60 then
				_shift_side = "right"
			end
			return false
		end)
		if not ok then print("Erreur majuscule : " .. tostring(result)) return false end
		return result
	end
)

local mouse_tap = eventtap.new(
	{ 
		eventtap.event.types.leftMouseDown, 
		eventtap.event.types.rightMouseDown, 
		eventtap.event.types.middleMouseDown,
		eventtap.event.types.scrollWheel 
	},
	function()
		local ok, result = pcall(function()
			if llm_reset_on_nav then buffer = "" end
			reset_predictions()
			return false
		end)
		if not ok then print("Erreur souris : " .. tostring(result)) return false end
		return result
	end
)

--- Safely registers and mounts the daemon listeners to the OS framework
function M.start()
	if tap then tap:start() end
	if shift_tap then shift_tap:start() end
	if mouse_tap then mouse_tap:start() end
end

--- Unhooks daemons gracefully preventing memory leaks
function M.stop()
	if tap then tap:stop() end
	if shift_tap then shift_tap:stop() end
	if mouse_tap then mouse_tap:stop() end
	reset_predictions()
end

M.start()
return M
