--- modules/keymap/llm_bridge.lua

--- ==============================================================================
--- MODULE: Keymap LLM Bridge
--- DESCRIPTION:
--- Manages the interaction between the active keymap buffer, the visual UI
--- tooltips, and the asynchronous Ollama LLM engine.
---
--- FEATURES & RATIONALE:
--- 1. Asynchronous Debounce: Timer delays to avoid flooding the LLM API.
--- 2. Seamless Injections: Passes backspace data for true Net productivity stats.
--- ==============================================================================

local M = {}

local hs         = hs
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke  = hs.eventtap.keyStroke

local km_utils   = require("modules.keymap.utils")
local text_utils = require("lib.text_utils")
local core_llm   = require("modules.llm")
local Logger     = require("lib.logger")

local LOG = "keymap.llm_bridge"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then
	Logger.warning(LOG, "❌ Module ui.tooltip failed to load! LLM predictions will NOT display.")
	tooltip = { 
		show = function() end, 
		hide = function() end,
		show_predictions = function() 
			-- Placeholder: log instead of displaying
			if Logger and type(Logger.debug) == "function" then
				Logger.debug(LOG, "⚠️  show_predictions called but tooltip module failed to load!")
			end
		end, 
		navigate = function() end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		set_timeout = function() end,
		set_navigate_callback = function() end,
		set_accept_callback = function() end
	}
end

local _state = nil





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local NUM_KEYCODES = {
	[18]=1, [19]=2, [20]=3, [21]=4, [23]=5,
	[22]=6, [26]=7, [28]=8, [25]=9, [29]=10,
}

local _pending_predictions     = {}
local _predictions_active      = false
local _enter_validates_pred    = false 
local _llm_request_id          = 0
local _llm_fetch_request_id    = 0
local _last_suggested_hs       = nil
local _last_llm_input_signature = nil

local current_llm_backend_name = nil

local llm_enabled              = core_llm.DEFAULT_LLM_ENABLED
local current_llm_model        = core_llm.DEFAULT_LLM_MODEL
local current_llm_display_name = core_llm.DEFAULT_LLM_MODEL
local preview_star_enabled        = true
local preview_autocorrect_enabled = true
local preview_ai_enabled          = true
local preview_colored_tooltips    = true

-- Hardcoded tint colors (hue only, applied over a fixed dark base in apply_tint)
local C_TINT_STAR_DEFAULT        = { red = 1.00, green = 0.00, blue = 0.00, alpha = 1.0 }
local C_TINT_AUTOCORRECT_DEFAULT = { red = 0.00, green = 0.80, blue = 0.00, alpha = 1.0 }
local C_TINT_PERSONAL_DEFAULT    = { red = 0.20, green = 0.55, blue = 1.00, alpha = 1.0 }
local C_TINT_AI_LOADING          = { red = 0.68, green = 0.38, blue = 1.00, alpha = 1.0 }

local preview_star_color        = C_TINT_STAR_DEFAULT
local preview_autocorrect_color = C_TINT_AUTOCORRECT_DEFAULT
local preview_ai_color          = nil

local llm_after_hotstring_enabled = false

local llm_debounce_time        = 0.5
local llm_context_length       = 500
local llm_reset_on_nav         = true
local llm_temperature          = 0.1
local llm_min_words            = 1
local llm_max_words            = 5
local llm_num_predictions      = 3
local llm_pred_indent          = -3
local llm_val_modifiers        = {"alt"}
local llm_nav_modifiers        = {}

local llm_excluded_apps        = {}
local llm_show_info_bar        = true
local llm_sequential_mode      = false





-- ===========================================
-- ===========================================
-- ======= 2/ Configuration Management =======
-- ===========================================
-- ===========================================

--- Parses modifier keys into a structured table.
--- @param mod_input string|table The modifier string or table.
--- @param default table The fallback table.
--- @return table The resolved modifier table.
local function parse_mods(mod_input, default)
	if type(mod_input) == "string" then return {mod_input} end
	if type(mod_input) == "table" then return mod_input end
	return default
end

function M.set_llm_model(m)
	local model_name = tostring(m)
	local backend = type(core_llm.get_backend) == "function" and core_llm.get_backend() or "ollama"
	if backend == "mlx" then
		if type(core_llm.set_llm_model_mlx) == "function" then
			core_llm.set_llm_model_mlx(model_name)
		end
	else
		if type(core_llm.set_llm_model_ollama) == "function" then
			core_llm.set_llm_model_ollama(model_name)
		end
	end
	current_llm_model = model_name
end

function M.set_llm_backend_name(n)
	current_llm_backend_name = (type(n) == "string") and n or nil
end

function M.set_llm_context_length(l)      llm_context_length     = math.max(1, tonumber(l) or 500) end
function M.set_llm_display_model_name(name)
	if type(name) == "string" and name ~= "" then current_llm_display_name = name end
end
function M.set_llm_reset_on_nav(r)        llm_reset_on_nav       = (r == true) end
function M.set_llm_temperature(t)         llm_temperature        = math.max(0, tonumber(t) or 0.1) end
function M.set_llm_min_words(w)           llm_min_words          = math.max(0, tonumber(w) or 1) end
function M.set_llm_max_words(w)           llm_max_words          = math.max(0, tonumber(w) or 5) end
function M.set_llm_num_predictions(n)     llm_num_predictions    = math.max(1, tonumber(n) or 3) end
function M.set_llm_show_info_bar(v)       llm_show_info_bar      = (v == true) end
function M.set_llm_pred_indent(v)         llm_pred_indent        = math.floor(tonumber(v) or -3) end
function M.set_llm_sequential_mode(v)     llm_sequential_mode    = (v == true) end
function M.set_llm_val_modifiers(mods)    llm_val_modifiers      = parse_mods(mods, {"alt"}) end
function M.set_llm_nav_modifiers(mods)    llm_nav_modifiers      = parse_mods(mods, {}) end
function M.get_llm_enabled()              return llm_enabled end

function M.set_llm_disabled_apps(apps)
	llm_excluded_apps = type(apps) == "table" and apps or {}
end

--- Toggles the LLM prediction state safely.
--- @param enabled boolean Whether to enable the engine.
function M.set_llm_enabled(enabled)
	llm_enabled = (enabled == true)
	if not llm_enabled then
		if tooltip.hide then tooltip.hide() end
		_pending_predictions  = {}
		_predictions_active   = false
		_enter_validates_pred = false
		_llm_request_id       = _llm_request_id + 1
		_llm_fetch_request_id = _llm_fetch_request_id + 1
		if M._llm_timer and type(M._llm_timer.running) == "function" and M._llm_timer:running() then 
			M._llm_timer:stop() 
		end
		if M._watchdog_timer then M._watchdog_timer:stop() end
	end
end

function M.set_preview_star_enabled(v)
	preview_star_enabled = (v == true)
	if not preview_star_enabled and tooltip.hide then tooltip.hide() end
end

function M.set_preview_autocorrect_enabled(v)
	preview_autocorrect_enabled = (v == true)
	if not preview_autocorrect_enabled and tooltip.hide then tooltip.hide() end
end

function M.set_preview_ai_enabled(v)
	preview_ai_enabled = (v == true)
	if not preview_ai_enabled and tooltip.hide then tooltip.hide() end
end

function M.set_preview_colored_tooltips(v)
	preview_colored_tooltips = (v == true)
	if tooltip.hide then tooltip.hide() end
end

function M.set_preview_star_color(c)
	preview_star_color = (type(c) == "table") and c or C_TINT_STAR_DEFAULT
end

function M.set_preview_autocorrect_color(c)
	preview_autocorrect_color = (type(c) == "table") and c or C_TINT_AUTOCORRECT_DEFAULT
end

function M.set_preview_ai_color(_)
	-- Fixed AI color (neutral gray) — non customizable
end

function M.set_llm_after_hotstring(v)
	llm_after_hotstring_enabled = (v == true)
end

--- Backward-compatible setter: enables or disables all hotstring tooltips at once.
--- @param enabled boolean Whether to enable the tooltips.
function M.set_preview_enabled(enabled)
	preview_star_enabled        = (enabled == true)
	preview_autocorrect_enabled = (enabled == true)
	if not enabled and tooltip.hide then tooltip.hide() end
end

--- Updates the debounce timer for the LLM request.
--- @param seconds number The debounce delay in seconds.
function M.set_llm_debounce(seconds)
	llm_debounce_time = math.max(0, tonumber(seconds) or 0.5)
	if M._llm_timer and type(M._llm_timer.stop) == "function" then M._llm_timer:stop() end
	M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)
end

function M.start_timer(delay)
	if llm_enabled and llm_debounce_time >= 0 and M._llm_timer and type(M._llm_timer.start) == "function" then
		if delay then M._llm_timer:start(delay) else M._llm_timer:start() end
	end
end

function M.stop_timer()
	if M._llm_timer and type(M._llm_timer.stop) == "function" then M._llm_timer:stop() end
end





-- ======================================
-- ======================================
-- ======= 3/ Engine & Validation =======
-- ======================================
-- ======================================

--- Safely resets the prediction engine state and invalidates any pending API request.
function M.reset_predictions()
	_pending_predictions  = {}
	_predictions_active   = false
	_enter_validates_pred = false
	_last_suggested_hs    = nil
	_last_llm_input_signature = nil
	
	_llm_request_id       = _llm_request_id + 1
	_llm_fetch_request_id = _llm_fetch_request_id + 1
	
	if tooltip.hide then tooltip.hide() end
	M.stop_timer()
	if M._watchdog_timer then M._watchdog_timer:stop() end
end

--- Validates and applies the selected LLM prediction with robust fail-safes.
--- @param idx number The index of the prediction to apply.
--- @return boolean True if applied, false otherwise.
function M.apply_prediction(idx)
	local pred = _pending_predictions[idx]
	if not pred then return false end
	M.reset_predictions()

	local deletes = pred.deletes or 0
	local to_type = pred.to_type or ""

	_state.expected_synthetic_deletes = _state.expected_synthetic_deletes + deletes
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
	
	_state.expected_synthetic_chars = _state.expected_synthetic_chars .. emitted_str
	
	-- Passes the deletes count to calculate true net generated chars
	if keylogger and type(keylogger.notify_synthetic) == "function" and emitted_str ~= "" then
		keylogger.notify_synthetic(emitted_str, "llm", deletes)
	end

	-- Immediately record acceptance in the keylogger/manifest for real-time metrics
	if keylogger and type(keylogger.log_llm_accepted) == "function" then
		local ok_app2, front_app2 = pcall(function() return hs.application.frontmostApplication() end)
		local app_name2 = nil
		if ok_app2 and front_app2 then
			local ok_title2, title2 = pcall(function() return front_app2:title() end)
			if ok_title2 and title2 then app_name2 = title2 end
		end
		pcall(keylogger.log_llm_accepted, to_type, app_name2)
	end

	if deletes == 0 then
		_state.buffer = _state.buffer .. to_type
	else
		local ok_offset, start = pcall(function()
			if deletes >= #_state.buffer then return 1 end
			local o = utf8.offset(_state.buffer, -deletes)
			return o or 1
		end)
		if not ok_offset then start = 1 end
		_state.buffer = (start and _state.buffer:sub(1, start - 1) or "") .. to_type
	end

	if keylogger and type(keylogger.set_buffer) == "function" then
		keylogger.set_buffer(_state.buffer)
	end

	_state.suppress_rescan_keep_buffer(0.3)
	M.start_timer()
	return true
end

if tooltip.set_accept_callback then
	tooltip.set_accept_callback(function(idx)
		M.apply_prediction(idx)
	end)
end

if tooltip.set_navigate_callback then
	tooltip.set_navigate_callback(function(idx)
		_enter_validates_pred = true
		if tooltip.set_enter_validates then tooltip.set_enter_validates(true) end
	end)
end

if tooltip.set_cancel_callback then
	tooltip.set_cancel_callback(function()
		M.reset_predictions()
	end)
end





-- ========================================
-- ========================================
-- ======= 4/ Execution Constraints =======
-- ========================================
-- ========================================

--- Builds a stable deduplication key from the final text effectively shown in the tooltip.
--- @param pred table The final prediction payload.
--- @return string The normalized display key.
local function build_tooltip_dedup_key(pred)
	if type(pred) ~= "table" then return "" end

	local chunks = pred.chunks
	local nw = tostring(pred.nw or "")
	local first_done = false
	local last_char = ""
	local parts = {}

	local function clean_first(s)
		local str = tostring(s or "")
		if not first_done and str ~= "" then
			str = str:gsub("^%s+", "")
			if str ~= "" then first_done = true end
		end
		return str
	end

	if type(chunks) == "table" and #chunks > 0 then
		for _, chunk in ipairs(chunks) do
			if type(chunk) == "table" then
				local s = clean_first(chunk.text)
				if s ~= "" then
					table.insert(parts, s)
					last_char = s:sub(-1)
				end
			end
		end
	end

	local s_nw = clean_first(nw)
	if s_nw ~= "" then
		if last_char ~= "" and not last_char:match("%s") and not s_nw:match("^%s") then
			s_nw = " " .. s_nw
		end
		table.insert(parts, s_nw)
	end

	return table.concat(parts):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Verifies if the active window is blacklisted from generating LLM predictions.
--- @return boolean True if excluded, false otherwise.
local function llm_suppressed_for_app()
	if km_utils and type(km_utils.is_ignored_window) == "function" then
		if km_utils.is_ignored_window(_state.ignored_window_titles, _state.ignored_window_patterns) then return true end
	end

	local frontApp = hs.application.frontmostApplication()
	if not frontApp then return false end
	
	local bid  = type(frontApp.bundleID) == "function" and frontApp:bundleID() or ""
	local path = type(frontApp.path) == "function" and frontApp:path() or ""
	
	for _, app in ipairs(llm_excluded_apps) do
		if type(app) == "table" then
			if (app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path) then
				return true
			end
		end
	end
	return false
end

--- Returns the prompt title part before the first em dash for compact display.
--- @param prompt_title string|nil Prompt title to shorten.
--- @return string|nil Short prompt title.
local function trim_prompt_title(prompt_title)
	if type(prompt_title) ~= "string" then return nil end
	local clean = prompt_title:gsub("^%s+", ""):gsub("%s+$", "")
	if clean == "" then return nil end
	local head = clean:match("^(.-)%s*—")
	if type(head) == "string" and head ~= "" then
		return head:gsub("%s+$", "")
	end
	return clean
end

--- Generates the string for the information bar tooltip with strict ordering: Model -> Backend -> Prompt -> Time
--- @param model_name string Model identifier.
--- @param elapsed_ms number Milliseconds taken for generation.
--- @param backend_name string|nil The active backend string.
--- @param profile_name string|nil Profile/prompt name for display.
--- @return string Formatted string.
local function build_info_bar(model_name, elapsed_ms, backend_name, profile_name)
	if not model_name or model_name == "" then return nil end
	
	local parts = {}
	table.insert(parts, model_name)
	
	if type(backend_name) == "string" and backend_name ~= "" then
		table.insert(parts, backend_name)
	end
	
	local profile_short = trim_prompt_title(profile_name)
	if profile_short then
		table.insert(parts, profile_short)
	end
	
	if elapsed_ms and elapsed_ms > 0 then
		local secs = elapsed_ms / 1000
		local time_str = secs < 10 and string.format("%.1fs", secs) or string.format("%ds", math.floor(secs + 0.5))
		table.insert(parts, "⏱️ " .. time_str)
	end
	
	return table.concat(parts, " — ")
end

--- Core routine to evaluate buffer state and dispatch API calls if suitable.
--- @param force_trigger boolean Ignore contextual bounds and fetch directly.
--- @param profile_name string Evaluated override profile string.
function M._perform_llm_check(force_trigger, profile_name)
	force_trigger = force_trigger == true
	Logger.debug(LOG, string.format("_perform_llm_check: force_trigger=%s, profile_name=%s", tostring(force_trigger), tostring(profile_name)))
	Logger.debug(LOG, string.format("llm_enabled=%s", tostring(llm_enabled)))
	
	if not llm_enabled then
		Logger.info(LOG, "LLM disabled — aborting.")
		return
	end
	
	local is_suppressed = llm_suppressed_for_app()
	Logger.debug(LOG, string.format("llm_suppressed_for_app()=%s", tostring(is_suppressed)))
	
	if is_suppressed then
		Logger.info(LOG, "LLM suppressed for this app — aborting.")
		return
	end

	local clean_buffer = _state.buffer
	Logger.debug(LOG, string.format("Buffer: '%s' (length=%d)", clean_buffer, #clean_buffer))
	
	local words = {}
	for w in clean_buffer:gmatch("%S+%s*") do table.insert(words, w) end
	Logger.debug(LOG, string.format("Words in buffer: %d.", #words))
	
	if #words == 0 and not force_trigger then
		Logger.info(LOG, "Empty buffer without manual trigger — aborting.")
		return
	end
	
	local tail = table.concat(words, "", math.max(1, #words - 4))
	Logger.debug(LOG, string.format("Tail: '%s' (length=%d)", tail, #tail))
	
	if (not tail or #tail < 2) and not force_trigger then
		Logger.info(LOG, "Tail too short without manual trigger — aborting.")
		return
	end

	local llm_input_signature = clean_buffer .. "\n" .. tail
	if not force_trigger and _last_llm_input_signature == llm_input_signature then
		Logger.debug(LOG, "LLM request ignored (input unchanged).")
		return
	end
	_last_llm_input_signature = llm_input_signature

	if tooltip.show then tooltip.show("⏳ Génération en cours…", true, preview_ai_enabled, C_TINT_AI_LOADING) end

	local num_pred = llm_num_predictions
	local req_temperature = llm_temperature

	_llm_request_id = _llm_request_id + 1
	_llm_fetch_request_id = _llm_fetch_request_id + 1
	local my_request_id = _llm_fetch_request_id

	if type(core_llm.fetch_llm_prediction) == "function" then
		if type(core_llm.get_active_profile) == "function" then
			local active_profile = core_llm.get_active_profile()
			if type(active_profile) == "table" then
				Logger.debug(LOG, string.format("Active profile: id=%s, label=%s, batch=%s", tostring(active_profile.id), tostring(active_profile.label), tostring(active_profile.batch)))
			end
		end

		local backend = type(core_llm.get_backend) == "function" and core_llm.get_backend() or "inconnu"
		
		-- Give the model plenty of room to respect the user's max_words requirement.
		local model_to_use = type(core_llm.get_current_model) == "function" and core_llm.get_current_model() or current_llm_model
		local max_predict_tokens = 150
		
		if backend == "mlx" then
			max_predict_tokens = llm_max_words > 0 and math.max(60, llm_max_words * 6 + 20) or 100
		elseif llm_max_words > 0 then
			max_predict_tokens = math.max(60, llm_max_words * 6 + 20)
		end
		
		local effective_num_pred = num_pred
		
		-- Automatically boost temperature if user requests multiple parallel predictions
		-- to prevent greedy deterministic engines from generating exactly identical strings.
		if effective_num_pred > 1 and req_temperature < 0.6 then
			req_temperature = 0.7
			Logger.debug(LOG, string.format("Boosted temperature to %.1f for parallel variety.", req_temperature))
		end
		
		Logger.debug(LOG, string.format("LLM dispatch tuned: backend=%s, num_pred=%d, max_tokens=%d", tostring(backend), effective_num_pred, max_predict_tokens))

		-- Watchdog timer to prevent eternal "..." placeholders if some parallel threads die silently
		if M._watchdog_timer then M._watchdog_timer:stop() end
		M._watchdog_timer = hs.timer.doAfter(12, function()
			if _llm_fetch_request_id == my_request_id and _predictions_active then
				local backend_name = current_llm_backend_name
				if not backend_name or backend_name == "" then
					if backend == "mlx" then backend_name = "MLX 🚀"
					elseif backend == "ollama" then backend_name = "Ollama 🦙"
					else backend_name = "" end
				end
				
				local info = llm_show_info_bar and build_info_bar(current_llm_display_name, nil, backend_name, "Timeout partiel") or nil
				
				local val_mods = llm_val_modifiers
				local val_mod_str = "none"
				if llm_num_predictions > 1 and not (#val_mods == 1 and val_mods[1] == "none") then
					val_mod_str = (#val_mods == 0) and "\226\128\139" or table.concat(val_mods, "+")
				end
				
				if tooltip.show_predictions then
					tooltip.show_predictions(_pending_predictions, 1, preview_ai_enabled, info, val_mod_str, llm_pred_indent, llm_nav_modifiers, preview_ai_color, nil, #_pending_predictions)
				end
			end
		end)
		
		core_llm.fetch_llm_prediction(
			clean_buffer, tail,
			model_to_use, req_temperature, max_predict_tokens, effective_num_pred,
			function(predictions, elapsed_ms, is_final)
				if _llm_fetch_request_id ~= my_request_id then return end

				if is_final == true and M._watchdog_timer then
					M._watchdog_timer:stop()
					M._watchdog_timer = nil
				end

				-- Determine frontmost application to attribute logs correctly
				local ok_app, front_app = pcall(function() return hs.application.frontmostApplication() end)
				local app_name = nil
				if ok_app and front_app then
					local ok_title, title = pcall(function() return front_app:title() end)
					if ok_title and title then app_name = title end
				end

				-- Log the raw generation response (context + full predictions list) with explicit app
				if keylogger and type(keylogger.log_llm) == "function" then
					pcall(keylogger.log_llm, clean_buffer, predictions, app_name)
				end

				local function get_pred_key(pred)
					if type(pred) ~= "table" then return "" end
					local k = build_tooltip_dedup_key(pred)
					if k ~= "" then return k end
					return tostring(pred.to_type or ""):gsub("%s+$", "")
				end
				
				local valid_preds = {}
				local seen_tooltip_texts = {}
				local ctx_words = {}
				for w in clean_buffer:lower():gmatch("[%aÀ-ÿ0-9]+") do
					ctx_words[w] = true
				end
				
				for _, p_raw in ipairs(predictions) do
					-- Clone the prediction to avoid mutating the API's internal tables
					local p = {}
					for k, v in pairs(p_raw) do p[k] = v end

					if p.to_type then
						-- 1. Apply global post-processing formatting (e.g., typographic apostrophes)
						apply_postprocessing(p)

						-- 2. Extract for noise checks
						local tt = p.to_type
						local tt_norm = tt:lower():gsub("’", "'")
						local ctx_norm = clean_buffer:lower():gsub("’", "'")
						local prev_non_space = clean_buffer:match(".*(%S)")
						local first_char = tt:match("^%s*(.)") or ""
						local starts_upper_ascii = first_char:match("[A-Z]") ~= nil
						local prev_ends_sentence = prev_non_space and prev_non_space:match("[%.%!%?…:;]") ~= nil
						local generic_pronoun_start = tt_norm:match("^%s*vous%s") and not ctx_norm:match("vous")
						local has_unrelated_pronoun = tt_norm:match("%f[%a]vous%f[%A]") and not ctx_norm:match("%f[%a]vous%f[%A]")
						local has_htmlish = tt_norm:find("<", 1, true) or tt_norm:find(">", 1, true) or tt_norm:find("%[user", 1, true)
						local has_urlish = tt_norm:find("http", 1, true) or tt_norm:find("www", 1, true) or tt_norm:match("%.com") or tt_norm:match("%.net")
						local has_hashish = tt_norm:match("%x%x%x%x%x%x%x") ~= nil
						local repeated_word = tt_norm:match("(%a+)%s+%1%s+%1") ~= nil
						local repeated_syllable = tt_norm:match("^([%aÀ-ÿ][%aÀ-ÿ])%1%1") ~= nil
							or tt_norm:match("^([%aÀ-ÿ][%aÀ-ÿ][%aÀ-ÿ])%1%1") ~= nil
						local has_novel_word = false
						for w in tt_norm:gmatch("[%aÀ-ÿ0-9]+") do
							if not ctx_words[w] then
								has_novel_word = true
								break
							end
						end

						local is_noise = tt_norm:match("^%s*suite%s+finale")
							or tt_norm:match("^%s*</")
							or tt_norm:match("^%s*vous avez besoin de plus")
							or tt_norm:match("^%s*vous etes les plus")
							or tt_norm:match("^%s*les versions a partir")
							or tt_norm:match("^%s*toujours accompagne")
							or tt_norm:match("^%s*grand etranger")
							or tt_norm:match("^%s*artiste prefere")
							or generic_pronoun_start
							or has_unrelated_pronoun
							or has_htmlish
							or has_urlish
							or has_hashish
							or (not has_novel_word)
							or repeated_word
							or repeated_syllable
							or (starts_upper_ascii and not prev_ends_sentence)
							or tt:find(":", 1, true) ~= nil

						if tt:gsub("[%s%.…]", "") ~= "" and not is_noise then
							p.to_type = tt
							
							local has_visual = true
							if type(tooltip.make_diff_styled) == "function" then
								has_visual = (tooltip.make_diff_styled(p.chunks, p.nw) ~= nil)
							end
							
							if has_visual then
								local dedup_key = build_tooltip_dedup_key(p)
								if dedup_key ~= "" and not seen_tooltip_texts[dedup_key] then
									seen_tooltip_texts[dedup_key] = true
									table.insert(valid_preds, p)
								elseif dedup_key == "" then
									table.insert(valid_preds, p)
								else
									Logger.debug(LOG, string.format("Prediction rejected (tooltip duplicate): '%s'", dedup_key))
								end
							end
						elseif is_noise then
							Logger.debug(LOG, string.format("Prediction rejected (noise): '%s'", tt))
						end
					end
				end

				-- Keeps already displayed order stable and appends only genuinely new predictions.
				if _predictions_active and type(_pending_predictions) == "table" and #_pending_predictions > 0 then
					local merged_preds = {}
					local seen_merge = {}

					for _, ep in ipairs(_pending_predictions) do
						local key = get_pred_key(ep)
						if key == "" or not seen_merge[key] then
							if key ~= "" then seen_merge[key] = true end
							table.insert(merged_preds, ep)
						end
					end

					for _, np in ipairs(valid_preds) do
						local key = get_pred_key(np)
						if key == "" or not seen_merge[key] then
							if key ~= "" then seen_merge[key] = true end
							table.insert(merged_preds, np)
						end
					end

					valid_preds = merged_preds
				end

				if #valid_preds == 0 then
					-- Do not reset the entire predictions buffer if a single parallel thread fails or is noisy.
					if is_final == true and not _predictions_active then
						if tooltip.hide then tooltip.hide() end
					end
					return
				end

				Logger.debug(LOG, string.format("%d valid prediction(s) in %dms:", #valid_preds, elapsed_ms or 0))
				for i, p in ipairs(valid_preds) do
					local nw_info = (p.nw and p.nw ~= "") and (" | nw='" .. p.nw .. "'") or ""
					Logger.debug(LOG, string.format("  #%d -> del=%d to_type='%s'%s", i, p.deletes or 0, p.to_type or "", nw_info))
				end

				-- Notify keylogger that we suggested a prediction
				if keylogger and type(keylogger.log_llm_suggested) == "function" then
					pcall(keylogger.log_llm_suggested, app_name, #valid_preds)
				end
				
				_pending_predictions = valid_preds
				_predictions_active  = true
				
				local display_profile_name = profile_name
				if not display_profile_name then
					if type(core_llm.get_active_profile) == "function" then
						local profile = core_llm.get_active_profile()
						if type(profile) == "table" and type(profile.label) == "string" then
							display_profile_name = profile.label
						end
					end
				end
				
				local display_model = (current_llm_display_name ~= "" and current_llm_display_name)
					or (type(core_llm.get_current_model) == "function" and core_llm.get_current_model())
					or current_llm_model
					
				local backend_name = current_llm_backend_name
				if not backend_name or backend_name == "" then
					if backend == "mlx" then backend_name = "MLX 🚀"
					elseif backend == "ollama" then backend_name = "Ollama 🦙"
					else backend_name = "" end
				end
				
				local info = llm_show_info_bar and build_info_bar(display_model, elapsed_ms, backend_name, display_profile_name) or nil
				
				local loading_text = nil
				if is_final ~= true and #valid_preds < llm_num_predictions then
					local spinner_frames = { "◐", "◓", "◑", "◒" }
					local idx = (math.floor(hs.timer.secondsSinceEpoch() * 6) % #spinner_frames) + 1
					loading_text = string.format("%s Enrichissement… %d/%d", spinner_frames[idx], #valid_preds, llm_num_predictions)
				end
				
				-- Dynamic reservation: organically expands as predictions trickle in without blocking empty lines
				local reserved_count = #valid_preds
				
				local val_mods = llm_val_modifiers
				local val_mod_str = "none"
				if llm_num_predictions > 1 and not (#val_mods == 1 and val_mods[1] == "none") then
					val_mod_str = (#val_mods == 0) and "\226\128\139" or table.concat(val_mods, "+")
				end

				local selected_index = 1
				if _predictions_active and type(tooltip.get_current_index) == "function" then
					local current_index = tooltip.get_current_index()
					if type(current_index) == "number" then
						selected_index = math.max(1, math.floor(current_index))
					end
				end
				selected_index = math.min(selected_index, #valid_preds)

				if tooltip.show_predictions then
					tooltip.show_predictions(valid_preds, selected_index, preview_ai_enabled, info, val_mod_str, llm_pred_indent, llm_nav_modifiers, preview_ai_color, loading_text, reserved_count)
				else
					-- Fallback: display predictions via log and notification if tooltip failed
					if #valid_preds > 0 then
						local pred_str = ""
						for i, pred in ipairs(valid_preds) do
							if i <= 3 then  -- Show top 3
								pred_str = pred_str .. "\n" .. i .. ". " .. (pred.to_type or "?")
							end
						end
						Logger.warning(LOG, string.format("📝 LLM Predictions received (tooltip unavailable):%s", pred_str))
						pcall(function()
							local ok_notif, notifications = pcall(require, "lib.notifications")
							if ok_notif and notifications and type(notifications.notify) == "function" then
								notifications.notify("🤖 IA Prédictions", "Reçues: " ..#valid_preds .. " suggestion(s)\n" .. pred_str:sub(1, 100))
							end
						end)
					end
				end
			end,
			function()
				if _llm_fetch_request_id ~= my_request_id then return end
				-- DO NOT reset the entire predictions buffer if one of the parallel threads drops.
				-- Let the successful ones continue to be displayed.
				if not _predictions_active then
					if tooltip.hide then tooltip.hide() end
				end
			end,
			llm_sequential_mode,
			force_trigger,
			function() return _llm_fetch_request_id end
		)
	end
end

M._llm_timer = hs.timer.delayed.new(llm_debounce_time, M._perform_llm_check)

--- Synchronizes state and invalidates previews when typing alters context.
--- @param buf string The current buffer context.
function M.update_preview(buf)
	M.stop_timer()

	local function buffer_ends_with_trigger(buffer, trigger, is_word)
		if type(buffer) ~= "string" or type(trigger) ~= "string" or trigger == "" then return false end
		if #buffer < #trigger then return false end
		if buffer:sub(-#trigger) ~= trigger then return false end
		if is_word ~= true then return true end

		local start_idx = #buffer - #trigger + 1
		if start_idx <= 1 then return true end

		local before = buffer:sub(1, start_idx - 1)
		local prev_offset = utf8.offset(before, -1)
		local prev_char = prev_offset and before:sub(prev_offset) or ""

		if prev_char == "@" then return false end
		if text_utils and type(text_utils.is_letter_char) == "function" and text_utils.is_letter_char(prev_char) then
			return false
		end
		return true
	end

	-- Essential: do not keep memory of unused suggestions
	if not buf or #buf == 0 then 
		_last_llm_input_signature = nil
		M.reset_predictions()
		return 
	end
	
	local last_word = buf:match("([^%s]+)$")
	if not last_word then 
		M.reset_predictions()
		M.start_timer()
		return 
	end

	local match_repl    = nil
	local matched_input = nil
	local match_type    = nil
	local match_group   = nil
	for _, provider in ipairs(_state.preview_providers) do
		local ok, res = pcall(provider, buf)
		if ok and res then match_repl = res; match_type = "provider"; break end
	end
	
	if not match_repl then
		for _, m in ipairs(_state.mappings) do
			local group_active = not m.group or not _state.groups[m.group] or _state.groups[m.group].enabled
			if group_active then
				local magic_len = #_state.magic_key
				local has_magic_suffix = magic_len > 0 and m.trigger:sub(-magic_len) == _state.magic_key
				local star_base = has_magic_suffix and m.trigger:sub(1, #m.trigger - magic_len) or nil

				if star_base and star_base ~= "" and buffer_ends_with_trigger(buf, star_base, m.is_word) then
					local clean = km_utils and type(km_utils.tokens_from_repl) == "function" 
						and km_utils.plain_text(km_utils.tokens_from_repl(m.repl)) or m.repl
					if clean ~= star_base then
						match_repl = m.repl
						match_type = "star"
						match_group = m.group
						matched_input = star_base
						break
					end
				elseif buffer_ends_with_trigger(buf, m.trigger, m.is_word) then
					if not (m.is_word == false and m.auto == true) then
						local clean = km_utils and type(km_utils.tokens_from_repl) == "function" 
							and km_utils.plain_text(km_utils.tokens_from_repl(m.repl)) or m.repl
						if clean ~= m.trigger then
							match_repl = m.repl
							match_type = "autocorrect"
							match_group = m.group
							matched_input = m.trigger
							break
						end
					end
				end
			end
		end
	end

	local is_fallback_repetition = false
	if match_repl and _state.is_repeat_feature_enabled() then
		local clean = km_utils and type(km_utils.tokens_from_repl) == "function" 
			and km_utils.plain_text(km_utils.tokens_from_repl(match_repl)) or match_repl
		local input_for_repeat = matched_input or last_word
		local last_char_offset = utf8.offset(input_for_repeat, -1)
		if last_char_offset then
			local last_char = input_for_repeat:sub(last_char_offset)
			if clean == input_for_repeat .. last_char then is_fallback_repetition = true end
		end
	end

	if match_repl and not is_fallback_repetition then
		_llm_request_id = _llm_request_id + 1
		local display_text = km_utils and type(km_utils.tokens_from_repl) == "function" 
			and km_utils.plain_text(km_utils.tokens_from_repl(match_repl)) or match_repl

        -- Set color depending on the type of hotstring
		local is_star    = (match_type == "star")
		local hs_enabled = is_star and preview_star_enabled or preview_autocorrect_enabled
		local hs_color = nil
		if preview_colored_tooltips then
			if match_group == "personal" or match_group == "custom" then
				hs_color = C_TINT_PERSONAL_DEFAULT
			else
				hs_color = is_star and preview_star_color or preview_autocorrect_color
			end
		end

		-- Synchronize the tooltip duration with the actual hotstring trigger window
		local hs_delay
		if match_type == "star" then
			hs_delay = type(_state.DELAYS) == "table" and (_state.DELAYS.STAR_TRIGGER or 2.0) or 2.0
		elseif match_type == "autocorrect" then
			hs_delay = type(_state.DELAYS) == "table" and (_state.DELAYS.autocorrection or 0.5) or 0.5
		else
			hs_delay = _state.WORD_TIMEOUT_SEC or 2.5
		end
        -- AI tooltip must stay visible during prediction phase
		if tooltip.set_timeout then tooltip.set_timeout(math.max(0.05, hs_delay)) end

		if tooltip.show then tooltip.show(display_text, false, hs_enabled, hs_color) end

		-- Launch AI timer only if the "AI after hotstring" option is enabled
		if llm_after_hotstring_enabled then
			M.start_timer(math.max(0.1, _state.WORD_TIMEOUT_SEC - 0.3))
		end
		
		local suggested_key = matched_input or last_word
		if _last_suggested_hs ~= suggested_key then
			_last_suggested_hs = suggested_key
			if keylogger and type(keylogger.log_hotstring_suggested) == "function" then
				pcall(keylogger.log_hotstring_suggested)
			end
		end
	else
		M.reset_predictions()
		M.start_timer()
	end
end





-- =====================================
-- =====================================
-- ======= 5/ Execution Handlers =======
-- =====================================
-- =====================================

--- Main controller function that decides if the OS keyboard event affects the LLM.
--- @param keyCode number Keystroke numeric code.
--- @param flags table Keystroke modifier keys.
--- @param is_ignored boolean Disables functionality temporarily.
--- @return boolean Returns true if the key triggers an LLM injection.
function M.handle_llm_keys(keyCode, flags, is_ignored)
	if is_ignored or not _predictions_active then return false end

	-- Arrow navigation: once user navigates at least once, Enter becomes an accept key.
	if keyCode >= 123 and keyCode <= 126 then
		local n_preds = type(_pending_predictions) == "table" and #_pending_predictions or 0
		if n_preds > 1 then
			local nav_mods = parse_mods(llm_nav_modifiers, {})
			if core_llm.check_modifiers(flags, nav_mods) then
				local nav_dir = (keyCode == 123 or keyCode == 126) and -1 or 1
				if type(tooltip.navigate) == "function" then
					tooltip.navigate(nav_dir)
				end
				_enter_validates_pred = true
				return true
			end
		end
	end

	if keyCode == 36 or keyCode == 76 then
		local idx = tooltip.get_current_index and tooltip.get_current_index() or 1
		local applied = M.apply_prediction(idx)
		if not applied then
			M.reset_predictions()
		end
		-- Enter is reserved for prediction validation while predictions are active.
		return true
	end

	local val_mods = parse_mods(llm_val_modifiers, M.LLM_VAL_MODIFIERS_DEFAULT)
	if #_pending_predictions > 1 and core_llm.check_modifiers(flags, val_mods) then
		local n = NUM_KEYCODES[keyCode]
		if n and n <= #_pending_predictions then
			return M.apply_prediction(n)
		end
	end

	return false
end

--- Validates if LLM reset must happen upon escape keystroke.
--- @return boolean Indicates if the keystroke event was consumed.
function M.check_escape_reset()
	if _predictions_active then M.reset_predictions(); return true end
	if llm_reset_on_nav then _state.buffer = "" end
	M.reset_predictions()
	return false
end

--- Verifies if navigational operations erase LLM memory.
function M.check_nav_reset()
	if llm_reset_on_nav then _state.buffer = "" end
	M.reset_predictions()
end





-- =============================
-- =============================
-- ======= 6/ Module API =======
-- =============================
-- =============================

--- Mounts the shared state to the LLM bridge module.
--- @param core_state table The shared state object.
function M.init(core_state)
	_state = core_state
	Logger.info(LOG, "Keymap LLM bridge initialized successfully.")
end

return M
