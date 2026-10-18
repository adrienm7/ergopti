--- tests/support/modules/keylogger/aggregation/hs274_duplicate_count_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_hs274_duplicate_count
--- DESCRIPTION:
--- Prelude shared by the test_hs274_duplicate_count_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local Accounting = require("tests.support.hs274_accounting_fixture")

-- macOS virtual keycodes of the shipped CapsLock tap (tap = Return).
local KEYCODE_CAPS_LOCK = 57
local KEYCODE_RETURN = 36
-- The left Command modifier, a flagsChanged key.
local KEYCODE_LEFT_COMMAND = 55

--- Returns the meta.kc of the only recorded typing event.
--- @param scenario table HS-274 accounting scenario.
--- @return number|nil kc
local function only_typing_kc(scenario)
	local events = scenario.typing_events()
	helpers.assert_eq(#events, 1, "the key must produce exactly one typing event")
	return events[1][3].kc
end






local function with_system_policy_callback(vector, body)
	Accounting.run(function(scenario)
		local startup_tracker = package.loaded["modules.keylogger.context_tracker"]
		local lifecycle = package.loaded["adapters.process_lifecycle"]
		local manager = package.loaded["modules.keylogger.log_manager"]
		local previous_activation, previous_append = lifecycle.onAppActivate, manager.append_log
		local ports = { "init", "app_watcher_cb", "update_private_status", "update_ax_observer",
			"capture_frontmost_app", "resync_context" }
		local previous_ports = {}
		for _, name in ipairs(ports) do previous_ports[name] = startup_tracker[name] end
		helpers.with_fresh_modules({ "modules.keylogger.context_tracker", "adapters.secure_field_detector" }, function()
			local native = _G.hs
			local previous_app, previous_window = native.application, native.window
			local previous_ax, previous_caffeinate = native.axuielement, native.caffeinate
			local previous_clock = native.timer.absoluteTime
			local controls = { clock_ms = 1000, role_reads = 0, subrole_reads = 0,
				title_reads = 0, observers = {}, metadata = {} }
			local function application(name, bundle, pid)
				return { name = function() return name end, bundleID = function() return bundle end,
					path = function() return "/Applications/Fixture.app" end, pid = function() return pid end }
			end
			local apps = {
				auth = application("Authentication Dialog", vector.auth_bundle_id, 4242),
				ordinary = application("Editor", "test.editor", 4848),
			}
			controls.current_app = apps[vector.startup_application]
			local ordinary = { attributeValue = function(_, name)
				if name == "AXRole" then controls.role_reads = controls.role_reads + 1; return "AXTextField" end
				if name == "AXSubrole" then controls.subrole_reads = controls.subrole_reads + 1; return nil end
				if name == "AXValue" then return "" end
			end }
			local app_element = { attributeValue = function(_, name)
				if name == "AXFocusedUIElement" then return ordinary end
			end }
			local window = { title = function() controls.title_reads = controls.title_reads + 1; return "Public document" end,
				isFullScreen = function() return false end,
				application = function() return controls.current_app end }
			local tracker, keylogger
			local called, failure = xpcall(function()
				native.timer.absoluteTime = function() return controls.clock_ms * 1000000 end
				native.application = { watcher = { activated = 1 }, frontmostApplication = function() return controls.current_app end }
				native.window = { focusedWindow = function() return window end }
				native.axuielement = {
					applicationElementForPID = function() return app_element end,
					applicationElement = function() return app_element end,
					windowElement = function() return nil end,
					observer = { new = function()
						local owner = { starts = 0, stops = 0 }
						owner.addWatcher = function(self) return self end
						owner.removeWatcher = function(self) return self end
						owner.callback = function(self, callback) self.retained_callback = callback; return self end
						owner.start = function(self) self.starts = self.starts + 1; return self end
						owner.stop = function(self) self.stops = self.stops + 1; return self end
						controls.observers[#controls.observers + 1] = owner
						return owner
					end },
				}
				native.caffeinate = { watcher = { new = function()
					return { start = function(self) return self end, stop = function(self) return self end }
				end } }
				tracker = require("modules.keylogger.context_tracker")
				for _, name in ipairs(ports) do if name ~= "init" then startup_tracker[name] = tracker[name] end end
				startup_tracker.init = function(state, log_manager, paused)
					controls.startup_dependencies = { state, log_manager, paused }
					return tracker.init(state, log_manager, paused)
				end
				lifecycle.onAppActivate = function(callback)
					controls.activation_callback = callback
					return previous_activation(callback)
				end
				manager.append_log = function(entry) controls.metadata[#controls.metadata + 1] = entry; return true end
				keylogger = package.loaded["modules.keylogger.init"]
				-- Only the actual public writer establishes initial policy, never raw state.
				keylogger.set_system_auth_filter_enabled(vector.initial_system_filter)
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, vector.initial_system_filter)
				scenario.state.is_enabled = false
				helpers.assert_eq(keylogger.start({ is_paused = function() return false end }), true)
				local deps = controls.startup_dependencies
				helpers.assert_eq(type(deps), "table")
				helpers.assert_eq(deps[1], scenario.state)
				helpers.assert_eq(deps[2], manager)
				helpers.assert_eq(type(deps[3]), "function")
				helpers.assert_nil(deps[4], "Root three-argument context owner is preserved")
				helpers.assert_eq(tracker.init(deps[1], deps[2], deps[3]), true)
				helpers.assert_eq(type(controls.activation_callback), "function")
				local retained_activation = controls.activation_callback
				controls.activate = function(kind)
					helpers.assert_true(kind == "auth" or kind == "ordinary")
					controls.current_app = apps[kind]
					local roles, subroles, titles = controls.role_reads, controls.subrole_reads, controls.title_reads
					helpers.assert_eq(_G.hs, native)
					helpers.assert_eq(package.loaded["modules.keylogger.context_tracker"], tracker)
					helpers.assert_eq(controls.activation_callback, retained_activation)
					retained_activation(controls.current_app:name(), controls.current_app)
					helpers.assert_true(controls.role_reads > roles and controls.subrole_reads > subroles,
						"Real AX classification must establish rawsecure=false independently of the auth bundle")
					helpers.assert_eq(controls.title_reads, titles + 1)
					helpers.assert_eq(scenario.state.active_app_bundle, kind == "auth" and vector.auth_bundle_id or "test.editor")
					helpers.assert_eq(scenario.state.is_secure_field, false)
					helpers.assert_eq(scenario.state.is_private_window, false)
					helpers.assert_eq(keylogger.context_allows_logging(), kind ~= "auth" or scenario.state.system_auth_filter_enabled == false)
					helpers.assert_eq(scenario.state.ax_observer, controls.observers[#controls.observers])
				end
				controls.activate(vector.startup_application)
				helpers.assert_eq(#scenario.system_events, 0)
				body(scenario, controls, keylogger)
			end, debug.traceback)
			local stopped_ok, stopped = true, true
			if keylogger then stopped_ok, stopped = pcall(keylogger.stop) end
			for _, name in ipairs(ports) do startup_tracker[name] = previous_ports[name] end
			lifecycle.onAppActivate, manager.append_log = previous_activation, previous_append
			native.application, native.window = previous_app, previous_window
			native.axuielement, native.caffeinate = previous_ax, previous_caffeinate
			native.timer.absoluteTime = previous_clock
			if not called then error(failure, 0) end
			helpers.assert_eq(stopped_ok, true)
			helpers.assert_eq(stopped, true)
			helpers.assert_true(#controls.observers >= 1)
			for _, owner in ipairs(controls.observers) do
				helpers.assert_eq(owner.starts, 1)
				helpers.assert_eq(owner.stops, 1)
			end
			helpers.assert_eq(scenario.state.ax_observer, nil)
		end)
	end)
end

local private_modifier_vectors = {
	{
		id = "windowFocused:ordinary_pair_control",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "ordinary@1000", "down55@1000", "up55@2000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:release_private_then_fresh_pair",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "ordinary@4000", "down55@5000", "up55@6000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:whole_private_interval_without_key_transition",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:press_private_then_crossing_release",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "ordinary@4000", "up55@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:whole_pair_inside_private",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "up55@4000", "ordinary@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:private_release_then_private_repress",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "down55@4000", "ordinary@5000", "up55@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:disabled_private_interval_preserves_full_hold",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:disabled_private_pair_is_included",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "private@2000", "down55@3000", "up55@9000", "ordinary@9500", "down55@10000", "up55@11000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:enabling_private_filter_inside_private_cancels_hold",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "public_set_private_filter_enabled(true)@3000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowFocused:private_and_secure_overlap_stays_denied_until_both_exit",
		registered_event = "windowFocused",
		private_title = "Example - INCOGNITO",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "real_AX_secure@3000", "ordinary@4000", "up55@5000", "real_AX_ordinary@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:ordinary_pair_control",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "ordinary@1000", "down55@1000", "up55@2000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:release_private_then_fresh_pair",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "ordinary@4000", "down55@5000", "up55@6000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:whole_private_interval_without_key_transition",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:press_private_then_crossing_release",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "ordinary@4000", "up55@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:whole_pair_inside_private",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "private@2000", "down55@3000", "up55@4000", "ordinary@5000", "down55@6000", "up55@7000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:private_release_then_private_repress",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "up55@3000", "down55@4000", "ordinary@5000", "up55@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:disabled_private_interval_preserves_full_hold",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:disabled_private_pair_is_included",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "private@2000", "down55@3000", "up55@9000", "ordinary@9500", "down55@10000", "up55@11000" },
		expected = { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:enabling_private_filter_inside_private_cancels_hold",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "public_set_private_filter_enabled(false)", "down55@1000", "private@2000", "public_set_private_filter_enabled(true)@3000", "ordinary@4000", "up55@7000", "down55@8000", "up55@9000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
	{
		id = "windowTitleChanged:private_and_secure_overlap_stays_denied_until_both_exit",
		registered_event = "windowTitleChanged",
		private_title = "Example - Private Browsing",
		ordinary_title = "Public document",
		steps = { "down55@1000", "private@2000", "real_AX_secure@3000", "ordinary@4000", "up55@5000", "real_AX_ordinary@6000", "down55@7000", "up55@8000" },
		expected = { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } },
	},
}

local function with_private_window_callback(vector, body)
	Accounting.run(function(scenario)
		local startup_tracker = package.loaded["modules.keylogger.context_tracker"]
		local lifecycle = package.loaded["adapters.process_lifecycle"]
		local manager = package.loaded["modules.keylogger.log_manager"]
		local original_activation = lifecycle.onAppActivate
		local original_append = manager.append_log
		local port_names = { "init", "app_watcher_cb", "update_private_status", "update_ax_observer",
			"capture_frontmost_app", "resync_context" }
		local previous_ports = {}
		for _, name in ipairs(port_names) do previous_ports[name] = startup_tracker[name] end
		helpers.with_fresh_modules({ "modules.keylogger.context_tracker", "adapters.secure_field_detector" }, function()
			local native = _G.hs
			local previous_application, previous_window = native.application, native.window
			local previous_ax, previous_caffeinate = native.axuielement, native.caffeinate
			local previous_clock = native.timer.absoluteTime
			local controls = { clock_ms = 1000, title = vector.ordinary_title,
				title_reads = 0, role_reads = 0, subrole_reads = 0,
				filter_new = 0, subscriptions = 0, unsubscribes = 0,
				ax_starts = 0, ax_stops = 0, metadata = {} }
			local function element(role)
				return { attributeValue = function(_, name)
					if name == "AXRole" then controls.role_reads = controls.role_reads + 1; return role end
					if name == "AXSubrole" then controls.subrole_reads = controls.subrole_reads + 1; return nil end
					if name == "AXValue" then return "" end
				end }
			end
			local ordinary, secure = element("AXTextField"), element("AXSecureTextField")
			local app_element = { attributeValue = function(_, name)
				if name == "AXFocusedUIElement" then return ordinary end
			end }
			local app = { name = function() return "Firefox" end,
				bundleID = function() return "org.mozilla.firefox" end,
				path = function() return "/Applications/Firefox.app" end,
				pid = function() return 4242 end }
			local window = { title = function() controls.title_reads = controls.title_reads + 1; return controls.title end,
				isFullScreen = function() return false end, application = function() return app end }
			local observer = {
				addWatcher = function(self) return self end,
				removeWatcher = function(self) return self end,
				callback = function(self, callback) controls.ax_callback = callback; return self end,
				start = function(self) controls.ax_starts = controls.ax_starts + 1; return self end,
				stop = function(self) controls.ax_stops = controls.ax_stops + 1; return self end,
			}
			local filter = {
				subscribe = function(self, events, callback)
					controls.subscriptions = controls.subscriptions + 1
					controls.events, controls.window_callback = events, callback
					return self
				end,
				unsubscribeAll = function(self) controls.unsubscribes = controls.unsubscribes + 1; return self end,
			}
			local tracker, keylogger
			local called, failure = xpcall(function()
				native.timer.absoluteTime = function() return controls.clock_ms * 1000000 end
				native.application = { watcher = { activated = 1 }, frontmostApplication = function() return app end }
				native.window = { focusedWindow = function() return window end, filter = {
					windowFocused = "windowFocused", windowTitleChanged = "windowTitleChanged",
					new = function(browsers)
						controls.filter_new = controls.filter_new + 1
						controls.browsers = browsers
						return filter
					end,
				} }
				native.axuielement = {
					applicationElementForPID = function() return app_element end,
					applicationElement = function() return app_element end,
					windowElement = function() return nil end,
					observer = { new = function() return observer end },
				}
				native.caffeinate = { watcher = { new = function()
					return { start = function(self) return self end, stop = function(self) return self end }
				end } }
				tracker = require("modules.keylogger.context_tracker")
				for _, name in ipairs(port_names) do
					if name ~= "init" then startup_tracker[name] = tracker[name] end
				end
				startup_tracker.init = function(state, log_manager, paused, settle)
					controls.startup_dependencies = { state, log_manager, paused, settle }
					controls.forwarded_dependencies = { state, log_manager, paused, settle }
					return tracker.init(state, log_manager, paused, settle)
				end
				lifecycle.onAppActivate = function(callback)
					controls.activation_callback = callback
					return original_activation(callback)
				end
				-- Persistence-boundary recorder: the original fixture has no append_log.
				manager.append_log = function(entry) controls.metadata[#controls.metadata + 1] = entry; return true end
				keylogger = package.loaded["modules.keylogger.init"]
				scenario.state.is_enabled = false
				helpers.assert_eq(keylogger.start({ is_paused = function() return false end }), true)
				local deps = controls.startup_dependencies
				helpers.assert_eq(type(deps), "table")
				helpers.assert_eq(deps[1], scenario.state)
				helpers.assert_eq(deps[2], manager)
				helpers.assert_eq(type(deps[3]), "function")
				helpers.assert_eq(type(deps[4]), "function", "Only the actual production startup supplies settlement")
				for index = 1, 4 do helpers.assert_eq(controls.forwarded_dependencies[index], deps[index]) end
				helpers.assert_eq(tracker.init(deps[1], deps[2], deps[3], deps[4]), true)
				helpers.assert_eq(type(controls.activation_callback), "function")
				helpers.assert_eq(controls.unsubscribes, 0, "The actual activation must precede native filter retirement")
				controls.activation_callback("Firefox", app)
				helpers.assert_eq(scenario.state.active_app_bundle, "org.mozilla.firefox")
				helpers.assert_eq(scenario.state.is_secure_field, false)
				helpers.assert_eq(scenario.state.is_private_window, false)
				helpers.assert_eq(keylogger.context_allows_logging(), true)
				helpers.assert_true(controls.role_reads > 0 and controls.subrole_reads > 0,
					"The real AX classifier must establish ordinary secure state")
				helpers.assert_eq(controls.filter_new, 1)
				helpers.assert_eq(controls.subscriptions, 1)
				helpers.assert_eq(controls.events, { native.window.filter.windowFocused, native.window.filter.windowTitleChanged })
				helpers.assert_true(type(controls.browsers) == "table")
				local firefox_found = false
				for _, browser in ipairs(controls.browsers) do if browser == "Firefox" then firefox_found = true end end
				helpers.assert_eq(firefox_found, true)
				helpers.assert_eq(controls.window_callback, tracker.update_private_status)
				helpers.assert_eq(scenario.state.ax_observer, observer)
				helpers.assert_eq(controls.ax_starts, 1)
				helpers.assert_eq(type(controls.ax_callback), "function")
				helpers.assert_eq(#scenario.system_events, 0)
				controls.expected_secure = false
				controls.private = function(private)
					helpers.assert_eq(controls.unsubscribes, 0, "An unsubscribed window callback has no delivery authority")
					controls.title = private and vector.private_title or vector.ordinary_title
					local reads = controls.title_reads
					helpers.assert_eq(_G.hs, native)
					helpers.assert_eq(package.loaded["modules.keylogger.context_tracker"], tracker)
					helpers.assert_eq(controls.window_callback, tracker.update_private_status)
					helpers.assert_eq(scenario.state.is_secure_field, controls.expected_secure)
					controls.window_callback(window, "Firefox", native.window.filter[vector.registered_event])
					helpers.assert_eq(controls.title_reads, reads + 1, "The registered callback must read the native title")
					helpers.assert_eq(scenario.state.is_private_window, private)
					helpers.assert_eq(scenario.state.is_secure_field, controls.expected_secure)
					local expected_allowed = not controls.expected_secure
						and (not private or scenario.state.private_filter_enabled == false)
					helpers.assert_eq(keylogger.context_allows_logging(), expected_allowed)
				end
				controls.ax = function(is_secure)
					helpers.assert_eq(controls.unsubscribes, 0, "The native window subscription must remain active during AX overlap")
					local roles, subroles = controls.role_reads, controls.subrole_reads
					controls.ax_callback(is_secure and secure or ordinary, "AXFocusedUIElementChanged", observer)
					helpers.assert_eq(controls.role_reads, roles + 1)
					helpers.assert_eq(controls.subrole_reads, subroles + 1)
					controls.expected_secure = is_secure
					helpers.assert_eq(scenario.state.is_secure_field, is_secure)
					local expected_allowed = not is_secure
						and (not scenario.state.is_private_window or scenario.state.private_filter_enabled == false)
					helpers.assert_eq(keylogger.context_allows_logging(), expected_allowed)
				end
				body(scenario, controls, keylogger)
			end, debug.traceback)
			local stop_ok, stopped = true, true
			if keylogger then stop_ok, stopped = pcall(keylogger.stop) end
			for _, name in ipairs(port_names) do startup_tracker[name] = previous_ports[name] end
			lifecycle.onAppActivate, manager.append_log = original_activation, original_append
			native.application, native.window = previous_application, previous_window
			native.axuielement, native.caffeinate = previous_ax, previous_caffeinate
			native.timer.absoluteTime = previous_clock
			if not called then error(failure, 0) end
			helpers.assert_eq(stop_ok, true)
			helpers.assert_eq(stopped, true)
			helpers.assert_eq(controls.unsubscribes, 1)
			helpers.assert_eq(controls.ax_stops, 1)
			helpers.assert_eq(scenario.state.ax_observer, nil)
		end)
	end)
end

return {
	Accounting = Accounting,
	KEYCODE_CAPS_LOCK = KEYCODE_CAPS_LOCK,
	KEYCODE_LEFT_COMMAND = KEYCODE_LEFT_COMMAND,
	KEYCODE_RETURN = KEYCODE_RETURN,
	only_typing_kc = only_typing_kc,
	private_modifier_vectors = private_modifier_vectors,
	with_private_window_callback = with_private_window_callback,
	with_system_policy_callback = with_system_policy_callback,
}
