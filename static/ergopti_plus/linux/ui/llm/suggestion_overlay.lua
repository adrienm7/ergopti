--- ui/llm/suggestion_overlay.lua

--- ==============================================================================
--- MODULE: LLM Suggestion Overlay (Linux)
--- DESCRIPTION:
--- Presents one or more parsed LLM predictions in the existing focus-free GTK
--- tooltip surface. This module owns presentation state only; prediction parsing,
--- acceptance, persistence, and keyboard interception remain with their owners.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local DisplaySettings = require("modules.llm.display_settings")

local LOG = "ui.llm.suggestion_overlay"

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

--- Builds renderer rows without touching GTK.
--- @param candidates table Array of { to_type = string }.
--- @param active_index integer
--- @param meta table { model?, profile?, validation_modifiers?, loading? }
--- @return table
function M.build_rows(candidates, active_index, meta)
	meta = type(meta) == "table" and meta or {}
	local rows = {}
	local indent = DisplaySettings.get("pred_indent") or 0
	local active_prefix = indent < 0 and string.rep(" ", -indent) or ""
	local inactive_prefix = indent > 0 and string.rep(" ", indent) or ""
	for index, candidate in ipairs(candidates or {}) do
		local text = type(candidate) == "table" and candidate.to_type or nil
		if type(text) == "string" and text ~= "" then
			local active = index == active_index
			rows[#rows + 1] = {
				text = (active and active_prefix or inactive_prefix) .. text,
				label = validation_label(index, meta.validation_modifiers),
				dimmed = not active,
			}
		end
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
	if _renderer and type(_renderer.hide) == "function" then _renderer.hide() end
	_candidates = {}
	_active_index = 1
	_meta = {}
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
