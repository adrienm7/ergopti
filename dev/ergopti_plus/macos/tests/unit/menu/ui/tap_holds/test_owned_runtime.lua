--- tests/unit/menu/ui/tap_holds/test_owned_runtime.lua

--- ==============================================================================
--- MODULE: Tap-Holds Rows Of Ergopti's Own Karabiner Runtime
--- DESCRIPTION:
--- With Ergopti's own Karabiner runtime, the Tap-Holds submenu says what the
--- runtime did to the user's Mac: that their Karabiner-Elements is closed while
--- Ergopti runs and comes back on pause or quit, and why the runtime cannot run
--- when the one-driver-version rule of the VirtualHIDDevice blocks it.
---
--- ROOT CAUSE ENCODED: a user whose Karabiner disappeared while Ergopti ran, or
--- whose tap-holds stopped because of a driver conflict, had only the log to
--- learn why.
--- ==============================================================================

local helpers = require("tests.helpers")

local LABEL = "notify.karabiner.user_closed"

--- Loads the menu module over a fresh picker cache and a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @param extra table|nil Facade fields added to the double.
--- @return table menu
--- @return table karabiner
local function menu_over_double(integration_enabled, extra)
	package.loaded["ui.menu.menu_tap_holds"] = nil
	local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
	menu._reset_picker_cache()
	local karabiner = {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		-- A left-hand key of the shared catalogue: its row sits right under the
		-- first hand header, where the hint belongs. Rows are labelled from the
		-- catalogue's label keys, not from this double's label.
		TAP_HOLD_KEYS = { { id = "tab", label = "Tab" } },
		MOD_COMBOS = { { id = "left_shift+right_shift", label = "Shift chord", group = "Shift",
			from = { simultaneous = { { key_code = "left_shift" }, { key_code = "right_shift" } } } } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return integration_enabled end,
		get_tap_holds_enabled = function() return true end,
		get_key_combinations_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "tab" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_lone_modifier_tap_max_ms = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
	}
	for name, value in pairs(extra or {}) do karabiner[name] = value end
	return menu, karabiner
end

--- Builds the Tap-Holds submenu over a remap double.
--- @param integration_enabled boolean « Ergopti uses Karabiner ».
--- @param extra table|nil Facade fields added to the double.
--- @return table rows
local function tap_hold_rows(integration_enabled, extra)
	local menu, karabiner = menu_over_double(integration_enabled, extra)
	local built = menu.build({ karabiner = karabiner, updateMenu = function() end })
	helpers.assert_true(type(built) == "table" and type(built.submenu) == "table",
		"the Tap-Holds submenu must build")
	return built.submenu
end

--- Finds the closed-Karabiner row.
--- @param rows table Rendered submenu rows.
--- @return table|nil row
local function consent_row(rows)
	for _, row in ipairs(rows) do
		if row.title == LABEL then return row end
	end
	return nil
end

helpers.describe("Tap-Holds: Ergopti's own Karabiner runtime", function()
	helpers.it("says the user's Karabiner is closed only while Ergopti holds it closed", function()
		helpers.assert_nil(consent_row(tap_hold_rows(true)))
		helpers.assert_nil(consent_row(tap_hold_rows(true, { user_karabiner_closed = function() return false end })))
		local row = consent_row(tap_hold_rows(true, { user_karabiner_closed = function() return true end }))
		helpers.assert_true(row ~= nil, "the closed-Karabiner row must be drawn")
		helpers.assert_eq(row.disabled, true)
		helpers.assert_nil(row.fn)
	end)

	helpers.it("shows the saved consent on an owned boot and toggles it through the facade", function()
		local CONSENT = "menu.tapholds.close_other_karabiner"
		local function find(rows)
			for _, row in ipairs(rows) do if row.title == CONSENT then return row end end
			return nil
		end
		helpers.assert_nil(find(tap_hold_rows(true)), "absent on the shared runtime")
		local written = {}
		local extra = {
			owned_runtime_selected = function() return true end,
			get_close_other_instances = function() return true end,
			set_close_other_instances = function(value) written[#written + 1] = value; return true end,
			regenerate = function() return true end,
		}
		local row = find(tap_hold_rows(true, extra))
		helpers.assert_true(row ~= nil, "the consent row must be drawn on an owned boot")
		helpers.assert_eq(row.checked, true)
		row.fn()
		helpers.assert_eq(written, { false })
		extra.get_close_other_instances = function() return false end
		local unticked = find(tap_hold_rows(true, extra))
		helpers.assert_eq(unticked.checked, false)
		unticked.fn()
		helpers.assert_eq(written, { false, true })
	end)

	helpers.it("explains a VirtualHIDDevice block above the closed-Karabiner row and nothing otherwise", function()
		local function rows_for(status)
			return tap_hold_rows(true, {
				user_karabiner_closed = function() return true end,
				owned_runtime_status = function() return status end,
			})
		end
		local function find(rows, title)
			for index, row in ipairs(rows) do if row.title == title then return row, index end end
			return nil
		end
		local blocked = rows_for({ state = "unavailable", reason = "virtual_hid_incompatible" })
		local row, at = find(blocked, "menu.tapholds.vhid_incompatible")
		helpers.assert_true(row ~= nil, "the driver-version block must be explained")
		helpers.assert_eq(row.disabled, true)
		local _, consent_at = find(blocked, LABEL)
		helpers.assert_true(at < consent_at, "the explanation comes first")
		helpers.assert_true(find(rows_for({ state = "unavailable", reason = "virtual_hid_not_active" }),
			"menu.tapholds.vhid_not_active") ~= nil)
		for _, status in ipairs({ { state = "ready" }, { state = "unavailable", reason = "other_karabiner_running" } }) do
			local rows = rows_for(status)
			helpers.assert_nil(find(rows, "menu.tapholds.vhid_incompatible"))
			helpers.assert_nil(find(rows, "menu.tapholds.vhid_not_active"))
		end
	end)

	helpers.it("explains every block the owner names, above the consent row, and no other state", function()
		-- An owned boot with the runtime missing, a user Karabiner left running or a
		-- failed download had the tap-holds off with no row saying why.
		local CONSENT = "menu.tapholds.close_other_karabiner"
		local function rows_for(status)
			return tap_hold_rows(true, {
				owned_runtime_selected = function() return true end,
				get_close_other_instances = function() return false end,
				set_close_other_instances = function() return true end,
				owned_runtime_status = function() return status end,
			})
		end
		local function find(rows, title)
			for index, row in ipairs(rows) do if row.title == title then return row, index end end
			return nil
		end
		local expected = {
			{ "unavailable", "runtime_not_installed", "menu.tapholds.owned_not_installed" },
			{ "unavailable", "runtime_job_not_loaded", "menu.tapholds.owned_service_stopped" },
			{ "unavailable", "virtual_hid_absent", "menu.tapholds.owned_not_installed" },
			{ "unavailable", "other_karabiner_running", "menu.tapholds.owned_other_running" },
			{ "unavailable", "close_other_unsupported", "menu.tapholds.owned_close_failed" },
			{ "failed", "close_other_failed", "menu.tapholds.owned_close_failed" },
			{ "unavailable", "other_karabiner_still_running", "menu.tapholds.owned_close_failed" },
			{ "unavailable", "artifact_fetch_failed", "menu.tapholds.owned_fetch_failed" },
		}
		for _, case in ipairs(expected) do
			local rows = rows_for({ state = case[1], reason = case[2] })
			local row, at = find(rows, case[3])
			helpers.assert_true(row ~= nil, case[2] .. " must be explained by " .. case[3])
			helpers.assert_eq(row.disabled, true, case[2])
			local _, consent_at = find(rows, CONSENT)
			helpers.assert_true(consent_at ~= nil and at < consent_at, case[2] .. ": the explanation comes first")
		end
		for _, status in ipairs({ { state = "ready" }, { state = "starting" },
			{ state = "failed", reason = "capture_lost" }, { state = "stopped", reason = "runtime_not_installed" } }) do
			local rows = rows_for(status)
			for _, case in ipairs(expected) do
				helpers.assert_nil(find(rows, case[3]), tostring(status.reason) .. " in " .. status.state)
			end
		end
	end)

	helpers.it("explains exactly the blocks the owner declares for the user", function()
		local menu = menu_over_double(true)
		package.loaded["platform.remap.runtime_owner"] = nil
		local declared = require("platform.remap.runtime_owner").USER_BLOCKS
		local explained = menu._explained_owned_reasons()
		for reason in pairs(declared) do helpers.assert_true(explained[reason] == true, reason .. " has no row") end
		for reason in pairs(explained) do helpers.assert_true(declared[reason] == true, reason .. " is not declared") end
	end)

	helpers.it("offers the driver-only update under an incompatible driver and only there", function()
		local UPDATE = "menu.tapholds.vhid_update"
		local opened = {}
		package.loaded["ui.virtual_hid_update"] = {
			open = function(remap) opened[#opened + 1] = remap; return true end,
		}
		local function rows_for(status, with_facade)
			local extra = { owned_runtime_status = function() return status end }
			if with_facade then extra.update_virtual_hid_driver = function() return true end end
			return tap_hold_rows(true, extra)
		end
		local function find(rows, title)
			for index, row in ipairs(rows) do if row.title == title then return row, index end end
			return nil
		end
		local blocked = rows_for({ state = "unavailable", reason = "virtual_hid_incompatible" }, true)
		local row, at = find(blocked, UPDATE)
		helpers.assert_true(row ~= nil, "the update offer must follow the incompatible-driver explanation")
		local _, explanation_at = find(blocked, "menu.tapholds.vhid_incompatible")
		helpers.assert_eq(at, explanation_at + 1)
		helpers.assert_true(type(row.fn) == "function", "the offer must be clickable")
		helpers.assert_eq(#opened, 0, "drawing the row must not open the confirmation")
		row.fn()
		helpers.assert_eq(#opened, 1, "the row opens the confirmation")
		helpers.assert_nil(find(rows_for({ state = "unavailable", reason = "virtual_hid_not_active" }, true), UPDATE))
		helpers.assert_nil(find(rows_for({ state = "ready" }, true), UPDATE))
		helpers.assert_nil(find(rows_for({ state = "unavailable", reason = "virtual_hid_incompatible" }, false), UPDATE),
			"no offer without the facade that performs it")
		package.loaded["ui.virtual_hid_update"] = nil
	end)

	helpers.it("offers the first install under a missing runtime and only there", function()
		-- WP8: the « not installed » row said the tap-holds were off and offered no way to install.
		local INSTALL = "menu.tapholds.owned_install"
		local opened = {}
		package.loaded["ai.ui.owned_runtime_install"] = {
			open = function(remap) opened[#opened + 1] = remap; return true end,
		}
		local function rows_for(status, with_facade)
			local extra = { owned_runtime_status = function() return status end }
			if with_facade then extra.install_owned_runtime = function() return true end end
			return tap_hold_rows(true, extra)
		end
		local function find(rows, title)
			for index, row in ipairs(rows) do if row.title == title then return row, index end end
			return nil
		end
		for _, reason in ipairs({ "runtime_not_installed", "virtual_hid_absent" }) do
			local blocked = rows_for({ state = "unavailable", reason = reason }, true)
			local row, at = find(blocked, INSTALL)
			helpers.assert_true(row ~= nil, reason .. ": the install offer must follow the explanation")
			local _, explanation_at = find(blocked, "menu.tapholds.owned_not_installed")
			helpers.assert_eq(at, explanation_at + 1)
			helpers.assert_true(type(row.fn) == "function", "the offer must be clickable")
		end
		helpers.assert_eq(#opened, 0, "drawing the row must not open the confirmation")
		find(rows_for({ state = "unavailable", reason = "runtime_not_installed" }, true), INSTALL).fn()
		helpers.assert_eq(#opened, 1, "the row opens the confirmation")
		-- An already published runtime is refused by the first install by design (MRT-004).
		for _, status in ipairs({ { state = "ready" }, { state = "unavailable", reason = "virtual_hid_incompatible" },
			{ state = "unavailable", reason = "other_karabiner_running" }, { state = "unavailable", reason = "runtime_job_not_loaded" } }) do
			helpers.assert_nil(find(rows_for(status, true), INSTALL), tostring(status.reason))
		end
		helpers.assert_nil(find(rows_for({ state = "unavailable", reason = "runtime_not_installed" }, false), INSTALL),
			"no offer without the facade that performs it")
		package.loaded["ai.ui.owned_runtime_install"] = nil
	end)

	helpers.it("offers « Réparer le service » under a stopped service of an installed runtime and only there (MRT-004)", function()
		-- The advertised retry ran the first install, which always refuses an already published runtime.
		local REPAIR = "menu.tapholds.owned_repair"
		local opened = {}
		package.loaded["ai.ui.owned_runtime_install"] = {
			open = function() error("the repair row must never open the first install") end,
			open_repair = function(remap) opened[#opened + 1] = remap; return true end,
		}
		local function rows_for(status, with_facade)
			local extra = { owned_runtime_status = function() return status end,
				install_owned_runtime = function() return true end }
			if with_facade then extra.repair_owned_runtime = function() return true end end
			return tap_hold_rows(true, extra)
		end
		local function find(rows, title)
			for index, row in ipairs(rows) do if row.title == title then return row, index end end
			return nil
		end
		local stopped = rows_for({ state = "unavailable", reason = "runtime_job_not_loaded" }, true)
		local row, at = find(stopped, REPAIR)
		helpers.assert_true(row ~= nil, "the repair offer must follow the explanation")
		local _, explanation_at = find(stopped, "menu.tapholds.owned_service_stopped")
		helpers.assert_eq(at, explanation_at + 1)
		helpers.assert_nil(find(stopped, "menu.tapholds.owned_install"), "no first install for a published runtime")
		helpers.assert_eq(#opened, 0, "drawing the row must not open the confirmation")
		row.fn()
		helpers.assert_eq(#opened, 1, "the row opens the repair confirmation")
		for _, status in ipairs({ { state = "ready" }, { state = "unavailable", reason = "runtime_not_installed" },
			{ state = "unavailable", reason = "virtual_hid_absent" }, { state = "unavailable", reason = "virtual_hid_incompatible" } }) do
			helpers.assert_nil(find(rows_for(status, true), REPAIR), tostring(status.reason))
		end
		helpers.assert_nil(find(rows_for({ state = "unavailable", reason = "runtime_job_not_loaded" }, false), REPAIR),
			"no offer without the facade that performs it")
		package.loaded["ai.ui.owned_runtime_install"] = nil
	end)

	-- Each block whose fix this menu offers, with the facade that performs it.
	local GATED = {
		{ reason = "runtime_not_installed", explanation = "menu.tapholds.owned_not_installed",
			fix = "menu.tapholds.owned_install", facade = "install_owned_runtime" },
		{ reason = "virtual_hid_absent", explanation = "menu.tapholds.owned_not_installed",
			fix = "menu.tapholds.owned_install", facade = "install_owned_runtime" },
		{ reason = "runtime_job_not_loaded", explanation = "menu.tapholds.owned_service_stopped",
			fix = "menu.tapholds.owned_repair", facade = "repair_owned_runtime" },
		{ reason = "virtual_hid_incompatible", explanation = "menu.tapholds.vhid_incompatible",
			fix = "menu.tapholds.vhid_update", facade = "update_virtual_hid_driver" },
	}

	--- Builds the whole Tap-Holds row over an owned boot.
	--- @param status table Owned runtime status.
	--- @param extra table|nil Facade fields added to the double.
	--- @return table built The parent row, its submenu in `submenu`.
	local function owned_build(status, extra)
		local fields = {
			owned_runtime_selected = function() return true end,
			get_close_other_instances = function() return false end,
			set_close_other_instances = function() return true end,
			owned_runtime_status = function() return status end,
		}
		for name, value in pairs(extra or {}) do fields[name] = value end
		local menu, karabiner = menu_over_double(true, fields)
		local built = menu.build({ karabiner = karabiner, updateMenu = function() end })
		helpers.assert_true(type(built) == "table" and type(built.submenu) == "table",
			"the Tap-Holds submenu must build")
		return built
	end

	--- Finds the first row with this title.
	--- @param rows table Rendered submenu rows.
	--- @param title string Title.
	--- @return table|nil row
	local function titled(rows, title)
		for _, row in ipairs(rows) do if row.title == title then return row end end
		return nil
	end

	helpers.it("greys every row but the block and its fix while the runtime waits for that fix (tap-holds-install-gate)", function()
		-- The submenu kept a ticked switch and live settings, so the user believed
		-- tap-holds worked on a Mac where their runtime was not even installed.
		for _, case in ipairs(GATED) do
			local built = owned_build({ state = "unavailable", reason = case.reason },
				{ [case.facade] = function() return true end })
			local rows = built.submenu
			local explanation_at, fix_at
			for index, row in ipairs(rows) do
				if row.title == case.explanation then explanation_at = index end
				if row.title == case.fix then fix_at = index end
			end
			helpers.assert_true(explanation_at ~= nil, case.reason .. ": the block is explained")
			helpers.assert_eq(rows[explanation_at].disabled, true, case.reason)
			helpers.assert_eq(fix_at, explanation_at + 1, case.reason .. ": its fix follows")
			helpers.assert_true(type(rows[fix_at].fn) == "function" and rows[fix_at].disabled ~= true,
				case.reason .. ": the fix stays clickable")
			local greyed = 0
			for index, row in ipairs(rows) do
				if row.title ~= "-" and index ~= explanation_at and index ~= fix_at then
					local name = case.reason .. ": " .. tostring(row.title)
					helpers.assert_eq(row.disabled, true, name .. " must be greyed")
					helpers.assert_nil(row.fn, name .. " must not run")
					helpers.assert_nil(row.menu, name .. " must open nothing")
					helpers.assert_nil(row.checked, name .. " must not read as on")
					greyed = greyed + 1
				end
			end
			helpers.assert_true(greyed > 3, case.reason .. ": the other rows stay visible, greyed")
			local switch = titled(rows, "menu.tapholds.enable")
			helpers.assert_true(switch ~= nil, case.reason .. ": the switch stays visible")
			helpers.assert_true(built.checked ~= true, case.reason .. ": the parent row must not read as on")
		end
	end)

	helpers.it("keeps the fix live and names no category-off cause when the switch is off (tap-holds-install-gate)", function()
		local built = owned_build({ state = "unavailable", reason = "runtime_not_installed" }, {
			install_owned_runtime = function() return true end,
			get_tap_holds_enabled = function() return false end,
		})
		local fix = titled(built.submenu, "menu.tapholds.owned_install")
		helpers.assert_true(fix ~= nil and type(fix.fn) == "function", "the install stays clickable")
		for _, row in ipairs(built.submenu) do
			helpers.assert_true(type(row.title) ~= "string" or not row.title:find("menu.category_off_reason", 1, true),
				tostring(row.title) .. " must not ask to tick the greyed switch")
		end
		helpers.assert_true(built.checked ~= true)
	end)

	helpers.it("leaves the submenu live for a block without a fix row here (tap-holds-install-gate)", function()
		-- The consent row is the fix of a running user Karabiner; the others have
		-- no fix in this menu, and greying everything would leave a dead end.
		local cases = {
			{ { state = "unavailable", reason = "other_karabiner_running" }, {} },
			{ { state = "unavailable", reason = "artifact_fetch_failed" }, {} },
			{ { state = "unavailable", reason = "runtime_not_installed" }, {} },
			{ { state = "ready" }, { install_owned_runtime = function() return true end } },
		}
		for _, case in ipairs(cases) do
			local built = owned_build(case[1], case[2])
			local name = tostring(case[1].reason or case[1].state)
			local switch = titled(built.submenu, "menu.tapholds.enable")
			helpers.assert_true(switch ~= nil and type(switch.fn) == "function", name .. ": the switch stays live")
			helpers.assert_eq(switch.checked, true, name)
			local consent = titled(built.submenu, "menu.tapholds.close_other_karabiner")
			helpers.assert_true(consent ~= nil and type(consent.fn) == "function", name .. ": the consent row stays live")
			helpers.assert_eq(built.checked, true, name .. ": the parent row keeps its tick")
		end
	end)
end)
