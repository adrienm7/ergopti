--- tests/unit/modules/keylogger/test_context_tracker_correlated_observation.lua

--- Independently exercises opt-in native window/app PID correlation without permission history.
local helpers = require("tests.helpers")
local Privacy = require("modules.keylogger.privacy_context")

local function with_fixture(callback)
	return helpers.with_stub_scope({ "modules.keylogger.context_tracker", "adapters.secure_field_detector",
		"adapters.physical_observation_clock", "keylogger.physical_context_observation" }, function()
		local controls = { paused = false, no_window = false, no_focus = false, no_frontmost = false,
			throw_property = nil, title = "Ordinary window", role = "AXTextField", subrole = nil,
			queries = {}, clock = 100, records = {}, failures = {}, decision_calls = 0 }
		local function query(name)
			controls.queries[#controls.queries + 1] = name
			if controls.on_query then controls.on_query(name) end
			if controls.throw_property == name then error("native refusal: " .. name) end
		end
		local element = { attributeValue = function(_, name)
			query(name)
			if name == "AXRole" then return controls.role end
			if name == "AXSubrole" then return controls.subrole end
			if name == "AXValue" then return "NOT-EMITTED-FIELD-VALUE" end
		end }
		local app_element = { attributeValue = function(_, name)
			query(name); if not controls.no_focus then return element end
		end }
		local app = {
			name = function() query("name"); return "Editor" end,
			bundleID = function() query("bundleID"); return "test.editor" end,
			path = function() query("path"); return "/Applications/Editor.app" end,
			pid = function() query("pid"); return 4242 end,
		}
		local window_app = { pid = function() query("window_pid"); return controls.window_pid end }
		controls.window_pid = 4242
		local window = { application = function()
			query("window_application"); if not controls.no_window_app then return window_app end
		end, title = function() query("title"); return controls.title end,
			isFullScreen = function() query("fullscreen"); return false end }
		local observer = {
			addWatcher = function(self) query("addWatcher"); return self end,
			removeWatcher = function(self) query("removeWatcher"); return self end,
			callback = function(self, cb) controls.ax_callback = cb; if controls.refuse_callback then return false end; return self end,
			start = function(self) query("start"); if controls.refuse_start then return false end; return self end,
			stop = function(self) query("stop"); return self end,
		}
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function()
				controls.clock = controls.clock + 1
				if controls.clock_reader then return controls.clock_reader() end
				return controls.clock
			end },
			application = { watcher = { activated = 1 }, frontmostApplication = function()
				query("frontmost"); if not controls.no_frontmost then return app end
			end },
			window = { focusedWindow = function() query("window"); if not controls.no_window then return window end end },
			axuielement = { applicationElementForPID = function() query("ax_app"); return app_element end,
				applicationElement = function() query("observer_app"); return app_element end,
				windowElement = function() query("ax_window"); return nil end,
				observer = { new = function() query("observer_new"); return observer end } },
		})
		local state = { is_enabled = true, disabled_apps = {}, active_app_name = "Old",
			active_app_bundle = "test.old", active_app_path = "/Old.app", active_app_pid = 12, active_app_start = 0,
			is_private_window = false, is_secure_field = false, private_filter_enabled = true,
			secure_field_filter_enabled = true, system_auth_filter_enabled = true,
			buffer_events = {}, buffer_text = "", rich_chunks = {}, last_time = 0 }
		helpers.assert_true(tracker.init(state, { append_log = function() return true end,
			flush_buffer = function() return true end, log_app_switch = function() return true end },
			function() return controls.paused end))
		controls.bind = function(owner, receive, capacity, decision)
			helpers.assert_eq(type(tracker.bind_physical_correlated_context_observer), "function")
			return tracker.bind_physical_correlated_context_observer(owner or {}, capacity or 128,
				receive or function(record) controls.records[#controls.records + 1] = record; return true end,
				function(reason) controls.failures[#controls.failures + 1] = reason end,
				decision or function()
					controls.decision_calls = controls.decision_calls + 1
					return state.is_enabled and not controls.paused and Privacy.allows_logging(state)
				end)
		end
		controls.activate = function() return tracker.app_watcher_cb("Editor", 1, app) end
		controls.focus = function(focused) return controls.ax_callback(focused, "AXFocusedUIElementChanged", observer) end
		controls.element, controls.app, controls.observer = element, app, observer
		controls.window, controls.window_app = window, window_app
		callback(tracker, state, controls)
	end)
end

local function last(records) return records[#records] end
local function assert_denied(record)
	helpers.assert_eq(record.allowed, false); helpers.assert_eq(record.complete, false)
	helpers.assert_eq(record.app, nil); helpers.assert_eq(record.title, nil); helpers.assert_eq(record.value, nil)
end


local function assert_correlated_denied(record)
	helpers.assert_eq(record.complete, false); helpers.assert_eq(record.allowed, false)
	helpers.assert_eq(record.correlated, false)
	helpers.assert_eq(record.title, nil); helpers.assert_eq(record.value, nil)
end
local function count_query(c, name)
	local n = 0; for _, query in ipairs(c.queries) do if query == name then n = n + 1 end end; return n
end

helpers.describe("explicit dormant correlated context", function()
	helpers.it("adds no identity query to ordinary unbound context writes", function()
		with_fixture(function(tracker, _, c)
			c.activate(); tracker.update_private_status(); c.focus(c.element)
			helpers.assert_eq(count_query(c, "window_application"), 0)
			helpers.assert_eq(count_query(c, "window_pid"), 0)
			helpers.assert_eq(#c.records, 0); helpers.assert_eq(c.decision_calls, 0)
		end)
	end)

	helpers.it("seeds denied correlation without probing a cached window or app", function()
		with_fixture(function(_, _, c)
			helpers.assert_true(c.bind()); helpers.assert_eq(#c.queries, 0)
			assert_correlated_denied(last(c.records)); helpers.assert_eq(last(c.records).fields_complete, false)
		end)
	end)

	helpers.it("qualifies only the exact native window app PID under an already denied boundary", function()
		with_fixture(function(_, _, c)
			c.bind(); c.on_query = function() assert_correlated_denied(last(c.records)) end
			c.activate(); c.on_query = nil
			helpers.assert_eq(count_query(c, "window_application"), 1)
			helpers.assert_eq(count_query(c, "window_pid"), 1)
			helpers.assert_eq(last(c.records).fields_complete, true)
			helpers.assert_eq(last(c.records).correlated, true)
			helpers.assert_eq(last(c.records).complete, true); helpers.assert_eq(last(c.records).allowed, true)
			helpers.assert_eq(last(c.records).app.pid, 4242)
			helpers.assert_eq(last(c.records).title, nil); helpers.assert_eq(last(c.records).value, nil)
		end)
	end)

	helpers.it("keeps complete policy fields denied when the native window belongs to another app", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window_pid = 9999; c.activate()
			assert_correlated_denied(last(c.records)); helpers.assert_eq(last(c.records).fields_complete, true)
			helpers.assert_eq(c.decision_calls, 0)
		end)
	end)

	helpers.it("keeps an unavailable window application denied without asking a guessed PID", function()
		with_fixture(function(_, _, c)
			c.bind(); c.no_window_app = true; c.activate()
			assert_correlated_denied(last(c.records)); helpers.assert_eq(count_query(c, "window_pid"), 0)
		end)
	end)

	helpers.it("keeps an unsupported application identity method denied", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window.application = nil; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps an application identity native refusal denied while preserving legacy fields", function()
		with_fixture(function(_, state, c)
			c.bind(); c.throw_property = "window_application"; c.activate()
			assert_correlated_denied(last(c.records)); helpers.assert_eq(state.is_private_window, false)
			helpers.assert_eq(count_query(c, "window_pid"), 0)
		end)
	end)

	helpers.it("keeps a window PID native refusal denied", function()
		with_fixture(function(_, _, c)
			c.bind(); c.throw_property = "window_pid"; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps a nil native window PID denied", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window_pid = nil; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps a string native window PID denied without coercion", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window_pid = "4242"; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps a floating representation of the correct native PID denied", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window_pid = 4242.0; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps a negative native window PID denied", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window_pid = -1; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps a zero native window PID denied", function()
		with_fixture(function(_, _, c)
			c.bind(); c.window_pid = 0; c.activate(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("keeps NaN and infinity native window PIDs denied", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.window_pid = 0 / 0; c.activate(); assert_correlated_denied(last(c.records))
			c.window_pid = math.huge; tracker.update_private_status(); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("never invokes equality on a forged native PID value", function()
		with_fixture(function(_, _, c)
			local calls = 0; c.bind(); c.window_pid = setmetatable({}, { __eq = function() calls = calls + 1; return true end })
			c.activate(); assert_correlated_denied(last(c.records)); helpers.assert_eq(calls, 0)
		end)
	end)

	helpers.it("keeps a missing focused window denied despite the unchanged nonprivate cache", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); c.no_window = true; tracker.update_private_status()
			assert_correlated_denied(last(c.records)); helpers.assert_eq(state.is_private_window, false)
			helpers.assert_eq(last(c.records).fields_complete, false)
		end)
	end)

	helpers.it("resynchronizes identity from the current focused window without stale reuse", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.window_pid = 9999; helpers.assert_true(tracker.resync_context())
			assert_correlated_denied(last(c.records)); c.window_pid = 4242
			helpers.assert_true(tracker.resync_context()); helpers.assert_eq(last(c.records).correlated, true)
		end)
	end)

	helpers.it("preserves private filtering after native identity qualification", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.title = "SECRET Private Browsing"; tracker.update_private_status()
			helpers.assert_eq(last(c.records).correlated, true); helpers.assert_eq(last(c.records).complete, true)
			helpers.assert_eq(last(c.records).private, true); helpers.assert_eq(last(c.records).allowed, false)
		end)
	end)

	helpers.it("keeps user-disabled private filtering under the existing policy predicate", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); state.private_filter_enabled = false
			c.title = "Private Browsing"; tracker.update_private_status()
			helpers.assert_eq(last(c.records).correlated, true); helpers.assert_eq(last(c.records).private, true)
			helpers.assert_eq(last(c.records).allowed, true)
		end)
	end)

	helpers.it("denies app closure and cannot reuse its former window correlation", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); tracker.close_active_app(); assert_correlated_denied(last(c.records))
			c.activate(); helpers.assert_eq(last(c.records).correlated, true)
		end)
	end)

	helpers.it("keeps wrong-PID AX evidence incomplete despite an earlier matched window", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); helpers.assert_true(tracker.update_ax_observer(9999))
			helpers.assert_eq(last(c.records).fields_complete, false)
			helpers.assert_eq(last(c.records).complete, false); helpers.assert_eq(last(c.records).allowed, false)
		end)
	end)

	helpers.it("does not query window identity during paused refresh", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.paused = true; local queries = #c.queries
			tracker.update_private_status(); assert_correlated_denied(last(c.records)); helpers.assert_eq(#c.queries, queries)
		end)
	end)

	helpers.it("does not query a PID after identity application lookup reenters the writer", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.on_query = function(name)
				if name == "window_application" then c.on_query = nil; tracker.update_private_status() end
			end
			c.activate(); helpers.assert_eq(count_query(c, "window_pid"), 0)
			helpers.assert_eq(#c.failures, 1); assert_correlated_denied(last(c.records))
		end)
	end)

	helpers.it("does not query a PID after the exact owner detaches during application lookup", function()
		with_fixture(function(tracker, _, c)
			local owner = {}; local accepted, token = c.bind(owner); helpers.assert_true(accepted)
			c.on_query = function(name)
				if name == "window_application" then c.on_query = nil
					helpers.assert_true(tracker.unbind_physical_context_observer(owner, token))
				end
			end
			c.activate(); helpers.assert_eq(count_query(c, "window_pid"), 0)
			assert_correlated_denied(last(c.records)); helpers.assert_eq(#c.records, 2)
		end)
	end)

	helpers.it("keeps a successor denied when the owner is replaced inside native identity lookup", function()
		with_fixture(function(tracker, _, c)
			local owner, successor = {}, {}; local accepted, token = c.bind(owner); helpers.assert_true(accepted)
			c.on_query = function(name)
				if name == "window_application" then c.on_query = nil
					helpers.assert_true(tracker.unbind_physical_context_observer(owner, token)); helpers.assert_true(c.bind(successor))
				end
			end
			c.activate(); helpers.assert_eq(count_query(c, "window_pid"), 0)
			assert_correlated_denied(last(c.records)); helpers.assert_eq(last(c.records).source, "binding")
			c.activate(); helpers.assert_eq(last(c.records).correlated, true)
		end)
	end)

	helpers.it("keeps a receiver-replaced owner generation denied until its own fresh writer", function()
		with_fixture(function(tracker, _, c)
			local owner, successor, switched = {}, {}, false
			c.bind(owner, function(record, token)
				c.records[#c.records + 1] = record
				if record.source == "activation" and record.stage == "boundary" and not switched then
					switched = true; helpers.assert_true(tracker.unbind_physical_context_observer(owner, token))
					helpers.assert_true(c.bind(successor))
				end
				return true
			end)
			c.activate(); helpers.assert_eq(count_query(c, "window_application"), 0)
			assert_correlated_denied(last(c.records)); c.activate(); helpers.assert_eq(last(c.records).correlated, true)
		end)
	end)

	helpers.it("shares one exact owner slot with field-only observers and rejects forged detach equality", function()
		with_fixture(function(tracker, _, c)
			local owner, calls = {}, 0; local accepted, token = c.bind(owner); helpers.assert_true(accepted)
			local bound = tracker.bind_physical_context_observer({}, 128, function() return true end,
				function() end, function() return true end); helpers.assert_eq(bound, false)
			local forged = setmetatable({}, { __eq = function() calls = calls + 1; return true end })
			helpers.assert_eq(tracker.unbind_physical_context_observer(forged, token), false)
			helpers.assert_eq(tracker.unbind_physical_context_observer(owner, forged), false)
			helpers.assert_eq(calls, 0); helpers.assert_true(tracker.unbind_physical_context_observer(owner, token))
		end)
	end)

	helpers.it("does not query identity after the receipt channel is retired by exhaustion", function()
		with_fixture(function(_, _, c)
			c.bind(nil, nil, 1); c.activate(); helpers.assert_eq(count_query(c, "window_application"), 0)
			helpers.assert_eq(#c.failures, 1); assert_correlated_denied(last(c.records))
		end)
	end)
end)

helpers.describe("writer-scoped native correlation freshness", function()
	helpers.it("does not promote a former window identity proof through a later secure-only writer", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.focus(c.element)
			helpers.assert_eq(last(c.records).fields_complete, true)
			assert_correlated_denied(last(c.records))
			helpers.assert_eq(count_query(c, "window_application"), 1)
			tracker.update_private_status(); helpers.assert_eq(last(c.records).correlated, true)
		end)
	end)

	helpers.it("does not promote a former window identity through direct healthy AX setup", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); helpers.assert_true(tracker.update_ax_observer(4242))
			assert_correlated_denied(last(c.records)); helpers.assert_eq(last(c.records).fields_complete, true)
		end)
	end)
end)

helpers.describe("field-only ownership remains explicit", function()
	helpers.it("adds no identity query or correlation field to a field-only bound subscriber", function()
		with_fixture(function(tracker, _, c)
			helpers.assert_true(tracker.bind_physical_context_observer({}, 128, function(record)
				c.records[#c.records + 1] = record; return true
			end, function(reason) error(reason) end, function() return true end))
			c.activate(); helpers.assert_eq(count_query(c, "window_application"), 0)
			helpers.assert_eq(count_query(c, "window_pid"), 0)
			helpers.assert_eq(last(c.records).complete, true)
			helpers.assert_eq(last(c.records).fields_complete, nil); helpers.assert_eq(last(c.records).correlated, nil)
		end)
	end)
end)

helpers.describe("native app PID provenance", function()
	helpers.it("does not treat a callback-mutated CoreState PID as the app identity actually read", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); c.window_pid = 9999
			c.on_query = function(name) if name == "window_pid" then state.active_app_pid = 9999 end end
			tracker.update_private_status(); assert_correlated_denied(last(c.records)); helpers.assert_eq(c.decision_calls, 1)
		end)
	end)
end)
