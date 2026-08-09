--- tests/unit/platform/remap/test_init_hotkey_defer.lua

--- ==============================================================================
--- MODULE: Lease-Bound F17 Hotkeys Stay Off Boot and Precede Activation
--- DESCRIPTION:
--- Preserves the original performance invariant (M.init never binds the four
--- convenience hotkeys) while pinning the stronger correctness invariant: a
--- fresh exact generation is PAUSED, all siblings commit synchronously, and
--- RESUME cannot be sent until after the final token/epoch revalidation.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	local src = helpers.read_driver_source("local KARABINER_KE_TILDE_PATH")
	helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")
	return src
end

local function between(src, first, last)
	local start_pos = assert(src:find(first, 1, true), "missing start marker: " .. first)
	local end_pos = assert(src:find(last, start_pos + #first, true), "missing end marker: " .. last)
	return src:sub(start_pos, end_pos - 1)
end

helpers.describe("lease-bound F17 activation ordering", function()
	helpers.it("keeps all four binders outside M.init and inside one transaction", function()
		local src = read_src()
		local init_body = between(src, "function M.init(", "local function stop_local_resources(")
		local mount_body = between(
			src,
			"local function start_lease_bound_inputs(",
			"local function refresh_managed_output_set("
		)

		for _, fn in ipairs({
			"start_cycle_windows_hotkey",
			"start_alt_tab_windows_hotkey",
			"start_alt_tab_monitor_hotkey",
			"start_alt_tab_apps_hotkey",
		}) do
			helpers.assert_true(not init_body:find("Watchers." .. fn, 1, true),
				fn .. " must stay off the M.init boot path")
			helpers.assert_true(mount_body:find("Watchers." .. fn, 1, true) ~= nil,
				fn .. " must belong to the exact lease-input transaction")
		end
	end)

	helpers.it("has no post-READY 0.5-second timer or deferred bind surface", function()
		local src = read_src()
		local mount_body = between(
			src,
			"local function start_lease_bound_inputs(",
			"local function refresh_managed_output_set("
		)
		helpers.assert_true(not src:find("HOTKEY_BIND_DEFER_SEC", 1, true))
		helpers.assert_true(not src:find("_deferred_hotkeys_timer", 1, true))
		helpers.assert_true(not mount_body:find("hs.timer.doAfter", 1, true),
			"F17 consumers must commit synchronously while native mode remains PAUSED")
	end)

	helpers.it("revalidates exact ownership before commit and resumes afterwards", function()
		local src = read_src()
		local mount_body = between(
			src,
			"local function start_lease_bound_inputs(",
			"local function refresh_managed_output_set("
		)
		local final_check = assert(mount_body:find("final_snapshot.token ~= expected_token", 1, true))
		local first_commit = assert(mount_body:find("_state.hotkey_cycle_windows = handles[1]", 1, true))
		helpers.assert_true(final_check < first_commit,
			"token/epoch ownership must be revalidated before publishing any handle")

		local activation_body = between(
			src,
			"local function activate_lease_generation(",
			"local function start_or_join_lease_activation("
		)
		local mount_call = assert(activation_body:find("start_lease_bound_inputs(phase", 1, true))
		local classifier = assert(activation_body:find("refresh_managed_output_set()", 1, true))
		local prepared_resume = assert(activation_body:find("LeaseController.resume_prepared", 1, true))
		helpers.assert_true(mount_call < classifier and classifier < prepared_resume,
			"PAUSED mount and KC classification must both precede prepared RESUME")
	end)
end)
