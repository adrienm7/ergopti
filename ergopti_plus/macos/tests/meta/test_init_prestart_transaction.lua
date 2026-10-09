--- tests/meta/test_init_prestart_transaction.lua

--- ==============================================================================
--- MODULE: Root Input Pre-start Fail-fast Regression
--- DESCRIPTION:
--- Root init cannot be loaded by the headless suite, so this guard connects its
--- two keyboard input-subsystem calls to the behaviourally tested startup
--- transaction, and proves boot leaves the gestures runtime to the preference
--- sync. It also preserves the onboarding short-circuit and panic-button order.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Returns root init.lua with full-line comments removed for code-only offsets.
--- @return string source Root bootstrap source.
local function boot_source()
	local src, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
	helpers.assert_true(src ~= nil and src ~= "", tostring(err))
	return (src:gsub("%-%-[^\n]*", ""))
end





-- ====================================================
-- ====================================================
-- ======= 1/ All Input Starts Share One Commit =======
-- ====================================================
-- ====================================================

helpers.describe("root pre-start: exact startup transaction", function()
	helpers.it("routes both keyboard input starts through the tested transaction", function()
		local src = boot_source()
		local transaction_at = src:find("StartupTransaction.run({", 1, true)
		local shortcuts_at = src:find("shortcuts.start()", 1, true)
		local script_at = src:find(
			"shortcuts.start_script_control(keymap, shortcuts, gestures, karabiner)", 1, true)
		local transaction_end = src:find("\n})", transaction_at, true)
		local failure_at = src:find("if prestart_committed ~= true then", 1, true)

		helpers.assert_not_nil(transaction_at,
			"root boot must invoke the behaviourally tested startup transaction")
		helpers.assert_true(shortcuts_at and script_at,
			"both keyboard input start calls must remain present")
		helpers.assert_true(transaction_at < shortcuts_at and shortcuts_at < script_at,
			"shortcuts, then panic-button must retain their intentional order")
		helpers.assert_true(transaction_end and script_at < transaction_end,
			"both input starts must remain inside one transaction descriptor list")
		helpers.assert_true(failure_at and transaction_end < failure_at,
			"root boot must inspect the exact aggregate result after every start")

		local failure_body = src:sub(failure_at, failure_at + 180)
		helpers.assert_true(failure_body:find("error(", 1, true) ~= nil,
			"a refused pre-start must abort boot loudly instead of continuing half-active")
	end)

	helpers.it("never arms the gestures runtime before the saved preference applies", function()
		-- A boot-time gestures.start() ran the touch watchers, the primer tap and the
		-- health-check timer even with Gestures OFF. The menu's preference sync owns
		-- that runtime through gestures.enable_all()/disable_all().
		local src = boot_source()
		helpers.assert_true(src:find("StartupTransaction.run({", 1, true) ~= nil,
			"the boot source must be the root init.lua")
		helpers.assert_eq(src:find("gestures.start(", 1, true), nil,
			"root boot must not start the gestures runtime unconditionally")
	end)

	helpers.it("keeps first-launch onboarding ahead of the transaction", function()
		local src = boot_source()
		local onboarding_at = src:find("onboarding_mod.should_run", 1, true)
		local transaction_at = src:find("StartupTransaction.run({", 1, true)

		helpers.assert_true(onboarding_at and transaction_at and onboarding_at < transaction_at,
			"the wizard must still return before any input subsystem can be armed")
	end)
end)

return true
