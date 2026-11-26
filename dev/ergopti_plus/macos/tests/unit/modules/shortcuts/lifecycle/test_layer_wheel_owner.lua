--- tests/unit/modules/shortcuts/lifecycle/test_layer_wheel_owner.lua

--- ==============================================================================
--- MODULE: Navigation Layer Wheel Owner Regression (BNM-1)
--- DESCRIPTION:
--- The navigation layer's wheel stopped when the Shortcuts switch was off: it
--- was a child of the bindings layer, which pause_bindings() pauses whole. On
--- Windows and Linux only the layer gates the wheel, and the macOS menu says it
--- is no shortcut. Its owner now lives outside the Shortcuts-gated layer and
--- the script pause holds it back as a step of its own.
---
--- FEATURES & RATIONALE:
--- 1. Real Owners: the real Shortcuts facade over the real Bindings registry,
---    so a wheel owned by Bindings again is released by pause_bindings() here.
--- 2. Real Pause: the real ScriptControl pause and resume transaction drives the
---    real wheel owner, so a pause that forgets the wheel leaves it bound.
--- 3. Native Accounting: the scroll tap is a counted native handle, observed
---    live until its exact delete.
--- ==============================================================================

local helpers = require("tests.helpers")
local BindingsFixture = require("tests.support.shortcut_bindings_fixture")
local with_pause_context = require("tests.support.pause_transaction_fixture").with_context

local VOLUME_UP = { code = "WheelUp", strokes = { { system = "SOUND_UP" } } }

--- Counts the live scroll taps of the navigation layer's wheel.
--- @param ctx table Bindings fixture observations.
--- @return integer count
local function live_wheels(ctx)
	local count = 0
	for handle in pairs(ctx.live) do
		if handle.id == "layer_wheel" then count = count + 1 end
	end
	return count
end

--- Loads the real Shortcuts facade over the fixture's real Bindings registry.
--- @param bindings table Real Bindings loaded by the fixture.
--- @param callback function Receives the facade.
local function with_shortcuts(bindings, callback)
	return helpers.with_stub_scope({
		"modules.shortcuts",
		"modules.shortcuts.init",
		"modules.shortcuts.layer_wheel",
		"modules.shortcuts.script_control",
		"modules.shortcuts.keyboard_shortcuts",
		"platform.input.hotkey_registrar",
	}, function()
		package.loaded["modules.shortcuts.bindings"] = bindings
		local actions = package.loaded["gestures.engine.actions"]
		actions.force_cleanup = function() return true end
		actions.resume_after_cleanup = function() return true end
		package.loaded["platform.input.hotkey_registrar"] = { set_delivery_guard = function() return true end }
		package.loaded["modules.shortcuts.script_control"] = {
			ACTIONS = {}, ACTION_LABELS = {},
			start = function() return true end,
			stop = function() return true end,
			is_paused = function() return false end,
		}
		local keyboard = {}
		for _, name in ipairs({ "start", "stop", "pause", "resume_after_pause", "release_pause_admission" }) do
			keyboard[name] = function() return true end
		end
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = keyboard
		package.loaded["modules.shortcuts"] = nil
		package.loaded["modules.shortcuts.layer_wheel"] = nil
		return callback(require("modules.shortcuts"))
	end)
end

helpers.describe("navigation layer wheel: no Shortcuts switch gates it (BNM-1)", function()
	helpers.it("pause_bindings leaves the wheel bound while the bindings layer pauses", function()
		BindingsFixture.with_bindings(function(bindings, ctx)
			ctx.wheel.vertical[1] = VOLUME_UP
			with_shortcuts(bindings, function(shortcuts)
				helpers.assert_eq(shortcuts.start(), true)
				helpers.assert_eq(live_wheels(ctx), 1, "a layer that binds the wheel takes the scroll wheel at start")

				helpers.assert_eq(shortcuts.pause_bindings("feature_toggle"), true)
				helpers.assert_eq(bindings.is_started(), false, "the Shortcuts switch still pauses the bindings layer")
				helpers.assert_eq(live_wheels(ctx), 1, "the Shortcuts switch must leave the layer's wheel bound")

				helpers.assert_eq(shortcuts.resume_bindings("feature_toggle"), true)
				helpers.assert_eq(live_wheels(ctx), 1, "switching Shortcuts back on must not duplicate the scroll tap")

				helpers.assert_eq(shortcuts.stop(), true)
				helpers.assert_eq(live_wheels(ctx), 0, "the subsystem stop releases the wheel")
			end)
		end)
	end)
end)

helpers.describe("navigation layer wheel: a script pause still holds it back (BNM-1)", function()
	helpers.it("the ScriptControl pause releases the scroll tap and its resume binds it again", function()
		local live = {}
		local function count()
			local n = 0
			for _ in pairs(live) do n = n + 1 end
			return n
		end
		helpers.with_stub_scope({
			"modules.shortcuts.layer_wheel",
			"modules.shortcuts.actions.system",
			"platform.remap.nav_layer",
		}, function()
			package.loaded["modules.shortcuts.actions.system"] = {
				bind_layer_wheel = function(admission)
					local handle = { admission = admission }
					live[handle] = true
					handle.delete = function() live[handle] = nil; return true end
					return handle
				end,
			}
			package.loaded["platform.remap.nav_layer"] = {
				load = function() return { wheel = { vertical = { [1] = VOLUME_UP }, horizontal = {} } } end,
			}
			local wheel
			with_pause_context({
				shortcuts_factory = function(_, record, inverse, snapshot)
					package.loaded["modules.shortcuts.layer_wheel"] = nil
					wheel = require("modules.shortcuts.layer_wheel")
					helpers.assert_eq(wheel.start(), true)
					return {
						pause_bindings = record("shortcuts_pause"),
						resume_bindings = inverse("shortcuts_resume"),
						release_bindings_pause_claim = record("shortcuts_release_claim"),
						is_bindings_started = snapshot("shortcuts_snapshot"),
						pause_layer_wheel = wheel.pause,
						resume_layer_wheel = wheel.resume,
					}
				end,
			}, function(script_control, ctx)
				helpers.assert_eq(count(), 1, "the wheel is bound before the pause")
				local tap = next(live)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callback(true, "paused")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_eq(count(), 0, "a script pause must release the layer's scroll tap")
				helpers.assert_eq(tap.admission(), false, "a retained callback is inert behind the pause")

				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callback(true, "resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(count(), 1, "the resume binds the layer's wheel again")
				helpers.assert_eq(next(live).admission(), true)
				helpers.assert_true(script_control.stop())
				helpers.assert_eq(wheel.stop(), true)
				helpers.assert_eq(count(), 0)
			end)
		end)
	end)

	helpers.it("a layers.toml edit behind the pause binds nothing until the resume reads it", function()
		local live = {}
		local file_wheel = { vertical = {}, horizontal = {} }
		helpers.with_stub_scope({
			"modules.shortcuts.layer_wheel",
			"modules.shortcuts.actions.system",
			"platform.remap.nav_layer",
		}, function()
			package.loaded["modules.shortcuts.actions.system"] = {
				bind_layer_wheel = function(_, slot)
					local handle = { slot = slot }
					live[handle] = true
					handle.delete = function() live[handle] = nil; return true end
					return handle
				end,
			}
			package.loaded["platform.remap.nav_layer"] = { load = function() return { wheel = file_wheel } end }
			package.loaded["modules.shortcuts.layer_wheel"] = nil
			local wheel = require("modules.shortcuts.layer_wheel")
			helpers.assert_eq(wheel.start(), true)
			helpers.assert_eq(wheel.is_bound(), false, "a layer without a wheel binding owns no input")
			helpers.assert_eq(wheel.pause(), true)
			file_wheel.vertical[1] = VOLUME_UP
			helpers.assert_eq(wheel.reconcile(), true)
			helpers.assert_nil(next(live), "an edit behind the pause owns no input")
			helpers.assert_eq(wheel.resume(), true)
			helpers.assert_eq(wheel.is_bound(), true, "the resume reads the edited file")
			helpers.assert_eq(next(live).slot("vertical", 1), VOLUME_UP)
			helpers.assert_nil(next(live).slot("vertical", -1), "an unbound direction scrolls")
			file_wheel.vertical[1] = nil
			helpers.assert_eq(wheel.reconcile(), true)
			helpers.assert_eq(wheel.is_bound(), false, "removing the last wheel binding releases the owner")
			helpers.assert_eq(wheel.stop(), true)
		end)
	end)
end)

helpers.describe("navigation layer wheel: exact release identity", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the scroll tap when its delete answers " .. mode .. " and settles on retry", function()
			local release_mode = mode
			local handles = {}
			helpers.with_stub_scope({
				"modules.shortcuts.layer_wheel",
				"modules.shortcuts.actions.system",
				"platform.remap.nav_layer",
			}, function()
				package.loaded["modules.shortcuts.actions.system"] = {
					bind_layer_wheel = function(admission)
						local handle = { admission = admission, delete_calls = 0 }
						handle.delete = function()
							handle.delete_calls = handle.delete_calls + 1
							if release_mode == "throw" then error("delete exploded") end
							if release_mode == "nil" then return nil end
							return release_mode == "true"
						end
						handles[#handles + 1] = handle
						return handle
					end,
				}
				package.loaded["platform.remap.nav_layer"] = {
					load = function() return { wheel = { vertical = { [1] = VOLUME_UP }, horizontal = {} } } end,
				}
				package.loaded["modules.shortcuts.layer_wheel"] = nil
				local wheel = require("modules.shortcuts.layer_wheel")
				helpers.assert_eq(wheel.start(), true)
				helpers.assert_eq(wheel.pause(), false, "an ambiguous release cannot settle the pause")
				helpers.assert_eq(wheel.is_bound(), true, "the exact handle is retained for the retry")
				helpers.assert_eq(handles[1].admission(), false, "the retained callback is inert behind the pause")
				release_mode = "true"
				helpers.assert_eq(wheel.pause(), true, "the pause retry releases the retained handle")
				helpers.assert_eq(handles[1].delete_calls, 2)
				helpers.assert_eq(wheel.resume(), true)
				helpers.assert_eq(#handles, 2, "the resume binds a fresh scroll tap")
				helpers.assert_eq(wheel.stop(), true)
			end)
		end)
	end
end)
