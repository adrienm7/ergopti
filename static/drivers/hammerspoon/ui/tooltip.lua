--- ui/tooltip.lua

--- ==============================================================================
--- MODULE: Tooltip UI
--- DESCRIPTION:
--- Handles the rendering and lifecycle of the on-screen tooltip used for
--- both standard hotstring previews and LLM predictions.
---
--- STYLING RULES (LLM Predictions):
--- 1. Selected Prediction: Original text is gray. New words (predictions) are
---    orange. If the prediction corrects a typo, the corrected part is green.
--- 2. Non-Selected Predictions: Entirely gray. If a non-selected prediction
---    contains a correction, the modified parts (correction + new words) are
---    made bold to distinguish them from what the user actually typed. If
---    there are no corrections, the text remains normal (non-bold) gray.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local LOG    = "tooltip"

local ok_bridge, vscode_bridge = pcall(require, "lib.vscode_bridge")
if not ok_bridge then vscode_bridge = nil end





-- ===============================
-- ===============================
-- ======= 1/ Canvas Setup =======
-- ===============================
-- ===============================

-- Pre-allocate the 6 static elements to ensure zero lag during rendering
local canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
if canvas then
	canvas:level(hs.canvas.windowLevels.cursor)
	canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
	canvas:appendElements(
		{ type = "rectangle", action = "fill",        fillColor  = { white = 0.10, alpha = 0.97 }, roundedRectRadii = { xRadius = 7, yRadius = 7 } }, -- [1] Background
		{ type = "rectangle", action = "strokeAndFill", fillColor = { white = 0, alpha = 0 }, strokeColor = { white = 1, alpha = 0.13 }, strokeWidth = 1, roundedRectRadii = { xRadius = 7, yRadius = 7 } }, -- [2] Border
		{ type = "text" },      -- [3] Predictions (Main text block)
		{ type = "rectangle" }, -- [4] Full-width separator line
		{ type = "text" },      -- [5] Hint / Shortcut OR Combined (Hint + Info)
		{ type = "text" }       -- [6] Info Bar (Time/Model) if not combined
	)
end





-- ===================================
-- ===================================
-- ======= 2/ State & Watchers =======
-- ===================================
-- ===================================

M.TIMEOUT_SEC_DEFAULT     = 2.5
M.LLM_TIMEOUT_SEC_DEFAULT = 12.0
M.HOTSTRING_TIMEOUT_MARGIN_SEC = 0.1

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
	timeout_sec     = M.TIMEOUT_SEC_DEFAULT,
	llm_timeout_sec = M.LLM_TIMEOUT_SEC_DEFAULT,
	current_is_llm  = false,
	bg_color        = nil,
	loading_text    = nil,
	enter_validates = false,  -- True only after user navigates with arrow keys
}

local _watchers = {}
local _idle_timer = nil

-- macOS hardware keycodes for number keys 1 to 0
local num_keycodes = {
	[18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5,
	[22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10
}

--- Automatically hides the tooltip if the user stops typing.
local function reset_idle_timer()
	if _idle_timer and type(_idle_timer.stop) == "function" then 
		_idle_timer:stop() 
	end
	
	local active_timeout = _state.current_is_llm and _state.llm_timeout_sec or _state.timeout_sec
	if active_timeout > 0 then
		_idle_timer = hs.timer.doAfter(active_timeout, M.hide)
	end
end

--- Stops all active event watchers and clears the idle timer.
local function stop_watchers()
	for _, w in ipairs(_watchers) do 
		if w and type(w.stop) == "function" then w:stop() end 
	end
	_watchers = {}
	
	if _idle_timer and type(_idle_timer.stop) == "function" then 
		_idle_timer:stop()
		_idle_timer = nil
	end
end

--- Validates modifier flags securely against expected target mods.
--- @param flags table Keystroke modifiers.
--- @param targetMods table List of required modifiers.
--- @return boolean True if matched exactly.
local function check_modifiers(flags, targetMods)
	if type(targetMods) ~= "table" then return false end
	if #targetMods == 1 and targetMods[1] == "none" then return false end
	
	local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
	for _, mod in ipairs(targetMods) do if target_map[mod] ~= nil then target_map[mod] = true end end
	
	if (flags.cmd or false)   ~= target_map.cmd   then return false end
	if (flags.alt or false)   ~= target_map.alt   then return false end
	if (flags.shift or false) ~= target_map.shift then return false end
	if (flags.ctrl or false)  ~= target_map.ctrl  then return false end
	
	return true
end

--- Starts listening for events that should naturally dismiss or interact with the tooltip.
local function start_watchers()
	stop_watchers()
	reset_idle_timer()
	
	local evTypes = hs.eventtap.event.types
	
	-- Hide tooltip on mouse movement or click
	local w_mouse = hs.eventtap.new({evTypes.mouseMoved, evTypes.leftMouseDown, evTypes.rightMouseDown, evTypes.scrollWheel}, function(_)
		if _state.current_is_llm and type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
		M.hide()
		return false
	end)
	w_mouse:start()
	table.insert(_watchers, w_mouse)

	-- Handle explicit key overrides
	local w_key = hs.eventtap.new({evTypes.keyDown}, function(e)
		local kc = e:getKeyCode()
		local flags = e:getFlags()
		local key_chars = e:getCharacters(true) or e:getCharacters(false) or ""
		local is_enter_key = (kc == 36 or kc == 76 or key_chars == "\r" or key_chars == "\n")
		
		-- Priority interception: STRICTLY consume TAB when LLM predictions are active
		if kc == 48 and _state.current_is_llm then
			if flags.shift then
				local n = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
				if n > 1 then
					M.navigate(-1)
					return true
				end
			else
				-- Only accept prediction if Tab is pressed alone (no other modifier)
				local has_other_mod = flags.cmd or flags.alt or flags.ctrl or (flags.shift == true)
				if not has_other_mod then
					if type(_state.on_accept) == "function" then
						_state.on_accept(_state.current_index)
					end
					return true
				end
				-- If Tab is pressed with modifiers, cancel predictions and let it pass through
				if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
				return false
			end
		end

		-- Priority interception: Enter accepts prediction ONLY if user has navigated with arrow keys first
		if _state.current_is_llm and is_enter_key then
			local has_other_mod = flags.cmd or flags.alt or flags.ctrl or flags.shift
			if not has_other_mod then
				if _state.enter_validates then
					if type(_state.on_accept) == "function" then
						_state.on_accept(_state.current_index)
					end
					return true
				else
					-- Enter not yet validated by navigation: cancel predictions and let it pass through
					if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
					return false
				end
			else
				-- Enter with modifier: cancel predictions and let it pass through for user shortcuts
				if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
				return false
			end
		end
		
		-- Priority interception: Arrow keys for secure navigation
		if _state.current_is_llm and kc >= 123 and kc <= 126 then
			local n = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
			if n > 1 and check_modifiers(flags, _state.nav_mods) then
				local nav_dir = (kc == 123 or kc == 126) and -1 or 1
				M.navigate(nav_dir)
				return true
			end
		end
		
		-- Ignored keys
		if kc == 48 then return false end 
		
		local mod = _state.shortcut_mod or "alt"
		
		-- Priority interception: Selection shortcuts (1-0)
		if mod ~= "none" then
			local match_all = true
			local req_flags = {}
			for m in mod:gmatch("[^+]+") do
				req_flags[m] = true
				if not flags[m] then match_all = false; break end
			end
			
			-- Strict check: no OTHER modifier should be pressed
			if match_all then
				for k, v in pairs(flags) do
					if v and not req_flags[k] and (k == "cmd" or k == "alt" or k == "shift" or k == "ctrl") then
						match_all = false; break
					end
				end
			end
			
			if match_all and num_keycodes[kc] then
				local idx = num_keycodes[kc]
				local n_preds = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
				
				if idx <= n_preds then
					if type(_state.on_accept) == "function" then
						_state.on_accept(idx)
					end
				end
				
				-- RETURN TRUE: We fully consume the keystroke so macOS never receives it
				return true
			end
		end
		
		-- Ignore raw modifier presses (Shift, Ctrl, Alt, Cmd) and common hyper/layer keys (F13-F20) to prevent premature dismissal
		if kc == 54 or kc == 55 or kc == 56 or kc == 58 or kc == 59 or kc == 60 or kc == 105 or kc == 107 or kc == 113 or kc == 106 or kc == 64 or kc == 79 or kc == 80 or kc == 90 then
			return false
		end
		
		-- Any other key: cancel active predictions and hide
		if _state.current_is_llm then
			if type(_state.on_cancel) == "function" then pcall(_state.on_cancel) end
		end
		M.hide()
		return false
	end)
	w_key:start()
	table.insert(_watchers, w_key)
end





-- ====================================
-- ====================================
-- ======= 3/ Anchor Resolution =======
-- ====================================
-- ====================================

--- Resolves the best screen coordinates to display the tooltip based on the current context.
--- @return table|nil Table containing x, y, and optionally h and type, or nil if resolution fails.
local function resolve_anchor()
	-- Native VSCode integration check
	if vscode_bridge and type(vscode_bridge.is_vscode) == "function" and vscode_bridge.is_vscode() then
		local ok, pos = pcall(vscode_bridge.estimate_position)
		if ok and type(pos) == "table" then return pos end
	end
	
	-- Accessibility API evaluation
	local ax_ok, pos = pcall(function()
		local ax = require("hs.axuielement")
		local focused = ax.systemWideElement():attributeValue("AXFocusedUIElement")
		if not focused then return nil end
		
		-- 1. Try text range selection
		local range = focused:attributeValue("AXSelectedTextRange")
		if range and type(range) == "table" then
			local b = focused:parameterizedAttributeValue("AXBoundsForRange", { location = range.location, length = 0 })
			if b and type(b) == "table" and b.x and b.y and b.h and b.h > 0 and b.h < 80 then 
				return { x = b.x, y = b.y, h = b.h, type = "caret" } 
			end
		end
		
		-- 2. Try line number detection
		local ln = focused:attributeValue("AXInsertionPointLineNumber")
		if ln then
			local lr = focused:parameterizedAttributeValue("AXRangeForLine", ln)
			if lr then
				local b = focused:parameterizedAttributeValue("AXBoundsForRange", lr)
				if b and type(b) == "table" and b.x and b.y and b.h and b.h > 0 and b.h < 80 then 
					return { x = b.x, y = b.y, h = b.h, type = "caret" } 
				end
			end
		end
		
		-- 3. Fallback to input box container frame
		local f = focused:attributeValue("AXFrame")
		if f and type(f) == "table" and f.x and f.y and f.w and f.h then 
			return { x = f.x + f.w / 2, y = f.y + f.h, h = 0, type = "input_box" } 
		end
		
		return nil
	end)
	
	if ax_ok and type(pos) == "table" then return pos end

	-- Absolute fallback to the center-bottom of the active window bounds
	local win = hs.window.focusedWindow()
	if win then
		local ok, f = pcall(function() return win:frame() end)
		if ok and f and type(f) == "table" then 
			return { x = f.x + f.w / 2, y = f.y + f.h - 40, h = 0, type = "window" } 
		end
	end
	
	return nil
end





-- =================================
-- =================================
-- ======= 4/ Colors & Fonts =======
-- =================================
-- =================================

local FONT      = ".AppleSystemUIFont"
local FONT_BOLD = ".AppleSystemUIFontBold"
local SIZE_MAIN = 14
local SIZE_HINT = 11
local SIZE_INFO = 10 

local C_BG       = { white = 0.10, alpha = 1.0 }

local C_CORR_SEL = { red = 0.25, green = 0.90, blue = 0.40, alpha = 1.0 }
local C_UNCH_SEL = { white = 0.60, alpha = 1.0 }
local C_NW_SEL   = { red = 1.00, green = 0.62, blue = 0.10, alpha = 1.0 }

local C_UNSELECTED_GRAY = { white = 0.50, alpha = 1.0 }

local C_CURSOR   = { red = 0.98, green = 0.88, blue = 0.22, alpha = 1.0 }
local C_CMD_SEL  = { red = 0.95, green = 0.58, blue = 0.08, alpha = 0.75 }
local C_CMD_DIM  = { white = 0.45, alpha = 1.0 }
local C_HINT     = { white = 0.40, alpha = 1.0 }
local C_INFO_BAR = { white = 0.30, alpha = 1.0 } 
local C_SEP      = { white = 1.00, alpha = 0.09 }
local C_INVIS    = { white = 0.00, alpha = 0.00 }
local C_LOADING  = { red = 0.94, green = 0.78, blue = 0.28, alpha = 1.0 }

--- Extracts the hue from an RGB color and rebuilds a dark, barely-saturated background.
--- @param tint table|nil RGBA tint color whose hue is used, or nil for neutral dark.
--- @return table RGBA resulting background color.
local function apply_tint(tint)
	if not tint or type(tint) ~= "table" then return C_BG end

	local r = math.max(0, math.min(1, tint.red   or 0))
	local g = math.max(0, math.min(1, tint.green or 0))
	local b = math.max(0, math.min(1, tint.blue  or 0))

	-- Extracts hue from RGB
	local max_c = math.max(r, g, b)
	local min_c = math.min(r, g, b)
	local delta = max_c - min_c

	local hue = 0
	if delta > 0.0001 then
		if max_c == r then
			hue = ((g - b) / delta) % 6
		elseif max_c == g then
			hue = (b - r) / delta + 2
		else
			hue = (r - g) / delta + 4
		end
		hue = hue / 6
	end

	-- Fixed dark lightness and very low saturation — only the hue changes
	local L = 0.10
	local S = 0.40

	-- HSL -> RGB
	local c  = (1 - math.abs(2 * L - 1)) * S
	local x  = c * (1 - math.abs((hue * 6) % 2 - 1))
	local m  = L - c / 2
	local h6 = hue * 6
	local nr, ng, nb
	if     h6 < 1 then nr, ng, nb = c, x, 0
	elseif h6 < 2 then nr, ng, nb = x, c, 0
	elseif h6 < 3 then nr, ng, nb = 0, c, x
	elseif h6 < 4 then nr, ng, nb = 0, x, c
	elseif h6 < 5 then nr, ng, nb = x, 0, c
	else               nr, ng, nb = c, 0, x
	end

	return {
		red   = math.max(0, math.min(1, nr + m)),
		green = math.max(0, math.min(1, ng + m)),
		blue  = math.max(0, math.min(1, nb + m)),
		alpha = 0.97,
	}
end





-- ==================================
-- ==================================
-- ======= 5/ Text Formatting =======
-- ==================================
-- ==================================

--- Safely appends styled segments to a result string.
local function append_seg(result, s, color, is_bold)
	if not s or tostring(s) == "" then return result end
	local fn  = is_bold and FONT_BOLD or FONT
	local seg = hs.styledtext.new(tostring(s), { font = { name = fn, size = SIZE_MAIN }, color = color })
	return result and (result .. seg) or seg
end

--- Builds a single line of text reflecting the diff states with precise coloring.
local function build_line(pred, is_sel, total_preds)
	if type(pred) ~= "table" then return nil end
	
	local result = nil
	local chunks = pred.chunks
	local nw     = pred.nw or ""

	local has_corr = pred.has_corrections == true

	-- Prevent all text from becoming bold if there is absolutely no gray reference text
	local has_gray = false
	if type(chunks) == "table" then
		for _, chunk in ipairs(chunks) do
			if chunk.type == "equal" and tostring(chunk.text or ""):match("%S") then
				has_gray = true
				break
			end
		end
	end
	
	local apply_bold = has_corr and has_gray
	
	if pred.disable_bold then
		apply_bold = false
	end

	local first_done = false
	local function clean_first(s)
		local str = tostring(s or "")
		if not first_done and str ~= "" then
			str = str:gsub("^%s+", "")
			if str ~= "" then first_done = true end
		end
		return str
	end

	local last_char = ""

	if type(chunks) == "table" and #chunks > 0 then
		for _, chunk in ipairs(chunks) do
			if type(chunk) == "table" then
				local s = clean_first(chunk.text)
				if s and s ~= "" then
					last_char = s:sub(-1)
					if chunk.type == "insert" then
						local color = is_sel and C_CORR_SEL or C_UNSELECTED_GRAY
						local is_bold = (not is_sel) and apply_bold
						result = append_seg(result, s, color, is_bold)
					elseif chunk.type == "equal" then
						local color = C_UNSELECTED_GRAY
						local is_bold = false
						result = append_seg(result, s, color, is_bold)
					end
				end
			end
		end
	end

	local s_nw = clean_first(nw)
	if s_nw and s_nw ~= "" then
		if last_char ~= "" and not last_char:match("%s") and not s_nw:match("^%s") then
			s_nw = " " .. s_nw
		end
		local color = is_sel and C_NW_SEL or C_UNSELECTED_GRAY
		local is_bold = (not is_sel) and apply_bold
		result = append_seg(result, s_nw, color, is_bold)
	end

	return result
end





-- ==============================
-- ==============================
-- ======= 6/ UI Assembly =======
-- ==============================
-- ==============================

--- Assembles all lines and bottom hints into styled blocks ready for rendering.
--- If reserved_count > n, adds empty placeholder lines to pre-size the canvas.
local function assemble_blocks(raw_preds, current_index, info_bar, shortcut_mod, indent, nav_mod_str, loading_text, reserved_count)
	local n = type(raw_preds) == "table" and #raw_preds or 0
	local display_count = math.max(n, tonumber(reserved_count) or n)
	
	if n == 0 and (not reserved_count or tonumber(reserved_count) == 0) then return { preds = hs.styledtext.new("") } end

	local PREFIX_SEL = ""
	local PREFIX_OTHER_TEXT = ""
	local PREFIX_OTHER_DEBUG_TEXT = ""
	local PREFIX_VISUAL_COMP_TEXT = " "

	-- Use display_count (not n) so placeholders align with real predictions from the start
	if display_count == 1 then
		PREFIX_SEL = "✨ "
	elseif display_count >= 2 and indent > 0 then
		PREFIX_SEL = string.rep(" ", indent) .. "✨ "
	else
		-- Case of negative indent values
		PREFIX_SEL = "✨ "
	end

	-- Indent rules for non-selected predictions
	-- indent = 0  -> no left margin
	-- indent = -3 -> exact PREFIX_SEL width
	-- indent = -4 -> PREFIX_SEL width + 1 space
	local indent_n = math.floor(tonumber(indent) or 0)
	if indent_n < 0 and indent_n > -3 then
		PREFIX_OTHER_TEXT = string.rep(" ", -indent_n)
	elseif indent_n <= -3 then
		PREFIX_OTHER_TEXT = PREFIX_SEL .. string.rep(" ", math.max(0, (-indent_n) - 3))
	end

	-- Global visual compensation for emoji side bearing on non-selected lines
	if indent_n > -3 then
		PREFIX_OTHER_TEXT = PREFIX_OTHER_TEXT .. PREFIX_VISUAL_COMP_TEXT
	end

	local PREFIX_OTHER_INVIS = hs.styledtext.new(PREFIX_OTHER_TEXT, { font = { name = FONT, size = SIZE_MAIN }, color = C_INVIS })
	local PREFIX_OTHER_DEBUG = hs.styledtext.new(PREFIX_OTHER_DEBUG_TEXT, { font = { name = FONT, size = SIZE_MAIN }, color = C_UNSELECTED_GRAY })
	local PREFIX_EMPTY = hs.styledtext.new("", { font = { name = FONT, size = SIZE_MAIN }, color = C_INVIS })

	local result = nil
	local gap    = hs.styledtext.new("\n", { font = { name = FONT, size = 3 }, color = C_INVIS })

	for i = 1, display_count do
		local pred = raw_preds[i]
		local is_sel = (i == current_index and pred ~= nil)
		local prefix_other = (PREFIX_OTHER_DEBUG_TEXT ~= "") and PREFIX_OTHER_DEBUG or PREFIX_OTHER_INVIS
		local prefix = is_sel
			and hs.styledtext.new(PREFIX_SEL, { font = { name = FONT, size = SIZE_MAIN }, color = C_CURSOR })
			or (PREFIX_OTHER_TEXT ~= "" and prefix_other or PREFIX_EMPTY)

		-- For reserved empty slots, show empty stub; otherwise show actual prediction
		local body
		if pred ~= nil then
			body = build_line(pred, is_sel, n)
			if not body then
				body = hs.styledtext.new("…", { font = { name = FONT, size = SIZE_MAIN, traits = { italic = true } }, color = C_UNSELECTED_GRAY })
			end
		else
			-- Reserved slot: keep the same left margin as real predictions
			local placeholder_prefix = PREFIX_OTHER_TEXT ~= "" and prefix_other or PREFIX_EMPTY
			body = hs.styledtext.new("...", { font = { name = FONT, size = SIZE_MAIN, traits = { italic = true } }, color = C_LOADING })
			result = result and (result .. gap .. (placeholder_prefix .. body)) or (placeholder_prefix .. body)
			goto continue
		end

		local cmd_str = ""
		if display_count > 1 and shortcut_mod ~= "none" then
			-- Format dynamically the modifier string to its Mac symbols
			local mod_sym = tostring(shortcut_mod):gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
			if mod_sym == "" or mod_sym == "nil" then mod_sym = "⌥" end
			
			if i <= 9 then cmd_str = "   " .. mod_sym .. i
			elseif i == 10 then cmd_str = "   " .. mod_sym .. "0"
			end
		end

		local line
		if cmd_str ~= "" then
			local cmd_seg = hs.styledtext.new(cmd_str, { font = { name = FONT, size = SIZE_HINT }, color = is_sel and C_CMD_SEL or C_CMD_DIM })
			line = prefix .. body .. cmd_seg
		else
			line = prefix .. body
		end

		result = result and (result .. gap .. line) or line
		::continue::
	end

	local SP = string.rep(" ", 6)
	local loading_st = nil

	local hint_st
	
	if display_count > 1 then
		local left_hint  = "⇧G + Tab"
		local right_hint = "⇧D + Tab"
		if nav_mod_str ~= "none" then
			left_hint  = left_hint  .. " ou " .. ((nav_mod_str ~= "" and nav_mod_str ~= "none") and (nav_mod_str .. " + ") or "") .. "↑/←"
			right_hint = right_hint .. " ou " .. ((nav_mod_str ~= "" and nav_mod_str ~= "none") and (nav_mod_str .. " + ") or "") .. "↓/→"
		end
		hint_st = hs.styledtext.new(
			left_hint .. SP .. " ◀" .. SP .. "Tab = accepter" .. SP .. "▶ " .. SP .. right_hint,
			{ font = { name = FONT, size = SIZE_HINT }, color = C_HINT, paragraphStyle = { alignment = "center" } }
		)
	else
		hint_st = hs.styledtext.new("Tab pour accepter", { font = { name = FONT, size = SIZE_HINT }, color = C_HINT, paragraphStyle = { alignment = "center" } })
	end

	local info_st = nil
	if info_bar and tostring(info_bar) ~= "" then
		local safe_info = tostring(info_bar)
		info_st = hs.styledtext.new(safe_info, { font = { name = FONT, size = SIZE_INFO }, color = C_INFO_BAR, paragraphStyle = { alignment = "center" } })
	end

	return { preds = result, loading_st = loading_st, hint_st = hint_st, info_st = info_st, SP = SP }
end





-- ====================================
-- ====================================
-- ======= 7/ Dynamic Rendering =======
-- ====================================
-- ====================================

--- Calculates element sizes, updates the canvas payload, and displays it.
local function render(blocks)
	if not canvas or (type(blocks) ~= "table" and type(blocks) ~= "userdata") then return end

	local PAD_X = 14
	local PAD_Y =  7
	
	local sz_preds = {w=0, h=0}
	if type(blocks) == "userdata" then
		sz_preds = canvas:minimumTextSize(3, blocks)
		blocks = { preds = blocks }
	else
		sz_preds = canvas:minimumTextSize(3, blocks.preds)
	end

	local hint_st = blocks.hint_st
	local info_st = blocks.info_st
	local SP = blocks.SP or "      "

	local sz_hint = hint_st and canvas:minimumTextSize(3, hint_st) or {w=0, h=0}
	local sz_info = info_st and canvas:minimumTextSize(3, info_st) or {w=0, h=0}

	local max_w = _state.fixed_width or sz_preds.w
	local is_combined = false
	local combined_st = nil

	-- Attempt to visually merge Hint and Info texts if horizontal space allows it
	if info_st and hint_st then
		local sep_st = hs.styledtext.new(SP .. "|" .. SP, { font = { name = FONT, size = SIZE_HINT }, color = C_SEP })
		combined_st = hs.styledtext.new("") .. hint_st .. sep_st .. info_st
		combined_st = combined_st:setStyle({ paragraphStyle = { alignment = "center" } }, 1, #combined_st)
		
		local sz_comb = canvas:minimumTextSize(3, combined_st)
		if sz_comb.w <= max_w then
			is_combined = true
		end
	end

	-- [1] Apply tinted dark background according to the active tooltip type
	canvas[1].fillColor = apply_tint(_state.bg_color)

	-- [2] Border: always covers the full canvas size (updated after size is known)

	local w = max_w + PAD_X * 2
	local cur_y = PAD_Y

	-- [3] Main text block rendering
	canvas[3].text  = blocks.preds
	canvas[3].frame = { x = PAD_X, y = cur_y, w = max_w, h = sz_preds.h }
	cur_y = cur_y + sz_preds.h + 8

	-- [4] Full-width separator line rendering
	if hint_st or info_st then
		canvas[4].action    = "fill"
		canvas[4].fillColor = C_SEP
		canvas[4].frame     = { x = 0, y = cur_y, w = w, h = 1 }
		cur_y = cur_y + 8
	else
		canvas[4].action = "skip"
	end

	-- [5] and [6] Hint / Info text blocks rendering
	if is_combined then
		local sz_comb = canvas:minimumTextSize(3, combined_st)
		canvas[5].action = "fill"
		canvas[5].text   = combined_st
		canvas[5].frame  = { x = 0, y = cur_y, w = w, h = sz_comb.h }
		cur_y = cur_y + sz_comb.h + 8
		canvas[6].action = "skip"
	else
		if hint_st then
			canvas[5].action = "fill"
			canvas[5].text   = hint_st
			canvas[5].frame  = { x = 0, y = cur_y, w = w, h = sz_hint.h }
			cur_y = cur_y + sz_hint.h + (info_st and 4 or 8)
		else
			canvas[5].action = "skip"
		end

		if info_st then
			canvas[6].action = "fill"
			canvas[6].text   = info_st
			canvas[6].frame  = { x = 0, y = cur_y, w = w, h = sz_info.h }
			cur_y = cur_y + sz_info.h + 8
		else
			canvas[6].action = "skip"
		end
	end

	local h = cur_y - 8 + PAD_Y

	-- Dynamic absolute positioning
	local anchor = resolve_anchor()
	local fw     = hs.window.focusedWindow()
	local scr    = nil
	if fw and type(fw.screen) == "function" then pcall(function() scr = fw:screen() end) end
	local screen = (scr or hs.screen.mainScreen()):frame()

	local px, py
	if anchor then
		if anchor.type == "caret" then
			px = anchor.x + 15
			py = anchor.y + anchor.h + 18
		else
			px = anchor.x - w / 2
			py = anchor.y + 5
			if py + h > screen.y + screen.h then py = anchor.y - h - 5 end
		end
	else
		-- Absolute center-bottom fallback if no context is found
		px = screen.x + (screen.w - w) / 2
		py = screen.y + screen.h - h - 5
	end

	-- Keep coordinates strictly within screen bounds
	local margin = 5
	px = math.max(screen.x + margin, math.min(px, screen.x + screen.w - w  - margin))
	py = math.max(screen.y + margin, math.min(py, screen.y + screen.h - h  - margin))

	-- Final render execution
	local ok, err = pcall(function()
		canvas:frame({ x = px, y = py, w = w, h = h })
		-- [2] Border frame is set after w/h are computed
		canvas[2].frame = { x = 0, y = 0, w = w, h = h }
		canvas:show()
		start_watchers()
	end)
	if not ok then Logger.error(LOG, string.format("Render error: %s.", tostring(err))) end
end





-- =============================
-- =============================
-- ======= 8/ Public API =======
-- =============================
-- =============================

--- Hides the tooltip and resets all local UI states.
function M.hide()
	if canvas and type(canvas.hide) == "function" then canvas:hide() end
	stop_watchers()
	_state.raw_predictions = {}
	_state.current_index   = 1
	_state.info_bar        = nil
	_state.fixed_width     = nil
	_state.bg_color        = nil
	_state.loading_text    = nil
	_state.enter_validates = false
end

--- Sets the auto-hide timeout duration for normal hotstrings.
--- @param sec number The duration in seconds.
function M.set_timeout(sec)
	local base_timeout = tonumber(sec) or M.TIMEOUT_SEC_DEFAULT
	_state.timeout_sec = math.max(0.05, base_timeout - M.HOTSTRING_TIMEOUT_MARGIN_SEC)
end

--- Assigns a callback executed when the user navigates through predictions.
--- @param fn function The callback function.
function M.set_navigate_callback(fn) _state.on_navigate = fn end

--- Assigns a callback executed when the user explicitly accepts a prediction.
--- @param fn function The callback function.
function M.set_accept_callback(fn) _state.on_accept = fn end

--- Assigns a callback executed when the user presses any key that interrupts predictions (shortcuts, modifiers, etc.).
--- @param fn function The callback function.
function M.set_cancel_callback(fn) _state.on_cancel = fn end

--- Sets whether Enter should validate the current prediction (true only after arrow navigation).
--- @param v boolean True to enable enter validation.
function M.set_enter_validates(v) _state.enter_validates = (v == true) end

--- Retrieves the currently highlighted prediction index.
--- @return number The current index.
function M.get_current_index()       return _state.current_index end

--- Navigates through the predictions list safely.
--- @param delta number Direction modifier (+1 or -1).
function M.navigate(delta)
	local n = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
	if n < 2 then return end
	
	_state.current_index = ((_state.current_index - 1 + delta) % n) + 1
	render(assemble_blocks(_state.raw_predictions, _state.current_index, _state.info_bar, _state.shortcut_mod, _state.indent, _state.nav_mod_str, _state.loading_text, _state.reserved_count))
	
	if type(_state.on_navigate) == "function" then 
		pcall(_state.on_navigate, _state.current_index) 
	end
	reset_idle_timer() -- Restart the inactivity timer on navigation
end

--- Displays multiple LLM predictions with full UI capabilities.
--- @param predictions table The list of predictions.
--- @param current_index number The currently selected index.
--- @param enabled boolean True to display.
--- @param info_bar string The info bar text.
--- @param shortcut_mod string The modifier string.
--- @param indent number The indentation level.
--- @param nav_mods table The navigation modifiers.
--- @param bg_color table Optional background tint.
--- @param loading_text string The loading text.
--- @param max_predictions_count number Optional: reserve space for N predictions (default: actual count).
function M.show_predictions(predictions, current_index, enabled, info_bar, shortcut_mod, indent, nav_mods, bg_color, loading_text, max_predictions_count)
	if not enabled then return end
	if type(predictions) ~= "table" or #predictions == 0 then M.hide(); return end
	
	_state.raw_predictions = predictions
	_state.current_index   = current_index or 1
	_state.info_bar        = info_bar
	_state.shortcut_mod    = shortcut_mod or "alt"
	_state.nav_mods        = type(nav_mods) == "table" and nav_mods or {}
	_state.indent          = indent or 0
	_state.current_is_llm  = true -- Ensure extended timeout is used
	_state.bg_color        = type(bg_color) == "table" and bg_color or nil
	_state.loading_text    = loading_text
	
	local nav_mod_str = "none"
	if #_state.nav_mods > 0 and not (#_state.nav_mods == 1 and _state.nav_mods[1] == "none") then
		nav_mod_str = table.concat(_state.nav_mods, "+")
		nav_mod_str = nav_mod_str:gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
	elseif #_state.nav_mods == 0 then
		nav_mod_str = ""
	end
	_state.nav_mod_str = nav_mod_str

	local reserved_count = math.max(1, math.floor(tonumber(max_predictions_count) or #predictions))
	local max_width = 0
	for i = 1, reserved_count do
		local b = assemble_blocks(predictions, i, _state.info_bar, _state.shortcut_mod, _state.indent, _state.nav_mod_str, _state.loading_text, reserved_count)
		local w_preds = canvas:minimumTextSize(3, b.preds).w
		
		local sz_hint = b.hint_st and canvas:minimumTextSize(3, b.hint_st) or {w=0}
		local sz_info = b.info_st and canvas:minimumTextSize(3, b.info_st) or {w=0}
		
		local w_final = w_preds
		if b.info_st and b.hint_st then
			local SP = b.SP or "      "
			local sep_st = hs.styledtext.new(SP .. "|" .. SP, { font = { name = FONT, size = SIZE_HINT } })
			local combined_st = hs.styledtext.new("") .. b.hint_st .. sep_st .. b.info_st
			local sz_comb = canvas:minimumTextSize(3, combined_st)
			
			if sz_comb.w > w_preds then
				w_final = math.max(w_preds, sz_hint.w, sz_info.w)
			end
		else
			w_final = math.max(w_preds, sz_hint.w, sz_info.w)
		end
		
		if w_final > max_width then max_width = w_final end
	end
	_state.fixed_width = max_width
	_state.reserved_count = reserved_count
	_state.enter_validates = false  -- Reset: Enter must not validate until user navigates

	render(assemble_blocks(predictions, _state.current_index, _state.info_bar, _state.shortcut_mod, _state.indent, _state.nav_mod_str, _state.loading_text, reserved_count))
end

--- Displays simple tooltip content.
--- @param content string|userdata The text to display.
--- @param is_llm boolean True if triggered by LLM.
--- @param enabled boolean True to display.
--- @param bg_color table Optional background tint.
function M.show(content, is_llm, enabled, bg_color)
	if not enabled then return end
	if content == nil or tostring(content) == "" then M.hide(); return end
	
	_state.raw_predictions = {}
	_state.current_index   = 1
	_state.info_bar        = nil
	_state.fixed_width     = nil
	_state.current_is_llm  = (is_llm == true)
	_state.bg_color        = type(bg_color) == "table" and bg_color or nil
	_state.loading_text    = nil
	
	local styled
	if type(content) == "userdata" then
		styled = content
	else
		styled = hs.styledtext.new(tostring(content), {
			font  = { name = FONT, size = SIZE_MAIN, traits = is_llm and { italic = true } or {} },
			color = is_llm and { white = 0.80, alpha = 1.0 } or { white = 1.00, alpha = 1.0 },
		})
	end
	render(styled)
end

--- Fallback mock interface used for diff styling extraction outside the module.
--- @param chunks table The diff chunks.
--- @param nw string Next words.
--- @param tc_fallback string Text fallback.
--- @return userdata The styled text object.
function M.make_diff_styled(chunks, nw, tc_fallback)
	local fake = { chunks = type(chunks) == "table" and chunks or {}, nw = tostring(nw or ""), has_corrections = true }
	return build_line(fake, true, 1)
end

--- Checks if the tooltip is currently displaying active predictions.
--- @return boolean True if active predictions are shown.
function M.is_visible()
	return type(_state.raw_predictions) == "table" and #_state.raw_predictions > 0
end

return M
