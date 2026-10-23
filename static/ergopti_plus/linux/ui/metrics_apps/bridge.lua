--- ui/metrics_apps/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Metrics Apps Dashboard (per-app statistics)
--- Handles JS->Lua messages from _shared/ui/metrics_apps/.
--- Bridge name: "metrics_apps_bridge"
---
--- NOTE: This file replaces the formerly-named metrics_typing_bridge.lua
--- so that the module name matches the _shared/ui/ app directory convention
--- used by webview_manager._load_handler().
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_apps_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.metrics_apps"
local Flush = require("ui.metrics_flush_bridge")

local function default_push(payload, state, context)
	return Flush.push("metrics_apps", M.bridge_name, payload, state, context)
end
M._push = default_push
local Requests = Flush.new("metrics_apps", function(...) return M._push(...) end)

--- Builds the shared metrics payload expected by the browser dashboard.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state, include_prefetch)
	local keystats = state.keystats
	if keystats then
		local status = Flush.status(keystats)
		if not status or not status.read_safe or status.stopping
			or type(keystats.get_dashboard_payload) ~= "function" then return nil end
		return keystats.get_dashboard_payload({ include_prefetch = include_prefetch ~= false })
	end
	return {
		metrics_manifest = {},
		app_icons        = {},
		_prefetch_data   = { historical = {}, today = {} },
		driver_meta      = { os = "linux", heatmap_id = "kc" },
	}
end

--- Exposes the payload builder to the typing dashboard bridge.
--- @param state table Daemon state.
--- @return table Shared metrics payload.
function M.build_payload(state)
	return _build_initial_payload(state, true)
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keystats, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
local function handle(payload, state, request)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Metrics apps UI ready.")
			return _build_initial_payload(state, true)
		end
		if payload == "refresh" then
			return _build_initial_payload(state, false)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	-- Every answer is a full dashboard payload, with the action's outcome added
	-- as a field: the page applies each reply as dashboard data, and a bare
	-- { saved = … } or { supported = false } emptied it until the next poll.
	local function with_payload(fields)
		if not request.valid() then return nil end
		local reply = _build_initial_payload(state, false)
		if not reply then return nil end
		for key, value in pairs(fields) do reply[key] = value end
		return reply
	end

	local action = payload.action
	if action == "ready" or action == "refresh" then
		return _build_initial_payload(state, action == "ready")
	end

	-- These four are not sent by the shared page today. They are kept because
	-- each calls a keystats function that exists and does what its name says,
	-- and because the bridge is also the daemon's programmatic entry point —
	-- unlike `app_detail`, which was removed: it called `get_app_detail`, a
	-- function that has never existed on this driver, behind a
	-- `type(…) == "function"` guard that turned the missing function into a
	-- silent nil. The guard read as defensive while making the branch
	-- permanently unreachable and wrong.
	if action == "reset" then
		local reset = false
		if state.keystats and type(state.keystats.reset_session) == "function" then
			local ok, accepted = pcall(state.keystats.reset_session)
			reset = ok and accepted == true
			if reset and not request.accept_reset() then return nil end
		end
		if not request.valid() then return nil end
		local reply = _build_initial_payload(state, true)
		if reply then reply.reset = reset end
		return reply
	end

	if action == "export" then
		if state.keystats and type(state.keystats.export_json) == "function" then
			local ok, json = pcall(state.keystats.export_json)
			return with_payload({ exported = ok, json = ok and json or nil })
		end
		return with_payload({ exported = false })
	end

	if action == "pause" then
		if state.keystats and type(state.keystats.suppress) == "function" then
			state.keystats.suppress()
		end
		return with_payload({ suppressed = true })
	end

	if action == "resume" then
		if state.keystats and type(state.keystats.unsuppress) == "function" then
			state.keystats.unsuppress()
		end
		return with_payload({ suppressed = false })
	end

	-- The category editor. This is the one control on the page that writes
	-- anything, and it was unhandled: the user picked a category, the modal
	-- closed, and the choice went nowhere. `category` is a real column on
	-- agg_app_day and the dashboard groups by it, so the effect was a control
	-- that looked like it worked and silently discarded its input.
	if action == "edit" then
		local app_name = tostring(payload.app or "")
		local category = tostring(payload.cat or "")
		if state.keystats and type(state.keystats.set_app_category) == "function" then
			local ok = state.keystats.set_app_category(app_name, category, tonumber(payload.score) or 0)
			return with_payload({ saved = ok == true })
		end
		Logger.error(LOG, "Category edit for '%s' arrived but the keystats cannot store it.", app_name)
		return with_payload({ saved = false })
	end

	-- macOS answers this with a native chooser listing the known applications.
	-- Linux has no equivalent modal, and saying so is the honest answer: the
	-- page can fall back to its own list. Returning nil would be indistinguishable
	-- from a handler that crashed.
	if action == "pick" then
		Logger.info(LOG, "Application picker requested; this driver has no native chooser.")
		return with_payload({ supported = false })
	end

	Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(action))
	return nil
end

--- Routes requests through the flush and native page owner before any action.
--- @param payload any
--- @param state table
--- @param context table|nil
--- @return table|nil
function M.on_message(payload, state, context)
	if type(payload) == "table" then
		payload = { action = payload.action, app = payload.app, cat = payload.cat, score = payload.score }
	end
	local action = type(payload) == "table" and payload.action or payload
	if action ~= "ready" and action ~= "refresh" and action ~= "reset" and action ~= "export"
		and action ~= "pause" and action ~= "resume" and action ~= "edit" and action ~= "pick" then return nil end
	local read = action == "ready" or action == "refresh" or action == "pick" or action == "export"
	return Requests.run(state, context, function(request) return handle(payload, state, request) end, not read)
end

--- Revokes deferred actions from the exact page being retired.
--- @param epoch number
function M.on_window_closed(epoch) Requests.close(epoch) end

--- Restores test channels and revokes outstanding requests.
function M._reset()
	Requests.reset()
	M._push = default_push
end

return M
