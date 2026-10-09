--- tests/unit/modules/shortcuts/test_start_transaction.lua

--- ==============================================================================
--- MODULE: Shortcuts Aggregate Startup Transaction
--- DESCRIPTION:
--- Drives the real shortcuts facade with controllable bindings and configurable
--- shortcut children. A partial child start must be rolled back and must never
--- be reported as a successful aggregate activation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the shortcuts facade with observable child lifecycle contracts.
--- @param controls table Per-child start modes and results.
--- @return table subject Loaded shortcuts facade.
--- @return table events Ordered lifecycle calls.
local function load_subject(controls)
	controls = controls or {}
	local events = {}

	local function start_child(name)
		return function(candidate)
			if name == "keyboard" then controls.keyboard_candidate = candidate end
			events[#events + 1] = "start:" .. name
			if controls[name .. "_mode"] == "throw" then
				error("START_THROW:" .. name)
			end
			local result = controls[name .. "_result"]
			if result == nil and controls[name .. "_has_result"] ~= true then return true end
			return result
		end
	end

	local function stop_child(name)
		return function()
			events[#events + 1] = "stop:" .. name
			return true
		end
	end

	package.loaded["modules.shortcuts.bindings"] = {
		DEFAULT_CHATGPT_URL = "https://example.invalid/",
		start = start_child("bindings"),
		stop = stop_child("bindings"),
		is_started = function() return false end,
	}
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
		start = start_child("keyboard"),
		stop = stop_child("keyboard"),
	}
	package.loaded["modules.gestures.actions"] = {
		resume_after_cleanup = start_child("actions"),
		force_cleanup = stop_child("actions"),
	}
	package.loaded["modules.shortcuts.script_control"] = {
		ACTIONS = {}, ACTION_LABELS = {},
		start = start_child("script_control"),
		stop = stop_child("script_control"),
		is_paused = function() return false end,
	}
	package.loaded["adapters.hotkey_registrar"] = {
		set_delivery_guard = function() return true end,
	}
	package.loaded["infra.startup_transaction"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.shortcuts"] = nil
	package.loaded["modules.shortcuts.init"] = nil

	return require("modules.shortcuts"), events
end





-- ============================================
-- ============================================
-- ======= 1/ Aggregate Commit Contract =======
-- ============================================
-- ============================================

helpers.describe("shortcuts aggregate start transaction", function()
	helpers.it("rolls back a refused shortcut action scope before exposing hotkeys", function()
		local subject, events = load_subject({
			actions_has_result = true,
			actions_result = false,
		})

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(table.concat(events, ","),
			"start:actions,stop:actions")
	end)

	helpers.it("returns exact true only after both child starts commit", function()
		local subject, events = load_subject()

		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(table.concat(events, ","),
			"start:actions,start:bindings,start:keyboard")
	end)

	helpers.it("rejects a bindings false before starting the keyboard child", function()
		local subject, events = load_subject({
			bindings_has_result = true,
			bindings_result = false,
		})

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(table.concat(events, ","), table.concat({
			"start:actions", "start:bindings", "stop:bindings", "stop:actions",
		}, ","))
	end)

	helpers.it("contains a bindings throw and rolls its partial ownership back", function()
		local subject, events = load_subject({bindings_mode = "throw"})

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(table.concat(events, ","), table.concat({
			"start:actions", "start:bindings", "stop:bindings", "stop:actions",
		}, ","))
	end)

	helpers.it("rolls keyboard refusal back before the committed bindings", function()
		local subject, events = load_subject({
			keyboard_has_result = true,
			keyboard_result = false,
		})

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(table.concat(events, ","), table.concat({
			"start:actions",
			"start:bindings",
			"start:keyboard",
			"stop:keyboard",
			"stop:bindings",
			"stop:actions",
		}, ","))
	end)

	helpers.it("rejects nil from a required child instead of treating it as success", function()
		local subject, events = load_subject({
			keyboard_has_result = true,
			keyboard_result = nil,
		})

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(table.concat(events, ","), table.concat({
			"start:actions", "start:bindings", "start:keyboard",
			"stop:keyboard", "stop:bindings", "stop:actions",
		}, ","))
	end)
end)

helpers.describe("shortcut candidate forwarding", function()
	helpers.it("passes the exact unpublished candidate through the real aggregate owner", function()
		local controls = {}
		local subject = load_subject(controls)
		local candidate = { shortcuts = { keyboard = { cmd_a = "send_text" } } }
		helpers.assert_eq(subject.pause_bindings("feature_toggle"), true)
		helpers.assert_eq(subject.resume_bindings("feature_toggle", candidate), true)
		helpers.assert_true(controls.keyboard_candidate == candidate)
	end)

	helpers.it("retains the claim after candidate refusal and permits exact recovery", function()
		local controls = { keyboard_has_result = true, keyboard_result = false }
		local subject, events = load_subject(controls)
		local candidate = { shortcuts = { keyboard = { cmd_a = "send_text" } } }
		helpers.assert_eq(subject.pause_bindings("feature_toggle"), true)
		helpers.assert_eq(subject.resume_bindings("feature_toggle", candidate), false)
		helpers.assert_true(controls.keyboard_candidate == candidate)
		helpers.assert_eq(events[#events - 1], "stop:bindings")
		helpers.assert_eq(events[#events], "stop:actions")
		controls.keyboard_result = true
		helpers.assert_eq(subject.resume_bindings("feature_toggle", {}), true)
		helpers.assert_eq(controls.keyboard_candidate, {})
	end)
end)

return true
