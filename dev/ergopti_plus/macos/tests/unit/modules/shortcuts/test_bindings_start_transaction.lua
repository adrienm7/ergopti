--- tests/unit/modules/shortcuts/test_bindings_start_transaction.lua

--- ==============================================================================
--- MODULE: Static Shortcut Bindings Startup Transaction
--- DESCRIPTION:
--- Drives the real bindings lifecycle through a refused factory and a native
--- cleanup exception. A failed aggregate start must leave no published hotkey,
--- while an unreleased exact handle must remain retryable instead of forgotten.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real binding registry with controllable hotkey factories.
--- @return table subject Loaded bindings module.
--- @return table controls Mutable failure controls.
--- @return table counters Observable factory and teardown counts.
local function load_subject()
	local controls = {
		refuse_special = false,
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

	package.loaded["modules.shortcuts.actions.system"] = {
		stop_awake = function() counters.stop_awake = counters.stop_awake + 1; return true end,
		bind_instant_screenshot = special_factory,
		bind_layer_scroll = special_factory,
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
	}
	package.loaded["infra.i18n"] = {get = function(key) return key end}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.shortcuts.bindings"] = nil

	local subject = helpers.load_with_stubs("modules.shortcuts.bindings", {
		hotkey = {bind = function() return handle() end},
	})
	return subject, controls, counters
end





-- =============================================
-- =============================================
-- ======= 1/ Factory Refusal Rolls Back =======
-- =============================================
-- =============================================

helpers.describe("shortcut bindings: startup transaction", function()
	helpers.it("returns false, clears partial publication, then permits a clean retry", function()
		local subject, controls, counters = load_subject()
		controls.refuse_special = true

		helpers.assert_eq(subject.start(), false)
		helpers.assert_eq(subject.is_started(), false)
		helpers.assert_true(counters.created > 0,
			"the refusal must happen after at least one native handle was acquired")
		helpers.assert_eq(counters.deleted, counters.created,
			"every handle acquired before the refusal must be released")
		for _, entry in ipairs(subject.list_shortcuts()) do
			helpers.assert_eq(entry.enabled, false,
				"failed startup must roll back every published binding: " .. entry.id)
		end

		controls.refuse_special = false
		helpers.assert_eq(subject.start(), true,
			"a settled rollback must leave the aggregate start retryable")
		helpers.assert_eq(subject.is_started(), true)
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
