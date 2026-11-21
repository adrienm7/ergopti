--- ui/metrics_typing/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Typing Metrics Dashboard
--- DESCRIPTION:
--- Supplies the same manifest and n-gram prefetch envelope consumed by the
--- shared typing dashboard on macOS and Windows. Linux previously registered no
--- handler for this UI, so its WebKit page fell through to a missing file fetch
--- and could never receive live keystats data.
---
--- FEATURES & RATIONALE:
--- 1. Instant first paint. The "ready" payload carries the n-grams of the whole
---    history, read through the sqlite3 CLI on the daemon's only thread: every
---    opening of the window blocked typing and delayed the page's first paint by
---    the length of that read. The last payload is now kept, answered at once,
---    and refreshed on a later loop tick, after the page has drawn.
--- 2. The refresh reaches the page through the same host response hook as the
---    answer, so the page applies it exactly as it applies a reply.
--- 3. The user's reset drops the kept payload with the keystats's caches, so a
---    reset is a clean rebuild.
--- 4. A payload built from an incomplete SQLite read is answered (the page says
---    the history is incomplete) but never kept, so the next opening retries.
--- 5. The heatmap names the keys the user types: every answer carries
---    `keycode_layout`, evdev code → the legend the running layout emulation
---    types there, else the loaded XKB keymap's, as Windows sends its active
---    layout and macOS `hs.keycodes.map`. Linux sent none, so the page kept
---    the static QWERTY names on every layout (MET-09).
--- 6. The page's 2 s poll follows the typing: its refresh carries today's
---    n-grams, without the history the page already holds, as Windows pushes
---    them. It carried the manifest alone, so the character, bigram and word
---    tables stood still while the window was open (MET-10).
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_typing_bridge"

local AppsBridge = require("ui.metrics_apps.bridge")
local Flush = require("ui.metrics_flush_bridge")
local Logger = require("core.logger.engine.shim")
local LOG = "bridge.metrics_typing"

local APP_NAME = "metrics_typing"

-- How long the refresh waits after a cached answer: long enough for WebKit to
-- run the reply and paint, short enough that the numbers catch up at once.
local REFRESH_DELAY_MS = 250

-- The evdev codes the heatmap can name: 1 to 88 are the PC scan codes the page
-- maps onto its keyboard (SC_TO_KC), as Windows reads scan codes 1 to 87.
local LAYOUT_LAST_CODE = 88

-- The last complete "ready" payload, and the generation of the latest refresh
-- (a newer request supersedes an older pending one).
local _cached_ready = nil
local _cached_keystats, _cached_generation = nil, nil
local _refresh_generation = 0
-- True while the last answered payload came from an incomplete read.
local _incomplete_reported = false

--- Returns whether a payload holds every row the database stores, logging the
--- start and the end of a run of incomplete reads once each.
--- @param payload table|nil Dashboard payload.
--- @return boolean complete
local function payload_complete(payload)
	if type(payload) ~= "table" then return false end
	local prefetch = payload._prefetch_data
	local complete = payload.metrics_manifest_incomplete ~= true
		and not (type(prefetch) == "table" and prefetch.incomplete == true)
	if not complete and not _incomplete_reported then
		_incomplete_reported = true
		Logger.warn(LOG, "Typing metrics history read incomplete; partial counts shown with a notice, not cached.")
	elseif complete and _incomplete_reported then
		_incomplete_reported = false
		Logger.info(LOG, "Typing metrics history read complete again; caching resumed.")
	end
	return complete
end

--- What a plain press of a key types now: the layout emulation's legend when
--- it types that key, else the loaded XKB keymap's symbol (a dead key reads
--- as its resting accent).
--- @param code integer evdev key code.
--- @return string|nil legend nil when the key types nothing printable.
local function default_legend(code)
	local emulated = require("modules.keymap.layout_emulation").legend_for_evdev(code)
	if emulated ~= nil then return emulated end
	local base = require("adapters.keyboard_layout").base_symbol(code)
	return type(base) == "table" and base.text or nil
end

--- Builds the heatmap's legend map from the active layout.
--- @return table { [evdev code string] = legend }
local function keycode_layout()
	local out = {}
	for code = 1, LAYOUT_LAST_CODE do
		local legend = M._legend(code)
		if type(legend) == "string" and legend ~= "" then out[tostring(code)] = legend end
	end
	return out
end

--- Builds the dashboard payload from the daemon state.
--- @param state table
--- @param include_prefetch boolean
--- @return table|nil
local function build_payload(state, include_prefetch)
	local payload
	if state.keystats and type(state.keystats.get_dashboard_payload) == "function" then
		payload = state.keystats.get_dashboard_payload({ include_prefetch = include_prefetch })
	else
		payload = AppsBridge.build_payload(state)
	end
	if type(payload) == "table" then payload.keycode_layout = keycode_layout() end
	return payload
end

--- Builds the poll's refresh: the manifest and today's n-grams. Without
--- `historical` the page keeps the history it holds and replaces today's.
--- @param state table
--- @return table|nil
local function build_refresh(state)
	local refreshed = build_payload(state, false)
	if type(refreshed) ~= "table" then return refreshed end
	local keystats = state.keystats
	if not keystats or type(keystats.get_today_payload) ~= "function" then
		Logger.error(LOG, "The keystats exposes no get_today_payload; the refresh carries the manifest alone.")
		return refreshed
	end
	local today, err = keystats.get_today_payload()
	if type(today) == "table" then
		refreshed._prefetch_data = today
	else
		Logger.warn(LOG, "Today's n-grams unavailable for the refresh (%s); the tables keep their last counts.",
			tostring(err))
	end
	return refreshed
end

--- Builds the dashboard payload with whether it may be kept for the next opening.
--- @param state table
--- @return table|nil payload, boolean cacheable
local function build_ready(state)
	local payload = build_payload(state, true)
	return payload, payload_complete(payload)
end

--- Default deferral: the daemon's event loop.
--- @param fn function
--- @param delay_ms number
--- @return boolean
local function default_defer(fn, delay_ms)
	local ok_loop, EventLoop = pcall(require, "core.events.loop")
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

-- Injectable seams for tests; production uses the event loop, WebKit and the
-- running layout.
M._defer = default_defer
M._push = default_push
M._legend = default_legend
local Requests = Flush.new(APP_NAME, function(...) return M._push(...) end,
	function(reply, cache, keystats, generation)
		if cache then
			_cached_ready, _cached_keystats, _cached_generation = reply, keystats, generation
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
			return build_ready(state)
		end, false, true)
	end, REFRESH_DELAY_MS)
	if not queued then
		Logger.error(LOG, "The dashboard refresh could not be scheduled — the page shows the cached payload.")
	end
end

--- Ends one range request the page is waiting for as failed. A nil answer sent
--- nothing, so the page kept its loader for the 120 s watchdog, where Windows
--- sends its range_terminal and macOS receive_range_data(null) at once (MET-05).
--- @param payload table The range request, with its request_id.
--- @param state table
--- @param context table|nil
--- @param reason string Logged cause, never the user's selection.
--- @return nil
local function fail_range(payload, state, context, reason)
	Logger.warn(LOG, "Typing metrics range request #%s refused: %s.", tostring(payload.request_id), reason)
	if type(payload.request_id) == "number" then
		Flush.call(APP_NAME, "complete_range_request", { payload.request_id, "failed" }, state, context)
	end
	return nil
end

--- Handles a ready or refresh request from the shared typing dashboard.
--- @param payload any Request payload from the WebKit bridge.
--- @param state table Daemon state.
--- @return table|nil Shared metrics prefetch payload.
local function handle(payload, state, context, request)
	local action = type(payload) == "table" and payload.action or payload
	if action == "ready" then
		if _cached_ready ~= nil and _cached_keystats == state.keystats
			and _cached_generation == request.generation then
			Logger.debug(LOG, "Typing metrics UI ready — answering from the cached payload.")
			schedule_refresh(state, context, request)
			return _cached_ready
		end
		Logger.debug(LOG, "Typing metrics UI ready — first payload of this session.")
		return build_ready(state)
	end
	if action == "refresh" then
		Logger.debug(LOG, "Typing metrics UI requested refresh.")
		local refreshed = build_refresh(state)
		payload_complete(refreshed)
		return refreshed
	end
	-- The dashboard's reset control. It clears the filters in the page and asks
	-- the backend to drop its caches so the next payload is a clean rebuild.
	-- macOS has handled this since the control existed; Linux answered nothing,
	-- so a reset re-rendered the page against the same cached manifest and the
	-- one observable effect was that resetting changed nothing.
	-- The answer is the rebuilt payload itself: the page applies every reply as
	-- dashboard data, and a bare { cleared = true } emptied the dashboard.
	-- It names the page's Reset and its outcome: the page holds its range until
	-- then, and read neither, so a failed purge was never told (MET-19).
	if action == "clear_cache" then
		local reset_id = payload.reset_id
		if type(reset_id) ~= "number" or reset_id <= 0 or reset_id % 1 ~= 0 then
			Logger.error(LOG, "A dashboard reset without a valid reset id was refused — nothing was cleared.")
			return nil
		end
		_refresh_generation = _refresh_generation + 1
		local cleared = false
		if state.keystats and type(state.keystats.clear_cache) == "function" then
			local ok, result = pcall(state.keystats.clear_cache)
			cleared = ok and result == true
			if cleared then
				Logger.info(LOG, "Dashboard caches cleared by user reset.")
			else
				Logger.error(LOG, "Dashboard reset failed: the caches were not cleared (%s).",
					ok and "the keystats refused while it flushes" or tostring(result))
			end
		else
			Logger.error(LOG, "Reset requested but the keystats exposes no clear_cache — nothing was cleared.")
		end
		if not request.valid() then return nil end
		local fresh, complete = build_ready(state)
		if not fresh then
			Flush.call(APP_NAME, "complete_cache_reset", { reset_id, cleared }, state, context)
			return nil
		end
		fresh.reset_id = reset_id
		fresh.cleared = cleared
		return fresh, cleared and complete
	end

	if action == "range" and type(payload) == "table" then
		if state.keystats and type(state.keystats.get_range_payload) == "function" then
			local range = state.keystats.get_range_payload(payload.start_date, payload.end_date, payload.apps)
			if not request.valid() then return nil end
			if not range then return fail_range(payload, state, context, "the range read failed") end
			local dashboard = build_payload(state, false)
			if not dashboard then return fail_range(payload, state, context, "the dashboard read failed") end
			local reply = {
				metrics_manifest = dashboard.metrics_manifest,
				metrics_manifest_incomplete = dashboard.metrics_manifest_incomplete,
				app_icons = {},
				_prefetch_data = range,
				keycode_layout = dashboard.keycode_layout,
				range_request_id = payload.request_id,
				driver_meta = { os = "linux", heatmap_id = "kc" },
			}
			payload_complete(reply)
			return reply
		end
		Logger.error(LOG, "The keystats exposes no get_range_payload; the range request is answered as failed.")
		return fail_range(payload, state, context, "no range reader")
	end
	return nil
end

--- The dashboard's Export and Purge: the keystats writer owns both, and the
--- page learns the outcome through complete_metrics_maintenance.
local MAINTENANCE = { metrics_export = "export", metrics_purge = "purge" }

--- Hands one Export or Purge to the writer and answers the page once.
--- @param payload table { action, maintenance_id }
--- @param state table
--- @param context table|nil
local function request_maintenance(payload, state, context)
	local id = payload.maintenance_id
	if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
		Logger.error(LOG, "Dashboard maintenance request without a valid owner id; ignored.")
		return
	end
	local function answer(success, path)
		Flush.call(APP_NAME, "complete_metrics_maintenance", { id, success == true, path }, state, context)
	end
	local k = state.keystats
	if not k or type(k.request_metrics_maintenance) ~= "function" then
		Logger.error(LOG, "The keystats exposes no request_metrics_maintenance; the dashboard is told it failed.")
		return answer(false)
	end
	if k.request_metrics_maintenance(MAINTENANCE[payload.action], answer) ~= true then answer(false) end
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
			request_id = payload.request_id, apps = apps, maintenance_id = payload.maintenance_id,
			reset_id = payload.reset_id }
	end
	local action = type(payload) == "table" and payload.action or payload
	if MAINTENANCE[action] then return request_maintenance(payload, state, context) end
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
	_cached_ready, _cached_keystats, _cached_generation = nil, nil, nil
	_refresh_generation = 0
	_incomplete_reported = false
	M._defer = default_defer
	M._push = default_push
	M._legend = default_legend
end

return M
