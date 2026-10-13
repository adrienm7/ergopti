--- tests/unit/modules/keylogger/test_physical_capture_unavailable.lua

--- Selects unavailable stream accounting without inventing a runtime or lease.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run

local function bind(capture, controls)
	helpers.assert_eq(capture.init(controls.dependencies), true)
	local owner = {}
	local capability = assert(capture.bind_managed_source(owner))
	helpers.assert_eq(type(capability.select_unavailable), "function")
	return owner, capability.identity(owner), capability
end

local function select(capture, observed, controls, owner, token, capability)
	helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), true)
	helpers.assert_eq(controls.mode.credit_source(), "gap")
	helpers.assert_eq(controls.mode.legacy_credits(), false)
	helpers.assert_eq(controls.mode.admitted_capture(), nil)
	helpers.assert_eq(capture.status(), { state = "unavailable", reason = "owned_runtime_unbound", settled = true })
	helpers.assert_eq(#observed.spawns, 0)
	helpers.assert_eq(capability.lease_identity(owner, token), nil)
end

helpers.describe("physical capture unavailable source selection", function()
	helpers.it("keeps binding dormant and selects GAP without invoking any native or delivery port", function()
		with_capture(function(capture, observed, controls)
			for name in pairs(controls.dependencies) do
				controls.dependencies[name] = function() error("Unexpected native port: " .. name) end
			end
			local owner, token, capability = bind(capture, controls)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(capture.status(), { state = "idle", settled = true })
			select(capture, observed, controls, owner, token, capability)
			helpers.assert_eq(observed.credits, {})
			helpers.assert_eq(observed.releases, {})
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(observed.writes, {})
			helpers.assert_eq(capture.bind_history_scope({}), false)
			helpers.assert_eq(capability.current(owner, token), true)
		end)
	end)

	helpers.it("requires exact custody before validating input and preserves its first selection", function()
		with_capture(function(capture, observed, controls)
			local settlements, comparisons = 0, 0
			helpers.assert_eq(controls.mode.bind_settlement({}, function() settlements = settlements + 1; return true end), true)
			local owner, token, capability = bind(capture, controls)
			local foreign = setmetatable({}, { __eq = function() comparisons = comparisons + 1; return true end })
			helpers.assert_eq(capability.select_unavailable(foreign, token, nil), false)
			helpers.assert_eq(capability.select_unavailable(owner, foreign, nil), false)
			helpers.assert_eq(comparisons, 0)
			helpers.assert_eq(settlements, 0)
			select(capture, observed, controls, owner, token, capability)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), true)
			helpers.assert_eq(capability.select_unavailable(owner, token, "different_reason"), false)
			helpers.assert_eq(settlements, 1)
			helpers.assert_eq(capture.status().reason, "owned_runtime_unbound")
			helpers.assert_eq(capture.bind_managed_source(owner), nil)
			helpers.assert_eq(capture.start(controls.options), false)
		end)
	end)

	helpers.it("rejects malformed reasons without changing accounting or consuming the binding", function()
		with_capture(function(capture, observed, controls)
			local owner, token, capability = bind(capture, controls)
			for _, reason in ipairs({ false, 1, {}, "", "bad\0reason", "bad\nreason", "bad\rreason" }) do
				local called = pcall(capability.select_unavailable, owner, token, reason)
				helpers.assert_eq(called, false)
				helpers.assert_eq(controls.mode.credit_source(), "legacy")
				helpers.assert_eq(capture.status(), { state = "idle", settled = true })
			end
			select(capture, observed, controls, owner, token, capability)
		end)
	end)

	helpers.it("retains legacy accounting when actual settlement refuses and permits an exact retry", function()
		with_capture(function(capture, observed, controls)
			local allow = false
			helpers.assert_eq(controls.mode.bind_settlement({}, function() return allow end), true)
			local owner, token, capability = bind(capture, controls)
			local accepted, reason = capability.select_unavailable(owner, token, "owned_runtime_unbound")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(reason, "settlement_refused")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(capture.status(), { state = "idle", settled = true })
			helpers.assert_eq(capability.current(owner, token), true)
			allow = true
			select(capture, observed, controls, owner, token, capability)
		end)
	end)

	helpers.it("contains a throwing settlement as a refusal without publishing false unavailability", function()
		with_capture(function(capture, observed, controls)
			local throws = true
			helpers.assert_eq(controls.mode.bind_settlement({}, function()
				if throws then error("Settlement failed") end
				return true
			end), true)
			local owner, token, capability = bind(capture, controls)
			local accepted, reason = capability.select_unavailable(owner, token, "owned_runtime_unbound")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(reason, "settlement_refused")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(capture.status().state, "idle")
			throws = false
			select(capture, observed, controls, owner, token, capability)
		end)
	end)

	helpers.it("preserves selected GAP after a lease-only stop and releases only at final shutdown", function()
		with_capture(function(capture, observed, controls)
			local owner, token, capability = bind(capture, controls)
			select(capture, observed, controls, owner, token, capability)
			helpers.assert_eq(capability.stop_lease(owner, token), true)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(capability.current(owner, token), true)
			local completions, retired_inside, successor_inside = 0, nil, nil
			local observer = function(value)
				completions = completions + 1
				helpers.assert_eq(value, true)
				retired_inside = capability.retired(owner, token)
				successor_inside = capture.bind_managed_source({})
			end
			helpers.assert_eq(capability.shutdown(owner, token, observer), true)
			helpers.assert_eq(completions, 1)
			helpers.assert_eq(retired_inside, false)
			helpers.assert_eq(successor_inside, nil)
			helpers.assert_eq(capability.retired(owner, token), true)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(capability.shutdown(owner, token, observer), true)
			helpers.assert_eq(completions, 1)
			helpers.assert_eq(#observed.spawns, 0)
		end)
	end)

	helpers.it("retains release debt and blocks successors until actual final settlement", function()
		with_capture(function(capture, observed, controls)
			local allow = true
			helpers.assert_eq(controls.mode.bind_settlement({}, function() return allow end), true)
			local owner, token, capability = bind(capture, controls)
			select(capture, observed, controls, owner, token, capability)
			allow = false
			local completions = 0
			helpers.assert_eq(capability.shutdown(owner, token, function() completions = completions + 1 end), false)
			helpers.assert_eq(capability.retired(owner, token), false)
			helpers.assert_eq(capability.current(owner, token), false)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(capability.start(owner, token, controls.options), false)
			helpers.assert_eq(capture.bind_managed_source({}), nil)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(completions, 0)
			allow = true
			helpers.assert_eq(capability.shutdown(owner, token), true)
			helpers.assert_eq(completions, 1)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(#observed.spawns, 0)
		end)
	end)

	helpers.it("latches shutdown during selection without adopting or abandoning its accounting obligation", function()
		with_capture(function(capture, observed, controls)
			local owner, token, capability, inside, duplicate, calls = nil, nil, nil, nil, nil, 0
			helpers.assert_eq(controls.mode.bind_settlement({}, function()
				calls = calls + 1
				if calls == 1 then
					duplicate = capability.select_unavailable(owner, token, "owned_runtime_unbound")
					inside = capability.shutdown(owner, token)
					helpers.assert_eq(capability.retired(owner, token), false)
					helpers.assert_eq(capture.bind_managed_source({}), nil)
				end
				return true
			end), true)
			owner, token, capability = bind(capture, controls)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(inside, false)
			helpers.assert_eq(duplicate, false)
			helpers.assert_eq(calls, 2, "Selected custody must be released after the selection frame unwinds")
			helpers.assert_eq(capability.retired(owner, token), true)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(#observed.spawns, 0)
		end)
	end)

	helpers.it("does not let mutated public views or a retired token acquire a successor's custody", function()
		with_capture(function(capture, observed, controls)
			local owner, token, capability = bind(capture, controls)
			select(capture, observed, controls, owner, token, capability)
			helpers.assert_eq(capability.shutdown(owner, token), true)
			capability.current = function() return true end
			capability.retired = function() return true end
			local successor_owner = {}
			local successor = assert(capture.bind_managed_source(successor_owner))
			local successor_token = successor.identity(successor_owner)
			helpers.assert_eq(rawequal(token, successor_token), false)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(capability.select_unavailable(successor_owner, successor_token, "owned_runtime_unbound"), false)
			helpers.assert_eq(successor.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(successor.select_unavailable(successor_owner, successor_token, "owned_runtime_unbound"), true)
			helpers.assert_eq(capability.shutdown(owner, token), true)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(#observed.spawns, 0)
		end)
	end)

	helpers.it("keeps unavailability through invalid start options and uses unchanged real start admission", function()
		with_capture(function(capture, observed, controls)
			local settlements = 0
			helpers.assert_eq(controls.mode.bind_settlement({}, function() settlements = settlements + 1; return true end), true)
			local owner, token, capability = bind(capture, controls)
			select(capture, observed, controls, owner, token, capability)
			local start_ok, start_error = pcall(capability.start, owner, token, {})
			helpers.assert_eq(start_ok, false)
			helpers.assert_eq(type(start_error), "string")
			helpers.assert_true(start_error:find("Physical capture requires an absolute executable", 1, true) ~= nil)
			helpers.assert_eq(capture.status().reason, "owned_runtime_unbound")
			helpers.assert_eq(#observed.spawns, 0)
			local accepted, lease = capability.start(owner, token, controls.options)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(type(lease), "table")
			helpers.assert_eq(capture.status().state, "verifying")
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(settlements, 1, "Native start reuses the already selected accounting owner")
			helpers.assert_eq(observed.spawns[1].executable, "/usr/bin/codesign")
			controls.verified()
			controls.open()
			helpers.assert_eq(controls.mode.credit_source(), "stream")
			helpers.assert_eq(capture.status().state, "capturing")
		end)
	end)

	helpers.it("refuses selection over an active capture or native retirement debt", function()
		with_capture(function(capture, observed, controls)
			local owner, token, capability = bind(capture, controls)
			helpers.assert_eq(capability.start(owner, token, controls.options), true)
			controls.verified()
			controls.open()
			local admitted = controls.mode.admitted_capture()
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(controls.mode.admitted_capture(), admitted)
			helpers.assert_eq(capture.status().state, "capturing")
			helpers.assert_eq(capability.stop_lease(owner, token), false)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(#observed.spawns, 3)
			observed.tasks[3].settle()
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), true)
			helpers.assert_eq(capture.status().state, "unavailable")
			helpers.assert_eq(capability.shutdown(owner, token), true)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("preserves exact history-scope custody after native tasks settle", function()
		with_capture(function(capture, observed, controls)
			local history_owner, scope = {}, nil
			local original = controls.dependencies.clock_ready
			controls.dependencies.clock_ready = function(...)
				local accepted = original(...)
				local bound, retained = capture.bind_history_scope(history_owner)
				if bound then scope = retained end
				return accepted
			end
			local owner, token, capability = bind(capture, controls)
			helpers.assert_eq(capability.start(owner, token, controls.options), true)
			controls.verified()
			controls.open()
			local history_token = scope.identity()
			helpers.assert_eq(capability.stop_lease(owner, token), false)
			observed.tasks[3].settle()
			helpers.assert_eq(scope.settled(history_token), true)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), false)
			helpers.assert_eq(scope.release(history_owner, history_token), true)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), true)
			helpers.assert_eq(capture.status().reason, "owned_runtime_unbound")
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(#observed.spawns, 3)
		end)
	end)
end)

--- Independently frozen control for retained final accounting settlement debt.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
helpers.describe("unavailable source retained final settlement debt", function()
	helpers.it("does not report settled while final Accounting.release is refused", function()
		with_capture(function(capture, observed, controls)
			local allow = true
			helpers.assert_eq(controls.mode.bind_settlement({}, function() return allow end), true)
			helpers.assert_eq(capture.init(controls.dependencies), true)
			local owner = {}
			local capability = assert(capture.bind_managed_source(owner))
			local token = capability.identity(owner)
			helpers.assert_eq(capability.select_unavailable(owner, token, "owned_runtime_unbound"), true)
			helpers.assert_eq(capture.status().settled, true)
			allow = false
			helpers.assert_eq(capability.shutdown(owner, token), false)
			helpers.assert_eq(capability.retired(owner, token), false)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(capture.status().settled, false,
				"Retained final accounting settlement debt must remain visible after the release frame unwinds")
			helpers.assert_eq(#observed.spawns, 0)
			allow = true
			helpers.assert_eq(capability.shutdown(owner, token), true)
			helpers.assert_eq(capability.retired(owner, token), true)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(capture.status().settled, true)
		end)
	end)
end)
