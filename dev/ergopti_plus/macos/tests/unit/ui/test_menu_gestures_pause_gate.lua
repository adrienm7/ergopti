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
--- Fix: pause-gate the master toggle (disabled + nil fn while paused), mirroring
--- the hotstrings master toggle, so pause owns the gesture state until resume
--- restores it. Pinned at source: the master toggle's fn must be gated on
--- `not paused` and the item carries `disabled = paused`.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_gestures: master toggle is pause-gated (F-MED-5)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/menu/menu_gestures.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local DISABLED_GESTURE_ACTION")
		helpers.assert_true(src ~= nil, "ui/menu/menu_gestures.lua source must be locatable")
		return src
	end

	-- `action`, the provider field, since the tray root became row data on
	-- 2026-08-07. The rule is unchanged: the CALLBACK must not exist while paused.
	helpers.it("gates the master-toggle callback on `not paused`", function()
		local src = read_src()
		local gate_pos = src:find("action  = (not paused) and function()", 1, true)
		local body_pos = src:find("local previous = state.gestures == true", 1, true)
		helpers.assert_true(gate_pos ~= nil,
			"the gestures master toggle callback must be gated on `not paused`")
		helpers.assert_true(body_pos ~= nil,
			"the transactional master-toggle body must still snapshot the prior state")
		helpers.assert_true(gate_pos < body_pos, "the `not paused` gate must wrap the toggle body")
	end)

	helpers.it("marks the master toggle disabled while paused", function()
		local src = read_src()
		-- Pin the master toggle specifically (slot items also use disabled=paused).
		local master = src:match("local item = {.-local previous = state.gestures == true")
		helpers.assert_true(master ~= nil, "master toggle item block must be locatable")
		helpers.assert_true(master:find("disabled = paused or nil", 1, true) ~= nil,
			"the gestures master toggle must carry `disabled = paused or nil`")
	end)
end)

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
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.manifest_menu"] = { build = function() return {} end }
	package.loaded["ui.action_picker"] = {}
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["infra.logger"] = helpers.make_logger_stub()

	local state = { gestures = previous }
	local MenuGestures = require("ui.menu.menu_gestures")
	local item = MenuGestures.build({
		gestures = package.loaded["modules.gestures"],
		state = state,
		paused = false,
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
	local ok, err = xpcall(function() body(item, state, runtime) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("menu_gestures: master toggle publishes only exact lifecycle commits", function()
	for _, previous in ipairs({ false, true }) do
		local direction = previous and "disable" or "enable"
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("rolls back a mutate-then-" .. mode .. " " .. direction, function()
				with_toggle_fixture(previous, { apply_mode = mode }, function(item, state, runtime)
					helpers.assert_eq(item.action(), false)
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
				}, function(item, state, runtime)
					helpers.assert_eq(item.action(), false)
					helpers.assert_eq(state.gestures, previous)
					helpers.assert_eq(runtime.enabled, not previous,
						"an adverse inverse remains visible as runtime cleanup debt")
					helpers.assert_eq(#runtime.calls, 2)
					helpers.assert_eq(runtime.saves, 0)
					helpers.assert_eq(runtime.notifications, 0)
					helpers.assert_eq(runtime.updates, 0)
					helpers.assert_eq(item.action(), false,
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
					function(item, state, runtime)
						helpers.assert_eq(item.action(), false)
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
					}, function(item, state, runtime)
						helpers.assert_eq(item.action(), false)
						helpers.assert_eq(state.gestures, previous)
						helpers.assert_eq(runtime.enabled, not previous)
						helpers.assert_eq(runtime.saves, 1)
						helpers.assert_eq(runtime.notifications, 0)
						helpers.assert_eq(runtime.updates, 0)
						helpers.assert_eq(item.action(), false)
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
