--- tests/unit/modules/shortcuts/pause_owners/test_shortcut_delivery.lua

--- ==============================================================================
--- MODULE: Pause Owner shortcut delivery Regressions
--- DESCRIPTION:
--- Preserves the behavioral pause-owner regression scenarios with a focused
--- fixture boundary. Shared fixtures create fresh runtime state per invocation.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixtures = require("tests.unit.modules.shortcuts.pause_owners.fixtures")
local reset_module = fixtures.reset_module
local load_inventory_context = fixtures.load_inventory_context

local function load_real_keep_awake_owner()
	local arm_mode = "true"
	local cancel_mode = "true"
	local handles = {}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, callback)
			if arm_mode == "throw" then error("keep-awake timer arm exploded") end
			local handle = { timer = {}, callback = callback }
			handles[#handles + 1] = handle
			if arm_mode == "false" then return handle, false end
			if arm_mode == "nil" then return handle, nil end
			return handle, true
		end,
		cancel = function(handle)
			if cancel_mode == "throw" then error("keep-awake timer cancel exploded") end
			if cancel_mode == "false" then return false end
			if cancel_mode == "nil" then return nil end
			handle.timer = nil
			return true
		end,
	}
	package.loaded["modules.shortcuts.actions.system"] = nil
	local system = helpers.load_with_stubs("modules.shortcuts.actions.system")
	return {
		system = system,
		handles = handles,
		set_arm_mode = function(mode) arm_mode = mode end,
		set_cancel_mode = function(mode) cancel_mode = mode end,
	}
end

helpers.describe("HS-012 real keep-awake pause child", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains keep-awake intent after timer cleanup " .. mode, function()
			local ctx = load_real_keep_awake_owner()
			helpers.assert_true(ctx.system.toggle_awake())
			helpers.assert_true(ctx.system.is_awake_active())
			ctx.set_cancel_mode(mode)
			helpers.assert_eq(ctx.system.pause_awake(), false)
			helpers.assert_eq(ctx.system.is_awake_active(), false)
			ctx.set_cancel_mode("true")
			helpers.assert_true(ctx.system.pause_awake())
			helpers.assert_true(ctx.system.resume_awake())
			helpers.assert_true(ctx.system.is_awake_active(),
				"the original keep-awake session must survive cleanup retry")
			helpers.assert_true(ctx.system.resume_awake(),
				"duplicate resume must not toggle the restored session off")
			helpers.assert_true(ctx.system.is_awake_active())
		end)

		helpers.it("retains keep-awake intent after timer rearm " .. mode, function()
			local ctx = load_real_keep_awake_owner()
			helpers.assert_true(ctx.system.toggle_awake())
			helpers.assert_true(ctx.system.pause_awake())
			ctx.set_arm_mode(mode)
			helpers.assert_eq(ctx.system.resume_awake(), false)
			helpers.assert_eq(ctx.system.is_awake_active(), false)
			ctx.set_arm_mode("true")
			helpers.assert_true(ctx.system.resume_awake())
			helpers.assert_true(ctx.system.is_awake_active(),
				"timer construction refusal must leave a retryable restore intent")
		end)
	end
end)

local function load_real_shortcut_delivery_owner()
	reset_module("tests.stubs.hs")
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	hs_stub.application.frontmostApplication = function()
		return { title = function() return "Fixture" end }
	end

	local handles = {}
	local wrap_handles = {}
	local delete_mode = "true"
	local lock_calls = 0
	local wrap_ax_calls = 0
	local function make_handle(callback, key, before_delete)
		local handle = { callback = callback, key = key, deleted = false, delete_calls = 0 }
		function handle:delete()
			self.delete_calls = self.delete_calls + 1
			if before_delete then before_delete(self) end
			if delete_mode == "throw" then error("hotkey delete exploded") end
			if delete_mode == "false" then return false end
			if delete_mode == "nil" then return nil end
			self.deleted = true
			return true
		end
		handles[#handles + 1] = handle
		return handle
	end
	hs_stub.hotkey.bind = function(_, key, callback)
		return make_handle(callback, key)
	end

	local function noop() return true end
	local function install_child_lifecycle(target, names)
		local paused = false
		target[names.pause] = function() paused = true; return true end
		target[names.resume] = function() paused = false; return true end
		target[names.stop] = function() paused = true; return true end
		target[names.is_paused] = function() return paused end
		target[names.has_pending] = function() return false end
	end
	local function make_wrap_handle(getter)
		local delivering = true
		local handle = make_handle(function()
			if not delivering then return false end
			wrap_ax_calls = wrap_ax_calls + 1
			if type(getter) == "function" then getter() end
			return false
		end, "wrap", function()
			delivering = false
		end)
		wrap_handles[#wrap_handles + 1] = handle
		return handle
	end
	local system_actions = setmetatable({
		bind_instant_screenshot = function() return make_handle(noop, "at_hash") end,
		bind_layer_scroll = function() return make_handle(noop, "layer_scroll") end,
		bind_wrap_text_if_selected = make_wrap_handle,
		bind_cmd_star = function() return make_handle(noop, "cmd_star") end,
		pause_awake = noop,
		resume_awake = noop,
		stop_awake = noop,
		lock_screen = function()
			lock_calls = lock_calls + 1
			return true
		end,
	}, { __index = function() return noop end })
	local inert_actions = setmetatable({}, { __index = function() return noop end })
	install_child_lifecycle(system_actions, {
		pause = "pause_mouse_actions",
		resume = "resume_mouse_actions",
		stop = "stop_mouse_actions",
		is_paused = "is_mouse_actions_paused",
		has_pending = "has_pending_mouse_action",
	})
	install_child_lifecycle(system_actions, {
		pause = "pause_pixel_actions",
		resume = "resume_pixel_actions",
		stop = "stop_pixel_actions",
		is_paused = "is_pixel_actions_paused",
		has_pending = "has_pending_pixel_action",
	})
	local screenshot_claims = {}
	system_actions.pause_screenshot_actions = function(parent)
		screenshot_claims[parent] = true
		return true
	end
	system_actions.resume_screenshot_actions = function(parent)
		screenshot_claims[parent] = nil
		return true
	end
	system_actions.stop_screenshot_actions = function(parent)
		screenshot_claims[parent] = true
		return true
	end
	system_actions.has_screenshot_pause_claim = function(parent)
		return screenshot_claims[parent] == true
	end
	system_actions.has_pending_screenshot_action = function() return false end
	install_child_lifecycle(inert_actions, {
		pause = "pause_text_actions",
		resume = "resume_text_actions",
		stop = "stop_text_actions",
		is_paused = "is_text_actions_paused",
		has_pending = "has_pending_text_action",
	})
	install_child_lifecycle(inert_actions, {
		pause = "pause_apps_actions",
		resume = "resume_apps_actions",
		stop = "stop_apps_actions",
		is_paused = "is_apps_actions_paused",
		has_pending = "has_pending_apps_action",
	})
	package.loaded["modules.shortcuts.actions.system"] = system_actions
	package.loaded["modules.shortcuts.actions.text"] = inert_actions
	package.loaded["modules.shortcuts.actions.apps"] = inert_actions
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return "https://example.invalid" end,
	}
	package.loaded["modules.keylogger"] = { log_shortcut = function() return true end }
	reset_module("modules.shortcuts.bindings")
	local bindings = require("modules.shortcuts.bindings")

	return {
		bindings = bindings,
		handles = handles,
		wrap_handles = wrap_handles,
		get_lock_calls = function() return lock_calls end,
		get_wrap_ax_calls = function() return wrap_ax_calls end,
		set_delete_mode = function(mode) delete_mode = mode end,
		latest_callback = function(key)
			for index = #handles, 1, -1 do
				if handles[index].key == key then return handles[index].callback end
			end
		end,
	}
end

helpers.describe("HS-012 real shortcut delivery fence", function()
	helpers.it("updates the live wrap preference without replacing its active native owner", function()
		local ctx = load_real_shortcut_delivery_owner()
		local first_getter_calls = 0
		local second_getter_calls = 0
		helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
			first_getter_calls = first_getter_calls + 1
			return {}
		end))
		helpers.assert_true(ctx.bindings.start())
		helpers.assert_eq(#ctx.wrap_handles, 1)
		local owner = ctx.wrap_handles[1]
		owner.callback()
		helpers.assert_eq(ctx.get_wrap_ax_calls(), 1)
		helpers.assert_eq(first_getter_calls, 1)

		helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
			second_getter_calls = second_getter_calls + 1
			return {}
		end))
		helpers.assert_eq(#ctx.wrap_handles, 1,
			"a live preference update must not acquire a replacement eventtap")
		helpers.assert_eq(owner.delete_calls, 0,
			"a live preference update must not tear down the active eventtap")
		owner.callback()
		helpers.assert_eq(ctx.get_wrap_ax_calls(), 2)
		helpers.assert_eq(first_getter_calls, 1)
		helpers.assert_eq(second_getter_calls, 1,
			"the unchanged native callback must resolve the newly published getter")

		helpers.assert_true(ctx.bindings.stop())
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("keeps a retained native hotkey inert after rollback delete " .. mode, function()
			local ctx = load_real_shortcut_delivery_owner()
			helpers.assert_true(ctx.bindings.start())
			local initial_callback = ctx.latest_callback("l")
			helpers.assert_not_nil(initial_callback)
			initial_callback()
			helpers.assert_eq(ctx.get_lock_calls(), 1,
				"positive control proves the real direct hotkey callback is live")

			local script_control = load_inventory_context({
				shortcuts = {
					is_bindings_started = ctx.bindings.is_started,
					pause_bindings = ctx.bindings.pause,
					resume_bindings = ctx.bindings.resume_after_pause,
					release_bindings_pause_claim = function() return true end,
				},
				fail_owner = "remote_warmup",
				fail_mode = "false",
				fail_direction = "resume",
			})
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())

			ctx.set_delete_mode(mode)
			helpers.assert_eq(script_control.resume_all(), false,
				"a later resume refusal must roll the real bindings owner back")
			helpers.assert_true(script_control.is_paused())
			local retained_callback = ctx.latest_callback("l")
			helpers.assert_not_nil(retained_callback)
			retained_callback()
			helpers.assert_eq(ctx.get_lock_calls(), 1,
				"a retained native callback must be logically fenced under PAUSED")

			ctx.set_delete_mode("true")
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			local resumed_callback = ctx.latest_callback("l")
			helpers.assert_not_nil(resumed_callback)
			resumed_callback()
			helpers.assert_eq(ctx.get_lock_calls(), 2,
				"delivery must reopen exactly after the successful global resume")
			helpers.assert_true(ctx.bindings.stop())
			script_control.stop()
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact wrap owner when menu rewiring follows rollback delete " .. mode, function()
			local ctx = load_real_shortcut_delivery_owner()
			local getter_calls = 0
			helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
				getter_calls = getter_calls + 1
				return {}
			end))
			helpers.assert_true(ctx.bindings.start())
			helpers.assert_eq(#ctx.wrap_handles, 1)
			local first_owner = ctx.wrap_handles[1]

			local script_control = load_inventory_context({
				shortcuts = {
					is_bindings_started = ctx.bindings.is_started,
					pause_bindings = ctx.bindings.pause,
					resume_bindings = ctx.bindings.resume_after_pause,
					release_bindings_pause_claim = function() return true end,
				},
				fail_owner = "remote_warmup",
				fail_mode = "false",
				fail_direction = "resume",
			})
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(first_owner.deleted,
				"the owner active before PAUSE must settle before the state is published")

			ctx.set_delete_mode(mode)
			helpers.assert_eq(script_control.resume_all(), false,
				"the later owner refusal must roll the newly resumed bindings back")
			helpers.assert_true(script_control.is_paused())
			helpers.assert_eq(#ctx.wrap_handles, 2)
			local retained_owner = ctx.wrap_handles[2]
			helpers.assert_eq(retained_owner.delete_calls, 1,
				"rollback must retain the exact native owner whose delete did not settle")
			retained_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 0,
				"the retained callback must already be logically fenced under PAUSED")

			local replacement_getter_calls = 0
			helpers.assert_true(ctx.bindings.set_wrap_pairs_getter(function()
				replacement_getter_calls = replacement_getter_calls + 1
				return {}
			end), "menu rewiring may publish preference state while native cleanup is pending")
			helpers.assert_eq(#ctx.wrap_handles, 2,
				"menu rewiring under PAUSED must not acquire a sibling eventtap")
			helpers.assert_eq(retained_owner.delete_calls, 1,
				"the setter must leave the retained cleanup capability to ScriptControl")
			retained_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 0)
			helpers.assert_eq(getter_calls, 0)
			helpers.assert_eq(replacement_getter_calls, 0)

			ctx.set_delete_mode("true")
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(retained_owner.delete_calls, 2,
				"retry must settle the same retained owner before acquiring its successor")
			helpers.assert_true(retained_owner.deleted)
			helpers.assert_eq(#ctx.wrap_handles, 3)
			local resumed_owner = ctx.wrap_handles[3]
			helpers.assert_true(resumed_owner ~= retained_owner)
			retained_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 0,
				"the old owner stays inert after RESUMED")
			resumed_owner.callback()
			helpers.assert_eq(ctx.get_wrap_ax_calls(), 1,
				"exactly the post-commit owner may reach the AX path")
			helpers.assert_eq(getter_calls, 0)
			helpers.assert_eq(replacement_getter_calls, 1,
				"the deferred preference must be installed on the sole successor")

			helpers.assert_true(ctx.bindings.stop())
			script_control.stop()
		end)
	end
end)
