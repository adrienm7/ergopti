--- tests/unit/ui/test_menu_gestures_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — gestures master toggle is pause-gated (F-MED-5)
--- DESCRIPTION:
--- The gesture engine's only fire gate is the shared CoreState.enabled flag, which
--- script_control.pause_all() drives via gestures.disable_all(). The menu's
--- gestures master toggle wrote that SAME flag with no pause guard, so two states
--- conflated:
---   (a) toggling gestures ON during pause set enabled=true → a swipe fired while
---       the script was paused (« pause = tout éteint » violated);
---   (b) toggling gestures OFF during pause desynced the _gestures_were_enabled
---       snapshot, so resume_all() re-enabled gestures against the user's intent.
---
--- Fix: pause-gate the master toggle, so pause owns the gesture state until
--- resume restores it. The switch is the command registered for the manifest's
--- gestures_toggle row (a row that opens a submenu is never clicked), so the
--- guard is on what that command does while paused: it refuses and touches
--- neither the engine nor the preference, and the parent row is greyed.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_toggle_fixture(previous, options, body)
	options = options or {}
	local names = {
		"modules.gestures", "ui.menu.menu_utils", "infra.dialog_util",
		"infra.i18n", "infra.manifest_menu", "ui.action_picker",
		"ui.menu.shortcut_utils", "infra.logger", "ui.menu.menu_gestures",
	}
	local saved = {}
	for _, name in ipairs(names) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local runtime = {
		enabled = previous,
		calls = {},
		saves = 0,
		notifications = 0,
		updates = 0,
	}
	local function lifecycle(name, desired)
		runtime.calls[#runtime.calls + 1] = name
		local index = #runtime.calls
		local mode = index == 1 and options.apply_mode or options.rollback_mode
		mode = mode or "true"
		-- The hostile apply mutates before refusing. A hostile inverse deliberately
		-- leaves that mutation owned so the test observes retained rollback debt.
		if index == 1 or mode == "true" then runtime.enabled = desired end
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		if mode == "throw" then error("synthetic gesture lifecycle refusal") end
		return true
	end
	package.loaded["modules.gestures"] = {
		DEFAULT_STATE = { gestures = false },
		enable_all = function() return lifecycle("enable", true) end,
		disable_all = function() return lifecycle("disable", false) end,
	}
	package.loaded["ui.menu.menu_utils"] = {}
	package.loaded["infra.dialog_util"] = {
		block_alert = function() return "button.activate" end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end, section = function(key) return key end }
	-- The switch is the command registered for the manifest's gestures_toggle
	-- row, captured where the menu hands it to the renderer.
	local render_ctx = nil
	package.loaded["infra.manifest_menu"] = { group_receiver = require("tests.support.declared_menu_parent_fixture").new().group_receiver, build = function(_, _, _, _, ctx)
		render_ctx = ctx
		return {}
	end }
	package.loaded["ui.action_picker"] = {}
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local state = { gestures = previous }
	local MenuGestures = require("ui.menu.menu_gestures")
	local item = MenuGestures.build({
		gestures = package.loaded["modules.gestures"],
		state = state,
		paused = options.paused == true,
		save_prefs = function()
			runtime.saves = runtime.saves + 1
			if options.save_mode == "false" then return false end
			if options.save_mode == "nil" then return nil end
			if options.save_mode == "throw" then error("synthetic gesture save refusal") end
			return true
		end,
		notify_feature = function() runtime.notifications = runtime.notifications + 1 end,
		updateMenu = function() runtime.updates = runtime.updates + 1 end,
	})
	local switch = {
		parent = item,
		action = render_ctx and render_ctx.commands and render_ctx.commands["gestures_toggle"],
	}
	local ok, err = xpcall(function()
		helpers.assert_nil(item.action, "the Gestures parent opens a submenu and must carry no action")
		helpers.assert_type(switch.action, "function", "the gestures switch must be registered")
		body(switch, state, runtime)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("menu_gestures: master toggle is pause-gated (F-MED-5)", function()
	for _, previous in ipairs({ false, true }) do
		helpers.it("refuses the switch while paused (gestures " .. tostring(previous) .. ")", function()
			with_toggle_fixture(previous, { paused = true }, function(switch, state, runtime)
				helpers.assert_eq(switch.action(), false, "the switch must refuse while paused")
				helpers.assert_eq(state.gestures, previous, "the preference must not move during a pause")
				helpers.assert_eq(runtime.calls, {}, "the gesture engine must not be touched during a pause")
				helpers.assert_eq(runtime.saves, 0, "nothing may be persisted during a pause")
			end)
		end)
	end

	helpers.it("greys the parent row while paused", function()
		with_toggle_fixture(true, { paused = true }, function(switch)
			helpers.assert_eq(switch.parent.disabled, true, "the gestures row must be greyed while paused")
			helpers.assert_eq(switch.parent.checked, true, "and keep reporting the stored preference")
		end)
	end)
end)

helpers.describe("menu_gestures: master toggle publishes only exact lifecycle commits", function()
	for _, previous in ipairs({ false, true }) do
		local direction = previous and "disable" or "enable"
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls back a mutate-then-" .. mode .. " " .. direction, function()
				with_toggle_fixture(previous, { apply_mode = mode }, function(switch, state, runtime)
					helpers.assert_eq(switch.action(), false)
					helpers.assert_eq(state.gestures, previous)
					helpers.assert_eq(runtime.enabled, previous)
					helpers.assert_eq(runtime.calls,
						previous and { "disable", "enable" } or { "enable", "disable" })
					helpers.assert_eq(runtime.saves, 0)
					helpers.assert_eq(runtime.notifications, 0)
					helpers.assert_eq(runtime.updates, 0)
				end)
			end)
		end

		for _, inverse_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains " .. direction .. " rollback debt on inverse "
				.. inverse_mode, function()
				with_toggle_fixture(previous, {
					apply_mode = "false", rollback_mode = inverse_mode,
				}, function(switch, state, runtime)
					helpers.assert_eq(switch.action(), false)
					helpers.assert_eq(state.gestures, previous)
					helpers.assert_eq(runtime.enabled, not previous,
						"an adverse inverse remains visible as runtime cleanup debt")
					helpers.assert_eq(#runtime.calls, 2)
					helpers.assert_eq(runtime.saves, 0)
					helpers.assert_eq(runtime.notifications, 0)
					helpers.assert_eq(runtime.updates, 0)
					helpers.assert_eq(switch.action(), false,
						"a retained rollback debt must block the next feature toggle")
					helpers.assert_eq(#runtime.calls, 3)
					helpers.assert_eq(runtime.calls[3], previous and "enable" or "disable",
						"the blocked retry must target only the exact prior posture")
					helpers.assert_eq(runtime.saves, 0)
				end)
			end)
		end

		for _, save_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls runtime back when gesture save returns " .. save_mode, function()
				with_toggle_fixture(previous, { save_mode = save_mode },
					function(switch, state, runtime)
						helpers.assert_eq(switch.action(), false)
						helpers.assert_eq(state.gestures, previous)
						helpers.assert_eq(runtime.enabled, previous)
						helpers.assert_eq(runtime.saves, 1)
						helpers.assert_eq(runtime.notifications, 0)
						helpers.assert_eq(runtime.updates, 0)
					end)
			end)

			for _, inverse_mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("retains exact debt when gesture save " .. save_mode
					.. " and inverse " .. inverse_mode, function()
					with_toggle_fixture(previous, {
						apply_mode = "true", rollback_mode = inverse_mode,
						save_mode = save_mode,
					}, function(switch, state, runtime)
						helpers.assert_eq(switch.action(), false)
						helpers.assert_eq(state.gestures, previous)
						helpers.assert_eq(runtime.enabled, not previous)
						helpers.assert_eq(runtime.saves, 1)
						helpers.assert_eq(runtime.notifications, 0)
						helpers.assert_eq(runtime.updates, 0)
						helpers.assert_eq(switch.action(), false)
						helpers.assert_eq(#runtime.calls, 3,
							"the next click retries only retained preference rollback debt")
						helpers.assert_eq(runtime.saves, 1,
							"debt settlement may not repeat the failed preference write")
					end)
				end)
			end
		end
	end
end)
