--- tests/unit/menu/ui/tap_holds/test_title_status.lua

--- ==============================================================================
--- MODULE: Tap-Holds Title Status Dot
--- DESCRIPTION:
--- The Tap-Holds title carries the AI title's status dot (maintainer,
--- 2026-11-23): green when the tap-holds work, red when they do not, the
--- warning dot while they are on their way or wait on the user, and none while
--- the feature is off or Ergopti is paused. The glyphs are the manifest's, the
--- ones the AI title reads, and the shared watch repaints the title when the
--- status changes after the build that painted it.
---
--- ROOT CAUSE ENCODED: the Tap-Holds title said nothing about its runtime, so a
--- user whose tap-holds were blocked had to open the submenu to learn it.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "ui.menu.menu_tap_holds", "ui.menu.tap_holds_status", "menu.ui.title_status",
	"core.events.timer_scheduler" }

--- The glyphs the manifest declares on its top-level ``llm`` entry.
--- @return table glyphs status -> glyph
local function manifest_glyphs()
	local root = require("menu.engine.manifest_menu").get_root()
	for _, entry in ipairs(root.top_level) do
		if entry.id == "llm" then return entry.health_dot end
	end
	error("the manifest declares no llm entry")
end

--- A remap double with the readers the title reads.
--- @param fields table|nil Facade fields replacing the defaults.
--- @return table karabiner
local function remap(fields)
	local karabiner = {
		DEFAULT_TAP_HOLD_TIMEOUT_MS = 200,
		DEFAULT_STICKY_TIMEOUT_MS = 1000,
		DEFAULT_SIMULTANEOUS_THRESHOLD_MS = 50,
		AVAILABLE_ACTIONS = {
			{ id = "none", label = "None", category = "Special", holdable = true, tappable = true },
		},
		TAP_HOLD_KEYS = { { id = "tab", label = "Tab" } },
		MOD_COMBOS = {},
		NON_CANONICAL_COMBOS = {},
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
		get_key_combinations_enabled = function() return true end,
		get_combo_symmetric = function() return false end,
		get_tap_action = function() return "tab" end,
		get_hold_action = function() return "none" end,
		get_tap_timeout = function() return nil end,
		get_tap_hold_timeout = function() return 200 end,
		get_sticky_timeout = function() return 1000 end,
		get_lone_modifier_tap_max_ms = function() return 1000 end,
		get_simultaneous_threshold = function() return 50 end,
		lease_phase = function() return "active" end,
	}
	for name, value in pairs(fields or {}) do karabiner[name] = value end
	return karabiner
end

--- Runs a case over a fresh menu and a scheduler double whose ticks the test drives.
--- @param fn function fn(menu, timers)
local function with_menu(fn)
	helpers.with_fresh_modules(MODULES, function()
		local timers = { armed = 0, cancelled = 0, tick = nil }
		package.loaded["core.events.timer_scheduler"] = {
			every = function(_, tick)
				timers.armed = timers.armed + 1
				timers.tick = tick
				return { id = timers.armed }, true
			end,
			cancel = function() timers.cancelled = timers.cancelled + 1; timers.tick = nil; return true end,
			after = function() return {}, true end,
		}
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds", {})
		menu._reset_picker_cache()
		local ok, err = pcall(fn, menu, timers)
		menu._status_watch.stop()
		if not ok then error(err, 0) end
	end)
end

--- The Tap-Holds title for one remap double.
--- @param menu table The menu module.
--- @param karabiner table Remap double.
--- @param ctx_fields table|nil Context fields added to the build context.
--- @return string label
local function title(menu, karabiner, ctx_fields)
	local ctx = { karabiner = karabiner, updateMenu = function() end }
	for name, value in pairs(ctx_fields or {}) do ctx[name] = value end
	local row = menu.build(ctx)
	helpers.assert_true(type(row) == "table" and type(row.label) == "string", "the Tap-Holds row must build")
	return row.label
end





-- ============================================
-- ============================================
-- ======= 1/ One Colour Per Owner Enum =======
-- ============================================
-- ============================================

helpers.describe("Tap-Holds title status: mapping", function()
	helpers.it("gives every owned runtime state and reason an explicit colour", function()
		package.loaded["platform.remap.runtime_owner"] = nil
		local Owner = require("platform.remap.runtime_owner")
		local Vhid = require("platform.remap.runtime_vhid")
		local Status = require("ui.menu.tap_holds_status")
		local states = {}
		for _, value in pairs(Owner.STATE) do
			states[value] = true
			helpers.assert_true(Status.OWNED_STATES[value] ~= nil, "state " .. value .. " has no colour")
		end
		for value in pairs(Status.OWNED_STATES) do helpers.assert_true(states[value], value .. " is no owner state") end
		local reasons = {}
		for _, value in pairs(Owner.REASON) do reasons[value] = true end
		for name, value in pairs(Vhid) do
			if type(name) == "string" and name:find("^REASON_") then reasons[value] = true end
		end
		for value in pairs(reasons) do
			helpers.assert_true(Status.OWNED_REASONS[value] ~= nil, "reason " .. value .. " has no colour")
		end
		for value in pairs(Status.OWNED_REASONS) do helpers.assert_true(reasons[value], value .. " is no owner reason") end
	end)

	helpers.it("maps the owner's states and reasons to green, warning and red", function()
		local Status = require("ui.menu.tap_holds_status")
		local function owned(state, reason)
			return Status.read(remap({ owned_runtime_status = function() return { state = state, reason = reason } end }),
				true, false)
		end
		helpers.assert_eq(owned("ready"), "ready")
		helpers.assert_eq(owned("starting"), "warming")
		helpers.assert_eq(owned("peers_starting"), "warming")
		helpers.assert_eq(owned("unavailable", "other_karabiner_running"), "warming")
		helpers.assert_eq(owned("unavailable", "virtual_hid_not_active"), "warming")
		helpers.assert_eq(owned("unavailable", "runtime_not_installed"), "unreachable")
		helpers.assert_eq(owned("unavailable", "virtual_hid_absent"), "unreachable")
		helpers.assert_eq(owned("failed", "capture_lost"), "unreachable")
		helpers.assert_eq(owned("failed", "a_reason_no_owner_declares"), "unreachable")
	end)

	helpers.it("maps the shared runtime's guardian and lease, and draws no dot while off or paused", function()
		local Status = require("ui.menu.tap_holds_status")
		helpers.assert_eq(Status.read(remap(), true, false), "ready")
		helpers.assert_eq(Status.read(remap({ lease_phase = function() return "starting" end }), true, false), "warming")
		helpers.assert_eq(Status.read(remap({ lease_phase = function() return "failed" end }), true, false), "unreachable")
		helpers.assert_eq(Status.read(remap({ guardian_state = function() return "requires_approval" end }), true, false),
			"warming")
		helpers.assert_eq(Status.read(remap({ guardian_state = function() return "unavailable" end }), true, false),
			"unreachable")
		helpers.assert_eq(Status.read(remap({ get_enabled = function() return false end }), true, false), "unreachable")
		helpers.assert_eq(Status.read(remap({ legacy_rule_conflicts = function() return { count = 1 } end }), true, false),
			"unreachable")
		helpers.assert_nil(Status.read(remap(), false, false), "no dot while the tap-holds are off")
		helpers.assert_eq(Status.read(remap({ owned_runtime_status = function()
			return { state = "unavailable", reason = "runtime_not_installed" }
		end }), false, false), "unreachable", "a missing owned runtime is red with the switch off")
		helpers.assert_nil(Status.read(remap({ owned_runtime_status = function()
			return { state = "unavailable", reason = "other_karabiner_running" }
		end }), false, false), "a warning block draws nothing with the switch off")
		helpers.assert_nil(Status.read(remap(), true, true), "no dot while Ergopti is paused")
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 2/ The Title And Its Watch =======
-- ==========================================
-- ==========================================

helpers.describe("Tap-Holds title status: title", function()
	helpers.it("carries the manifest's glyph for each status and none while off or paused", function()
		with_menu(function(menu)
			local glyphs = manifest_glyphs()
			local plain = title(menu, remap({ get_tap_holds_enabled = function() return false end }))
			helpers.assert_eq(title(menu, remap()), plain .. " " .. glyphs.ready)
			helpers.assert_eq(title(menu, remap({ lease_phase = function() return "starting" end })),
				plain .. " " .. glyphs.warming)
			helpers.assert_eq(title(menu, remap({ owned_runtime_status = function()
				return { state = "unavailable", reason = "runtime_not_installed" }
			end })), plain .. " " .. glyphs.unreachable)
			helpers.assert_eq(title(menu, remap(), { is_paused = function() return true end }), plain,
				"a paused Ergopti draws no dot")
		end)
	end)

	helpers.it("repaints the title once when the runtime turns ready after the build", function()
		with_menu(function(menu, timers)
			local phase, repaints = "starting", 0
			local karabiner = remap({ lease_phase = function() return phase end })
			menu.build({ karabiner = karabiner, updateMenu = function() repaints = repaints + 1 end })
			helpers.assert_eq(timers.armed, 1, "a painted dot must arm the watch")
			timers.tick()
			helpers.assert_eq(repaints, 0, "an unchanged dot must not rebuild the menu")
			phase = "active"
			timers.tick()
			helpers.assert_eq(repaints, 1, "the dot turning green must rebuild the menu")
			timers.tick()
			helpers.assert_eq(repaints, 1, "a dot already repainted must not rebuild again")
			menu.build({ karabiner = remap({ get_tap_holds_enabled = function() return false end }),
				updateMenu = function() end })
			helpers.assert_eq(timers.cancelled, 0, "a build without a dot keeps the Tap-Holds watch armed")
			helpers.assert_eq(timers.armed, 1, "the armed watch is reused, never doubled")
		end)
	end)

	helpers.it("is red while the owned runtime is not installed or failed, even with the switch off (2026-11-24)", function()
		-- Field report dev.178: the install was refused and the runtime missing,
		-- the install gate greyed the switch, and the title drew no dot at all.
		with_menu(function(menu)
			local glyphs = manifest_glyphs()
			local off = function() return false end
			local plain = title(menu, remap({ get_tap_holds_enabled = off }))
			for _, status in ipairs({
				{ state = "unavailable", reason = "runtime_not_installed" },
				{ state = "unavailable", reason = "runtime_job_not_loaded" },
				{ state = "failed", reason = "capture_lost" },
			}) do
				local karabiner = remap({ get_tap_holds_enabled = off,
					owned_runtime_status = function() return status end,
					install_owned_runtime = function() return true end })
				helpers.assert_eq(title(menu, karabiner), plain .. " " .. glyphs.unreachable,
					status.reason .. " must draw the red dot with the switch off")
			end
			helpers.assert_eq(title(menu, remap({ get_tap_holds_enabled = off,
				owned_runtime_status = function() return { state = "starting" } end })), plain,
				"a starting runtime draws nothing while the switch is off")
			helpers.assert_eq(title(menu, remap({ owned_runtime_status = function()
				return { state = "unavailable", reason = "runtime_not_installed" }
			end }), { is_paused = function() return true end }), plain, "a paused Ergopti draws no dot")
		end)
	end)

	helpers.it("repaints the title red when the runtime fails after a build that drew no dot", function()
		with_menu(function(menu, timers)
			local status, repaints = { state = "starting" }, 0
			local karabiner = remap({ get_tap_holds_enabled = function() return false end,
				owned_runtime_status = function() return status end })
			menu.build({ karabiner = karabiner, updateMenu = function() repaints = repaints + 1 end })
			helpers.assert_eq(timers.armed, 1, "a title without a dot must still be watched")
			timers.tick()
			helpers.assert_eq(repaints, 0, "nothing changed: no rebuild")
			status = { state = "unavailable", reason = "runtime_not_installed" }
			timers.tick()
			helpers.assert_eq(repaints, 1, "the runtime failing must repaint the title red")
		end)
	end)
end)
