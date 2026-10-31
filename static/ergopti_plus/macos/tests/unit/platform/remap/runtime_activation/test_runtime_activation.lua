--- tests/unit/platform/remap/runtime_activation/test_runtime_activation.lua

--- ==============================================================================
--- MODULE: Owned Runtime Activation Rule
--- DESCRIPTION:
--- Pins platform/remap/runtime_activation.lua, the maintainer's rule of
--- 2026-10-31 for a Mac that may already run its own Karabiner-Elements: while
--- Ergopti runs and is not paused, Ergopti's runtime is active and theirs is
--- closed; paused or quit, Ergopti's stops and theirs comes back if Ergopti
--- closed it, and only then. No menu switch takes part.
---
--- ROOT CAUSES ENCODED: (a) a restore without a record of the close would
--- start a Karabiner the user had quit themselves; (b) a stop that forgot the
--- restore would leave the user without their own rules; (c) a crash between
--- the close and the restore must not lose the record; (d) a second capture
--- cannot start in one Lua VM, so a resume after a stop must reload instead of
--- failing with capture_start_refused.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the rule over fake ports.
--- @param initial_state string|nil Owner state at the start.
--- @return table activation
--- @return table world
--- @return table Activation module
local function fake(initial_state)
	package.loaded["platform.remap.runtime_activation"] = nil
	local Activation = require("platform.remap.runtime_activation")
	local world = { state = initial_state or "idle", starts = {}, stops = 0, restores = 0, marker = false,
		restore_result = true, reloads = 0, admit = true }
	local owner = {
		status = function() return { state = world.state } end,
		start = function(options, on_settled)
			world.starts[#world.starts + 1] = options
			world.state = world.admit and "ready" or "unavailable"
			on_settled(world.admit)
			return true
		end,
		stop = function(observer)
			world.stops = world.stops + 1
			world.state = "stopped"
			if observer then observer(true) end
			return true
		end,
	}
	local activation = Activation.new({
		owner = owner,
		restore = function(callback)
			world.restores = world.restores + 1
			callback(world.restore_result)
		end,
		marker = {
			get = function() return world.marker end,
			clear = function() world.marker = false; return true end,
		},
		reload = function() world.reloads = world.reloads + 1 end,
	})
	return activation, world, Activation
end





-- ================================
-- ================================
-- ======= 1/ The Predicate =======
-- ================================
-- ================================

helpers.describe("owned runtime activation: what « wanted » means", function()
	helpers.it("is running and not paused, and nothing else", function()
		local _, _, Activation = fake()
		helpers.assert_eq(Activation.wanted({ running = true, paused = false }), true)
		helpers.assert_eq(Activation.wanted({ running = true }), true)
		helpers.assert_eq(Activation.wanted({ running = true, paused = true }), false)
		helpers.assert_eq(Activation.wanted({ running = false }), false)
		helpers.assert_eq(Activation.wanted({ running = true, tap_holds_enabled = false }), true)
		helpers.assert_eq(Activation.wanted(nil), false)
	end)
end)





-- =================================
-- =================================
-- ======= 2/ Running: Close =======
-- =================================
-- =================================

helpers.describe("owned runtime activation: Ergopti runs", function()
	helpers.it("starts Ergopti's runtime, which always closes the user's Karabiner", function()
		local activation, world = fake()
		local admitted = 0
		helpers.assert_eq(activation.reconcile(true, function() admitted = admitted + 1 end), "start")
		helpers.assert_eq(world.starts, { { close_other_instances = true } })
		helpers.assert_eq(admitted, 1)
	end)

	helpers.it("does not start a second time while the runtime starts or runs", function()
		for _, state in ipairs({ "starting", "admitted", "peers_starting", "ready" }) do
			local activation, world = fake(state)
			helpers.assert_eq(activation.reconcile(true), "starting")
			helpers.assert_eq(#world.starts, 0)
		end
	end)

	helpers.it("records and announces a close only when Karabiner's own quit succeeded", function()
		local _, _, Activation = fake()
		local marked, announced = 0, 0
		local marker = { set = function() marked = marked + 1; return true end }
		local announce = function() announced = announced + 1 end
		local answers = {}
		Activation.remembering_close(function(callback) callback(false) end, marker, announce)(function(ok)
			answers[1] = ok
		end)
		helpers.assert_eq({ marked, announced }, { 0, 0 })
		Activation.remembering_close(function(callback) callback(true) end, marker, announce)(function(ok)
			answers[2] = ok
		end)
		helpers.assert_eq({ marked, announced }, { 1, 1 })
		helpers.assert_eq(answers, { false, true })
	end)
end)





-- ============================================
-- ============================================
-- ======= 3/ Paused Or Quit: Give Back =======
-- ============================================
-- ============================================

helpers.describe("owned runtime activation: Ergopti paused", function()
	helpers.it("stops Ergopti's runtime and gives back the Karabiner it closed", function()
		local activation, world = fake("ready")
		world.marker = true
		helpers.assert_eq(activation.reconcile(false), "stop")
		helpers.assert_eq(world.stops, 1)
		helpers.assert_eq(world.restores, 1)
		helpers.assert_eq(world.marker, false)
	end)

	helpers.it("never starts or restores anything when Ergopti closed nothing", function()
		local activation, world = fake("ready")
		activation.reconcile(false)
		helpers.assert_eq(world.restores, 0)
		local idle, idle_world = fake("idle")
		helpers.assert_eq(idle.reconcile(false), "idle")
		helpers.assert_eq(#idle_world.starts, 0)
		helpers.assert_eq(idle_world.restores, 0)
	end)

	helpers.it("keeps the record after a crash and gives the Karabiner back at the next pause", function()
		local activation, world = fake("idle")
		world.marker = true
		helpers.assert_eq(activation.reconcile(true), "start")
		helpers.assert_eq(world.marker, true, "a start keeps the record of the earlier close")
		helpers.assert_eq(world.restores, 0)
		activation.reconcile(false)
		helpers.assert_eq(world.restores, 1)
		helpers.assert_eq(world.marker, false)
	end)

	helpers.it("keeps the record when the restore is refused, so a later try can succeed", function()
		local activation, world = fake("idle")
		world.marker, world.restore_result = true, false
		local answer
		activation.restore_if_closed(function(restored) answer = restored end)
		helpers.assert_eq(answer, false)
		helpers.assert_eq(world.marker, true)
		world.restore_result = true
		activation.restore_if_closed(function(restored) answer = restored end)
		helpers.assert_eq(answer, true)
		helpers.assert_eq(world.marker, false)
	end)
end)





-- =============================================
-- =============================================
-- ======= 4/ Resume: One Capture Per VM =======
-- =============================================
-- =============================================

helpers.describe("owned runtime activation: Ergopti resumes", function()
	helpers.it("reloads instead of starting a second capture in the same Lua VM", function()
		local activation, world = fake()
		activation.reconcile(true)
		activation.reconcile(false)
		helpers.assert_eq(activation.reconcile(true), "reload")
		helpers.assert_eq(world.reloads, 1)
		helpers.assert_eq(#world.starts, 1)
	end)

	helpers.it("starts again in place when no earlier start reached the capture", function()
		local activation, world = fake()
		world.admit = false
		activation.reconcile(true)
		world.admit = true
		helpers.assert_eq(activation.reconcile(true), "start")
		helpers.assert_eq(world.reloads, 0)
		helpers.assert_eq(#world.starts, 2)
	end)
end)
