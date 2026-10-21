--- tests/unit/ui/metrics/test_metrics_flush_bridge.lua

--- Dashboard messages cross both SQLite settlement and the exact page owner.
local H = require("tests.helpers")

local function fixture(app)
	local generation, pending, debt, stopping, epoch = 1, true, true, false, 1
	local subscribers, pushed = {}, {}
	local counts = { reads = 0, writes = 0, subscriptions = 0 }
	local K = {}
	K.get_flush_status = function()
		return { phase = pending and "writing" or "idle", pending = pending, has_debt = debt,
			read_safe = not pending and not stopping, committed = not debt,
			stopping = stopping, generation = generation }
	end
	K.is_flush_pending = function() return pending end
	K.has_flush_debt = function() return debt end
	K.when_flush_settled = function(callback)
		counts.subscriptions = counts.subscriptions + 1
		subscribers[#subscribers + 1] = callback
		return true
	end
	K.get_dashboard_payload = function()
		counts.reads = counts.reads + 1
		if pending then return nil, "SQLite flush pending" end
		return { metrics_manifest = { day = { app = { chars = 17 } } }, app_icons = {},
			_prefetch_data = { historical = {}, today = {} }, driver_meta = { os = "linux" } }
	end
	K.get_range_payload = function()
		counts.reads = counts.reads + 1
		if pending then return nil, "SQLite flush pending" end
		return { historical = { witness = 9 }, today = {} }
	end
	K.set_app_category = function()
		counts.writes = counts.writes + 1
		return not debt and not pending and not stopping
	end
	K.clear_cache = K.set_app_category
	K.reset_session = function()
		counts.writes = counts.writes + 1
		if debt or pending or stopping then return false end
		generation = generation + 1
		return true
	end
	local state = { keylogger = K, webview_manager = {
		page_current = function(name, owner) return name == app and owner == epoch end,
		eval_js = function(_, js) pushed[#pushed + 1] = js return true end,
	} }
	local B = H.load_module("ui." .. app .. ".bridge")
	if B._reset then B._reset() end
	local function settle(keep_debt)
		pending, debt = false, keep_debt == true
		local callbacks = subscribers
		subscribers = {}
		for _, callback in ipairs(callbacks) do callback(K.get_flush_status()) end
	end
	return { B = B, state = state, context = { app_name = app, epoch = 1 }, K = K, c = counts,
		pushed = pushed, settle = settle, epoch = function(value) epoch = value end,
		stop = function() stopping = true end, generation = function() generation = generation + 1 end,
		read_safe = function(keep_debt) pending, debt = false, keep_debt == true end }
end

H.describe("metrics flush bridge", function()
	for _, app in ipairs({ "metrics_apps", "metrics_typing" }) do
		H.it(app .. " defers ready without reading then pushes complete data", function()
			local F = fixture(app)
			H.assert_nil(F.B.on_message("ready", F.state, F.context))
			H.assert_eq(F.c.reads, 0)
			H.assert_eq(F.c.subscriptions, 1)
			F.settle()
			H.assert_eq(#F.pushed, 1)
		end)
		H.it(app .. " coalesces polls without cancelling the user's mutation", function()
			local F = fixture(app)
			F.B.on_message({ action = app == "metrics_apps" and "edit" or "clear_cache", app = "a" }, F.state, F.context)
			for _ = 1, 20 do F.B.on_message("refresh", F.state, F.context) end
			H.assert_eq(F.c.writes, 0)
			H.assert_eq(F.c.subscriptions, 1)
			F.settle()
			H.assert_eq(F.c.writes, 1)
			H.assert_eq(#F.pushed, 2)
		end)
		H.it(app .. " refuses an action after close and replacement", function()
			local F = fixture(app)
			F.B.on_message({ action = app == "metrics_apps" and "edit" or "clear_cache", app = "a" }, F.state, F.context)
			F.B.on_window_closed(1)
			F.epoch(2)
			F.settle()
			H.assert_eq(F.c.writes, 0)
			H.assert_eq(#F.pushed, 0)
		end)
		H.it(app .. " rejects stale source generation or stopping before reading", function()
			for _, invalidate in ipairs({ "stop", "generation" }) do
				local F = fixture(app)
				F.B.on_message("ready", F.state, F.context)
				F[invalidate]()
				F.settle()
				H.assert_eq(F.c.reads, 0)
				H.assert_eq(#F.pushed, 0)
			end
		end)
		H.it(app .. " refuses incomplete API rather than inventing safe status", function()
			local F = fixture(app)
			F.K.get_flush_status = nil
			H.assert_nil(F.B.on_message("ready", F.state, F.context))
			H.assert_eq(F.c.reads, 0)
		end)
		H.it(app .. " rechecks native page after payload reading", function()
			local F = fixture(app)
			local read = F.K.get_dashboard_payload
			F.K.get_dashboard_payload = function() local result = read() F.epoch(2) return result end
			F.B.on_message("ready", F.state, F.context)
			F.settle()
			H.assert_eq(#F.pushed, 0)
		end)
		H.it(app .. " refuses an unavailable category projection and recovers after a fresh read", function()
			local F = fixture(app)
			local available = F.K.get_dashboard_payload
			F.K.get_dashboard_payload = function()
				F.c.reads = F.c.reads + 1
				return nil, "SQLite projection unavailable"
			end
			F.B.on_message("ready", F.state, F.context)
			F.settle()
			H.assert_eq(F.c.reads, 1)
			H.assert_eq(#F.pushed, 0, "An unavailable category owner cannot publish a fresh empty dashboard")
			F.K.get_dashboard_payload = available
			local reply = F.B.on_message("ready", F.state, F.context)
			H.assert_eq(reply.metrics_manifest.day.app.chars, 17)
			H.assert_eq(F.c.reads, 2, "Refusal must not seed the typing ready cache")
		end)
	end
	for _, mode in ipairs({ "immediate", "deferred" }) do
		H.it("(range-projection-unavailable) " .. mode .. " nil projection cannot publish or poison the next read", function()
			local F = fixture("metrics_typing")
			if mode == "immediate" then F.read_safe() end
			local available = F.K.get_range_payload
			F.K.get_range_payload = function()
				F.c.reads = F.c.reads + 1
				return nil, "SQLite projection unavailable"
			end
			H.assert_nil(F.B.on_message({ action = "range", request_id = 80 }, F.state, F.context))
			if mode == "deferred" then
				H.assert_eq(F.c.reads, 0, "Pending ownership must defer even an unavailable projection")
				F.settle()
			end
			H.assert_eq(F.c.reads, 1, "A nil range must stop before reading/caching another dashboard payload")
			H.assert_eq(#F.pushed, 0, "No incomplete range may be published")
			F.K.get_range_payload = available
			local reply = F.B.on_message({ action = "range", request_id = 81 }, F.state, F.context)
			H.assert_eq(reply.range_request_id, 81)
			H.assert_eq(reply._prefetch_data.historical.witness, 9)
			H.assert_eq(F.c.reads, 3, "Recovery must read a fresh range and dashboard exactly once")
		end)
	end

	H.it("typing range preserves request identity after deferred settlement", function()
		local F = fixture("metrics_typing")
		H.assert_nil(F.B.on_message({ action = "range", request_id = 71 }, F.state, F.context))
		H.assert_eq(F.c.reads, 0)
		F.B._push = function(reply) F.pushed[#F.pushed + 1] = reply return true end
		F.settle()
		H.assert_eq(F.pushed[1].range_request_id, 71)
		H.assert_eq(F.pushed[1]._prefetch_data.historical.witness, 9)
	end)
	H.it("typing cache refusal returns full data and false outcome", function()
		local F = fixture("metrics_typing")
		F.read_safe(true)
		local reply = F.B.on_message({ action = "clear_cache" }, F.state, F.context)
		H.assert_eq(reply.cleared, false)
		H.assert_eq(reply.metrics_manifest.day.app.chars, 17)
	end)
	H.it("apps reset waits then accepts only its acknowledged generation increment", function()
		local F = fixture("metrics_apps")
		F.B.on_message({ action = "reset" }, F.state, F.context)
		H.assert_eq(F.c.writes, 0)
		F.settle()
		H.assert_eq(F.c.writes, 1)
		H.assert_eq(#F.pushed, 1)
	end)
	H.it("rollback permits full data while category mutation refuses", function()
		local F = fixture("metrics_apps")
		F.B._push = function(reply) F.pushed[#F.pushed + 1] = reply return true end
		F.B.on_message({ action = "edit", app = "a" }, F.state, F.context)
		F.settle(true)
		H.assert_eq(F.pushed[1].saved, false)
		H.assert_eq(F.pushed[1].metrics_manifest.day.app.chars, 17)
	end)
	H.it("inline notification before subscription rejection cannot perform an edit", function()
		local F = fixture("metrics_apps")
		F.K.when_flush_settled = function(cb) F.read_safe() cb(F.K.get_flush_status()) return false end
		H.assert_nil(F.B.on_message({ action = "edit", app = "a" }, F.state, F.context))
		H.assert_eq(F.c.writes, 0)
		H.assert_eq(#F.pushed, 0)
	end)
	H.it("absent K preserves empty initial reads and refuses mutations", function()
		local F = fixture("metrics_apps")
		H.assert_true(type(F.B.on_message("ready", {}).metrics_manifest) == "table")
		H.assert_eq(F.B.on_message({ action = "edit" }, {}).saved, false)
		local T = fixture("metrics_typing")
		H.assert_eq(T.B.on_message({ action = "clear_cache" }, {}).cleared, false)
	end)
	H.it("subscription throw after inline notification cannot execute a mutation", function()
		local F = fixture("metrics_apps")
		F.K.when_flush_settled = function(cb) F.read_safe() cb(F.K.get_flush_status()) error("refused") end
		H.assert_nil(F.B.on_message({ action = "edit", app = "a" }, F.state, F.context))
		H.assert_eq(F.c.writes, 0)
		H.assert_eq(#F.pushed, 0)
	end)
	H.it("an acknowledged inline subscription delivers exactly once", function()
		local F = fixture("metrics_apps")
		F.K.when_flush_settled = function(cb)
			F.read_safe()
			cb(F.K.get_flush_status())
			cb(F.K.get_flush_status())
			return true
		end
		F.B.on_message({ action = "edit", app = "a" }, F.state, F.context)
		H.assert_eq(F.c.writes, 1)
		H.assert_eq(#F.pushed, 1)
	end)
	H.it("source replacement cannot publish an old settlement", function()
		local F = fixture("metrics_apps")
		F.B.on_message("ready", F.state, F.context)
		F.state.keylogger = require("tests.fakes.metrics_keylogger").synchronous({})
		F.settle()
		H.assert_eq(F.c.reads, 0)
		H.assert_eq(#F.pushed, 0)
	end)
	H.it("captured page epochs cannot be retargeted by changing a context table", function()
		local F = fixture("metrics_apps")
		F.B.on_message({ action = "edit", app = "a" }, F.state, F.context)
		F.context.epoch = 2
		F.epoch(2)
		F.settle()
		H.assert_eq(F.c.writes, 0)
	end)
	H.it("both distinct queued edits survive read polling", function()
		local F = fixture("metrics_apps")
		F.B.on_message({ action = "edit", app = "a" }, F.state, F.context)
		F.B.on_message({ action = "edit", app = "b" }, F.state, F.context)
		F.B.on_message("refresh", F.state, F.context)
		F.settle()
		H.assert_eq(F.c.writes, 2)
		H.assert_eq(#F.pushed, 3)
	end)
	H.it("status exceptions and invalid or contradictory receipts refuse all reads", function()
		for _, invalid in ipairs({
			function() error("unavailable") end,
			function() return {} end,
			function() return { phase = "writing", pending = true, has_debt = true,
				read_safe = true, committed = false, stopping = false, generation = 1 } end,
		}) do
			local F = fixture("metrics_apps")
			F.K.get_flush_status = invalid
			H.assert_nil(F.B.on_message("ready", F.state, F.context))
			H.assert_eq(F.c.reads, 0)
		end
	end)
	H.it("a reset refusal is explicit and keeps the full rollback projection", function()
		local F = fixture("metrics_apps")
		F.read_safe(true)
		local reply = F.B.on_message({ action = "reset" }, F.state, F.context)
		H.assert_eq(reply.reset, false)
		H.assert_eq(reply.metrics_manifest.day.app.chars, 17)
	end)
	H.it("typing cached refresh cannot enter the replacement page or cache", function()
		local F = fixture("metrics_typing")
		F.read_safe()
		local deferred = {}
		F.B._defer = function(cb) deferred[#deferred + 1] = cb return true end
		F.B.on_message("ready", F.state, F.context)
		F.B.on_message("ready", F.state, F.context)
		H.assert_eq(#deferred, 1)
		F.B.on_window_closed(1)
		F.epoch(2)
		deferred[1]()
		H.assert_eq(F.c.reads, 1)
		H.assert_eq(#F.pushed, 0)
	end)
	H.it("typing cache is scoped to its actual keylogger generation", function()
		local F = fixture("metrics_typing")
		F.read_safe()
		local first = F.B.on_message("ready", F.state, F.context)
		F.generation()
		local second = F.B.on_message("ready", F.state, F.context)
		H.assert_eq(F.c.reads, 2)
		H.assert_true(first ~= second)
	end)

	H.it("an asynchronous category edit captures its original arguments", function()
		local F = fixture("metrics_apps")
		local saved_app
		F.K.set_app_category = function(app) saved_app = app return true end
		local payload = { action = "edit", app = "original", cat = "Web" }
		F.B.on_message(payload, F.state, F.context)
		payload.app = "replacement"
		F.settle()
		H.assert_eq(saved_app, "original")
	end)
	H.it("an asynchronous range captures its original application filter", function()
		local F = fixture("metrics_typing")
		local selected
		F.K.get_range_payload = function(_, _, apps) selected = apps[1] return {} end
		local payload = { action = "range", apps = { "original" } }
		F.B.on_message(payload, F.state, F.context)
		payload.apps[1] = "replacement"
		F.settle()
		H.assert_eq(selected, "original")
	end)

	for _, app in ipairs({ "metrics_apps", "metrics_typing" }) do
		H.it(app .. " does not read after its mutator revokes the native page", function()
			local F = fixture(app)
			F.read_safe()
			local function revoke()
				F.B.on_window_closed(1)
				F.epoch(2)
				return false
			end
			F.K.set_app_category, F.K.clear_cache = revoke, revoke
			H.assert_nil(F.B.on_message({ action = app == "metrics_apps" and "edit" or "clear_cache" }, F.state, F.context))
			H.assert_eq(F.c.reads, 0)
			H.assert_eq(#F.pushed, 0)
		end)
	end
	H.it("a coherent stopped keylogger status remains inspectable but cannot admit UI", function()
		local F = fixture("metrics_apps")
		F.read_safe()
		local status = F.K.get_flush_status()
		status.stopping = true
		F.K.get_flush_status = function() return status end
		local Flush = require("ui.metrics_flush_bridge")
		H.assert_eq(Flush.status(F.K), status)
		H.assert_nil(F.B.on_message("ready", F.state, F.context))
		H.assert_eq(F.c.reads, 0)
	end)

	H.it("a malformed native page identity is refused before reading", function()
		local F = fixture("metrics_apps")
		F.read_safe()
		H.assert_nil(F.B.on_message("ready", F.state, { app_name = "metrics_apps", epoch = "invalid" }))
		H.assert_eq(F.c.reads, 0)
	end)

end)
