--- tests/unit/adapters/atspi/test_atspi_focus_watch_worker.lua

--- ==============================================================================
--- MODULE: Resident Focus Publication Reentrancy Regressions
--- DESCRIPTION:
--- Synchronous native callbacks cannot revive an interrupted ordinary snapshot
--- or relabel its old query as a newer admission request. Original worker bodies
--- execute over controlled native ports; fresh positive publication stays live.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.focus_watch_worker_fixture")

--- Connects the actual parent watcher and contextual Guard to the actual worker
--- bodies. A controlled native callback moves from ordinary A to password B.
--- @return table guard
--- @return table worker
--- @return function race Arms exactly one old query crossing a newer request.
local function parent_fixture()
	local Json = require("json")
	local worker = Fixture.new()
	local next_message, raced = 1, false
	local epoch, secure = 0, true
	local operation = { started = true }
	function operation:is_running() return true end
	function operation:is_settled() return false end
	function operation:on_settled() end
	function operation:cancel() return false end
	local transport = {}
	function transport.command() return "controlled-resident-worker", {} end
	function transport.cleanup() return true end
	function transport.close() return true end
	function transport.read()
		local message = worker.messages[next_message]
		if not message then return nil, "again" end
		next_message = next_message + 1
		return Json.encode(message) .. "\n"
	end
	function transport.request(request)
		if raced then
			raced = false
			worker.during_check = function() worker.focus("B"); worker.request(request) end
			worker.publish()
		else worker.request(request); worker.publish() end
		return true
	end
	local watch = require("adapters.atspi_focus_watch").new({
		now_ms = function() return worker.now end, create_transport = function() return transport end,
		start_process = function() return operation end,
		pause = function() worker.now = worker.now + 1; worker.publish() end,
	})
	local guard = require("modules.keylogger.focus_guard").new({ watch = watch,
		now_ms = function() return worker.now end,
		detector = {
			invalidateFocus = function() epoch = epoch + 1; secure = true; return epoch end,
			currentEpoch = function() return epoch end,
			publishFocus = function(role, wanted, protected)
				if wanted ~= epoch then return false end; secure = role == 40 or protected; return true
			end,
			isSecureField = function() return secure end,
		},
		keylogger = { set_secure_field = function(value) secure = value end, is_context_protected = function() return false end },
		capture_context = function() return { app_id = "editor", title = "same-frame", native_identity = "frame:1" } end,
		publish_context = function() return true, false end,
	})
	assert(watch.start()); worker.ready(); assert(watch.pump()); assert(guard.refresh(true))
	assert(guard.blocks_text() == false, "ordinary native field must be an admitted positive control")
	return guard, worker, function() raced = true end, function() guard.stop(); watch.stop() end
end

helpers.describe("resident focus worker: causal publication", function()
	helpers.it("(focus-publication) actual parent Guard blocks password callbacks crossing a newer request", function()
		local guard, worker, race, cleanup = parent_fixture()
		local ok, reason = pcall(function()
			race()
			helpers.assert_true(guard.blocks_text(), "old-request unknown cannot let the parent accept old ordinary text as a new password query")
			helpers.assert_eq(worker.current, "B")
		end)
		cleanup()
		if not ok then error(reason, 0) end
	end)

	for _, mode in ipairs({ "focus", "request", "both" }) do
		helpers.it("(focus-publication) rejects retained query interrupted by " .. mode, function()
			local state = Fixture.new()
			state.during_check = function()
				if mode ~= "request" then state.focus("B") end
				if mode ~= "focus" then state.request(1) end
			end
			state.publish()
			for _, message in ipairs(state.messages) do
				helpers.assert_true(message.kind ~= "snapshot", "a native callback revoked the original query before publication")
			end
			helpers.assert_eq(state.released, 2, "both interrupted retained GObjects must release exactly once")
			state.publish()
			local fresh = state.messages[#state.messages]
			helpers.assert_eq(fresh.kind, "snapshot")
			helpers.assert_eq(fresh.role, mode == "request" and 61 or 40)
			helpers.assert_eq(fresh.request, mode == "focus" and 0 or 1)
			helpers.assert_nil(state.failed)
		end)
	end

	helpers.it("(focus-publication) releases full-scan results interrupted by a native callback", function()
		local state = Fixture.new()
		state.clear_handles()
		state.during_scan = function() state.focus("B"); state.request(1) end
		state.publish()
		helpers.assert_eq(#state.messages, 1)
		helpers.assert_eq(state.messages[1].kind, "unknown")
		helpers.assert_eq(state.released, 2, "an interrupted new scan must release its returned native references")
		state.publish()
		local fresh = state.messages[#state.messages]
		helpers.assert_eq(fresh.kind, "snapshot"); helpers.assert_eq(fresh.role, 40)
		helpers.assert_eq(fresh.path, "/field/B"); helpers.assert_eq(fresh.request, 1)
	end)

	helpers.it("(focus-publication) nested GLib publication cannot query the same retained objects twice", function()
		local state = Fixture.new()
		state.during_check = state.publish
		state.publish()
		helpers.assert_eq(state.checks, 1, "synchronous GLib reentry cannot start a second native focus query")
		helpers.assert_eq(#state.messages, 1)
		helpers.assert_eq(state.messages[1].role, 61)
	end)

	helpers.it("(focus-publication) ignores child names and preserves an unchanged ordinary positive", function()
		local state = Fixture.new()
		state.during_check = state.child_name
		state.publish()
		helpers.assert_eq(#state.messages, 1)
		helpers.assert_eq(state.messages[1].kind, "snapshot")
		helpers.assert_eq(state.messages[1].role, 61)
		helpers.assert_eq(state.events_freed, 1)
		helpers.assert_eq(state.released, 0)
	end)
end)
