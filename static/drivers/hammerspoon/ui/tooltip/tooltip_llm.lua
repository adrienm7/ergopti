--- ui/tooltip/tooltip_llm.lua

--- ==============================================================================
--- MODULE: Tooltip AI (LLM)
--- DESCRIPTION:
--- Manages the rendering, interaction, and lifecycle of AI predictions.
--- 
--- FEATURES & RATIONALE:
--- 1. Dedicated Context: Separates complex AI UI from simple hotstring alerts.
--- 2. Keyboard Intercepts: Handles arrow navigation and tab acceptance.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")
local LOG = "tooltip_llm"

local Config = require("ui.tooltip.config")
local Renderer = require("ui.tooltip.renderer")

local MAC_KEYCODES_NUMBERS = {
	[18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5,
	[22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10
}

local KEY_TAB = 48
local KEY_RETURN = 36
local KEY_ENTER = 76
local KEY_LEFT_ARROW = 123
local KEY_UP_ARROW = 126





-- ==================================
-- ==================================
-- ======= 1/ State Variables =======
-- ==================================
-- ==================================

local _state = {
	raw_predictions = {},
	current_index   = 1,
	on_navigate     = nil,
	on_accept       = nil,
	on_cancel       = nil,
	info_bar        = nil,
	shortcut_mod    = "alt",
	nav_mods        = {},
	nav_mod_str     = "none",
	indent          = 0,
	fixed_width     = nil,
	bg_color        = nil,
	loading_text    = nil,
	enter_validates = false,
	reserved_count  = 0
}

local _watchers = {}
local _idle_timer = nil
local _shift_side = nil  -- "left", "right", or nil when no shift is held





-- ================================
-- ================================
-- ======= 2/ Event Control =======
-- ================================
-- ================================

--- Clears active timers and sets a new idle timeout if applicable.
local function reset_idle_timer()
	if _idle_timer and type(_idle_timer.stop) == "function" then _idle_timer:stop() end
	local active_timeout = Config.settings.llm_timeout_sec
	
	if active_timeout > 0 then
		_idle_timer = hs.timer.doAfter(active_timeout, M.hide)
	end
end

--- Terminates all active keyboard and mouse watchers.
local function stop_watchers()
	for _, watcher in ipairs(_watchers) do 
		if watcher and type(watcher.stop) == "function" then watcher:stop() end 
	end
	_watchers = {}
	
	if _idle_timer and type(_idle_timer.stop) == "function" then 
		_idle_timer:stop()
		_idle_timer = nil 
	end
end

--- Validates modifier flags securely against expected target mods.
--- @param current_flags table Keystroke modifiers active.
--- @param target_mods table List of required modifiers.
--- @return boolean True if matched exactly.
local function evaluate_modifiers(current_flags, target_mods)
	if type(target_mods) ~= "table" then return false end
	
	local flattened_mods = {}
	for _, mod in ipairs(target_mods) do
		if type(mod) == "string" then table.insert(flattened_mods, mod:lower())
		elseif type(mod) == "table" then
			for _, sub_mod in ipairs(mod) do if type(sub_mod) == "string" then table.insert(flattened_mods, sub_mod:lower()) end end
		end
	end
	
	if #flattened_mods == 1 and flattened_mods[1] == "none" then return false end
	
	local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
	for _, mod in ipairs(flattened_mods) do if target_map[mod] ~= nil then target_map[mod] = true end end
	
	if (current_flags.cmd or false)   ~= target_map.cmd   then return false end
	if (current_flags.alt or false)   ~= target_map.alt   then return false end
	if (current_flags.shift or false) ~= target_map.shift then return false end
	if (current_flags.ctrl or false)  ~= target_map.ctrl  then return false end
	
	return true
end

--- Starts OS-level interception to handle LLM navigation and dismissal.
local function start_watchers()
	stop_watchers()
	reset_idle_timer()
	
	local event_types = hs.eventtap.event.types
	
	-- Mouse Watcher
	local ok_mouse, watcher_mouse = pcall(hs.eventtap.new, { event_types.mouseMoved, event_types.leftMouseDown, event_types.rightMouseDown, event_types.scrollWheel }, function(_)
		if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
		M.hide()
		return false
	end)
	
	if ok_mouse and watcher_mouse then 
		watcher_mouse:start()
		table.insert(_watchers, watcher_mouse) 
	end

	-- Keyboard Watcher
	-- Track which shift key is held so Tab navigation uses the correct direction.
	-- Left shift + Tab  → previous prediction (-1)
	-- Right shift + Tab → next prediction    (+1)
	local ok_flags, watcher_flags = pcall(hs.eventtap.new, { event_types.flagsChanged }, function(e)
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
	if ok_flags and watcher_flags then
		watcher_flags:start()
		table.insert(_watchers, watcher_flags)
	end

	local ok_key, watcher_key = pcall(hs.eventtap.new, { event_types.keyDown }, function(event)
		local keycode = event:getKeyCode()
		local flags = event:getFlags()
		local chars = event:getCharacters(true) or event:getCharacters(false) or ""
		local is_submit_key = (keycode == KEY_RETURN or keycode == KEY_ENTER or chars == "\r" or chars == "\n")

		-- Handling Tab presses during LLM execution
		if keycode == KEY_TAB then
			if flags.shift then
				local preds_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
				if preds_count > 1 then
					-- Left shift → back (-1), right shift → forward (+1)
					local direction = (_shift_side == "right") and 1 or -1
					M.navigate(direction)
					return true
				end
			else
				local has_other_modifiers = flags.cmd or flags.alt or flags.ctrl or (flags.shift == true)
				if not has_other_modifiers then
					if type(_state.on_accept) == "function" then _state.on_accept(_state.current_index) end
					return true
				end
				if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
				return false
			end
		end

		-- Handling Enter confirmation
		if is_submit_key then
			local has_other_modifiers = flags.cmd or flags.alt or flags.ctrl or flags.shift
			if not has_other_modifiers then
				if _state.enter_validates then
					if type(_state.on_accept) == "function" then _state.on_accept(_state.current_index) end
					return true
				else
					if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
					return false
				end
			else
				if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
				return false
			end
		end
		
		-- Handling Arrow Navigation
		if keycode >= KEY_LEFT_ARROW and keycode <= KEY_UP_ARROW then
			local preds_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
			if preds_count > 1 and evaluate_modifiers(flags, _state.nav_mods) then
				local nav_direction = (keycode == KEY_LEFT_ARROW or keycode == KEY_UP_ARROW) and -1 or 1
				M.navigate(nav_direction)
				return true
			end
		end
		
		-- Handling Hotkey Selection
		local shortcut_modifier = _state.shortcut_mod or "alt"
		if shortcut_modifier ~= "none" then
			local match_all = true
			local required_flags = {}
			
			for mod_str in shortcut_modifier:gmatch("[^+]+") do 
				required_flags[mod_str] = true
				if not flags[mod_str] then match_all = false; break end 
			end
			
			if match_all then
				for flag_name, flag_active in pairs(flags) do 
					if flag_active and not required_flags[flag_name] and (flag_name == "cmd" or flag_name == "alt" or flag_name == "shift" or flag_name == "ctrl") then 
						match_all = false
						break 
					end 
				end
			end
			
			if match_all and MAC_KEYCODES_NUMBERS[keycode] then
				local pred_index = MAC_KEYCODES_NUMBERS[keycode]
				local preds_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
				if pred_index <= preds_count then 
					if type(_state.on_accept) == "function" then _state.on_accept(pred_index) end 
				end
				return true
			end
		end
		
		-- Ignored system modifier keys (preventing unintended dismissals)
		local ignored_keycodes = { 54, 55, 56, 58, 59, 60, 105, 107, 113, 106, 64, 79, 80, 90 }
		for _, ignored_code in ipairs(ignored_keycodes) do
			if keycode == ignored_code then return false end
		end
		
		if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end 
		M.hide()
		return false
	end)
	
	if ok_key and watcher_key then 
		watcher_key:start()
		table.insert(_watchers, watcher_key) 
	else 
		Logger.error(LOG, "Failed to mount keyboard event listener.") 
	end
end





-- ==================================
-- ==================================
-- ======= 3/ Text Formatting =======
-- ==================================
-- ==================================

--- Safely appends styled segments to a result string.
local function append_segment(result, text, color, is_bold)
	if not text or tostring(text) == "" then return result end
	local font_name = is_bold and Config.fonts.bold or Config.fonts.main
	local segment = hs.styledtext.new(tostring(text), { font = { name = font_name, size = Config.sizes.main }, color = color })
	return result and (result .. segment) or segment
end

--- Builds a single line of text reflecting the diff states with precise coloring.
--- @param prediction table The prediction payload.
--- @param is_selected boolean True if this prediction is currently highlighted.
--- @return userdata|nil The styled text object.
local function build_line(prediction, is_selected)
	if type(prediction) ~= "table" then return nil end

	local result = nil
	local diff_chunks = type(prediction.chunks) == "table" and prediction.chunks or {}
	local next_words = prediction.nw or ""

	local has_corrections = prediction.has_corrections == true
	local has_gray_reference = false
	
	for _, chunk in ipairs(diff_chunks) do
		if chunk.type == "equal" and tostring(chunk.text or ""):match("%S") then
			has_gray_reference = true
			break
		end
	end

	local apply_bold = has_corrections and has_gray_reference
	if prediction.disable_bold then apply_bold = false end

	local is_first_chunk_cleaned = false
	local function clean_leading_spaces(str)
		local safe_str = tostring(str or "")
		if not is_first_chunk_cleaned and safe_str ~= "" then
			safe_str = safe_str:gsub("^%s+", "")
			if safe_str ~= "" then is_first_chunk_cleaned = true end
		end
		return safe_str
	end

	local last_character = ""

	if #diff_chunks > 0 then
		for _, chunk in ipairs(diff_chunks) do
			if type(chunk) == "table" then
				local chunk_text = clean_leading_spaces(chunk.text)
				if chunk_text and chunk_text ~= "" then
					last_character = chunk_text:sub(-1)
					
					if chunk.type == "insert" then
						-- colorization_enabled controls the background tint only; text accent colors
						-- always apply to the selected item so it remains visually distinct
						local chunk_color = is_selected and Config.colors.corr_sel or Config.colors.unsel_gray
						local chunk_bold = (not is_selected) and apply_bold
						result = append_segment(result, chunk_text, chunk_color, chunk_bold)
					elseif chunk.type == "equal" then
						result = append_segment(result, chunk_text, Config.colors.unsel_gray, false)
					end
				end
			end
		end
	end

	local safe_next_words = clean_leading_spaces(next_words)
	if safe_next_words and safe_next_words ~= "" then
		if last_character ~= "" and not last_character:match("%s") and not safe_next_words:match("^%s") then
			safe_next_words = " " .. safe_next_words
		end
		
		local nw_color = is_selected and Config.colors.nw_sel or Config.colors.unsel_gray
		local nw_bold = (not is_selected) and apply_bold
		result = append_segment(result, safe_next_words, nw_color, nw_bold)
	end

	return result
end

--- Assembles all lines and bottom hints into styled blocks ready for rendering.
--- @param state table The global orchestrator state.
--- @param reserved_count number Spaces to reserve for loading predictions.
--- @return table The block components.
local function assemble_blocks(state, reserved_count)
	local active_count = type(state.raw_predictions) == "table" and #state.raw_predictions or 0
	local display_count = math.max(active_count, tonumber(reserved_count) or active_count)

	if active_count == 0 and (not reserved_count or tonumber(reserved_count) == 0) then 
		return { preds = hs.styledtext.new("") } 
	end

	local prefix_selected = ""
	local prefix_unselected = ""
	local visual_compensation_space = " "

	if display_count == 1 then prefix_selected = "✨ "
	elseif display_count >= 2 and state.indent > 0 then prefix_selected = string.rep(" ", state.indent) .. "✨ "
	else prefix_selected = "✨ "
	end

	local indent_numeric = math.floor(tonumber(state.indent) or 0)
	if indent_numeric < 0 and indent_numeric > -3 then
		prefix_unselected = string.rep(" ", -indent_numeric)
	elseif indent_numeric <= -3 then
		prefix_unselected = prefix_selected .. string.rep(" ", math.max(0, (-indent_numeric) - 3))
	end

	if indent_numeric > -3 then prefix_unselected = prefix_unselected .. visual_compensation_space end

	local styled_prefix_unselected = hs.styledtext.new(prefix_unselected, { font = { name = Config.fonts.main, size = Config.sizes.main }, color = Config.colors.invis })
	local styled_prefix_empty = hs.styledtext.new("", { font = { name = Config.fonts.main, size = Config.sizes.main }, color = Config.colors.invis })
	local styled_gap = hs.styledtext.new("\n", { font = { name = Config.fonts.main, size = Config.sizes.gap }, color = Config.colors.invis })

	local assembled_result = nil

	for i = 1, display_count do
		local prediction = state.raw_predictions[i]
		local is_selected = (i == state.current_index and prediction ~= nil)
		
		local prefix_block = is_selected
			and hs.styledtext.new(prefix_selected, { font = { name = Config.fonts.main, size = Config.sizes.main }, color = Config.colors.cursor })
			or (prefix_unselected ~= "" and styled_prefix_unselected or styled_prefix_empty)

		local body_block
		if prediction ~= nil then
			body_block = build_line(prediction, is_selected)
			if not body_block then
				body_block = hs.styledtext.new("…", { font = { name = Config.fonts.main, size = Config.sizes.main, traits = { italic = true } }, color = Config.colors.unsel_gray })
			end
		else
			local placeholder_prefix = prefix_unselected ~= "" and styled_prefix_unselected or styled_prefix_empty
			body_block = hs.styledtext.new("...", { font = { name = Config.fonts.main, size = Config.sizes.main, traits = { italic = true } }, color = Config.colors.loading })
			assembled_result = assembled_result and (assembled_result .. styled_gap .. (placeholder_prefix .. body_block)) or (placeholder_prefix .. body_block)
			goto continue
		end

		local shortcut_string = ""
		if display_count > 1 and state.shortcut_mod ~= "none" then
			local modifier_symbol = tostring(state.shortcut_mod):gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
			if modifier_symbol == "" or modifier_symbol == "nil" then modifier_symbol = "⌥" end
			
			if i <= 9 then shortcut_string = "   " .. modifier_symbol .. i 
			elseif i == 10 then shortcut_string = "   " .. modifier_symbol .. "0" 
			end
		end

		local full_line
		if shortcut_string ~= "" then
			local shortcut_segment = hs.styledtext.new(shortcut_string, { font = { name = Config.fonts.main, size = Config.sizes.hint }, color = is_selected and Config.colors.cmd_sel or Config.colors.cmd_dim })
			full_line = prefix_block .. body_block .. shortcut_segment
		else
			full_line = prefix_block .. body_block
		end

		assembled_result = assembled_result and (assembled_result .. styled_gap .. full_line) or full_line
		::continue::
	end

	local space_divider = string.rep(" ", 6)
	local styled_hint

	if display_count > 1 then
		local hint_left  = "⇧G + Tab"
		local hint_right = "⇧D + Tab"
		if state.nav_mod_str ~= "none" then
			local optional_nav_mod = (state.nav_mod_str ~= "" and state.nav_mod_str ~= "none") and (state.nav_mod_str .. " + ") or ""
			hint_left  = hint_left  .. " ou " .. optional_nav_mod .. "↑/←"
			hint_right = hint_right .. " ou " .. optional_nav_mod .. "↓/→"
		end
		
		styled_hint = hs.styledtext.new(
			hint_left .. space_divider .. " ◀" .. space_divider .. "Tab = accepter" .. space_divider .. "▶ " .. space_divider .. hint_right,
			{ font = { name = Config.fonts.main, size = Config.sizes.hint }, color = Config.colors.hint, paragraphStyle = { alignment = "center" } }
		)
	else
		styled_hint = hs.styledtext.new("Tab pour accepter", { font = { name = Config.fonts.main, size = Config.sizes.hint }, color = Config.colors.hint, paragraphStyle = { alignment = "center" } })
	end

	local styled_info = nil
	if state.info_bar and tostring(state.info_bar) ~= "" then
		styled_info = hs.styledtext.new(tostring(state.info_bar), { font = { name = Config.fonts.main, size = Config.sizes.info }, color = Config.colors.info_bar, paragraphStyle = { alignment = "center" } })
	end

	return { preds = assembled_result, hint_st = styled_hint, info_st = styled_info, SP = space_divider }
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

function M.set_navigate_callback(callback) _state.on_navigate = callback end
function M.set_accept_callback(callback) _state.on_accept = callback end
function M.set_cancel_callback(callback) _state.on_cancel = callback end
function M.set_enter_validates(validates) _state.enter_validates = (validates == true) end
function M.get_current_index() return _state.current_index end

--- Sets the auto-dismiss timeout used by the internal idle timer.
--- Pass 0 to keep the tooltip visible indefinitely until user interaction.
--- @param seconds number The timeout duration in seconds.
function M.set_timeout(seconds)
	Config.settings.llm_timeout_sec = math.max(0, tonumber(seconds) or 0)
end
 
--- Resets the internal idle timer using the currently configured timeout.
--- Called by llm_bridge after every navigation and once predictions are final.
function M.reset_timer()
	reset_idle_timer()
end
 

function M.hide()
	pcall(function()
		stop_watchers()
		_state.raw_predictions = {}
		_state.current_index   = 1
		_state.info_bar        = nil
		_state.fixed_width     = nil
		_state.bg_color        = nil
		_state.loading_text    = nil
		_state.enter_validates = false
		Renderer.hide()
	end)
end

function M.navigate(delta)
	local ok, err = pcall(function()
		local active_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
		if active_count < 2 then return end
		
		_state.current_index = ((_state.current_index - 1 + delta) % active_count) + 1
		Renderer.render(assemble_blocks(_state, _state.reserved_count), _state, start_watchers)
		
		if type(_state.on_navigate) == "function" then pcall(_state.on_navigate, _state.current_index) end
		reset_idle_timer()
	end)
	
	if not ok then Logger.error(LOG, "Crash during navigation execution: " .. tostring(err) .. ".") end
end

function M.show_predictions(predictions, current_index, is_enabled, info_bar, shortcut_modifier, indent, navigation_modifiers, background_color, loading_text, max_reserved_count)
	local ok, err = pcall(function()
		if not is_enabled then return end
		
		local active_count = type(predictions) == "table" and #predictions or 0
		local reserved_slots = tonumber(max_reserved_count) or 0
		
		if active_count == 0 and reserved_slots == 0 then 
			M.hide()
			return 
		end

		_state.raw_predictions = type(predictions) == "table" and predictions or {}
		_state.current_index   = current_index or 1
		_state.info_bar        = info_bar
		_state.shortcut_mod    = shortcut_modifier or "alt"
		_state.nav_mods        = type(navigation_modifiers) == "table" and navigation_modifiers or {}
		_state.indent          = indent or 0
		_state.bg_color        = Config.settings.colorization_enabled and (type(background_color) == "table" and background_color or nil) or nil
		_state.loading_text    = loading_text
		
		local flattened_nav_modifiers = {}
		for _, mod in ipairs(_state.nav_mods) do
			if type(mod) == "string" then table.insert(flattened_nav_modifiers, mod)
			elseif type(mod) == "table" then
				for _, sub_mod in ipairs(mod) do if type(sub_mod) == "string" then table.insert(flattened_nav_modifiers, sub_mod) end end
			end
		end

		local nav_modifier_string = "none"
		if #flattened_nav_modifiers > 0 and not (#flattened_nav_modifiers == 1 and flattened_nav_modifiers[1] == "none") then
			nav_modifier_string = table.concat(flattened_nav_modifiers, "+")
			nav_modifier_string = nav_modifier_string:gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
		elseif #flattened_nav_modifiers == 0 then 
			nav_modifier_string = "" 
		end
		_state.nav_mod_str = nav_modifier_string

		local render_count = math.max(1, math.floor(reserved_slots > 0 and reserved_slots or active_count))
		local calculated_max_width = 0

		for i = 1, render_count do
			local simulation_state = {}
			for k, v in pairs(_state) do simulation_state[k] = v end
			simulation_state.current_index = i
			
			local blocks = assemble_blocks(simulation_state, render_count)
			local width_predictions = Renderer.canvas:minimumTextSize(3, blocks.preds).w
			local width_hint = blocks.hint_st and Renderer.canvas:minimumTextSize(3, blocks.hint_st).w or 0
			local width_info = blocks.info_st and Renderer.canvas:minimumTextSize(3, blocks.info_st).w or 0
			
			local final_width = width_predictions
			if blocks.info_st and blocks.hint_st then
				local space_divider = blocks.SP or "      "
				local separator_styled = hs.styledtext.new(space_divider .. "|" .. space_divider, { font = { name = Config.fonts.main, size = Config.sizes.hint } })
				local combined_styled = hs.styledtext.new("") .. blocks.hint_st .. separator_styled .. blocks.info_st
				local width_combined = Renderer.canvas:minimumTextSize(3, combined_styled).w
				
				if width_combined > width_predictions then final_width = math.max(width_predictions, width_hint, width_info) end
			else
				final_width = math.max(width_predictions, width_hint, width_info)
			end
			
			if final_width > calculated_max_width then calculated_max_width = final_width end
		end

		_state.fixed_width = calculated_max_width
		_state.reserved_count = render_count
		_state.enter_validates = false

		Renderer.render(assemble_blocks(_state, render_count), _state, start_watchers)
	end)
	
	if not ok then Logger.error(LOG, "Crash during show_predictions initialization: " .. tostring(err) .. ".") end
end

function M.make_diff_styled(diff_chunks, next_words, fallback_text)
	local ok, result = pcall(function()
		local prediction_mock = { chunks = type(diff_chunks) == "table" and diff_chunks or {}, nw = tostring(next_words or ""), has_corrections = true }
		return build_line(prediction_mock, true)
	end)
	return ok and result or hs.styledtext.new(tostring(fallback_text))
end

function M.is_visible()
	return type(_state.raw_predictions) == "table" and #_state.raw_predictions > 0
end

return M
