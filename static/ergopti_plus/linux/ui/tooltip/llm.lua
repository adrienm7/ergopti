--- ui/tooltip/llm.lua

--- ==============================================================================
--- MODULE: LLM Suggestion Overlay (Linux)
--- DESCRIPTION:
--- Presents one or more parsed LLM predictions in the existing focus-free GTK
--- tooltip surface. This module owns presentation state only; prediction parsing,
--- acceptance, persistence, and keyboard interception remain with their owners.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Config = require("ui.tooltip.config")
local DisplaySettings = require("modules.llm.display_settings")
local LlmLine = require("tooltip.llm_line")

local LOG = "ui.tooltip.llm"

local _renderer = nil
local _style = nil
local _anchor_provider = nil
local _screen_provider = nil
local _candidates = {}
local _active_index = 1
local _meta = {}

local function modifier_label(modifiers)
	local labels = { alt = "Alt", ctrl = "Ctrl", shift = "Shift", cmd = "Super", super = "Super" }
	local parts = {}
	for _, name in ipairs(modifiers or {}) do
		parts[#parts + 1] = labels[name] or tostring(name)
	end
	return table.concat(parts, "+")
end

local function validation_label(index, modifiers)
	local prefix = modifier_label(modifiers)
	local digit = index == 10 and "0" or tostring(index)
	return prefix ~= "" and (prefix .. "+" .. digit) or digit
end

--- The pieces a candidate's line reads, each with its role.
---
--- A parsed prediction carries its own (the typed tail, the corrections, the
--- next words). A candidate that is only text to type — a screen answer, a
--- translation — is one piece: a correction when it replaces the selection,
--- a continuation otherwise.
--- @param candidate table
--- @param active boolean
--- @return table Array of { text, role, bold }.
local function line_segments(candidate, active)
	local segments = LlmLine.segments(candidate, active)
	if #segments > 0 then return segments end
	local text = candidate.to_type:gsub("^%s+", "")
	if text == "" then return segments end
	return { {
		text = text,
		role = candidate.replaces_selection == true and "corrected" or "next",
		bold = false,
	} }
end

--- Builds renderer rows without touching GTK.
---
--- A prediction row is a prefix and coloured segments, as on macOS: the mark
--- in front of the selected line, the typed text grey, the corrections green
--- and the continuation orange on it, every other line grey, and the
--- validation chord in a separate right-aligned column.
--- @param candidates table Array of { to_type, chunks?, nw?, has_corrections? }.
--- @param active_index integer
--- @param meta table { model?, profile?, validation_modifiers?, loading? }
--- @return table
function M.build_rows(candidates, active_index, meta)
	meta = type(meta) == "table" and meta or {}
	local rows = {}
	local shown = {}
	for index, candidate in ipairs(candidates or {}) do
		local text = type(candidate) == "table" and candidate.to_type or nil
		if type(text) == "string" and text ~= "" then
			shown[#shown + 1] = { index = index, candidate = candidate }
		end
	end

	local chrome = #shown > 0 and Config.llm_line() or nil
	local selected_prefix, unselected_prefix
	if chrome then
		selected_prefix, unselected_prefix = LlmLine.prefixes(
			DisplaySettings.get("pred_indent") or 0, #shown, chrome.mark, chrome.align)
	end
	for _, entry in ipairs(shown) do
		local active = entry.index == active_index
		local segments = {}
		for _, segment in ipairs(line_segments(entry.candidate, active)) do
			segments[#segments + 1] = {
				text = segment.text,
				role = segment.role,
				bold = segment.bold,
				color = active and chrome.colors[segment.role] or chrome.colors.typed,
			}
		end
		rows[#rows + 1] = {
			-- The mark is drawn on the selected line only; elsewhere the prefix
			-- is spacing, of the width its characters would take.
			prefix = active and selected_prefix or unselected_prefix,
			prefix_color = active and chrome.colors.cursor or nil,
			segments = segments,
			label = validation_label(entry.index, meta.validation_modifiers),
			label_color = chrome.colors.label_unselected,
			label_gap = chrome.column_gap,
			selected = active,
		}
	end
	if meta.loading == true and #rows == 0 then
		rows[1] = { text = "…", label = "", dimmed = true }
	end
	if DisplaySettings.get("show_info_bar") and #rows > 0 then
		local info = {}
		if type(meta.model) == "string" and meta.model ~= "" then info[#info + 1] = meta.model end
		if type(meta.profile) == "string" and meta.profile ~= "" then info[#info + 1] = meta.profile end
		if #candidates > 1 then info[#info + 1] = string.format("%d/%d", active_index, #candidates) end
		if #info > 0 then rows[#rows + 1] = { text = table.concat(info, " · "), dimmed = true } end
	end
	return rows
end

--- Initialises the presentation adapter.
--- @param opts table { style, renderer?, anchor_provider?, screen_provider? }
--- @return boolean
function M.init(opts)
	opts = type(opts) == "table" and opts or {}
	_style = opts.style
	_renderer = opts.renderer
	if not _renderer then
		local ok, renderer = pcall(require, "adapters.graphics_renderer")
		if ok then _renderer = renderer end
	end
	_anchor_provider = opts.anchor_provider
	_screen_provider = opts.screen_provider
	if type(_style) ~= "table" or type(_renderer) ~= "table" then
		Logger.error(LOG, "Suggestion overlay initialisation failed: style or renderer unavailable.")
		return false
	end
	return true
end

local function draw()
	if type(_renderer) ~= "table" or type(_renderer.show) ~= "function" then return false end
	local rows = M.build_rows(_candidates, _active_index, _meta)
	if #rows == 0 then M.hide(); return false end
	local anchor = type(_anchor_provider) == "function" and _anchor_provider() or nil
	local screen = type(_screen_provider) == "function" and _screen_provider()
		or { x = 0, y = 0, w = 1920, h = 1080 }
	return _renderer.show(rows, {
		style = _style,
		accent = nil,
		anchor = anchor,
		screen = screen,
	}) == true
end

--- Replaces the displayed candidates atomically.
--- @param candidates table
--- @param meta table|nil
--- @return boolean
function M.show(candidates, meta)
	if type(candidates) ~= "table" then return false end
	_candidates = candidates
	_active_index = math.min(math.max(1, tonumber(meta and meta.active_index) or 1), math.max(1, #candidates))
	_meta = type(meta) == "table" and meta or {}
	return draw()
end

--- Selects one displayed candidate and redraws.
--- @param index integer
--- @return boolean
function M.select(index)
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #_candidates then return false end
	_active_index = index
	return draw()
end

--- Moves the active selection by one, wrapping around.
--- @param delta integer
--- @return boolean
function M.move(delta)
	if #_candidates < 2 or type(delta) ~= "number" then return false end
	_active_index = ((_active_index - 1 + delta) % #_candidates) + 1
	return draw()
end

--- Returns the active candidate index.
--- @return integer
function M.active_index()
	return _active_index
end

--- Hides and forgets every candidate.
function M.hide()
	if _renderer and type(_renderer.hide) == "function" and _renderer.hide() ~= true then return false end
	_candidates = {}
	_active_index = 1
	_meta = {}
	return true
end

--- Whether candidates are presented: set by show(), cleared by hide().
---
--- The logical state, not the window's. The GTK surface maps asynchronously
--- (and a session without a compositor may never report it mapped), so a key
--- answered by "is the window up" would type the digit meant to accept.
--- @return boolean
function M.is_showing()
	return #_candidates > 0
end

--- @return boolean
function M.is_visible()
	return #_candidates > 0
		and _renderer ~= nil and type(_renderer.is_visible) == "function"
		and _renderer.is_visible() == true
end

--- Destroys the shared renderer surface.
function M.destroy()
	M.hide()
	if _renderer and type(_renderer.destroy) == "function" then _renderer.destroy() end
	_renderer = nil
	_style = nil
end

return M
