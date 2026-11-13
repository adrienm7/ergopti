--- ui/tooltip/llm.lua

--- ==============================================================================
--- MODULE: LLM Suggestion Overlay (Linux)
--- DESCRIPTION:
--- Presents one or more parsed LLM predictions in the existing focus-free GTK
--- tooltip surface. This module owns presentation state only; prediction parsing,
--- acceptance, persistence, and keyboard interception remain with their owners.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Config = require("ui.tooltip.config")
local DisplaySettings = require("modules.llm.display_settings")
local LlmLine = require("core.ui.engine.tooltip.llm_line")
local ConfigKeys = require("settings.engine.keys")
local InfoBar = require("ai.engine.request_plan.info_bar")

local LOG = "ui.tooltip.llm"

local _renderer = nil
local _style = nil
local _anchor_provider = nil
local _screen_provider = nil
local _candidates = {}
local _active_index = 1
local _meta = {}
local _cleanup_pending = nil
local _cleanup_busy = false
local _generation = 0
local _presenting = nil
local _retiring = false
local settle_cleanup
-- The hotstring preview sharing the window: { rows = fn, showing = fn,
-- covered = fn }. rows() answers the preview rows to draw above the
-- suggestions (llm.trigger.while_hotstring_tooltip = "both"), nil otherwise.
local _companion = nil

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
--- and the continuation orange on it, every other line grey, and the chord
--- that inserts each line right-aligned in a muted column
--- (_shared/core/ui/data/tooltip/constants.toml [llm_ui]).
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
			DisplaySettings.get(ConfigKeys.LEAF.PRED_INDENT) or 0, #shown, chrome.mark, chrome.align)
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
			selected = active,
			label = LlmLine.shortcut_label(entry.index, meta.validation_modifiers, chrome.shortcut_spec),
			label_color = chrome.colors.label,
		}
	end
	if meta.loading == true and #rows == 0 then
		rows[1] = { text = "…", label = "", dimmed = true }
	end
	if DisplaySettings.get(ConfigKeys.LEAF.SHOW_INFO_BAR) and #rows > 0 then
		-- The pieces and the short prompt name are the shared plan's; the separator and
		-- the i/n position (candidates are cycled here, listed on macOS) are Linux's.
		local info = InfoBar.parts({
			model = meta.model, profile_label = meta.profile,
			position = { index = active_index, count = #candidates },
		})
		if info then rows[#rows + 1] = { text = table.concat(info, " · "), dimmed = true } end
	end
	return rows
end

--- Initialises the presentation adapter.
--- @param opts table { style, renderer?, anchor_provider?, screen_provider? }
--- @return boolean
function M.init(opts)
	if _retiring or _presenting ~= nil or (_cleanup_pending and not settle_cleanup()) then return false end
	opts = type(opts) == "table" and opts or {}
	_style = opts.style
	_renderer = opts.renderer
	if not _renderer then
		local ok, renderer = pcall(require, "adapters.graphics_renderer")
		if ok then _renderer = renderer end
	end
	_anchor_provider = opts.anchor_provider
	_screen_provider = opts.screen_provider
	_companion = type(opts.companion) == "table" and opts.companion or nil
	if type(_style) ~= "table" or type(_renderer) ~= "table" then
		Logger.error(LOG, "Suggestion overlay initialisation failed: style or renderer unavailable.")
		return false
	end
	return true
end

--- The preview rows drawn above the suggestions, nil when they are drawn alone.
--- @return table|nil
local function companion_rows()
	if not _companion or type(_companion.rows) ~= "function" then return nil end
	local ok, rows = pcall(_companion.rows)
	if not ok then
		Logger.warn(LOG, "Hotstring rows unavailable: %s", tostring(rows))
		return nil
	end
	return type(rows) == "table" and #rows > 0 and rows or nil
end

--- Whether the hotstring preview holds the window now.
--- @return boolean
local function companion_showing()
	if not _companion or type(_companion.showing) ~= "function" then return false end
	local ok, showing = pcall(_companion.showing)
	return ok and showing == true
end

--- The companion's partial draw must be settled before this owner touches the surface.
local function prepare_companion(companion)
	if not companion or type(companion.prepare) ~= "function" then return true end
	if type(companion.ready) == "function" then
		local ok, ready = pcall(companion.ready)
		if (not ok or ready ~= true) and #_candidates > 0 then
			_generation = _generation + 1
			_candidates, _active_index, _meta = {}, 1, {}
		end
	end
	local ok, ready = pcall(function()
		local revision = type(companion.revision) == "function" and companion.revision() or nil
		if companion.prepare() ~= true then return false end
		return revision == nil or (type(companion.revision) == "function" and companion.revision() == revision)
	end)
	return ok and ready == true
end

--- Reads a stable companion ownership decision, or refuses it on reentry.
local function companion_owner_status()
	local companion, generation = _companion, _generation
	if companion == nil then return false end
	if type(companion.showing) ~= "function" then return nil end
	local ok, result = pcall(function()
		local revision = type(companion.revision) == "function" and companion.revision() or nil
		local showing = companion.showing()
		if type(showing) ~= "boolean" then return nil end
		if revision ~= nil and (type(companion.revision) ~= "function" or companion.revision() ~= revision) then return nil end
		return showing
	end)
	if not ok or companion ~= _companion or generation ~= _generation then return nil end
	return result
end

--- Settles a possibly partial draw through the surface owner captured with it.
--- A visible companion must redraw itself; it must never be hidden for us.
settle_cleanup = function()
	local pending = _cleanup_pending
	if not pending then return true end
	if _cleanup_busy then return false end
	_cleanup_busy = true
	if not prepare_companion(pending.companion) or _cleanup_pending ~= pending then
		_cleanup_busy = false
		return false
	end
	local called, settled = pcall(function()
		local companion, renderer = pending.companion, pending.renderer
		local showing = false
		if companion and type(companion.showing) == "function" then
			showing = companion.showing() == true
		end
		local callback = showing and companion.redraw or renderer and renderer.hide
		return type(callback) == "function" and callback() == true
	end)
	_cleanup_busy = false
	if not called or settled ~= true or _cleanup_pending ~= pending then return false end
	_cleanup_pending = nil
	return true
end

local function draw(generation)
	_presenting = generation
	if type(_renderer) ~= "table" or type(_renderer.show) ~= "function" then error("suggestion renderer unavailable") end
	local renderer, companion = _renderer, _companion
	local companion_revision
	if companion and type(companion.revision) == "function" then
		local ok, value = pcall(companion.revision)
		if not ok then _candidates, _active_index, _meta, _presenting = {}, 1, {}, nil; return false end
		companion_revision = value
	end
	local rows = M.build_rows(_candidates, _active_index, _meta)
	if #rows == 0 then
		if _presenting == generation then _presenting = nil end
		M.hide(); return false
	end
	local preview_rows = companion_rows()
	local cover = not preview_rows and companion_showing()
	if preview_rows then
		for index = #preview_rows, 1, -1 do table.insert(rows, 1, preview_rows[index]) end
	end
	local anchor = type(_anchor_provider) == "function" and _anchor_provider() or nil
	local screen = type(_screen_provider) == "function" and _screen_provider()
		or { x = 0, y = 0, w = 1920, h = 1080 }
	if generation ~= _generation then
		if _presenting == generation then _presenting = nil end
		return false
	end
	if companion_revision ~= nil then
		local ok, current = pcall(companion.revision)
		if not ok or current ~= companion_revision then
			_candidates, _active_index, _meta, _presenting = {}, 1, {}, nil
			return false
		end
	end
	local called, drawn = pcall(renderer.show, rows, { style = _style, accent = nil, anchor = anchor, screen = screen })
	if _presenting == generation then _presenting = nil end
	if not rawequal(package.loaded["ui.tooltip.llm"], M) then return false end
	if generation ~= _generation then
		-- An older native call can finish after a reentrant replacement. Repair
		-- the current owner rather than allowing that stale call to cover it.
		if _cleanup_pending then settle_cleanup()
		elseif #_candidates > 0 and _presenting == nil then M.redraw()
		elseif #_candidates == 0 then
			_cleanup_pending = { renderer = renderer, companion = companion }
			settle_cleanup()
		end
		return false
	end
	if companion_revision ~= nil and companion and type(companion.revision) == "function" then
		local ok, current = pcall(companion.revision)
		if not ok or current ~= companion_revision then
			_candidates, _active_index, _meta = {}, 1, {}
			_cleanup_pending = { renderer = renderer, companion = companion }
			settle_cleanup()
			return false
		end
	end
	if not called or drawn ~= true then
		_candidates, _active_index, _meta = {}, 1, {}
		_cleanup_pending = { renderer = renderer, companion = companion }
		settle_cleanup()
		return false
	end
	if cover and companion and type(companion.covered) == "function" then pcall(companion.covered) end
	return generation == _generation
end

local function attempt_draw(generation)
	local called, result = pcall(draw, generation)
	if not called and generation == _generation then
		_candidates, _active_index, _meta = {}, 1, {}
		if _presenting == generation then _presenting = nil end
		if _renderer ~= nil then
			_cleanup_pending = { renderer = _renderer, companion = _companion }
			settle_cleanup()
		end
	end
	return called and result == true
end

--- Replaces the displayed candidates atomically.
--- @param candidates table
--- @param meta table|nil
--- @return boolean
function M.show(candidates, meta)
	if _retiring then return false end
	local before = _generation
	if type(candidates) ~= "table" or not prepare_companion(_companion) or not settle_cleanup()
		or before ~= _generation then return false end
	-- A fresh owner without a draw method has touched no surface to clean up.
	-- An existing offer still needs the usual cleanup if its renderer changed.
	if #_candidates == 0 and (type(_renderer) ~= "table" or type(_renderer.show) ~= "function") then return false end
	_generation = _generation + 1
	_candidates = candidates
	_meta = type(meta) == "table" and meta or {}
	_active_index = math.min(math.max(1, tonumber(_meta.active_index) or 1), math.max(1, #candidates))
	return attempt_draw(_generation)
end

--- Selects one displayed candidate and redraws.
--- @param index integer
--- @return boolean
function M.select(index)
	if _retiring then return false end
	local before = _generation
	if not prepare_companion(_companion) or before ~= _generation then return false end
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #_candidates then return false end
	_generation = _generation + 1
	_active_index = index
	return attempt_draw(_generation)
end

--- Moves the active selection by one, wrapping around.
--- @param delta integer
--- @return boolean
function M.move(delta)
	if _retiring then return false end
	local before = _generation
	if not prepare_companion(_companion) or before ~= _generation then return false end
	if #_candidates < 2 or type(delta) ~= "number" then return false end
	_generation = _generation + 1
	_active_index = ((_active_index - 1 + delta) % #_candidates) + 1
	return attempt_draw(_generation)
end

--- Returns the active candidate index.
--- @return integer
function M.active_index()
	return _active_index
end

--- Draws the shown candidates again, with or without the hotstring rows as
--- they stand now. Does nothing while no candidate is shown.
--- @return boolean drawn
function M.redraw()
	if _retiring then return false end
	local before = _generation
	if #_candidates == 0 or not prepare_companion(_companion) or not settle_cleanup()
		or before ~= _generation then return false end
	_generation = _generation + 1
	return attempt_draw(_generation)
end

--- Redraws a deferred suggestion only while the preview is still absent.
--- A newer preview or a replacement module owns the surface instead.
--- @return boolean drawn
function M.redraw_if_preview_hidden()
	if not rawequal(package.loaded["ui.tooltip.llm"], M)
		or type(_companion) ~= "table" or type(_companion.showing) ~= "function" then return false end
	local ok, showing = pcall(_companion.showing)
	if not ok or showing ~= false or not rawequal(package.loaded["ui.tooltip.llm"], M) then return false end
	return M.redraw()
end

--- Revokes an offer covered by a failed companion draw, without touching its surface.
function M.revoke_presentation()
	_generation = _generation + 1
	_candidates, _active_index, _meta = {}, 1, {}
end

--- Hides and forgets every candidate.
function M.hide()
	if _retiring then return false end
	local before = _generation
	if not prepare_companion(_companion) or not settle_cleanup() or before ~= _generation then return false end
	_generation = _generation + 1
	-- The preview drawn over the suggestions keeps the window; it hides itself.
	local showing = companion_owner_status()
	if showing == nil then return false end
	if not showing and _renderer and type(_renderer.hide) == "function" then
		_retiring = true
		local called, hidden = pcall(_renderer.hide)
		_retiring = false
		if not called or hidden ~= true then return false end
	end
	local shared = #_candidates > 0 and companion_rows() ~= nil
	_candidates = {}
	_active_index = 1
	_meta = {}
	-- Shown together, the preview stays on screen alone.
	if shared then
		if not _companion or type(_companion.redraw) ~= "function" then return false end
		local called, redrawn = pcall(_companion.redraw)
		if not called or redrawn ~= true then return false end
	end
	return true
end

local function companion_ready()
	if not _companion or type(_companion.ready) ~= "function" then return true end
	local ok, ready = pcall(_companion.ready)
	return ok and ready == true
end

--- Whether candidates are presented: set by show(), cleared by hide().
---
--- The logical state, not the window's. The GTK surface maps asynchronously
--- (and a session without a compositor may never report it mapped), so a key
--- answered by "is the window up" would type the digit meant to accept.
--- @return boolean
function M.is_showing()
	return _presenting == nil and companion_ready() and #_candidates > 0
end

--- @return boolean
function M.is_visible()
	return _presenting == nil and companion_ready() and #_candidates > 0
		and _renderer ~= nil and type(_renderer.is_visible) == "function"
		and _renderer.is_visible() == true
end

--- Destroys the shared renderer surface.
function M.destroy()
	if _retiring or _presenting ~= nil or M.hide() ~= true then return false end
	local generation = _generation
	if not prepare_companion(_companion) or generation ~= _generation then return false end
	local showing = companion_owner_status()
	if showing == nil then return false end
	if showing then _renderer, _style = nil, nil; return true end
	if _renderer and type(_renderer.destroy) == "function" then
		_retiring = true
		local called, destroyed = pcall(_renderer.destroy)
		_retiring = false
		if not called or destroyed ~= true then return false end
	end
	_renderer = nil
	_style = nil
	return true
end

return M
