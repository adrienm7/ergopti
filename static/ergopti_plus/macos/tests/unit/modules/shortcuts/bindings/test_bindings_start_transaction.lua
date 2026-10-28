--- tests/unit/modules/shortcuts/bindings/test_bindings_start_transaction.lua

--- ==============================================================================
--- MODULE: Static Shortcut Bindings Startup Transaction
--- DESCRIPTION:
--- Drives the real bindings lifecycle through a refused factory and a native
--- cleanup exception. One refused hotkey fails alone: the start commits every
--- sibling, names the refused one and retries it, while an unreleased exact
--- handle must remain retryable instead of forgotten.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real binding registry with controllable hotkey factories.
--- @return table subject Loaded bindings module.
--- @return table controls Mutable failure controls.
--- @return table counters Observable factory and teardown counts.
local function load_subject()
	local controls = {
		refuse_special = false,
		refuse_native = false,
		delete_throws_once = false,
	}
	local counters = {created = 0, deleted = 0, stop_awake = 0}

	local function handle()
		counters.created = counters.created + 1
		return {
			delete = function()
				counters.deleted = counters.deleted + 1
				if controls.delete_throws_once then
					controls.delete_throws_once = false
					error("DELETE_THROW")
				end
				return true
			end,
		}
	end

	local function special_factory()
		-- Four registry entries share this factory. Let the first one commit so a
		-- later one refuses after ownership exists, independent of pairs() order.
		if controls.refuse_special and counters.created > 0 then return nil end
		return handle()
	end
	local mouse_paused = false
	local pixel_paused = false
	local screenshot_claims = {}

	package.loaded["modules.shortcuts.actions.system"] = {
		stop_awake = function() counters.stop_awake = counters.stop_awake + 1; return true end,
		bind_tap_keys = special_factory,
		bind_layer_wheel = special_factory,
		bind_wrap_text_if_selected = special_factory,
		bind_cmd_star = special_factory,
		toggle_awake = function() end,
		interactive_screenshot = function() end,
		toggle_display_mirror = function() end,
		copy_pixel_color = function() end,
		toggle_capslock = function() end,
		lock_screen = function() end,
		open_emoji_picker = function() end,
		spotlight_mouse = function() end,
		teleport_mouse = function() end,
		pause_mouse_actions = function() mouse_paused = true; return true end,
		resume_mouse_actions = function() mouse_paused = false; return true end,
		stop_mouse_actions = function() mouse_paused = true; return true end,
		is_mouse_actions_paused = function() return mouse_paused end,
		has_pending_mouse_action = function() return false end,
		pause_pixel_actions = function() pixel_paused = true; return true end,
		resume_pixel_actions = function() pixel_paused = false; return true end,
		stop_pixel_actions = function() pixel_paused = true; return true end,
		is_pixel_actions_paused = function() return pixel_paused end,
		has_pending_pixel_action = function() return false end,
		pause_screenshot_actions = function(parent)
			screenshot_claims[parent] = true
			return true
		end,
		resume_screenshot_actions = function(parent)
			screenshot_claims[parent] = nil
			return true
		end,
		stop_screenshot_actions = function(parent)
			screenshot_claims[parent] = true
			return true
		end,
		has_screenshot_pause_claim = function(parent)
			return screenshot_claims[parent] == true
		end,
		has_pending_screenshot_action = function() return false end,
	}
	package.loaded["infra.i18n"] = {get = function(key) return key end}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.shortcuts.bindings"] = nil
	-- The registrar reads the active keymap through the hs it captured at load:
	-- reload it under this scenario's stub so a cleared key is observed.
	package.loaded["adapters.hotkey_registrar"] = nil

	local subject = helpers.load_with_stubs("modules.shortcuts.bindings", {
		hotkey = {bind = function()
			if controls.refuse_native then return nil end
			return handle()
		end},
	})
	require("tests.support.shortcut_bindings_fixture").prefer_all(subject)
	return subject, controls, counters
end





-- =============================================
-- =============================================
-- ======= 1/ Factory Refusal Rolls Back =======
-- =============================================
-- =============================================

--- Counts the hotkeys of list_shortcuts() by their bound state.
--- @param subject table Loaded bindings module.
--- @return integer bound
--- @return integer unbound
local function count_bound(subject)
	local bound, unbound = 0, 0
	for _, entry in ipairs(subject.list_shortcuts()) do
		if entry.bound then bound = bound + 1 else unbound = unbound + 1 end
	end
	return bound, unbound
end

helpers.describe("shortcut bindings: one refused hotkey fails alone (shortcut-refusal-isolation)", function()
	helpers.it("commits every sibling of a refused factory and retries the refused one", function()
		local subject, controls, counters = load_subject()
		controls.refuse_special = true

		helpers.assert_eq(subject.start(), true,
			"one refused hotkey must not abort the layer")
		helpers.assert_eq(subject.is_started(), true)
		helpers.assert_eq(counters.deleted, 0,
			"the hotkeys that registered must stay registered")
		local bound, unbound = count_bound(subject)
		helpers.assert_true(bound > 0 and unbound > 0,
			"the refused hotkeys stay unbound while their siblings are bound")
		for _, entry in ipairs(subject.list_shortcuts()) do
			helpers.assert_eq(entry.enabled, true,
				"a refusal must not rewrite the preference: " .. entry.id)
		end
		helpers.assert_true(next(subject.pending_bindings()) ~= nil,
			"the refused hotkeys are recorded for the retry")

		controls.refuse_special = false
		helpers.assert_eq(subject.bind_pending(false), true,
			"the retry binds the refused hotkeys once the OS accepts them")
		local _, still_unbound = count_bound(subject)
		helpers.assert_eq(still_unbound, 0)
		helpers.assert_eq(next(subject.pending_bindings()), nil)
	end)

	helpers.it("names a hotkey macOS refuses in a WARNING and keeps the others (Ctrl+G 2026-10-28)", function()
		local subject, controls = load_subject()
		controls.refuse_native = true
		local warnings = {}
		package.loaded["infra.logger"].warn = function(_, msg, ...)
			warnings[#warnings + 1] = { msg = msg, args = { ... } }
		end

		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(subject.is_bound("ctrl_g"), false)
		helpers.assert_eq(subject.is_bound("cmd_star"), true,
			"a factory that does not use the refused chord stays bound")
		local refusal = subject.pending_bindings().ctrl_g
		helpers.assert_true(type(refusal) == "string" and refusal:find("Ctrl+G", 1, true) ~= nil,
			"the refusal names the chord: " .. tostring(refusal))
		local warned = false
		for _, entry in ipairs(warnings) do
			if tostring(entry.msg):find("could not be registered", 1, true)
				and tostring(entry.args and entry.args[1]) == "ctrl_g" then warned = true end
		end
		helpers.assert_true(warned, "the refusal is a WARNING naming the hotkey")
	end)

	helpers.it("defers a key the active layout cannot resolve instead of guessing its position", function()
		local subject, _, counters = load_subject()
		rawset(hs.keycodes.map, "g", nil)

		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(subject.is_bound("ctrl_g"), false,
			"a key missing from the active keymap must not bind at a US-ANSI guess")
		local refusal = subject.pending_bindings().ctrl_g
		helpers.assert_true(type(refusal) == "string"
			and refusal:find("not in the active keyboard layout", 1, true) ~= nil,
			"the refusal says why: " .. tostring(refusal))

		local created = counters.created
		helpers.assert_eq(subject.bind_pending(false), false,
			"an ordinary retry still waits for the layout")
		helpers.assert_eq(counters.created, created)
		hs.keycodes.map.g = 5
		helpers.assert_eq(subject.bind_pending(false), true,
			"the retry binds it once the layout resolves the key")
		helpers.assert_eq(subject.is_bound("ctrl_g"), true)
		hs.keycodes.__rebuild_map()
	end)

	helpers.it("binds a still-missing key at its US-ANSI position only on the final retry", function()
		local subject = load_subject()
		rawset(hs.keycodes.map, "g", nil)
		helpers.assert_eq(subject.start(), true)
		helpers.assert_eq(subject.bind_pending(true), true)
		helpers.assert_eq(subject.is_bound("ctrl_g"), true)
		hs.keycodes.__rebuild_map()
	end)

	helpers.it("still rolls everything back when the lifecycle changes mid-start", function()
		local subject, _, counters = load_subject()
		package.loaded["modules.shortcuts.actions.system"].bind_cmd_star = function()
			subject.pause()
			return nil
		end
		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(subject.is_started(), false)
		helpers.assert_eq(counters.deleted, counters.created,
			"a superseded start publishes no hotkey")
	end)

	helpers.it("retains a handle whose delete raises and settles it on retry", function()
		local subject, controls = load_subject()
		helpers.assert_eq(subject.start(), true)
		controls.delete_throws_once = true

		helpers.assert_eq(subject.stop(), false,
			"a native delete exception must make the aggregate stop refuse success")
		helpers.assert_eq(subject.stop(), true,
			"the exact failed handle must still be owned for a later cleanup retry")
	end)
end)

return true
