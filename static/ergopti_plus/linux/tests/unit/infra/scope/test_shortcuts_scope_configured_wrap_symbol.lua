--- tests/unit/infra/scope/test_shortcuts_scope_configured_wrap_symbol.lua

--- Exercises the actual shortcut readers, dispatchers and parameter owner.

package.loaded["tests.support.infra.scope.shortcuts_scope_fixture"] = nil
local Fixture = require("tests.support.infra.scope.shortcuts_scope_fixture")
local helpers, Sandbox, with_scope, with_collision_scope, COLLISION_BASE, NO_TAP_HOLDS, with_prediction_preflight =
	Fixture.helpers, Fixture.Sandbox, Fixture.with_scope, Fixture.with_collision_scope, Fixture.COLLISION_BASE, Fixture.NO_TAP_HOLDS, Fixture.with_prediction_preflight




helpers.describe("Linux configured wrap-symbol physical collision preflight", function()
	local WRAP_BASE = COLLISION_BASE:gsub("enabled = true", "enabled = true\nwrap_text_if_selected = true")
	local function unchanged(owners, controls, path, before)
		helpers.assert_eq(Sandbox.read_bytes(path), before)
		helpers.assert_eq(#controls.backups, 0); helpers.assert_eq(controls.runtime_calls, 0)
		helpers.assert_eq(controls.device_calls, 0); helpers.assert_eq(#controls.executed, 0)
		helpers.assert_eq(controls.pair_changes, 0); helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
	end

	for _, modifier in ipairs({ "none", "shift" }) do
		helpers.it("(wrap-configured-preflight) refuses an enabled " .. modifier .. " wrap trigger before any publication", function()
			with_collision_scope(WRAP_BASE, NO_TAP_HOLDS, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
				controls.chord_j_identity = "("
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_" .. modifier .. "_KeyJ",
					value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "collision")
				unchanged(owners, controls, path, before)
			end)
		end)
	end

	for _, modifier in ipairs({ "ctrl", "alt", "super" }) do
		helpers.it("(wrap-configured-preflight) " .. modifier .. " bypasses wrapping but gains no native delivery rights", function()
			with_collision_scope(WRAP_BASE, NO_TAP_HOLDS, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
				controls.chord_j_identity = "("
				controls.on_source = function() controls.delivery_available = false end
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_" .. modifier .. "_KeyJ",
					value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable")
				helpers.assert_eq(controls.source_reads, 1)
				unchanged(owners, controls, path, before)
			end)
		end)
	end

	helpers.it("(wrap-configured-preflight) disabled wrapping is not a guessed collision or native readiness", function()
		local source = '[shortcuts]\nenabled = true\nwrap_text_if_selected = false\n[shortcuts.keyboard]\nmagic_editor = "none"\n'
		with_collision_scope(source, NO_TAP_HOLDS, function(scope, owners, controls, path)
			local before = Sandbox.read_bytes(path)
			controls.chord_j_identity = "("
			controls.on_source = function() controls.delivery_available = false end
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ",
				value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "unavailable")
			unchanged(owners, controls, path, before)
		end)
	end)

	helpers.it("(wrap-configured-preflight) a real switch round trip during XKB observation revokes old claims", function()
		with_collision_scope(WRAP_BASE, NO_TAP_HOLDS, function(scope, owners, controls, path)
			local before, changed = Sandbox.read_bytes(path), false
			controls.chord_j_identity = "("
			controls.on_source = function()
				if changed then return end; changed = true
				local token = {}
				helpers.assert_true(owners.manager.acquire_configuration(token))
				helpers.assert_true(owners.manager.release_configuration(token))
			end
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ",
				value = "copy", intent = "keyboard_assignment" } })
			helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "source_changed")
			unchanged(owners, controls, path, before)
		end)
	end)

	helpers.it("(wrap-configured-preflight) explicit physical None preserves native intent without observing wrap reservations", function()
		with_scope(function(scope, owners, controls, path)
			local original, calls = owners.manager.capture_collision_inventory, 0
			owners.manager.capture_collision_inventory = function() calls = calls + 1; error("None does not acquire wrapping") end
			local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_none_KeyJ",
				value = "none", intent = "keyboard_assignment" } })
			owners.manager.capture_collision_inventory = original
			helpers.assert_eq(accepted, true, tostring(reason)); helpers.assert_eq(calls, 0)
			helpers.assert_eq(Sandbox.read_bytes(path):find('physical_none_KeyJ', 1, true) ~= nil, true)
			helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
		end, WRAP_BASE)
	end)
end)




helpers.describe("Linux genuine configured prediction collision preflight", function()
	local PREDICTION_BASE = COLLISION_BASE .. '[llm]\nenabled = true\n[llm.navigation]\nnav_modifiers = ["ctrl"]\nval_modifiers = ["shift"]\n'
	local function unchanged(owners, controls, path, before)
		helpers.assert_eq(Sandbox.read_bytes(path), before)
		helpers.assert_eq(#controls.backups, 0); helpers.assert_eq(controls.runtime_calls, 0)
		helpers.assert_eq(controls.device_calls, 0); helpers.assert_eq(#controls.executed, 0)
		helpers.assert_eq(controls.pair_changes, 0); helpers.assert_eq(owners.keyboard.physical_delivery_available(), false)
	end

	for _, case in ipairs({
		{ name = "original native navigation role", key = "physical_ctrl_ArrowUp" },
		{ name = "original native digit role", key = "physical_shift_Digit2" },
		{ name = "either-side Shift Tab", key = "physical_shift_Tab" },
		{ name = "possible live or agent Tab", key = "physical_none_Tab" },
		{ name = "actual native source typing a digit", key = "physical_shift_KeyJ", identity = "2" },
	}) do
		helpers.it("(prediction-configured-preflight) refuses " .. case.name .. " before publication", function()
			with_prediction_preflight(PREDICTION_BASE, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
				controls.chord_j_identity = case.identity
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = case.key,
					value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "collision")
				unchanged(owners, controls, path, before)
			end)
		end)
	end

	for _, known in ipairs({ false, true }) do
		helpers.it("(prediction-configured-preflight) unknown disabled AI plus " .. (known and "known collision" or "otherwise free input"), function()
			local source = COLLISION_BASE .. (known and 'ctrl_j = "copy"\n' or "") .. '[llm]\nenabled = false\n'
			with_prediction_preflight(source, function(scope, owners, controls, path)
				local before = Sandbox.read_bytes(path)
				helpers.assert_eq(owners.prediction.capture_collision_inventory(), nil)
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_ctrl_KeyJ",
					value = "copy", intent = "keyboard_assignment" } })
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, known and "collision" or "unavailable")
				unchanged(owners, controls, path, before)
			end)
		end)
	end

	for _, seam in ipairs({ "original factory", "actual request cancellation" }) do
		helpers.it("(prediction-configured-preflight) " .. seam .. " change revokes the source join", function()
			with_prediction_preflight(PREDICTION_BASE, function(scope, owners, controls, path)
				local before, changed = Sandbox.read_bytes(path), false
				local factory = owners.prediction.capture_collision_inventory
				controls.on_source = function()
					if changed then return end; changed = true
					if seam == "original factory" then owners.prediction.capture_collision_inventory = function() return nil end
					else owners.prediction.cancel() end
				end
				local accepted, reason = scope.edit({ { section = "shortcuts.keyboard", key = "physical_shift_Digit2",
					value = "copy", intent = "keyboard_assignment" } })
				owners.prediction.capture_collision_inventory = factory
				helpers.assert_eq(accepted, false); helpers.assert_eq(reason, "source_changed")
				unchanged(owners, controls, path, before)
			end)
		end)
	end
end)

