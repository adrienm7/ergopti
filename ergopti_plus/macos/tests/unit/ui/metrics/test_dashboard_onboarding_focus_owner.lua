--- tests/unit/ui/metrics/test_dashboard_onboarding_focus_owner.lua

--- ==============================================================================
--- MODULE: Dashboard and Onboarding Deferred Focus Ownership
--- DESCRIPTION:
--- Exercises real open and close paths while a native focus retry remains pending.
--- ==============================================================================

local helpers = require("tests.helpers")

local with_window = require("tests.support.dashboard_window_fixture")
helpers.describe("dashboard and onboarding focus ownership", function()
	helpers.it("(metrics-cleanup-authority) refused deletion revokes bridge and data continuations", function()
		with_window("ui.metrics_apps", function(dashboard, state)
			local pending, discoveries = {}, 0
			package.loaded["adapters.timer_scheduler"].after = function(_, callback)
				local handle = { timer = {} }
				pending[#pending + 1] = function() handle.timer = nil; callback() end
				return handle, true
			end
			helpers.with_fresh_modules({ "infra.app_picker" }, function()
				package.loaded["infra.app_picker"] = {
					discover_apps = function() discoveries = discoveries + 1 end,
				}
				helpers.assert_true(dashboard.show())
				local startup_count = #pending
				state.receiver({ body = { action = "pick" } })
				pending[#pending]()
				helpers.assert_eq(discoveries, 1, "a live bridge must dispatch application discovery")
				state.receiver({ body = { action = "pick" } })
				local queued_pick = pending[#pending]
				state.refused = true
				helpers.assert_eq(dashboard.close(), false)
				local count = #pending
				state.receiver({ body = { action = "pick" } })
				helpers.assert_eq(#pending, count, "cleanup-only bridge must not acquire new work")
				queued_pick()
				helpers.assert_eq(discoveries, 1, "previously queued actions must also lose authority")
				helpers.assert_eq(dashboard.push_live_update(), false)
				for index = 1, startup_count do pending[index]() end
				helpers.assert_eq(#pending, count, "retired bootstrap must not schedule a data refresh")
				state.refused = false
				helpers.assert_true(dashboard.close(), "exact native cleanup must remain retryable")
				helpers.assert_eq(state.deleted, 2)
				helpers.assert_true(dashboard.show(), "settled cleanup must allow a new generation")
				state.receiver({ body = { action = "pick" } })
				pending[#pending]()
				helpers.assert_eq(discoveries, 2)
			end)
		end)
	end)
	helpers.it("(metrics-cleanup-authority) late native close settles a retired exact owner", function()
		with_window("ui.metrics_apps", function(dashboard, state)
			helpers.assert_true(dashboard.show())
			local old_view, old_receiver = state.view, state.receiver
			state.refused = true
			helpers.assert_eq(dashboard.close(), false)
			old_view.options.on_close()
			helpers.assert_nil(dashboard._wv)
			helpers.assert_eq(state.deleted, 1, "native settlement must not retry deletion")
			state.refused = false
			helpers.assert_true(dashboard.show())
			local current = dashboard._wv
			old_view.options.on_close()
			old_receiver({ body = { action = "pick" } })
			helpers.assert_eq(dashboard._wv, current, "old native close must not retire its successor")
			helpers.assert_true(dashboard.close())
		end)
	end)

	for _, refused in ipairs({ false, true }) do
		helpers.it("(webview-focus-owner) dashboard retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_window("ui.metrics_apps", function(dashboard, state)
				helpers.assert_true(dashboard.show())
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return dashboard.show() end,
					function() state.refused = refused; helpers.assert_eq(dashboard.close(), not refused) end,
					state.view.options)
			end)
		end)
		helpers.it("(webview-focus-owner) onboarding retirement revokes focus, delete refused=" .. tostring(refused), function()
			with_window("ui.onboarding", function(onboarding, state)
				require("tests.support.onboarding_shared_data").install()
				helpers.assert_true(onboarding.run("/virtual/config.toml"))
				require("tests.support.webview_focus_fixture").check(state.view,
					function() return onboarding.run("/virtual/config.toml") end,
					function()
						if refused then
							state.refused = true
							state.receiver({ body = { action = "finish", answers = { locale = "en", config_dir = "", operations = {} } } })
							helpers.assert_eq(state.deleted, 1)
						else
							state.view.options.on_close()
						end
					end, state.view.options)
			end)
		end)
	end
	helpers.it("(webview-focus-owner) onboarding constructor close revokes factory focus", function()
		with_window("ui.onboarding", function(onboarding, state)
			require("tests.support.onboarding_shared_data").install()
			state.close_during_create = true
			helpers.assert_eq(onboarding.run("/virtual/config.toml"), false)
			helpers.assert_eq(state.view.options.is_current(), false)
		end)
	end)
end)

-- Public reuse must distinguish a live wizard from exact cleanup-only ownership.
-- These use the genuine controller and existing native fixture ports, not AppKit.
local function with_onboarding_reuse(callback)
	with_window("ui.onboarding", function(onboarding, state)
		require("tests.support.onboarding_shared_data").install()
		local builder = package.loaded["ui.ui_builder"]
		local show = builder.show_webview
		local owners = {}
		state.acquisitions, state.focus_calls = 0, 0
		builder.show_webview = function(options)
			local view = show(options)
			state.acquisitions = state.acquisitions + 1
			owners[#owners + 1] = { view = view, delete = view.delete,
				close = options.on_close, receiver = state.receiver, settled = false }
			return view
		end
		builder.force_focus = function(view, _, options)
			state.focus_calls = state.focus_calls + 1
			state.focus_view, state.focus_options = view, options
			return options.is_current()
		end
		local called, primary = xpcall(function() callback(onboarding, state, owners, builder) end,
			function(err) return err end)
		local cleanup_errors = {}
		state.refused = false
		for _, owner in ipairs(owners) do
			if not owner.settled then
				-- Attempt both exact owned ports independently before module restoration.
				local deleted, delete_error = pcall(owner.delete, owner.view)
				if not deleted then cleanup_errors[#cleanup_errors + 1] = delete_error end
				local closed, close_error = pcall(owner.close)
				if not closed then cleanup_errors[#cleanup_errors + 1] = close_error end
			end
		end
		if not called then
			if #cleanup_errors > 0 then
				pcall(function() io.stderr:write("Onboarding reuse fixture also refused owned cleanup.\n") end)
			end
			error(primary, 0)
		end
		if #cleanup_errors > 0 then error(cleanup_errors[1], 0) end
	end)
end

local function retire_onboarding_with_refused_close(state)
	state.refused = true
	-- The existing fixture refuses locale persistence before any config writer.
	-- The genuine failure continuation attempts native close and revokes the page.
	state.receiver({ body = { action = "finish", answers = {
		locale = "en", config_dir = "", operations = {},
	} } })
	helpers.assert_eq(state.deleted, 1)
	helpers.assert_eq(state.view.options.is_current(), false)
end

helpers.describe("onboarding cleanup-only public reuse", function()
	helpers.it("(onboarding-cleanup-only-reuse) refuses retired reuse and preserves exact retry through repair", function()
		with_onboarding_reuse(function(onboarding, state, owners)
			helpers.assert_true(onboarding.run("/virtual/original-config.toml"))
			local original, receiver = state.view, state.receiver
			retire_onboarding_with_refused_close(state)
			helpers.assert_eq(onboarding.run("/virtual/replacement-config.toml"), false,
				"a retained cleanup-only window is not an active wizard")
			helpers.assert_eq(state.acquisitions, 1)
			helpers.assert_eq(state.focus_calls, 0, "retired reuse must not acquire native focus")
			helpers.assert_eq(state.view, original)
			helpers.assert_eq(state.receiver, receiver)
			receiver({ body = { action = "cancel" } })
			helpers.assert_eq(state.deleted, 2, "only the retained bridge retries its exact native cleanup")
			helpers.assert_eq(onboarding.run("/virtual/replacement-config.toml"), false)
			helpers.assert_eq(state.acquisitions, 1)
			state.refused = false
			receiver({ body = { action = "cancel" } })
			owners[1].settled = true
			helpers.assert_eq(state.deleted, 3)
			helpers.assert_true(onboarding.run("/virtual/replacement-config.toml"))
			local successor, successor_receiver = state.view, state.receiver
			helpers.assert_true(successor ~= original)
			helpers.assert_eq(state.acquisitions, 2)
			helpers.assert_true(successor.options.is_current())
			receiver({ body = { action = "finish", answers = {
				locale = "en", config_dir = "", operations = {},
			} } })
			receiver({ body = { action = "cancel" } })
			helpers.assert_eq(state.deleted, 3, "retired callbacks cannot close a successor")
			helpers.assert_eq(state.view, successor)
			helpers.assert_eq(state.receiver, successor_receiver)
			helpers.assert_true(successor.options.is_current())
		end)
	end)

	helpers.it("(onboarding-cleanup-only-reuse) refuses before a throwing foreign focus observer", function()
		with_onboarding_reuse(function(onboarding, state, _, builder)
			helpers.assert_true(onboarding.run("/virtual/original-config.toml"))
			local original, receiver = state.view, state.receiver
			retire_onboarding_with_refused_close(state)
			local observations = 0
			builder.force_focus = function()
				observations = observations + 1
				error("retired reuse reached native focus")
			end
			helpers.assert_eq(onboarding.run("/virtual/replacement-config.toml"), false)
			helpers.assert_eq(observations, 0)
			helpers.assert_eq(state.acquisitions, 1)
			helpers.assert_eq(state.view, original)
			helpers.assert_eq(state.receiver, receiver)
			helpers.assert_eq(state.deleted, 1)
		end)
	end)

	helpers.it("(onboarding-cleanup-only-reuse) preserves the original live existing-view branch", function()
		with_onboarding_reuse(function(onboarding, state)
			helpers.assert_true(onboarding.run("/virtual/live-config.toml"))
			local original, receiver = state.view, state.receiver
			helpers.assert_true(onboarding.run("/virtual/live-config.toml"))
			helpers.assert_eq(state.acquisitions, 1)
			helpers.assert_eq(state.deleted, 0)
			helpers.assert_eq(state.focus_calls, 1)
			helpers.assert_eq(state.focus_view, original)
			helpers.assert_true(state.focus_options.is_current())
			helpers.assert_true(original.options.is_current())
			helpers.assert_eq(state.view, original)
			helpers.assert_eq(state.receiver, receiver)
		end)
	end)
end)

-- A failed factory returns diagnostics, never a caller-owned native window.
local function onboarding_factory_error_observer()
	local errors = {}
	package.loaded["infra.logger"].error = function(_, message, ...)
		errors[#errors + 1] = string.format(message, ...)
	end
	return errors
end

local function onboarding_report_contains(errors, marker)
	for _, message in ipairs(errors) do
		if message:find(marker, 1, true) then return true end
	end
	return false
end

-- Capture standalone bridges even when no view was ever returned. Keep attached
-- bridges with the existing view owner's delete-before-release finalizer.
local function with_factory_error_ports(callback)
	with_onboarding_reuse(function(onboarding, state, owners, builder)
		local native_new, bridges = hs.webview.usercontent.new, {}
		hs.webview.usercontent.new = function(...)
			local bridge = native_new(...)
			local setter = bridge.setCallback
			local record = { bridge = bridge, setter = setter, cleared = false }
			bridges[#bridges + 1] = record
			bridge.setCallback = function(self, receiver)
				local result = setter(self, receiver)
				if receiver == nil then record.cleared = true end
				return result
			end
			return bridge
		end
		local called, primary = xpcall(function() callback(onboarding, state, owners, builder) end,
			function(err) return err end)
		local cleanup_errors = {}
		for _, record in ipairs(bridges) do
			local attached = state.view and state.view.options.usercontent == record.bridge
			if not record.cleared and not attached then
				local cleared, clear_error = pcall(record.setter, record.bridge, nil)
				if not cleared then cleanup_errors[#cleanup_errors + 1] = clear_error end
			end
		end
		hs.webview.usercontent.new = native_new
		if not called then
			if #cleanup_errors > 0 then
				pcall(function() io.stderr:write("Factory fixture also refused standalone native callback cleanup.\n") end)
			end
			error(primary, 0)
		end
		if #cleanup_errors > 0 then error(cleanup_errors[1], 0) end
	end)
end

helpers.describe("onboarding factory error ownership", function()
	helpers.it("(onboarding-factory-error-owner) early string failure releases actual bridge and permits repair", function()
		with_factory_error_ports(function(onboarding, state, _, builder)
			local show, errors = builder.show_webview, onboarding_factory_error_observer()
			builder.show_webview = function() error("EARLY_ONBOARDING_FACTORY_FAILURE") end
			helpers.assert_eq(onboarding.run("/virtual/failed-factory.toml"), false)
			helpers.assert_eq(state.acquisitions, 0)
			helpers.assert_eq(state.deleted, 0, "there was no native window to delete")
			helpers.assert_nil(state.view)
			helpers.assert_nil(state.receiver, "the actual acquired bridge is released without fabricating a view")
			helpers.assert_true(onboarding_report_contains(errors, "EARLY_ONBOARDING_FACTORY_FAILURE"),
				"the original factory failure remains diagnostic evidence")
			builder.show_webview = show
			helpers.assert_true(onboarding.run("/virtual/repaired-factory.toml"))
			helpers.assert_eq(state.acquisitions, 1)
			helpers.assert_true(state.view.options.is_current())
			helpers.assert_type(state.receiver, "function")
		end)
	end)

	helpers.it("(onboarding-factory-error-owner) an error object's delete method gains no native authority", function()
		with_factory_error_ports(function(onboarding, state, _, builder)
			local show, errors = builder.show_webview, onboarding_factory_error_observer()
			local phantom_deletes = 0
			local primary = setmetatable({ delete = function()
				phantom_deletes = phantom_deletes + 1
			end }, { __tostring = function() return "EARLY_ONBOARDING_ERROR_OBJECT" end })
			builder.show_webview = function() error(primary, 0) end
			helpers.assert_eq(onboarding.run("/virtual/error-object.toml"), false)
			helpers.assert_eq(phantom_deletes, 0, "a factory error cannot issue a native cleanup capability")
			helpers.assert_eq(state.acquisitions, 0)
			helpers.assert_eq(state.deleted, 0)
			helpers.assert_nil(state.receiver)
			helpers.assert_true(onboarding_report_contains(errors, "EARLY_ONBOARDING_ERROR_OBJECT"))
			builder.show_webview = show
			helpers.assert_true(onboarding.run("/virtual/repaired-object.toml"))
			helpers.assert_eq(state.acquisitions, 1)
			helpers.assert_true(state.view.options.is_current())
		end)
	end)

	helpers.it("(onboarding-factory-error-owner) bridge cleanup refusal retains only its exact owner through repair", function()
		with_factory_error_ports(function(onboarding, state, _, builder)
			local show, errors = builder.show_webview, onboarding_factory_error_observer()
			local native_new = hs.webview.usercontent.new
			local bridges, refuse_release, factory_calls = {}, true, 0
			local called, primary = xpcall(function()
				hs.webview.usercontent.new = function(...)
					local bridge = native_new(...)
					local setter = bridge.setCallback
					local record = { bridge = bridge, releases = 0, cleared = false }
					bridges[#bridges + 1] = record
					bridge.setCallback = function(self, receiver)
						if receiver == nil then
							record.releases = record.releases + 1
							if self == bridges[1].bridge and refuse_release then
								error("OWNED_ONBOARDING_BRIDGE_RELEASE_REFUSED")
							end
						end
						local result = setter(self, receiver)
						if receiver == nil then record.cleared = true end
						return result
					end
					record.release = bridge.setCallback
					return bridge
				end
				builder.show_webview = function()
					factory_calls = factory_calls + 1
					error("EARLY_FACTORY_WITH_BRIDGE_DEBT")
				end
				helpers.assert_eq(onboarding.run("/virtual/refused-bridge.toml"), false)
				local old_receiver = state.receiver
				helpers.assert_type(old_receiver, "function")
				helpers.assert_eq(#bridges, 1)
				helpers.assert_eq(bridges[1].releases, 1)
				helpers.assert_eq(factory_calls, 1)
				helpers.assert_eq(state.deleted, 0)
				helpers.assert_true(onboarding_report_contains(errors, "EARLY_FACTORY_WITH_BRIDGE_DEBT"))
				builder.show_webview = show
				helpers.assert_eq(onboarding.run("/virtual/refused-retry.toml"), false)
				helpers.assert_eq(#bridges, 1, "refused cleanup cannot acquire another bridge")
				helpers.assert_eq(bridges[1].releases, 2, "retry must reach the exact original bridge")
				helpers.assert_eq(state.receiver, old_receiver)
				helpers.assert_eq(state.acquisitions, 0)
				refuse_release = false
				helpers.assert_true(onboarding.run("/virtual/repaired-bridge.toml"))
				helpers.assert_eq(bridges[1].releases, 3)
				helpers.assert_eq(#bridges, 2)
				helpers.assert_eq(state.acquisitions, 1)
				local current, current_receiver = state.view, state.receiver
				old_receiver({ body = { action = "finish", answers = {
					locale = "en", config_dir = "", operations = {},
				} } })
				old_receiver({ body = { action = "cancel" } })
				helpers.assert_eq(state.deleted, 0)
				helpers.assert_eq(state.view, current)
				helpers.assert_eq(state.receiver, current_receiver)
				helpers.assert_true(current.options.is_current())
			end, function(err) return err end)
			local cleanup_errors = {}
			refuse_release = false
			-- View-owned bridges keep the original delete-before-release cleanup order.
			-- A factory that never returned a view still owns its standalone bridge.
			for _, record in ipairs(bridges) do
				local attached = state.view and state.view.options.usercontent == record.bridge
				if not record.cleared and not attached then
					local released, release_error = pcall(record.release, record.bridge, nil)
					if not released then cleanup_errors[#cleanup_errors + 1] = release_error end
				end
			end
			hs.webview.usercontent.new = native_new
			if not called then
				if #cleanup_errors > 0 then
					pcall(function() io.stderr:write("Factory fixture also refused standalone bridge cleanup.\n") end)
				end
				error(primary, 0)
			end
			if #cleanup_errors > 0 then error(cleanup_errors[1], 0) end
		end)
	end)
end)

-- Same-source singleton acknowledgment must not revive retired page authority.
helpers.describe("onboarding retained same-source acknowledgment", function()
	helpers.it("(onboarding-retained-same-source) acknowledges exact source without new native or write authority", function()
		with_onboarding_reuse(function(onboarding, state, owners)
			local native_new = hs.webview.usercontent.new
			local writer = require("infra.toml.writer")
			local batch_write = writer.batch_write
			local bridges, writes = 0, 0
			local called, primary = xpcall(function()
				hs.webview.usercontent.new = function(...)
					bridges = bridges + 1
					return native_new(...)
				end
				writer.batch_write = function(...)
					writes = writes + 1
					return batch_write(...)
				end
				helpers.assert_true(onboarding.run("/virtual/original-config.toml"))
				local original, receiver = state.view, state.receiver
				retire_onboarding_with_refused_close(state)
				helpers.assert_true(onboarding.run("/virtual/original-config.toml"),
					"the exact retained singleton keeps its original public acknowledgment")
				helpers.assert_eq(state.focus_calls, 1)
				helpers.assert_eq(state.focus_view, original)
				helpers.assert_eq(state.focus_options.is_current(), false,
					"a same-source acknowledgment grants no native focus authority")
				helpers.assert_eq(original.options.is_current(), false)
				helpers.assert_eq(state.acquisitions, 1)
				helpers.assert_eq(bridges, 1)
				helpers.assert_eq(writes, 0)
				helpers.assert_eq(state.view, original)
				helpers.assert_eq(state.receiver, receiver)
				helpers.assert_eq(onboarding.run("/virtual/replacement-config.toml"), false)
				helpers.assert_eq(state.focus_calls, 1)
				receiver({ body = { action = "finish", answers = {
					locale = "en", config_dir = "", operations = {},
				} } })
				helpers.assert_eq(writes, 0, "a retired bridge cannot resume configuration publication")
				helpers.assert_eq(state.acquisitions, 1)
				helpers.assert_eq(bridges, 1)
				state.refused = false
				receiver({ body = { action = "cancel" } })
				owners[1].settled = true
				helpers.assert_true(onboarding.run("/virtual/replacement-config.toml"))
				helpers.assert_eq(state.acquisitions, 2)
				helpers.assert_eq(bridges, 2)
				helpers.assert_true(state.view.options.is_current())
			end, function(err) return err end)
			hs.webview.usercontent.new = native_new
			writer.batch_write = batch_write
			if not called then error(primary, 0) end
		end)
	end)
end)
