--- tests/unit/platform/remap/runtime_activation/test_runtime_activation.lua

--- ==============================================================================
--- MODULE: Owned Runtime Activation Rule
--- DESCRIPTION:
--- Pins platform/remap/runtime_activation.lua, the maintainer's rule for a Mac
--- that may already run its own Karabiner-Elements: Tap-Hold on closes theirs
--- (with consent) and runs Ergopti's; Tap-Hold off never runs Ergopti's and
--- leaves theirs untouched; turning Tap-Hold off gives theirs back if Ergopti
--- closed it, and only then.
---
--- ROOT CAUSES ENCODED: (a) a restore without a record of the close would
--- start a Karabiner the user had quit themselves; (b) a stop that forgot the
--- restore would leave the user without their own rules; (c) a crash between
--- the close and the restore must not lose the record.
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
		restore_result = true, consent = true }
	local owner = {
		status = function() return { state = world.state } end,
		start = function(options, on_settled)
			world.starts[#world.starts + 1] = options
			world.state = "starting"
			world.settle_start = on_settled
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
		close_other_instances = function() return world.consent end,
	})
	return activation, world, Activation
end





-- ================================
-- ================================
-- ======= 1/ The Predicate =======
-- ================================
-- ================================

helpers.describe("owned runtime activation: what Tap-Hold on means", function()
	helpers.it("is on only when Ergopti uses Karabiner and Tap-Hold is on", function()
		local _, _, Activation = fake()
		helpers.assert_eq(Activation.wanted({ enabled = true, tap_holds_enabled = true }), true)
		helpers.assert_eq(Activation.wanted({ enabled = true }), true)
		helpers.assert_eq(Activation.wanted({ enabled = true, tap_holds_enabled = false }), false)
		helpers.assert_eq(Activation.wanted({ enabled = false, tap_holds_enabled = true }), false)
		helpers.assert_eq(Activation.wanted(nil), false)
	end)
end)





-- ==============================
-- ==============================
-- ======= 2/ Tap-Hold On =======
-- ==============================
-- ==============================

helpers.describe("owned runtime activation: Tap-Hold on", function()
	helpers.it("runs Ergopti's runtime with the user's close consent", function()
		local activation, world = fake()
		helpers.assert_eq(activation.reconcile(true), "start")
		helpers.assert_eq(world.starts, { { close_other_instances = true } })
		world.consent = false
		world.state = "idle"
		activation.reconcile(true)
		helpers.assert_eq(world.starts[2], { close_other_instances = false })
	end)

	helpers.it("does not start a second time while the runtime starts or runs", function()
		for _, state in ipairs({ "starting", "admitted", "peers_starting", "ready" }) do
			local activation, world = fake(state)
			helpers.assert_eq(activation.reconcile(true), "starting")
			helpers.assert_eq(#world.starts, 0)
		end
	end)

	helpers.it("tells the caller once the runtime is admitted", function()
		local activation, world = fake()
		local admitted = 0
		activation.reconcile(true, function() admitted = admitted + 1 end)
		world.settle_start(false, "other_karabiner_running")
		helpers.assert_eq(admitted, 0)
		world.state = "unavailable"
		activation.reconcile(true, function() admitted = admitted + 1 end)
		world.settle_start(true)
		helpers.assert_eq(admitted, 1)
	end)

	helpers.it("records a close only when Karabiner's own quit succeeded", function()
		local _, _, Activation = fake()
		local marked = 0
		local marker = { set = function() marked = marked + 1; return true end }
		local answers = {}
		Activation.remembering_close(function(callback) callback(false) end, marker)(function(ok) answers[1] = ok end)
		helpers.assert_eq(marked, 0)
		Activation.remembering_close(function(callback) callback(true) end, marker)(function(ok) answers[2] = ok end)
		helpers.assert_eq(marked, 1)
		helpers.assert_eq(answers, { false, true })
	end)
end)





-- ===============================
-- ===============================
-- ======= 3/ Tap-Hold Off =======
-- ===============================
-- ===============================

helpers.describe("owned runtime activation: Tap-Hold off", function()
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
		helpers.assert_eq(idle_world.stops, 0)
		helpers.assert_eq(idle_world.restores, 0)
	end)

	helpers.it("gives back a Karabiner left closed by a crash on the next boot with Tap-Hold off", function()
		local activation, world = fake("idle")
		world.marker = true
		helpers.assert_eq(activation.reconcile(false), "idle")
		helpers.assert_eq(world.restores, 1)
		helpers.assert_eq(world.stops, 0)
		helpers.assert_eq(#world.starts, 0)
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
