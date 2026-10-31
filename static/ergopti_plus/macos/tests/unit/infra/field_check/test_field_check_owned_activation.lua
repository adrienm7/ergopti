--- tests/unit/infra/field_check/test_field_check_owned_activation.lua

--- ==============================================================================
--- MODULE: Field Run Owned Runtime Activation Check
--- DESCRIPTION:
--- Drives infra/field_check_owned_activation.lua over a fake Mac whose remap
--- owner follows the maintainer's rule, and over one that breaks it:
--- 1. downloaded and verified, inactive off, ready on, the user's Karabiner
---    closed then given back, the switch restored: every step passes;
--- 2. a runtime that leaves the user's Karabiner closed fails `off_restored`;
--- 3. a shared boot skips every step, a Mac without a user Karabiner skips the
---    close and restore steps, and a refused artifact skips the rest;
--- 4. the Tap-Hold switch always ends as the check found it.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes",
	"infra.field_check_owned_activation" }

--- A fake Mac: the owner follows the switch at once, the user Karabiner is
--- closed when ours starts and given back when ours stops (unless broken).
--- @param options table owned, tap_holds, others, fetch_ok, restores, on_state.
--- @return table ports
--- @return table world
local function mac(options)
	local world = { tap_holds = options.tap_holds == true, others = options.others or 0, marker = false,
		state = options.tap_holds and "ready" or "idle", flips = 0 }
	world.ports = {
		after = function(_, callback) callback() end,
		owned_activation = {
			selected = function() return options.owned ~= false end,
			tap_holds = function() return world.tap_holds end,
			set_tap_holds = function(value)
				world.flips = world.flips + 1
				world.tap_holds = value
				if value then
					world.state = options.on_state or "ready"
					if world.others > 0 and world.state == "ready" then world.others, world.marker = 0, true end
				else
					world.state = "stopped"
					if world.marker and options.restores ~= false then
						world.others, world.marker = options.others, false
					end
				end
				return true
			end,
			owner_state = function() return world.state end,
			owner_reason = function() return options.reason end,
			fetch = function(callback)
				if options.fetch_ok == false then return callback(false, "artifact_digest_mismatch") end
				callback(true, "/payload")
			end,
			other_active = function(callback) callback(world.others) end,
			marker = function() return world.marker end,
		},
	}
	return world.ports, world
end

--- Runs the check.
--- @param ports table Ports.
--- @return table steps by id
--- @return table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		for _, name in ipairs(MODULES) do if name ~= "infra.logger" then package.loaded[name] = nil end end
		local Engine = require("infra.field_check")
		assert(Engine.run("owned_activation", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("field run: the owned runtime activation rule", function()
	helpers.it("passes every step on a Mac that follows the rule and restores the switch", function()
		local ports, world = mac({ tap_holds = true, others = 2 })
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.artifact.value, "verified")
		helpers.assert_eq(steps.off_inactive.state, "pass")
		helpers.assert_eq(steps.on_active.value, "ready")
		helpers.assert_eq(steps.on_closed_other.state, "pass")
		helpers.assert_eq(steps.off_restored.state, "pass")
		helpers.assert_eq(steps.off_restored.value, "2")
		helpers.assert_eq(world.tap_holds, true)
		helpers.assert_eq(steps.tap_holds_restored.state, "pass")
	end)

	helpers.it("fails when the user's Karabiner is not given back", function()
		local ports = mac({ tap_holds = false, others = 1, restores = false })
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.off_restored.state, "fail")
		helpers.assert_eq(steps.on_closed_other.state, "pass")
	end)

	helpers.it("names the owner's reason when the runtime does not become ready", function()
		local ports = mac({ others = 0, on_state = "unavailable", reason = "runtime_not_installed" })
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.on_active.value, "unavailable:runtime_not_installed")
	end)

	helpers.it("skips what it cannot prove instead of passing it", function()
		local shared = run((mac({ owned = false })))
		for _, id in ipairs({ "artifact", "off_inactive", "on_active", "on_closed_other", "off_restored" }) do
			helpers.assert_eq(shared[id].state, "skip")
			helpers.assert_eq(shared[id].value, "shared_runtime")
		end
		local alone = run((mac({ others = 0 })))
		helpers.assert_eq(alone.on_closed_other.value, "no_user_karabiner")
		helpers.assert_eq(alone.off_restored.value, "no_user_karabiner")
		local ports, world = mac({ tap_holds = true, fetch_ok = false })
		local refused = run(ports)
		helpers.assert_eq(refused.artifact.state, "fail")
		helpers.assert_eq(refused.on_active.value, "no_artifact")
		helpers.assert_eq(world.flips, 0)
	end)
end)
