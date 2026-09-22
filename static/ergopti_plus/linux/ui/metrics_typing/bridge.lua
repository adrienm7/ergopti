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
local Logger = require("logger.shim")
local LOG = "bridge.metrics_typing"

local APP_NAME = "metrics_typing"

-- How long the refresh waits after a cached answer: long enough for WebKit to
-- run the reply and paint, short enough that the numbers catch up at once.
local REFRESH_DELAY_MS = 250

-- The last complete "ready" payload, and the generation of the latest refresh
-- (a newer request supersedes an older pending one).
local _cached_ready = nil
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
local function default_push(payload)
	local ok_manager, Manager = pcall(require, "ui.webview_manager")
	if not ok_manager or type(Manager.eval_js) ~= "function" then
		Logger.error(LOG, "Cannot push the dashboard refresh: webview_manager.eval_js is unavailable.")
		return false
	end
	local Json = require("json")
	local Base64 = require("compat.base64")
	return Manager.eval_js(APP_NAME, string.format(
		"if(window.__hostBridgeResponse)window.__hostBridgeResponse('%s',true,'%s')",
		M.bridge_name, Base64.encode(Json.encode(payload)))) == true
end

-- Injectable seams for tests; production uses the event loop and WebKit.
M._defer = default_defer
M._push = default_push

--- Schedules a fresh "ready" payload after the cached answer has painted.
--- @param state table
local function schedule_refresh(state)
	_refresh_generation = _refresh_generation + 1
	local generation = _refresh_generation
	local queued = M._defer(function()
		if generation ~= _refresh_generation then
			Logger.debug(LOG, "Discarded a superseded dashboard refresh (generation %d).", generation)
			return
		end
		Logger.start(LOG, "Refreshing the typing dashboard after its cached first paint…")
		local fresh = build_payload(state, true)
		if fresh == nil then
			Logger.error(LOG, "The dashboard refresh produced no payload — the page keeps the cached one.")
			return
		end
		_cached_ready = fresh
		if M._push(fresh) then
			Logger.success(LOG, "Typing dashboard refreshed.")
		else
			Logger.success(LOG, "Typing dashboard refresh computed and kept; no open window received it.")
		end
	end, REFRESH_DELAY_MS)
	if not queued then
		Logger.error(LOG, "The dashboard refresh could not be scheduled — the page shows the cached payload.")
	end
end

--- Handles a ready or refresh request from the shared typing dashboard.
--- @param payload any Request payload from the WebKit bridge.
--- @param state table Daemon state.
--- @return table|nil Shared metrics prefetch payload.
function M.on_message(payload, state)
	local action = type(payload) == "table" and payload.action or payload
	if action == "ready" then
		if _cached_ready ~= nil then
			Logger.debug(LOG, "Typing metrics UI ready — answering from the cached payload.")
			schedule_refresh(state)
			return _cached_ready
		end
		Logger.debug(LOG, "Typing metrics UI ready — first payload of this session.")
		_cached_ready = build_payload(state, true)
		return _cached_ready
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
	if action == "clear_cache" then
		_cached_ready = nil
		if state.keylogger and type(state.keylogger.clear_cache) == "function" then
			state.keylogger.clear_cache()
			Logger.info(LOG, "Dashboard caches cleared by user reset.")
			return { cleared = true }
		end
		Logger.error(LOG, "Reset requested but the keylogger exposes no clear_cache — nothing was cleared.")
		return { cleared = false }
	end

	if action == "range" and type(payload) == "table" then
		if state.keylogger and type(state.keylogger.get_range_payload) == "function" then
			local range = state.keylogger.get_range_payload(payload.start_date, payload.end_date, payload.apps)
			return {
				metrics_manifest = state.keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest,
				app_icons = {},
				_prefetch_data = range,
				range_request_id = payload.request_id,
				driver_meta = { os = "linux", heatmap_id = "kc" },
			}
		end
	end
	return nil
end

--- Test seam: forgets the cached payload and restores the default channels.
function M._reset()
	_cached_ready = nil
	_refresh_generation = 0
	M._defer = default_defer
	M._push = default_push
end

return M
