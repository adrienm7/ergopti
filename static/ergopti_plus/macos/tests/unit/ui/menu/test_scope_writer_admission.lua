--- tests/unit/ui/menu/test_scope_writer_admission.lua

local helpers = require("tests.helpers")

local function fixture()
	local controls = {}
	local function unused() error("unrelated owner must not run") end
	local dependencies = {
		state = {}, capture_preferences = unused, sync_runtime = unused, restore_state = unused,
		settings = { get = unused, set = unused, get_keys = unused },
		file_mover = { capture = unused, move = unused, restore = unused },
		reset_journal = { prepare = unused, mark_commit = unused, mark_prepared = unused, clear = unused },
		gestures = { get_action = unused, set_action = unused, enable_all = unused, disable_all = unused },
		shortcuts = { set_shortcut_action = unused, get_keyboard_action = unused, set_keyboard_action = unused,
			get_keyboard_assignments = unused },
		karabiner = { snapshot_settings = unused, reset_to_defaults = unused, restore_settings = unused },
		request_reload = unused, terminal_pending = function()
			if controls.preflight then controls.preflight() end
			return controls.terminal == true
		end,
	}
	return require("ui.menu.global_actions_transaction").create(dependencies), controls
end

helpers.describe("scope writer admission", function()
	helpers.it("fences reentrant writers before preflight and retains failed compensation by identity", function()
		local owner, controls = fixture()
		local debt, attempts = false, 0
		local claim = { pending = function() return debt end, retry_restore = function()
			attempts = attempts + 1
			if controls.refuse then return false end
			debt = false
			return true
		end }
		controls.preflight = function()
			helpers.assert_eq(owner.run_exclusive("reentrant", function() error("must not run") end), false)
		end
		helpers.assert_eq(owner.run_exclusive("scope", function() debt = true; return false end, claim), false)
		helpers.assert_eq(owner.is_pending(), true)
		helpers.assert_eq(owner.run_exclusive("ordinary save", function() error("must not run") end), false)
		helpers.assert_eq(owner.reset_defaults(), false)
		helpers.assert_eq(owner.run_exclusive("foreign scope", function() error("must not run") end,
			{ pending = claim.pending, retry_restore = claim.retry_restore }), false)
		controls.terminal = true
		helpers.assert_eq(owner.run_exclusive("scope", function() error("must not run") end, claim), false)
		helpers.assert_eq(attempts, 0)
		controls.terminal, controls.refuse = false, true
		helpers.assert_eq(owner.run_exclusive("scope", function() error("must not run") end, claim), false)
		helpers.assert_eq(attempts, 1)
		controls.refuse = false
		helpers.assert_eq(owner.run_exclusive("scope", function() return true end, claim), true)
		helpers.assert_eq(attempts, 2)
		helpers.assert_eq(owner.is_pending(), false)
	end)
	helpers.it("does not release retained ownership on a truthy or dishonest inverse", function()
		for _, result in ipairs({ "accepted", true }) do
			local owner = fixture()
			local claim = { pending = function() return true end, retry_restore = function() return result end }
			helpers.assert_eq(owner.run_exclusive("scope", function() return true end, claim), false)
			helpers.assert_eq(owner.run_exclusive("scope", function() error("must not run") end, claim), false)
			helpers.assert_eq(owner.is_pending(), true)
		end
	end)
end)
