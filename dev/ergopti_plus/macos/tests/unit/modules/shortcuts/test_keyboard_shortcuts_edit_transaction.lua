--- tests/unit/modules/shortcuts/test_keyboard_shortcuts_edit_transaction.lua

--- ==============================================================================
--- MODULE: Configurable Keyboard Shortcut Edit Transaction
--- DESCRIPTION:
--- Exercises live shortcut edits against native acquisition/enable refusal and
--- persistence failure. The exact handle must survive for retry, action-to-action
--- edits must not churn the OS chord, and callbacks must resolve the committed
--- action at delivery rather than capturing an obsolete value.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.hotkey_registrar",
	"adapters.file_system",
	"infra.paths",
	"infra.logger",
	"modules.gestures.actions",
	"modules.shortcuts.keyboard_shortcuts",
}

--- Loads the real shortcut owner with one controllable native slot.
--- @param initial_action string
--- @param scenario function
local function with_subject(initial_action, scenario)
	local prior = {}
	for _, name in ipairs(MODULES) do prior[name] = package.loaded[name] end
	local prior_hs = _G.hs

	local key = "keyboard_shortcut_cmd_a"
	local store = {[key] = initial_action}
	local controls = {
		bind_refuses = false,
		bind_hook = nil,
		set_enabled_hook = nil,
		set_enabled_refuses_once = false,
		settings_throw_after_write_once = false,
	}
	local counters = {bind = 0, unbind = 0, set_enabled = 0, settings_set = 0}
	local handles = {}
	local unbound_handles = {}
	local fired = {}

	local registrar = {}
	function registrar.bind(chord, callback)
		counters.bind = counters.bind + 1
		if controls.bind_refuses then return nil end
		local handle = {
			id = counters.bind,
			chord = chord,
			callback = callback,
			enabled = true,
			native_settled = true,
		}
		handles[#handles + 1] = handle
		if type(controls.bind_hook) == "function" then controls.bind_hook(handle) end
		return handle
	end
	function registrar.setEnabled(handle, enabled)
		counters.set_enabled = counters.set_enabled + 1
		if type(controls.set_enabled_hook) == "function" then
			controls.set_enabled_hook(handle, enabled)
		end
		if controls.set_enabled_refuses_once then
			controls.set_enabled_refuses_once = false
			if not enabled then handle.enabled = false end
			handle.native_settled = false
			return false
		end
		handle.enabled = enabled and true or false
		handle.native_settled = true
		return true
	end
	function registrar.unbind(handle)
		counters.unbind = counters.unbind + 1
		unbound_handles[#unbound_handles + 1] = handle
		handle.enabled = false
		return true
	end

	package.loaded["adapters.hotkey_registrar"] = registrar
	package.loaded["adapters.file_system"] = {
		read = function() return '{"keys":[{"id":"a","label":"A"}]}' end,
	}
	package.loaded["infra.paths"] = {shared = function() return "catalogue.json" end}
	local logger = helpers.make_logger_stub()
	logger.callback = function(_, _, fn, ...)
		local ok, result = xpcall(fn, debug.traceback, ...)
		return ok, result
	end
	package.loaded["infra.logger"] = logger
	package.loaded["modules.gestures.actions"] = {
		execute_single = function(action_id)
			fired[#fired + 1] = action_id
			return true
		end,
	}
	package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil

	local subject
	local ok, err = xpcall(function()
		subject = helpers.load_with_stubs("modules.shortcuts.keyboard_shortcuts", {
			settings = {
				getKeys = function() return {key} end,
				get = function(setting_key) return store[setting_key] end,
				set = function(setting_key, value)
					counters.settings_set = counters.settings_set + 1
					store[setting_key] = value
					if controls.settings_throw_after_write_once then
						controls.settings_throw_after_write_once = false
						error("synthetic settings failure after write")
					end
				end,
			},
			json = {
				decode = function()
					return {keys = {{id = "a", label = "A"}}}
				end,
			},
		})
		helpers.assert_eq(subject.start(), true)
		scenario(subject, {
			controls = controls,
			counters = counters,
			handles = handles,
			unbound_handles = unbound_handles,
			fired = fired,
			store = store,
			setting_key = key,
		})
	end, debug.traceback)

	if subject and type(subject.stop) == "function" then pcall(subject.stop) end
	for _, name in ipairs(MODULES) do package.loaded[name] = prior[name] end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end





-- ==========================================
-- ==========================================
-- ======= 1/ Edit Commit Contract ==========
-- ==========================================
-- ==========================================

helpers.describe("configurable shortcut edit transaction (HS-013)", function()
	helpers.it("changes an active action without native chord churn", function()
		with_subject("copy_selection", function(subject, ctx)
			local exact = ctx.handles[1]
			local binds = ctx.counters.bind
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), true)
			helpers.assert_eq(ctx.counters.bind, binds, "action edits must reuse the live chord")
			helpers.assert_eq(ctx.counters.unbind, 0, "action edits must not release the chord")
			helpers.assert_eq(ctx.counters.set_enabled, 0, "an active chord stays active")
			exact.callback()
			helpers.assert_eq(ctx.fired[#ctx.fired], "paste_plain",
				"the retained callback must resolve the newly committed action")
		end)
	end)

	helpers.it("keeps action, setting, and exact handle when persistence raises", function()
		with_subject("copy_selection", function(subject, ctx)
			local exact = ctx.handles[1]
			ctx.controls.settings_throw_after_write_once = true
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), false)
			helpers.assert_eq(subject.get_action("cmd_a"), "copy_selection")
			helpers.assert_eq(ctx.store[ctx.setting_key], "copy_selection",
				"a write that raises after mutation must restore the exact prior setting")
			helpers.assert_eq(ctx.handles[1], exact)
			helpers.assert_eq(ctx.counters.bind, 1)
			helpers.assert_eq(ctx.counters.unbind, 0)
			exact.callback()
			helpers.assert_eq(ctx.fired[#ctx.fired], "copy_selection")
		end)
	end)

	helpers.it("retains a refused disable and retries the same native handle", function()
		with_subject("copy_selection", function(subject, ctx)
			local exact = ctx.handles[1]
			ctx.controls.set_enabled_refuses_once = true
			helpers.assert_eq(subject.set_action("cmd_a", "none"), false)
			helpers.assert_eq(subject.get_action("cmd_a"), "copy_selection")
			helpers.assert_eq(ctx.store[ctx.setting_key], "copy_selection")
			helpers.assert_eq(ctx.counters.unbind, 0)
			helpers.assert_eq(ctx.handles[1], exact)

			helpers.assert_eq(subject.set_action("cmd_a", "none"), true)
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(ctx.handles[1], exact)
			helpers.assert_eq(ctx.counters.bind, 1, "retry must not allocate a successor")
			helpers.assert_eq(exact.enabled, false)
		end)
	end)

	helpers.it("retains an inert fresh candidate across persistence failure", function()
		with_subject("none", function(subject, ctx)
			ctx.controls.settings_throw_after_write_once = true
			ctx.controls.set_enabled_refuses_once = true
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), false)
			local exact = ctx.handles[1]
			helpers.assert_true(exact ~= nil, "the acquired handle must remain owned")
			helpers.assert_eq(exact.enabled, false, "failed publication must fence delivery")
			helpers.assert_eq(exact.native_settled, false,
				"a refused compensation must remain explicit cleanup debt")
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(ctx.store[ctx.setting_key], "none")

			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), true)
			helpers.assert_eq(ctx.handles[1], exact)
			helpers.assert_eq(ctx.counters.bind, 1, "retry must re-enable the exact candidate")
			helpers.assert_eq(exact.enabled, true)
			exact.callback()
			helpers.assert_eq(ctx.fired[#ctx.fired], "paste_plain")
		end)
	end)

	helpers.it("leaves a fresh assignment unchanged when native bind is refused", function()
		with_subject("none", function(subject, ctx)
			ctx.controls.bind_refuses = true
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), false)
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(ctx.store[ctx.setting_key], "none")
			helpers.assert_eq(#ctx.handles, 0)
		end)
	end)

	helpers.it("keeps a none-to-action factory visible to re-entrant PAUSE", function()
		with_subject("none", function(subject, ctx)
			local nested_pause = nil
			ctx.controls.bind_hook = function()
				ctx.controls.bind_hook = nil
				nested_pause = subject.pause()
			end
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), false)
			helpers.assert_eq(nested_pause, false,
				"PAUSE cannot certify settlement while Registrar.bind is in flight")
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(ctx.store[ctx.setting_key], "none")
			helpers.assert_eq(ctx.counters.unbind, 1)
			helpers.assert_eq(ctx.handles[1].enabled, false)
			helpers.assert_eq(ctx.handles[1].callback(), false)
			helpers.assert_eq(#ctx.fired, 0)
			helpers.assert_eq(subject.pause(), true)
		end)
	end)

	helpers.it("keeps retained-handle re-enable visible to re-entrant PAUSE", function()
		with_subject("none", function(subject, ctx)
			ctx.controls.settings_throw_after_write_once = true
			ctx.controls.set_enabled_refuses_once = true
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), false)
			local exact = ctx.handles[1]
			local nested_pause = nil
			ctx.controls.set_enabled_hook = function()
				ctx.controls.set_enabled_hook = nil
				nested_pause = subject.pause()
			end
			helpers.assert_eq(subject.set_action("cmd_a", "paste_plain"), false)
			helpers.assert_eq(nested_pause, false)
			helpers.assert_eq(ctx.unbound_handles[1] == exact, true)
			helpers.assert_eq(ctx.unbound_handles[2] == exact, true,
				"the superseded native re-enable must compensate the same handle")
			helpers.assert_eq(exact.enabled, false)
			helpers.assert_eq(subject.get_action("cmd_a"), "none")
			helpers.assert_eq(subject.pause(), true)
		end)
	end)
end)

return true
