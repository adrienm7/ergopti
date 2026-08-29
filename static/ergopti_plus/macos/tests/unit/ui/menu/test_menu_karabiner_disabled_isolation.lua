--- tests/unit/ui/menu/test_menu_karabiner_disabled_isolation.lua

--- ==============================================================================
--- MODULE: Disabled Karabiner Menu Is Externally Inert
--- DESCRIPTION:
--- Building or prewarming the submenu while integration is disabled may read
--- local settings and in-memory lease status only. It must not probe, launch,
--- signal or stop the user's shared Karabiner runtime.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Minimal disabled platform.remap double consumed by the menu builders.
--- @return table remap_double
local function disabled_remap()
	return {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "left_shift", label = "Left Shift" } },
		MOD_COMBOS = { { id = "shift_pair", label = "Shift pair", group = "Shift" } },
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return false end,
		set_enabled = function() error("top-level toggle must not run during build") end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "none" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_combo_combo_action = function() return "none" end,
		get_combo_tap_action = function() return "none" end,
		get_combo_hold_action = function() return "none" end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
		open_gui = function() error("GUI open must remain explicit") end,
		open_guardian_settings = function()
			error("guardian settings must remain an explicit enabled-only action")
		end,
		regenerate = function() error("disabled build must not regenerate") end,
		stop_lease = function() error("disabled build must not stop the exact lease") end,
	}
end

--- Finds a rendered menu row by either provider or hs.menubar field names.
--- @param item table Built top-level Karabiner item.
--- @param label string Exact test-i18n label.
--- @return table|nil
local function find_item(item, label)
	for _, entry in ipairs(item.menu or item.items or {}) do
		if entry.title == label or entry.label == label then return entry end
	end
	return nil
end

--- Returns the callback carried by a rendered row in either menu dialect.
--- @param row table|nil
--- @return function|nil
local function row_action(row)
	if type(row) ~= "table" then return nil end
	return row.fn or row.action
end

helpers.describe("disabled Karabiner menu has no external side effects", function()
	helpers.it("contains a controller status fault while rendering", function()
		package.loaded["platform.remap.lease_controller"] = {
			status = function() error("status fault") end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()

		local ok, built = pcall(menu.build, { karabiner = remap, updateMenu = function() end })
		helpers.assert_true(ok, "status faults must remain inside the existing read guard: " .. tostring(built))
		helpers.assert_true(type(built) == "table")
	end)

	helpers.it("contains a regenerate fault from the exact-lease Start action", function()
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "idle", { phase = "idle" } end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.regenerate = function() error("regenerate fault") end
		remap.open_gui = function() return true end
		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local start_row = find_item(built, "menu.karabiner.start")

		helpers.assert_not_nil(start_row)
		helpers.assert_type(row_action(start_row), "function")
		local ok, err = pcall(row_action(start_row))
		helpers.assert_true(ok, "Start faults must be logged, not escape the menu callback: " .. tostring(err))
	end)

	helpers.it("contains a remap transaction fault from the exact-lease Stop action", function()
		local calls = { raw_stop = 0, stop_lease = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "active", { phase = "active" } end,
			stop = function()
				calls.raw_stop = calls.raw_stop + 1
				error("menu must not bypass the remap transaction")
			end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.regenerate = function() return true end
		remap.stop_lease = function()
			calls.stop_lease = calls.stop_lease + 1
			error("stop transaction fault")
		end
		remap.open_gui = function() return true end
		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local stop_row = find_item(built, "menu.karabiner.stop")

		helpers.assert_not_nil(stop_row)
		helpers.assert_type(row_action(stop_row), "function")
		local ok, err = pcall(row_action(stop_row))
		helpers.assert_true(ok, "Stop faults must be logged, not escape the menu callback: " .. tostring(err))
		helpers.assert_eq(calls.stop_lease, 1)
		helpers.assert_eq(calls.raw_stop, 0,
			"even the fault path must not bypass the remap intent transaction")
	end)

	helpers.it("build and prime perform zero shell, GUI, task, start or stop actions", function()
		local calls = { status = 0, start = 0, stop = 0, execute = 0, gui = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				calls.status = calls.status + 1
				return "idle", { phase = "idle" }
			end,
			start = function() calls.start = calls.start + 1 return true end,
			stop = function() calls.stop = calls.stop + 1 return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {
			execute = function()
				calls.execute = calls.execute + 1
				return "", true
			end,
			application = {
				launchOrFocus = function()
					calls.gui = calls.gui + 1
					return true
				end,
			},
		})
		local ctx = { karabiner = disabled_remap(), updateMenu = function() end }

		local built = menu.build(ctx)
		menu.prime(ctx)

		helpers.assert_true(type(built) == "table", "disabled submenu must still render")
		helpers.assert_true(calls.status >= 1,
			"the status label may read the controller's in-memory idle phase")
		helpers.assert_eq(calls.start, 0)
		helpers.assert_eq(calls.stop, 0)
		helpers.assert_eq(calls.execute, 0)
		helpers.assert_eq(calls.gui, 0)
	end)

	helpers.it("hides a cached guardian approval action while integration is disabled", function()
		local calls = { probe = 0, raw_open = 0, facade_open = 0, regenerate = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				return "idle", { phase = "idle", guardian_status = "requires_approval" }
			end,
			probe_guardian_status = function()
				calls.probe = calls.probe + 1
				error("disabled menu must never probe the guardian")
			end,
			open_guardian_settings = function()
				calls.raw_open = calls.raw_open + 1
				error("disabled menu must never open Login Items settings")
			end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.open_guardian_settings = function()
			calls.facade_open = calls.facade_open + 1
			return true
		end
		remap.regenerate = function()
			calls.regenerate = calls.regenerate + 1
			return true
		end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local approval_row = find_item(built,
			"menu.karabiner.status_guardian_approval_required")
		local inactive_row = find_item(built, "menu.karabiner.status_inactive")

		helpers.assert_nil(approval_row,
			"a cached bundled-app hint must not expose an approval action for stock Karabiner")
		helpers.assert_not_nil(inactive_row)
		helpers.assert_nil(row_action(inactive_row),
			"the disabled status row must carry no stale native action")
		helpers.assert_true(helpers.deep_equal(calls, {
			probe = 0, raw_open = 0, facade_open = 0, regenerate = 0,
		}), "rendering a disabled approval snapshot must have zero external effects")
	end)

	helpers.it("routes the enabled approval row only to the guarded settings facade", function()
		local calls = { open = 0, regenerate = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				return "failed", { phase = "failed", guardian_status = "requires_approval" }
			end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.open_guardian_settings = function(callback)
			calls.open = calls.open + 1
			if callback then callback(true, "opened") end
			return true
		end
		remap.regenerate = function()
			calls.regenerate = calls.regenerate + 1
			return true
		end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local approval_row = find_item(built,
			"menu.karabiner.status_guardian_approval_required")
		helpers.assert_not_nil(approval_row)
		helpers.assert_type(row_action(approval_row), "function")

		row_action(approval_row)()
		helpers.assert_eq(calls.open, 1,
			"one approval click must reach the ownership-aware facade exactly once")
		helpers.assert_eq(calls.regenerate, 0,
			"approval cannot be repaired by rebuilding rules before native consent")
	end)

	helpers.it("makes an approval closure inert after integration is disabled", function()
		local enabled = true
		local calls = { open = 0, regenerate = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				return "failed", { phase = "failed", guardian_status = "requires_approval" }
			end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return enabled end
		remap.open_guardian_settings = function()
			calls.open = calls.open + 1
			return true
		end
		remap.regenerate = function()
			calls.regenerate = calls.regenerate + 1
			return true
		end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local approval_action = row_action(find_item(built,
			"menu.karabiner.status_guardian_approval_required"))
		helpers.assert_type(approval_action, "function")
		enabled = false

		approval_action()
		helpers.assert_true(helpers.deep_equal(calls, { open = 0, regenerate = 0 }),
			"the stale closure must perform no native or remap action")
	end)

	helpers.it("contains a guardian settings facade fault inside the approval action", function()
		local notifications = {}
		local regenerate_calls = 0
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				notifications[#notifications + 1] = { title = title, body = body, kind = kind }
			end,
		}
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				return "failed", { phase = "failed", guardian_status = "requires_approval" }
			end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.open_guardian_settings = function() error("injected facade fault") end
		remap.regenerate = function()
			regenerate_calls = regenerate_calls + 1
			return true
		end
		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local approval_action = row_action(find_item(built,
			"menu.karabiner.status_guardian_approval_required"))

		approval_action()
		helpers.assert_eq(regenerate_calls, 0)
		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1].title,
			"karabiner.guardian_settings_open_failed")
		helpers.assert_eq(notifications[1].kind, "error")
	end)

	helpers.it("can cancel the exact lease while its watchdog is still starting", function()
		local calls = { raw_stop = 0, stop_lease = 0 }
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "starting", { phase = "starting" } end,
			stop = function() calls.raw_stop = calls.raw_stop + 1 return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.regenerate = function() return true end
		remap.stop_lease = function(callback)
			calls.stop_lease = calls.stop_lease + 1
			if callback then callback(true, "stopped") end
			return true
		end
		remap.open_gui = function() return true end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local stop_row = find_item(built, "menu.karabiner.stop")

		helpers.assert_not_nil(stop_row, "the exact-lease stop row must be rendered")
		helpers.assert_true(stop_row.disabled ~= true,
			"starting is cancellable — disabling Stop leaves a racing generation able to activate")
		helpers.assert_type(row_action(stop_row), "function")
		row_action(stop_row)()
		helpers.assert_eq(calls.stop_lease, 1,
			"the menu must route Stop through the remap intent fence")
		helpers.assert_eq(calls.raw_stop, 0,
			"the menu must never bypass recovery cancellation through the raw controller")
	end)

	helpers.it("does not offer a second start while the exact lease is paused", function()
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "paused", { phase = "paused" } end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.regenerate = function() return true end
		remap.open_gui = function() return true end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local start_row = find_item(built, "menu.karabiner.start")

		helpers.assert_not_nil(start_row, "the exact-lease start row must be rendered")
		helpers.assert_true(start_row.disabled == true,
			"paused is already attached — Start would only run a guarded no-op")
	end)

	helpers.it("surfaces a failed transactional disable and refreshes after completion", function()
		local notifications = {}
		local refreshes = 0
		local disable_requests = 0
		local disable_callback = nil
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				notifications[#notifications + 1] = { title = title, body = body, kind = kind }
			end,
		}
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "active", { phase = "active" } end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return true end
		remap.set_enabled = function(value, callback)
			helpers.assert_eq(value, false)
			disable_requests = disable_requests + 1
			disable_callback = callback
			return true
		end

		local built = menu.build({
			karabiner = remap,
			updateMenu = function() refreshes = refreshes + 1 end,
		})
		row_action(built)()
		row_action(built)()
		helpers.assert_eq(disable_requests, 1,
			"a second click must join the pending UI state, not start another transaction")
		helpers.assert_type(disable_callback, "function",
			"the menu must observe the eventual STOPPED/rollback result")
		helpers.assert_eq(#notifications, 0,
			"no failure may be claimed while the disable transaction is pending")

		disable_callback(false, "stop-failed-rollback-restored")
		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1].title, "karabiner.disable_failed")
		helpers.assert_eq(notifications[1].kind, "error")
		helpers.assert_true(refreshes >= 2,
			"the menu must render both the pending phase and the final restored state")
	end)

	helpers.it("surfaces a failed transactional enable without claiming it active", function()
		local notifications = {}
		local enable_callback = nil
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind)
				notifications[#notifications + 1] = { title = title, body = body, kind = kind }
			end,
		}
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "idle", { phase = "idle" } end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		remap.get_enabled = function() return false end
		remap.set_enabled = function(value, callback)
			helpers.assert_true(value == true)
			enable_callback = callback
			return true
		end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		row_action(built)()
		helpers.assert_eq(#notifications, 0, "pending READY must not report success or failure")
		enable_callback(false, "deploy-failed")
		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1].title, "karabiner.enable_failed")
		helpers.assert_eq(notifications[1].kind, "error")
	end)

	for _, vector in ipairs({
		{ rendered = true, live = false, expected = true },
		{ rendered = false, live = true, expected = false },
	}) do
		helpers.it("toggles against the live facade after a stale rendered "
			.. tostring(vector.rendered), function()
			package.loaded["platform.remap.lease_controller"] = {
				status = function()
					local phase = vector.rendered and "active" or "idle"
					return phase, { phase = phase }
				end,
				stop = function() return true end,
			}
			package.loaded["ui.menu.menu_remap"] = nil
			local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
			local remap = disabled_remap()
			local live_enabled = vector.rendered
			local requested = nil
			remap.get_enabled = function() return live_enabled end
			remap.set_enabled = function(value, callback)
				requested = value
				callback(true)
				return true
			end

			local built = menu.build({ karabiner = remap, updateMenu = function() end })
			live_enabled = vector.live
			row_action(built)()
			helpers.assert_eq(requested, vector.expected,
				"the click must negate the facade's live state, not its render snapshot")
		end)
	end

	helpers.it("fails closed when the live facade state cannot be read", function()
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "active", { phase = "active" } end,
			stop = function() return true end,
		}
		package.loaded["ui.menu.menu_remap"] = nil
		local menu = helpers.load_with_stubs("ui.menu.menu_remap", {})
		local remap = disabled_remap()
		local reads = 0
		local set_calls = 0
		remap.get_enabled = function()
			reads = reads + 1
			if reads > 1 then error("synthetic live-state refusal") end
			return true
		end
		remap.set_enabled = function()
			set_calls = set_calls + 1
			return true
		end

		local built = menu.build({ karabiner = remap, updateMenu = function() end })
		local call_ok, committed = pcall(row_action(built))
		helpers.assert_true(call_ok, "a facade read fault must stay inside the menu callback")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(set_calls, 0, "no direction is safe without a live boolean state")
	end)
end)
