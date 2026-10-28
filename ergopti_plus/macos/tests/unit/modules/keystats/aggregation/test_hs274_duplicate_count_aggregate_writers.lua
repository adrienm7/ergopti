--- tests/unit/modules/keystats/aggregation/test_hs274_duplicate_count_aggregate_writers.lua

--- ==============================================================================
--- MODULE: HS-274 — a remapped tap and its physical key
--- DESCRIPTION:
--- Ported from docs/audits/hammerspoon/2026_09_08/proofs/duplicate-count.lua,
--- driving the real keystats keyDown and flagsChanged branches and the real
--- aggregator instead of a stubbed classifier.
---
--- ROOT CAUSE ENCODED:
--- Two independent writers credit a managed tap-hold. The Karabiner
--- shell_command ledger credits the physical key (karabiner_press), and the
--- Quartz event tap credits the remapped output it observes (meta.kc). The
--- historical guard `kc = KcBridge.is_ke_managed_output_kc(keycode) and nil or
--- keycode` always evaluated to keycode, because `true and nil` is nil and
--- `nil or keycode` is keycode, so every remapped tap is credited twice. With the
--- shipped defaults, one CapsLock tap (tap = Return) credits CapsLock AND Return.
---
--- The legacy cases pin today's behaviour, double count included: fixing it by
--- suppressing the output keycode would lose real presses (see
--- test_hs274_physical_collision.lua). The stream cases prove the fix that
--- physical_accounting_mode.lua enables: while a complete capture is admitted,
--- neither the event tap nor the ledger credits anything, so each physical press
--- is credited once, by the stream. Restoring the `and nil or keycode` idiom
--- fails them, and so does any fallback to the legacy sources during a gap.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.keystats.aggregation.hs274_duplicate_count_fixture"] = nil
local Fixture = require("tests.support.modules.keystats.aggregation.hs274_duplicate_count_fixture")
local Accounting = Fixture.Accounting
local private_modifier_vectors = Fixture.private_modifier_vectors
local with_private_window_callback = Fixture.with_private_window_callback





-- Policy-writer controls keep the existing real consumer/tracker fixtures.
-- Cipher/migration and native application/AX ports are boundary doubles only.
-- The new Auth fixture forwards the genuine fourth startup dependency while
-- the original three-argument fixture and all its cases above remain untouched.
local function with_current_auth_policy_callback(vector, body)
	Accounting.run(function(scenario)
		local startup_tracker = package.loaded["modules.keystats.context_tracker"]
		local lifecycle = package.loaded["adapters.process_lifecycle"]
		local manager = package.loaded["modules.keystats.log_manager"]
		local previous_activation, previous_append = lifecycle.onAppActivate, manager.append_log
		local ports = { "init", "app_watcher_cb", "update_private_status", "update_ax_observer",
			"capture_frontmost_app", "resync_context" }
		local previous_ports = {}
		for _, name in ipairs(ports) do previous_ports[name] = startup_tracker[name] end
		helpers.with_fresh_modules({ "modules.keystats.context_tracker", "adapters.secure_field_detector" }, function()
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
			local tracker, keystats
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
				tracker = require("modules.keystats.context_tracker")
				for _, name in ipairs(ports) do if name ~= "init" then startup_tracker[name] = tracker[name] end end
				startup_tracker.init = function(state, log_manager, paused, settle)
					controls.startup_dependencies = { state, log_manager, paused, settle }
					return tracker.init(state, log_manager, paused, settle)
				end
				lifecycle.onAppActivate = function(callback)
					controls.activation_callback = callback
					return previous_activation(callback)
				end
				manager.append_log = function(entry) controls.metadata[#controls.metadata + 1] = entry; return true end
				keystats = package.loaded["modules.keystats.init"]
				-- Only the actual public writer establishes initial policy, never raw state.
				keystats.set_system_auth_filter_enabled(vector.initial_system_filter)
				helpers.assert_eq(scenario.state.system_auth_filter_enabled, vector.initial_system_filter)
				scenario.state.is_enabled = false
				helpers.assert_eq(keystats.start({ is_paused = function() return false end }), true)
				local deps = controls.startup_dependencies
				helpers.assert_eq(type(deps), "table")
				helpers.assert_eq(deps[1], scenario.state)
				helpers.assert_eq(deps[2], manager)
				helpers.assert_eq(type(deps[3]), "function")
				helpers.assert_eq(type(deps[4]), "function", "The actual startup owns the policy settlement callback")
				helpers.assert_eq(tracker.init(deps[1], deps[2], deps[3], deps[4]), true)
				helpers.assert_eq(type(controls.activation_callback), "function")
				local retained_activation = controls.activation_callback
				controls.activate = function(kind)
					helpers.assert_true(kind == "auth" or kind == "ordinary")
					controls.current_app = apps[kind]
					local roles, subroles, titles = controls.role_reads, controls.subrole_reads, controls.title_reads
					helpers.assert_eq(_G.hs, native)
					helpers.assert_eq(package.loaded["modules.keystats.context_tracker"], tracker)
					helpers.assert_eq(controls.activation_callback, retained_activation)
					retained_activation(controls.current_app:name(), controls.current_app)
					helpers.assert_true(controls.role_reads > roles and controls.subrole_reads > subroles,
						"Real AX classification must establish rawsecure=false independently of the auth bundle")
					helpers.assert_eq(controls.title_reads, titles + 1)
					helpers.assert_eq(scenario.state.active_app_bundle, kind == "auth" and vector.auth_bundle_id or "test.editor")
					helpers.assert_eq(scenario.state.is_secure_field, false)
					helpers.assert_eq(scenario.state.is_private_window, false)
					helpers.assert_eq(keystats.context_allows_logging(), kind ~= "auth" or scenario.state.system_auth_filter_enabled == false)
					helpers.assert_eq(scenario.state.ax_observer, controls.observers[#controls.observers])
				end
				controls.activate(vector.startup_application)
				helpers.assert_eq(#scenario.system_events, 0)
				body(scenario, controls, keystats)
			end, debug.traceback)
			local stopped_ok, stopped = true, true
			if keystats then stopped_ok, stopped = pcall(keystats.stop) end
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


helpers.describe("HS-274 actual aggregate and disabled-app policy writers (wp3)", function()
	local function with_policy_ports(body)
		helpers.with_stub_scope({ "modules.keystats.text_cipher", "modules.keystats.text_migration",
			"adapters.physical_observation_clock", "keystats.physical_configuration_observation" }, function()
			local ports = { encrypted = false, available = true, migrating = false, accept_cipher = true }
			package.loaded["modules.keystats.text_cipher"] = {
				is_available = function() return ports.available end,
				is_enabled = function() return ports.encrypted end,
				set_enabled = function(value) if ports.accept_cipher then ports.encrypted = value end end,
			}
			package.loaded["modules.keystats.text_migration"] = { is_running = function() return ports.migrating end }
			package.loaded["adapters.physical_observation_clock"] = nil
			package.loaded["keystats.physical_configuration_observation"] = nil
			body(ports)
		end)
	end

	local function with_policy(body)
		with_policy_ports(function(ports)
			with_private_window_callback(private_modifier_vectors[1], function(scenario, controls, core)
				body(scenario, controls, core, ports)
			end)
		end)
	end

	local function plan(core)
		local config = core.configuration_snapshot()
		helpers.assert_eq(type(config), "table")
		config.options.encrypt, config.cipher_enabled = false, false
		return config
	end

	local function expect_events(scenario, expected)
		local actual = {}
		for _, event in ipairs(scenario.system_events) do
			actual[#actual + 1] = { event.action, event.keycode, event.hold_ms }
		end
		helpers.assert_eq(actual, expected)
	end

	local function press(scenario, controls)
		controls.clock_ms = 1000
		scenario.flags_changed(55, { cmd = true })
		expect_events(scenario, { { "modifier_press", 55 } })
	end

	local function fresh_pair(scenario, controls)
		controls.clock_ms = 8000; scenario.flags_changed(55, { cmd = true })
		controls.clock_ms = 9000; scenario.flags_changed(55, {})
		helpers.assert_eq(scenario.state.modifier_down_at, {})
		helpers.assert_eq(scenario.state.modifier_suppressed_releases, {})
	end

	local function crossing_then_fresh(scenario, controls)
		controls.clock_ms = 7000; scenario.flags_changed(55, {})
		expect_events(scenario, { { "modifier_press", 55 } })
		fresh_pair(scenario, controls)
		expect_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } })
	end

	for _, field in ipairs({ "bundleID", "appPath" }) do
		helpers.it("(wp3-policy) disabled_" .. field .. "_cancels_whole_interval", function()
			with_policy(function(scenario, controls, core)
				press(scenario, controls)
				local value = field == "bundleID" and scenario.state.active_app_bundle or scenario.state.active_app_path
				helpers.assert_eq(type(value), "string")
				controls.clock_ms = 2000; core.set_disabled_apps({ { [field] = value } })
				helpers.assert_eq(core.context_allows_logging(), false)
				helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], true)
				controls.clock_ms = 4000; core.set_disabled_apps({})
				helpers.assert_eq(core.context_allows_logging(), true)
				crossing_then_fresh(scenario, controls)
			end)
		end)
	end

	helpers.it("(wp3-policy) disabled_foreign_preserves_included_hold", function()
		with_policy(function(scenario, controls, core)
			press(scenario, controls)
			controls.clock_ms = 2000; core.set_disabled_apps({ { bundleID = "other.application" } })
			helpers.assert_eq(core.context_allows_logging(), true)
			controls.clock_ms = 7000; scenario.flags_changed(55, {})
			expect_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 } })
		end)
	end)

	helpers.it("(wp3-policy) disabled_refused_held_debt_retries", function()
		with_policy(function(scenario, controls, core)
			press(scenario, controls)
			local timestamp = scenario.state.modifier_down_at[55]
			scenario.state.modifier_down_at[55] = "invalid"
			local apps = { { bundleID = scenario.state.active_app_bundle } }
			local accepted = pcall(core.set_disabled_apps, apps)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(scenario.state.disabled_apps, apps)
			helpers.assert_eq(core.may_persist(), false)
			helpers.assert_eq(scenario.state.modifier_down_at[55], "invalid")
			accepted = pcall(core.set_disabled_apps, {})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(core.context_allows_logging(), false, "inclusion cannot discharge refused settlement debt")
			helpers.assert_eq(scenario.state.modifier_down_at[55], "invalid")
			scenario.state.modifier_down_at[55] = timestamp
			core.set_disabled_apps(apps); core.set_disabled_apps({})
			helpers.assert_eq(core.context_allows_logging(), true)
			crossing_then_fresh(scenario, controls)
		end)
	end)

	for _, kind in ipairs({ "private", "secure" }) do
		helpers.it("(wp3-policy) aggregate_" .. kind .. "_enable_cancels", function()
			with_policy(function(scenario, controls, core)
				local field = kind == "private" and "private_filter_enabled" or "secure_field_filter_enabled"
				if kind == "private" then
					core.set_private_filter_enabled(false)
					controls.private(true)
				else
					core.set_secure_field_filter_enabled(false)
					local secure = { attributeValue = function(_, name)
						if name == "AXRole" then return "AXSecureTextField" end
						if name == "AXValue" then return "" end
					end }
					controls.ax_callback(scenario.state.ax_observer, secure, "AXFocusedUIElementChanged", {})
					helpers.assert_eq(scenario.state.is_secure_field, true, "the real registered classifier publishes secure state")
				end
				helpers.assert_eq(core.context_allows_logging(), true)
				press(scenario, controls)
				local config = plan(core); config[field] = true
				controls.clock_ms = 2000; helpers.assert_eq(core.apply_configuration(config), true)
				helpers.assert_eq(core.context_allows_logging(), false)
				helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
				config[field] = false
				controls.clock_ms = 4000; helpers.assert_eq(core.apply_configuration(config), true)
				helpers.assert_eq(core.context_allows_logging(), true)
				crossing_then_fresh(scenario, controls)
			end)
		end)
	end

	helpers.it("(wp3-policy) aggregate_included_to_included_preserves_full_hold", function()
		with_policy(function(scenario, controls, core)
			press(scenario, controls)
			local config = plan(core); config.disabled_apps = { { bundleID = "other.application" } }
			controls.clock_ms = 2000; helpers.assert_eq(core.apply_configuration(config), true)
			helpers.assert_eq(core.context_allows_logging(), true)
			controls.clock_ms = 7000; scenario.flags_changed(55, {})
			expect_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 } })
		end)
	end)

	helpers.it("(wp3-policy) aggregate_refused_marker_debt_retries", function()
		with_policy(function(scenario, controls, core)
			press(scenario, controls)
			scenario.state.modifier_suppressed_releases[54] = false
			local config = plan(core); config.disabled_apps = { { bundleID = scenario.state.active_app_bundle } }
			local accepted = pcall(core.apply_configuration, config)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(scenario.state.disabled_apps, config.disabled_apps)
			helpers.assert_eq(core.may_persist(), false)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[54], false)
			config.disabled_apps = {}
			accepted = pcall(core.apply_configuration, config)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(core.context_allows_logging(), false)
			helpers.assert_eq(scenario.state.modifier_suppressed_releases[54], false)
			scenario.state.modifier_suppressed_releases[54] = nil
			config.disabled_apps = { { bundleID = scenario.state.active_app_bundle } }
			helpers.assert_eq(core.apply_configuration(config), true)
			config.disabled_apps = {}; helpers.assert_eq(core.apply_configuration(config), true)
			helpers.assert_eq(core.context_allows_logging(), true)
			crossing_then_fresh(scenario, controls)
		end)
	end)

	for _, phase in ipairs({ "migration", "unavailable", "posture" }) do
		helpers.it("(wp3-policy) aggregate_refuses_" .. phase .. "_without_policy_or_hold_commit", function()
			with_policy(function(scenario, controls, core, ports)
				press(scenario, controls)
				local before = core.configuration_snapshot()
				local held, timestamp = scenario.state.modifier_down_at, scenario.state.modifier_down_at[55]
				local config = plan(core)
				config.disabled_apps = { { bundleID = scenario.state.active_app_bundle } }
				config.options.encrypt, config.cipher_enabled = true, true
				local records, owner = 0, {}
				local bound, token = core.bind_physical_configuration_observer(owner, 8,
					function() records = records + 1; return true end, function() end)
				helpers.assert_eq(bound, true); helpers.assert_eq(records, 1)
				ports.migrating = phase == "migration"
				ports.available = phase ~= "unavailable"
				ports.accept_cipher = phase ~= "posture"
				helpers.assert_eq(core.apply_configuration(config), false)
				helpers.assert_eq(records, 1, "refused plans publish no receipt")
				helpers.assert_eq(scenario.state.modifier_down_at, held)
				helpers.assert_eq(scenario.state.modifier_down_at[55], timestamp)
				helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], nil)
				ports.migrating, ports.available, ports.accept_cipher = false, true, true
				helpers.assert_eq(core.configuration_snapshot(), before)
				helpers.assert_eq(core.unbind_physical_configuration_observer(owner, token), true)
				controls.clock_ms = 7000; scenario.flags_changed(55, {})
				expect_events(scenario, { { "modifier_press", 55 }, { "modifier_hold", 55, 6000 } })
			end)
		end)
	end

	for _, writer in ipairs({ "disabled", "aggregate" }) do
		helpers.it("(wp3-policy) " .. writer .. "_settles_before_foreign_publication", function()
			with_policy(function(scenario, controls, core)
				local records, delivered, refused, owner = 0, 0, 0, {}
				local bound, token = core.bind_physical_configuration_observer(owner, 8, function(record)
					records = records + 1
					if records == 2 then
						helpers.assert_eq(record.disabled_apps, { { bundleID = scenario.state.active_app_bundle } })
						helpers.assert_eq(core.context_allows_logging(), false)
						helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
						helpers.assert_eq(scenario.state.modifier_suppressed_releases[55], true)
						scenario.flags_changed(55, {})
						delivered = delivered + 1
					end
					return true
				end, function() refused = refused + 1 end)
				helpers.assert_eq(bound, true); helpers.assert_eq(records, 1)
				press(scenario, controls)
				controls.clock_ms = 2000
				if writer == "disabled" then
					core.set_disabled_apps({ { bundleID = scenario.state.active_app_bundle } })
				else
					local config = plan(core); config.disabled_apps = { { bundleID = scenario.state.active_app_bundle } }
					helpers.assert_eq(core.apply_configuration(config), true)
				end
				helpers.assert_eq(records, 2)
				helpers.assert_eq(delivered, 1, "the real observer completed its reentrant crossing-release checks")
				helpers.assert_eq(refused, 0, "the observer did not swallow an assertion failure")
				expect_events(scenario, { { "modifier_press", 55 } })
				helpers.assert_eq(core.unbind_physical_configuration_observer(owner, token), true)
				core.set_disabled_apps({})
				fresh_pair(scenario, controls)
				expect_events(scenario, { { "modifier_press", 55 }, { "modifier_press", 55 }, { "modifier_hold", 55, 1000 } })
			end)
		end)

		helpers.it("(wp3-policy) " .. writer .. "_refreshes_stale_generic_cache_after_auth_optout", function()
			with_policy_ports(function()
				with_current_auth_policy_callback({ auth_bundle_id = "com.apple.SecurityAgent",
					startup_application = "auth", initial_system_filter = true }, function(scenario, controls, core)
					helpers.assert_eq(core.context_allows_logging(), false)
					core.set_system_auth_filter_enabled(false)
					helpers.assert_eq(core.context_allows_logging(), true)
					press(scenario, controls)
					if writer == "disabled" then
						controls.clock_ms = 2000; core.set_disabled_apps({ { bundleID = "com.apple.SecurityAgent" } })
						controls.clock_ms = 4000; core.set_disabled_apps({})
					else
						local config = plan(core); config.system_auth_filter_enabled = true
						controls.clock_ms = 2000; helpers.assert_eq(core.apply_configuration(config), true)
						config.system_auth_filter_enabled = false
						controls.clock_ms = 4000; helpers.assert_eq(core.apply_configuration(config), true)
					end
					crossing_then_fresh(scenario, controls)
				end)
			end)
		end)
	end

	helpers.it("(wp3-policy) existing_secure_writer_after_auth_optout_uses_current_generic_policy", function()
		with_policy_ports(function()
			with_current_auth_policy_callback({ auth_bundle_id = "com.apple.SecurityAgent",
				startup_application = "auth", initial_system_filter = true }, function(scenario, controls, core)
				core.set_secure_field_filter_enabled(false)
				local secure = { attributeValue = function(_, name)
					if name == "AXRole" then return "AXSecureTextField" end
					if name == "AXValue" then return "" end
				end }
				local observer = scenario.state.ax_observer
				observer.retained_callback(observer, secure, "AXFocusedUIElementChanged", {})
				helpers.assert_eq(scenario.state.is_secure_field, true)
				helpers.assert_eq(core.context_allows_logging(), false)
				core.set_system_auth_filter_enabled(false)
				helpers.assert_eq(core.context_allows_logging(), true)
				press(scenario, controls)
				controls.clock_ms = 2000; core.set_secure_field_filter_enabled(true)
				helpers.assert_eq(core.context_allows_logging(), false)
				helpers.assert_eq(scenario.state.modifier_down_at[55], nil)
				controls.clock_ms = 4000; core.set_secure_field_filter_enabled(false)
				crossing_then_fresh(scenario, controls)
			end)
		end)
	end)
end)
