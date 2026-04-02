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

local LOG = "llm_bridge"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local ok_tt, tooltip = pcall(require, "ui.tooltip")
if not ok_tt then
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
local _last_suggested_hs       = nil

local current_llm_model        = core_llm.DEFAULT_LLM_MODEL or "llama3.2"
local llm_enabled              = core_llm.DEFAULT_LLM_ENABLED or false
local preview_star_enabled        = true
local preview_autocorrect_enabled = true
local preview_ai_enabled          = true
local preview_colored_tooltips    = true

-- Hardcoded tint colors (hue only, applied over a fixed dark base in apply_tint)
local C_TINT_STAR_DEFAULT        = { red = 1.00, green = 0.00, blue = 0.00, alpha = 1.0 }
local C_TINT_AUTOCORRECT_DEFAULT = { red = 0.00, green = 0.80, blue = 0.00, alpha = 1.0 }
local C_TINT_PERSONAL_DEFAULT     = { red = 0.20, green = 0.55, blue = 1.00, alpha = 1.0 }
local C_TINT_AI_LOADING           = { red = 0.68, green = 0.38, blue = 1.00, alpha = 1.0 }
-- IA uses nil = neutral dark gray (no tint)

local preview_star_color        = C_TINT_STAR_DEFAULT
local preview_autocorrect_color = C_TINT_AUTOCORRECT_DEFAULT
local preview_ai_color          = nil

local llm_after_hotstring_enabled = false

local llm_debounce_time        = 0.5
local llm_context_length       = 500
local llm_reset_on_nav         = true
local llm_temperature          = 0.1
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

function M.set_llm_model(m)               current_llm_model      = tostring(m) end
function M.set_llm_context_length(l)      llm_context_length     = math.max(1, tonumber(l) or 500) end
function M.set_llm_reset_on_nav(r)        llm_reset_on_nav       = (r == true) end
function M.set_llm_temperature(t)         llm_temperature        = math.max(0, tonumber(t) or 0.1) end
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
		if M._llm_timer and type(M._llm_timer.running) == "function" and M._llm_timer:running() then 
			M._llm_timer:stop() 
		end
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
	-- Couleur IA fixe (gris neutre) — non personnalisable
end

function M.set_llm_after_hotstring(v)
	llm_after_hotstring_enabled = (v == true)
end

--- Backward-compatible setter : enables or disables all hotstring tooltips at once.
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





-- =====================================
-- =====================================
-- ======= 3/ Engine & Validation ======
-- =====================================
-- =====================================

--- Safely resets the prediction engine state and invalidates any pending API request.
function M.reset_predictions()
	_pending_predictions  = {}
	_predictions_active   = false
	_enter_validates_pred = false
	_last_suggested_hs    = nil
	
	_llm_request_id       = _llm_request_id + 1
	
	if tooltip.hide then tooltip.hide() end
	M.stop_timer()
end

--- Validates and applies the selected LLM prediction with robust fail-safes.
--- @param idx number The index of the prediction to apply.
--- @return boolean True if applied, false otherwise.
function M.apply_prediction(idx)
	local pred = _pending_predictions[idx]
	if not pred then return false end
	M.reset_predictions()

	local original_deletes = pred.deletes or 0
	local original_to_type = pred.to_type or ""
	
	local deletes = original_deletes
	local to_type = original_to_type

	local ok_overlap, res_deletes, res_to = pcall(function()
		if km_utils and type(km_utils.resolve_prediction_overlap) == "function" then
			return km_utils.resolve_prediction_overlap(_state.buffer, original_deletes, original_to_type)
		end
		return original_deletes, original_to_type
	end)
	
	if ok_overlap then
		deletes = res_deletes
		to_type = res_to
		
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
				buffer_kept = _state.buffer
			else
				local start_del = utf8.offset(_state.buffer, -deletes)
				if start_del and start_del > 1 then
					buffer_kept = _state.buffer:sub(1, start_del - 1)
				end
			end
			
			if not ends_with_space(buffer_kept) then
				to_type = " " .. to_type
			end
		end
	else
		Logger.error(LOG, "Solveur d'expansion: %s", tostring(res_deletes))
		deletes = original_deletes
		to_type = original_to_type
	end

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
	end)
end





-- =========================================
-- =========================================
-- ======= 4/ Execution Constraints ========
-- =========================================
-- =========================================

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

--- Generates the string for the information bar tooltip.
--- @param model_name string Model identifier.
--- @param elapsed_ms number Milliseconds taken for generation.
--- @param is_mlx boolean Whether MLX backend is active.
--- @param profile_name string|nil Profile/prompt name for display.
--- @return string Formatted string.
local function build_info_bar(model_name, elapsed_ms, is_mlx, profile_name)
	if not model_name or model_name == "" then return nil end
	
	local parts = {}
	table.insert(parts, model_name)
	
	if profile_name and profile_name ~= "" then
		table.insert(parts, profile_name)
	end
	
	if elapsed_ms and elapsed_ms > 0 then
		local secs = elapsed_ms / 1000
		local time_str = secs < 10 and string.format("%.1fs", secs) or string.format("%ds", math.floor(secs + 0.5))
		local time_block = "⏱️ " .. time_str .. (is_mlx and " (MLX 🚀)" or "")
		table.insert(parts, time_block)
		return table.concat(parts, " — ")
	end
	return table.concat(parts, " — ")
end

--- Core routine to evaluate buffer state and dispatch API calls if suitable.
function M._perform_llm_check(force_trigger, profile_name)
	force_trigger = force_trigger == true
	Logger.debug(LOG, "_perform_llm_check: force_trigger=%s, profile_name=%s", tostring(force_trigger), tostring(profile_name))
	Logger.debug(LOG, "llm_enabled=%s", tostring(llm_enabled))
	if not llm_enabled then
		Logger.debug(LOG, "LLM désactivé — abandon")
		return
	end
	
	local is_suppressed = llm_suppressed_for_app()
	Logger.debug(LOG, "llm_suppressed_for_app()=%s", tostring(is_suppressed))
	if is_suppressed then
		Logger.debug(LOG, "LLM supprimé pour cette app — abandon")
		return
	end

	local clean_buffer = _state.buffer
	Logger.debug(LOG, "Buffer: '%s' (length=%d)", clean_buffer, #clean_buffer)
	
	local words = {}
	for w in clean_buffer:gmatch("%S+%s*") do table.insert(words, w) end
	Logger.debug(LOG, "Mots dans le buffer: %d", #words)
	
	if #words == 0 and not force_trigger then
		Logger.debug(LOG, "Buffer vide sans trigger manuel — abandon")
		return
	end
	
	local tail = table.concat(words, "", math.max(1, #words - 4))
	Logger.debug(LOG, "Tail: '%s' (length=%d)", tail, #tail)
	
	if (not tail or #tail < 2) and not force_trigger then
		Logger.debug(LOG, "Tail trop court sans trigger manuel — abandon")
		return
	end

	if tooltip.show then tooltip.show("⏳ Génération en cours...", true, preview_ai_enabled, C_TINT_AI_LOADING) end

	local num_pred = llm_num_predictions

	_llm_request_id = _llm_request_id + 1
	local my_request_id = _llm_request_id

	if type(core_llm.fetch_llm_prediction) == "function" then
		core_llm.fetch_llm_prediction(
			clean_buffer, tail,
			current_llm_model, llm_temperature, 80, num_pred,
			function(predictions, elapsed_ms)
				if _llm_request_id ~= my_request_id then return end
				
				local valid_preds = {}
				for _, p in ipairs(predictions) do
					if p.to_type then
						local tt = p.to_type
						
						if llm_max_words > 0 then
							tt = truncate_words(tt, llm_max_words)
							if p.nw then
								p.nw = truncate_words(p.nw, llm_max_words)
							end
						end
						
						if tt:gsub("[%s%.…]", "") ~= "" then
							p.to_type = tt
							
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

				if #valid_preds == 0 then
					M.reset_predictions(); return
				end
				
				-- Notify keylogger that we suggested a prediction
				if keylogger and type(keylogger.log_llm_suggested) == "function" then
					pcall(keylogger.log_llm_suggested)
				end
				
				_pending_predictions = valid_preds
				_predictions_active  = true
				local using_mlx = type(core_llm.is_using_mlx) == "function" and core_llm.is_using_mlx() or false
				
				local display_profile_name = profile_name
				if not display_profile_name then
					if type(core_llm.get_active_profile) == "function" then
						local profile = core_llm.get_active_profile()
						if type(profile) == "table" and type(profile.label) == "string" then
							display_profile_name = profile.label
						end
					end
				end
				
				local info = llm_show_info_bar and build_info_bar(current_llm_model, elapsed_ms, using_mlx, display_profile_name) or nil
				
				local val_mods = llm_val_modifiers
				local val_mod_str = "none"
				if llm_num_predictions > 1 and not (#val_mods == 1 and val_mods[1] == "none") then
					val_mod_str = (#val_mods == 0) and "\226\128\139" or table.concat(val_mods, "+")
				end

				if tooltip.show_predictions then
					tooltip.show_predictions(valid_preds, 1, preview_ai_enabled, info, val_mod_str, llm_pred_indent, llm_nav_modifiers, preview_ai_color)
				end
			end,
			function()
				if _llm_request_id ~= my_request_id then return end
				M.reset_predictions()
			end,
			llm_sequential_mode,
			force_trigger
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

	-- Essentiel: ne pas conserver la mémoire des suggestions inexploitées
	if not buf or #buf == 0 then 
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
	-- "star" = hotstring terminant par ★, "autocorrect" = déclenché par espace, "provider" = dynamique
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

		-- Sélectionne le drapeau et la couleur en fonction du type de hotstring correspondant
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

		-- Synchronise la durée du tooltip avec la fenêtre de déclenchement réelle du hotstring
		local hs_delay
		if match_type == "star" then
			hs_delay = type(_state.DELAYS) == "table" and (_state.DELAYS.STAR_TRIGGER or 2.0) or 2.0
		elseif match_type == "autocorrect" then
			hs_delay = type(_state.DELAYS) == "table" and (_state.DELAYS.autocorrection or 0.5) or 0.5
		else
			hs_delay = _state.WORD_TIMEOUT_SEC or 2.5
		end
		-- Le tooltip doit rester visible pendant la fenêtre de déclenchement (avec la marge appliquée dans tooltip.lua)
		if tooltip.set_timeout then tooltip.set_timeout(math.max(0.05, hs_delay)) end

		if tooltip.show then tooltip.show(display_text, false, hs_enabled, hs_color) end

		-- Lance le timer IA seulement si l'option "IA après hotstring" est activée
		if llm_after_hotstring_enabled then
			M.start_timer(math.max(0.1, _state.WORD_TIMEOUT_SEC - 0.3))
		end
		
		-- Enregistre qu'une suggestion vient de s'afficher à l'écran si ce n'est pas déjà le cas
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

	if keyCode == 36 then
		if _enter_validates_pred then
			local idx = tooltip.get_current_index and tooltip.get_current_index() or 1
			return M.apply_prediction(idx)
		else
			M.reset_predictions()
		end
		return false
	end

	local val_mods = parse_mods(llm_val_modifiers, M.LLM_VAL_MODIFIERS_DEFAULT)
	if #_pending_predictions > 1 and core_llm.check_modifiers(flags, val_mods) then
		local n = NUM_KEYCODES[keyCode]
		if n and n <= #_pending_predictions then return M.apply_prediction(n) end
	end

	return false
end

--- Validates if LLM reset must happen upon escape keystroke.
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
end

return M
