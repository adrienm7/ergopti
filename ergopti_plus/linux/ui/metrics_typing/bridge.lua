--- ui/metrics_typing/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Typing Metrics Dashboard
--- DESCRIPTION:
--- Supplies the same manifest and n-gram prefetch envelope consumed by the
--- shared typing dashboard on macOS and Windows. Linux previously registered no
--- handler for this UI, so its WebKit page fell through to a missing file fetch
--- and could never receive live keylogger data.
---
--- FEATURES & RATIONALE:
--- 1. Instant first paint. The "ready" payload carries the n-grams of the whole
---    history, read through the sqlite3 CLI on the daemon's only thread: every
---    opening of the window blocked typing and delayed the page's first paint by
---    the length of that read. The last payload is now kept, answered at once,
---    and refreshed on a later loop tick, after the page has drawn.
--- 2. The refresh reaches the page through the same host response hook as the
---    answer, so the page applies it exactly as it applies a reply.
--- 3. The user's reset drops the kept payload with the keylogger's caches, so a
---    reset is a clean rebuild.
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_typing_bridge"

local AppsBridge = require("ui.metrics_apps.bridge")
local Flush = require("ui.metrics_flush_bridge")
local Logger = require("logger.shim")
local LOG = "bridge.metrics_typing"

local APP_NAME = "metrics_typing"

-- How long the refresh waits after a cached answer: long enough for WebKit to
-- run the reply and paint, short enough that the numbers catch up at once.
local REFRESH_DELAY_MS = 250

-- The last complete "ready" payload, and the generation of the latest refresh
-- (a newer request supersedes an older pending one).
local _cached_ready = nil
local _cached_keylogger, _cached_generation = nil, nil
local _refresh_generation = 0

--- Builds the dashboard payload from the daemon state.
--- @param state table
--- @param include_prefetch boolean
--- @return table|nil
local function build_payload(state, include_prefetch)
	if state.keylogger and type(state.keylogger.get_dashboard_payload) == "function" then
		return state.keylogger.get_dashboard_payload({ include_prefetch = include_prefetch })
	end
	return AppsBridge.build_payload(state)
end

--- Default deferral: the daemon's event loop.
--- @param fn function
--- @param delay_ms number
--- @return boolean
local function default_defer(fn, delay_ms)
	local ok_loop, EventLoop = pcall(require, "adapters.event_loop")
	if not ok_loop or type(EventLoop.defer) ~= "function" then
		Logger.error(LOG, "Cannot schedule the dashboard refresh: the event loop has no defer().")
		return false
	end
	return EventLoop.defer(fn, delay_ms)
end

--- Default page channel: the host response hook the page installs.
--- @param payload table
--- @return boolean pushed
local function default_push(payload, state, context)
	return Flush.push(APP_NAME, M.bridge_name, payload, state, context)
end

-- Injectable seams for tests; production uses the event loop and WebKit.
M._defer = default_defer
M._push = default_push
local Requests = Flush.new(APP_NAME, function(...) return M._push(...) end,
	function(reply, cache, keylogger, generation)
		if cache then
			_cached_ready, _cached_keylogger, _cached_generation = reply, keylogger, generation
		end
	end)

--- Schedules a fresh "ready" payload after the cached answer has painted.
--- @param state table
local function schedule_refresh(state, context, request)
	_refresh_generation = _refresh_generation + 1
	local generation = _refresh_generation
	local queued = M._defer(function()
		if generation ~= _refresh_generation or not request.valid() then
			Logger.debug(LOG, "Discarded a superseded dashboard refresh (generation %d).", generation)
			return
		end
		Requests.run(state, context, function()
			return build_payload(state, true), true
		end, false, true)
	end, REFRESH_DELAY_MS)
	if not queued then
		Logger.error(LOG, "The dashboard refresh could not be scheduled — the page shows the cached payload.")
	end
end

--- Handles a ready or refresh request from the shared typing dashboard.
--- @param payload any Request payload from the WebKit bridge.
--- @param state table Daemon state.
--- @return table|nil Shared metrics prefetch payload.
local function handle(payload, state, context, request)
	local action = type(payload) == "table" and payload.action or payload
	if action == "ready" then
		if _cached_ready ~= nil and _cached_keylogger == state.keylogger
			and _cached_generation == request.generation then
			Logger.debug(LOG, "Typing metrics UI ready — answering from the cached payload.")
			schedule_refresh(state, context, request)
			return _cached_ready
		end
		Logger.debug(LOG, "Typing metrics UI ready — first payload of this session.")
		return build_payload(state, true), true
	end
	if action == "refresh" then
		Logger.debug(LOG, "Typing metrics UI requested refresh.")
		return build_payload(state, false)
	end
	-- The dashboard's reset control. It clears the filters in the page and asks
	-- the backend to drop its caches so the next payload is a clean rebuild.
	-- macOS has handled this since the control existed; Linux answered nothing,
	-- so a reset re-rendered the page against the same cached manifest and the
	-- one observable effect was that resetting changed nothing.
	-- The answer is the rebuilt payload itself: the page applies every reply as
	-- dashboard data, and a bare { cleared = true } emptied the dashboard.
	if action == "clear_cache" then
		_refresh_generation = _refresh_generation + 1
		local cleared = false
		if state.keylogger and type(state.keylogger.clear_cache) == "function" then
			local ok, result = pcall(state.keylogger.clear_cache)
			cleared = ok and result == true
			if cleared then Logger.info(LOG, "Dashboard caches cleared by user reset.") end
		else
			Logger.error(LOG, "Reset requested but the keylogger exposes no clear_cache — nothing was cleared.")
		end
		if not request.valid() then return nil end
		local fresh = build_payload(state, true)
		if not fresh then return nil end
		fresh.cleared = cleared
		return fresh, cleared
	end

	if action == "range" and type(payload) == "table" then
		if state.keylogger and type(state.keylogger.get_range_payload) == "function" then
			local range = state.keylogger.get_range_payload(payload.start_date, payload.end_date, payload.apps)
			if not range or not request.valid() then return nil end
			local dashboard = build_payload(state, false)
			if not dashboard then return nil end
			return {
				metrics_manifest = dashboard.metrics_manifest,
				app_icons = {},
				_prefetch_data = range,
				range_request_id = payload.request_id,
				driver_meta = { os = "linux", heatmap_id = "kc" },
			}
		end
	end
	return nil
end

--- Defers requests until the database/RAM view and native page are both current.
--- @param payload any
--- @param state table
--- @param context table|nil
--- @return table|nil
function M.on_message(payload, state, context)
	if type(payload) == "table" then
		local apps = payload.apps
		if type(apps) == "table" then
			apps = {}
			for key, value in pairs(payload.apps) do apps[key] = value end
		end
		payload = { action = payload.action, start_date = payload.start_date, end_date = payload.end_date,
			request_id = payload.request_id, apps = apps }
	end
	local action = type(payload) == "table" and payload.action or payload
	if action ~= "ready" and action ~= "refresh" and action ~= "clear_cache" and action ~= "range" then return nil end
	return Requests.run(state, context, function(request)
		return handle(payload, state, request.context, request)
	end, action == "clear_cache")
end

--- Revokes requests belonging to the retired native page.
--- @param epoch number
function M.on_window_closed(epoch) Requests.close(epoch) end

--- Test seam: forgets the cached payload and restores the default channels.
function M._reset()
	Requests.reset()
	_cached_ready, _cached_keylogger, _cached_generation = nil, nil, nil
	_refresh_generation = 0
	M._defer = default_defer
	M._push = default_push
end

return M
