--- tests/unit/modules/keylogger/test_context_tracker_physical_observation.lua

--- Drives actual context writers; receipts never substitute for retained history.
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
		local window = { title = function() query("title"); return controls.title end,
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
			helpers.assert_eq(type(tracker.bind_physical_context_observer), "function")
			return tracker.bind_physical_context_observer(owner or {}, capacity or 128,
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
		callback(tracker, state, controls)
	end)
end

local function last(records) return records[#records] end
local function assert_denied(record)
	helpers.assert_eq(record.allowed, false); helpers.assert_eq(record.complete, false)
	helpers.assert_eq(record.app, nil); helpers.assert_eq(record.title, nil); helpers.assert_eq(record.value, nil)
end

helpers.describe("context tracker dormant physical observation", function()
	helpers.it("keeps ordinary unbound context and nil-focus writer behavior without observation work", function()
		with_fixture(function(tracker, state, c)
			c.activate(); helpers.assert_eq(state.active_app_bundle, "test.editor")
			helpers.assert_eq(state.is_private_window, false)
			c.focus(nil); helpers.assert_eq(state.is_secure_field, false)
			helpers.assert_eq(tracker.close_active_app(), false, "The tiny native interval rounds to zero milliseconds")
			helpers.assert_eq(#c.records, 0); helpers.assert_eq(c.decision_calls, 0)
			helpers.assert_eq(c.clock, 103, "Only the three pre-existing legacy timing reads run")
		end)
	end)

	helpers.it("starts denied without promoting cached context or reading native state", function()
		with_fixture(function(_, _, c)
			helpers.assert_true(c.bind())
			helpers.assert_eq(#c.queries, 0); helpers.assert_eq(c.decision_calls, 0)
			helpers.assert_eq(c.records, {{ kind = "physical_context", revision = 1, at = 101,
				source = "binding", stage = "boundary", complete = false, allowed = false }})
		end)
	end)

	helpers.it("denies before activation native queries and completes only copied fully refreshed policy", function()
		with_fixture(function(_, state, c)
			helpers.assert_true(c.bind())
			c.on_query = function() helpers.assert_eq(last(c.records).stage, "boundary"); assert_denied(last(c.records)) end
			c.activate(); c.on_query = nil
			helpers.assert_eq(#c.records, 3)
			helpers.assert_eq(c.records[2].at, 102)
			helpers.assert_eq(last(c.records), { kind = "physical_context", revision = 3, at = 105,
				source = "activation", stage = "complete", complete = true, allowed = true,
				app = { name = "Editor", bundle_id = "test.editor", path = "/Applications/Editor.app", pid = 4242 },
				private = false, secure = false })
			state.active_app_bundle = "external.fixture.mutation"
			helpers.assert_eq(last(c.records).app.bundle_id, "test.editor")
			helpers.assert_eq(c.decision_calls, 1)
		end)
	end)

	helpers.it("observes private-window changes without emitting the window title or document", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.title = "SECRET TITLE - Private Browsing"
			tracker.update_private_status()
			helpers.assert_eq(#c.records, 5); helpers.assert_eq(c.records[4].stage, "boundary")
			helpers.assert_eq(last(c.records).complete, true); helpers.assert_eq(last(c.records).allowed, false)
			helpers.assert_eq(last(c.records).private, true)
			helpers.assert_eq(last(c.records).title, nil); helpers.assert_eq(last(c.records).document, nil)
		end)
	end)

	helpers.it("keeps paused private refresh explicitly incomplete without native window queries", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.paused = true; local reads = #c.queries
			tracker.update_private_status()
			helpers.assert_eq(#c.queries, reads); assert_denied(last(c.records))
			helpers.assert_eq(last(c.records).stage, "incomplete")
		end)
	end)

	helpers.it("does not promote stale private state when resync happens inside pause", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); c.paused = true; c.title = "Private Browsing"
			helpers.assert_true(tracker.resync_context())
			helpers.assert_eq(state.is_private_window, false, "Legacy skipped refresh remains unchanged")
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).source, "resync")
			c.paused = false; tracker.update_private_status()
			helpers.assert_eq(last(c.records).complete, true); helpers.assert_eq(last(c.records).allowed, false)
		end)
	end)

	helpers.it("does not publish stale app identity after a refused resync property read", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); state.active_app_bundle = "cached.previous.identity"; c.throw_property = "bundleID"
			helpers.assert_true(tracker.resync_context())
			helpers.assert_eq(state.active_app_bundle, "cached.previous.identity")
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).stage, "incomplete")
		end)
	end)

	helpers.it("observes nil-element AX assignment as unknown instead of accepting its legacy false cache", function()
		with_fixture(function(_, state, c)
			c.bind(); c.activate(); c.focus(nil)
			helpers.assert_eq(state.is_secure_field, false)
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).source, "secure_focus")
			c.focus(c.element)
			helpers.assert_eq(last(c.records).complete, true); helpers.assert_eq(last(c.records).allowed, true)
		end)
	end)

	helpers.it("keeps unavailable AX focus denied across activation despite the unchanged false cache", function()
		with_fixture(function(_, state, c)
			c.bind(); c.no_focus = true; c.activate()
			helpers.assert_eq(state.is_secure_field, false); assert_denied(last(c.records))
			helpers.assert_eq(last(c.records).stage, "incomplete")
		end)
	end)

	helpers.it("observes app closure as a denied boundary even when the legacy interval is empty", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); tracker.close_active_app()
			helpers.assert_eq(state.active_app_name, nil); assert_denied(last(c.records))
			helpers.assert_eq(last(c.records).source, "closure")
			local count = #c.records; helpers.assert_eq(tracker.close_active_app(), false)
			helpers.assert_eq(#c.records, count + 2); assert_denied(last(c.records))
		end)
	end)

	helpers.it("keeps failed frontmost capture denied without reusing previous observed authority", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate(); c.no_frontmost = true
			helpers.assert_eq(tracker.capture_frontmost_app(), false); assert_denied(last(c.records))
		end)
	end)

	helpers.it("retires reentrant native queries before any completion can escape", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.on_query = function(name)
				if name == "title" then c.on_query = nil; tracker.update_private_status() end
			end
			c.activate(); helpers.assert_eq(#c.failures, 1)
			helpers.assert_eq(#c.records, 2); assert_denied(last(c.records))
		end)
	end)

	helpers.it("keeps a successor denied when an initial boundary receiver detaches and rebinds", function()
		with_fixture(function(tracker, _, c)
			local owner, successor, token, successor_token, switched = {}, {}, nil, nil, false
			local ok; ok, token = c.bind(owner, function(record, identity)
				c.records[#c.records + 1] = record
				if record.source == "activation" and record.stage == "boundary" and not switched then
					switched = true; helpers.assert_true(tracker.unbind_physical_context_observer(owner, identity))
					local accepted; accepted, successor_token = c.bind(successor)
					helpers.assert_true(accepted)
				end
				return true
			end)
			helpers.assert_true(ok); c.activate()
			helpers.assert_eq(#c.records, 3); helpers.assert_eq(last(c.records).source, "binding"); assert_denied(last(c.records))
			c.activate(); helpers.assert_eq(last(c.records).complete, true)
			helpers.assert_eq(tracker.unbind_physical_context_observer(owner, token), false)
			helpers.assert_true(tracker.unbind_physical_context_observer(successor, successor_token))
		end)
	end)

	helpers.it("retires an unknown native clock and never manufactures a timestamp", function()
		with_fixture(function(_, _, c)
			c.clock_reader = function() return 42.0 end
			helpers.assert_eq(c.bind(), false); helpers.assert_eq(#c.records, 0); helpers.assert_eq(#c.failures, 1)
		end)
	end)

	helpers.it("retires exhaustion without evicting observations or releasing the exact owner", function()
		with_fixture(function(tracker, _, c)
			local owner = {}; local ok, token = c.bind(owner, nil, 2); helpers.assert_true(ok)
			c.activate(); helpers.assert_eq(#c.records, 2); helpers.assert_eq(#c.failures, 1)
			helpers.assert_eq(c.bind(), false)
			helpers.assert_true(tracker.unbind_physical_context_observer(owner, token))
			helpers.assert_true(c.bind())
		end)
	end)

	helpers.it("never invokes caller equality to detach a forged observation identity", function()
		with_fixture(function(tracker, _, c)
			local owner, calls = {}, 0; local ok, token = c.bind(owner); helpers.assert_true(ok)
			local fake = setmetatable({}, { __eq = function() calls = calls + 1; return true end })
			helpers.assert_eq(tracker.unbind_physical_context_observer(fake, token), false)
			helpers.assert_eq(tracker.unbind_physical_context_observer(owner, fake), false)
			helpers.assert_eq(calls, 0); helpers.assert_true(tracker.unbind_physical_context_observer(owner, token))
		end)
	end)

	helpers.it("keeps a throwing native writer denied and preserves its existing exception", function()
		with_fixture(function(tracker, _, c)
			c.bind(); c.activate()
			helpers.assert_eq(last(c.records).complete, true); helpers.assert_eq(last(c.records).allowed, true)
			helpers.assert_eq(last(c.records).app.pid, 4242)
			c.throw_property = "title"
			local ok, reason = pcall(tracker.update_private_status)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("native refusal: title", 1, true) ~= nil)
			helpers.assert_eq(#c.failures, 1); assert_denied(last(c.records))
			helpers.assert_true(c.failures[1]:find("Physical context writer failed", 1, true) ~= nil)
			local retired_count = #c.records
			c.throw_property = nil; tracker.update_private_status()
			helpers.assert_eq(#c.records, retired_count); helpers.assert_eq(#c.failures, 1)
		end)
	end)

	helpers.it("does not publish a completed verdict when the trusted persistence predicate reenters", function()
		with_fixture(function(tracker, _, c)
			c.bind(nil, nil, nil, function() tracker.update_private_status(); return true end)
			c.activate(); helpers.assert_eq(#c.failures, 1)
			helpers.assert_eq(#c.records, 2); assert_denied(last(c.records))
		end)
	end)
end)

helpers.describe("actual secure detector refresh completeness", function()
	helpers.it("preserves default refresh return and exact existing query inventory", function()
		with_fixture(function(_, _, c)
			local detector = require("adapters.secure_field_detector")
			helpers.assert_eq(detector.refresh(), nil)
			helpers.assert_eq(c.queries, { "frontmost", "pid", "ax_app", "AXFocusedUIElement", "AXRole", "AXSubrole" })
			helpers.assert_eq(detector.isSecureField(), false)
			c.queries = {}; local complete, pid
			helpers.assert_eq(detector.refresh(function(known, inspected) complete, pid = known, inspected end), nil)
			helpers.assert_eq(c.queries, { "frontmost", "pid", "ax_app", "AXFocusedUIElement", "AXRole", "AXSubrole" })
			helpers.assert_eq(complete, true); helpers.assert_eq(pid, 4242)
		end)
	end)

	helpers.it("distinguishes unavailable focus from a conclusive nonsecure classification without extra queries", function()
		with_fixture(function(_, _, c)
			local detector = require("adapters.secure_field_detector"); c.no_focus = true
			local complete; detector.refresh(function(known) complete = known end)
			helpers.assert_eq(complete, false); helpers.assert_eq(detector.isSecureField(), false)
			helpers.assert_eq(c.queries, { "frontmost", "pid", "ax_app", "AXFocusedUIElement" })
		end)
	end)

	helpers.it("distinguishes refused AX reads while preserving the conservative legacy true cache", function()
		with_fixture(function(_, _, c)
			local detector = require("adapters.secure_field_detector"); c.throw_property = "AXSubrole"
			local complete; detector.refresh(function(known) complete = known end)
			helpers.assert_eq(complete, false); helpers.assert_eq(detector.isSecureField(), true)
		end)
	end)
end)


helpers.describe("context writer incomplete evidence and callback retirement", function()
	helpers.it("keeps a missing window denied despite the legacy reset to nonprivate", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); c.no_window = true; tracker.update_private_status()
			helpers.assert_eq(state.is_private_window, false); assert_denied(last(c.records))
			c.no_window = false; tracker.update_private_status()
			helpers.assert_eq(last(c.records).complete, true)
		end)
	end)

	helpers.it("keeps missing AX role evidence denied instead of treating its false cache as classification", function()
		with_fixture(function(_, state, c)
			c.bind(); c.role = nil; c.activate()
			helpers.assert_eq(state.is_secure_field, false); assert_denied(last(c.records))
		end)
	end)

	helpers.it("keeps rejected AX observer acquisition denied after a valid app refresh", function()
		with_fixture(function(_, _, c)
			c.bind(); c.throw_property = "observer_new"; c.activate()
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).stage, "incomplete")
		end)
	end)

	helpers.it("preserves the legacy cache even when its optional outer completeness observer throws", function()
		with_fixture(function(_, _, c)
			local detector = require("adapters.secure_field_detector")
			c.role = "AXSecureTextField"
			local callbacks, complete, pid = 0, nil, nil
			local ok, reason = pcall(detector.refresh, function(known, inspected)
				callbacks, complete, pid = callbacks + 1, known, inspected
				error("optional observer refused")
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("optional observer refused", 1, true) ~= nil)
			helpers.assert_eq(callbacks, 1); helpers.assert_eq(complete, true); helpers.assert_eq(pid, 4242)
			helpers.assert_eq(detector.isSecureField(), true)
			helpers.assert_eq(c.queries, { "frontmost", "pid", "ax_app", "AXFocusedUIElement", "AXRole", "AXSubrole" })
			c.queries = {}
			helpers.assert_eq(detector.refresh(function(known, inspected)
				callbacks, complete, pid = callbacks + 1, known, inspected
			end), nil)
			helpers.assert_eq(callbacks, 2); helpers.assert_eq(complete, true); helpers.assert_eq(pid, 4242)
			helpers.assert_eq(detector.isSecureField(), true)
			helpers.assert_eq(c.queries, { "frontmost", "pid", "ax_app", "AXFocusedUIElement", "AXRole", "AXSubrole" })
		end)
	end)

	helpers.it("retires refused completion without accepting further context receipts", function()
		with_fixture(function(tracker, _, c)
			local owner = {}; local ok, token = c.bind(owner, function(record)
				c.records[#c.records + 1] = record; return record.stage ~= "complete"
			end)
			helpers.assert_true(ok); c.activate(); helpers.assert_eq(#c.failures, 1)
			local count = #c.records; tracker.update_private_status(); helpers.assert_eq(#c.records, count)
			helpers.assert_true(tracker.unbind_physical_context_observer(owner, token))
		end)
	end)
end)

helpers.describe("context observer acquisition authority", function()
	helpers.it("keeps a refused native start denied after a complete bootstrap classification", function()
		with_fixture(function(_, _, c)
			c.bind(); c.refuse_start = true; c.activate()
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).stage, "incomplete")
		end)
	end)

	helpers.it("keeps a refused callback registration denied after a complete bootstrap classification", function()
		with_fixture(function(_, _, c)
			c.bind(); c.refuse_callback = true; c.activate()
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).stage, "incomplete")
		end)
	end)

	helpers.it("does not classify current app authority from an observer attached to another PID", function()
		with_fixture(function(tracker, state, c)
			c.bind(); c.activate(); helpers.assert_true(tracker.update_ax_observer(9999))
			helpers.assert_eq(state.active_app_pid, 4242)
			assert_denied(last(c.records)); helpers.assert_eq(last(c.records).stage, "incomplete")
			c.focus(c.element); assert_denied(last(c.records))
		end)
	end)
end)
