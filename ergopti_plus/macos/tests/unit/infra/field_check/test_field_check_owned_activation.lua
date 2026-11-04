--- tests/unit/infra/field_check/test_field_check_owned_activation.lua

--- ==============================================================================
--- MODULE: Field Run Owned Runtime Activation Checks
--- DESCRIPTION:
--- Drives infra/field_check_owned_activation.lua over a fake Mac whose owner
--- follows the maintainer's rule of 2026-10-31, and over ones that break it:
--- 1. owned_start: verified artifact, ready runtime, the user's Karabiner closed
---    and recorded; a running user Karabiner with no record fails;
--- 2. owned_pause: the controlled pause stops ours and gives theirs back, and
---    the resume is queued for after the run, never run inside it;
--- 3. a shared boot skips every step, a Mac where nothing was closed skips the
---    close and restore steps.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes",
	"infra.field_check_owned_activation" }

--- A fake Mac following the rule unless told otherwise.
--- @param options table owned, paused, state, others, marker, restores, fetch_ok, after_run.
--- @return table ports
--- @return table world
local function mac(options)
	local world = { paused = options.paused == true, state = options.state or "ready", others = options.others or 0,
		marker = options.marker == true, resumes = 0, queued = {}, pauses = 0 }
	world.ports = {
		after = function(_, callback) callback() end,
		after_run = function(work)
			if options.after_run == false then return false end
			world.queued[#world.queued + 1] = work
			return true
		end,
		owned_activation = {
			selected = function() return options.owned ~= false end,
			paused = function() return world.paused end,
			pause = function()
				world.pauses = world.pauses + 1
				world.paused, world.state = true, "stopped"
				if world.marker and options.restores ~= false then world.others, world.marker = 1, false end
				return true
			end,
			resume = function() world.resumes = world.resumes + 1 end,
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

--- Runs one check.
--- @param check string Check identity.
--- @param ports table Ports.
--- @return table steps by id
--- @return table result
local function run(check, ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		for _, name in ipairs(MODULES) do if name ~= "infra.logger" then package.loaded[name] = nil end end
		local Engine = require("infra.field_check")
		assert(Engine.run(check, ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("field run: Ergopti runs, so its runtime closes the user's Karabiner", function()
	helpers.it("passes a verified, ready runtime holding the user's Karabiner closed", function()
		local steps, result = run("owned_start", (mac({ marker = true, others = 0 })))
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.artifact.value, "verified")
		helpers.assert_eq(steps.runtime_ready.value, "ready")
		helpers.assert_eq(steps.user_karabiner_closed.state, "pass")
	end)

	helpers.it("fails a user Karabiner left running beside a running Ergopti", function()
		local steps, result = run("owned_start", (mac({ marker = false, others = 1 })))
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.user_karabiner_closed.state, "fail")
	end)

	helpers.it("names the owner's reason when the runtime is not ready", function()
		local steps = run("owned_start", (mac({ state = "unavailable", reason = "virtual_hid_incompatible" })))
		helpers.assert_eq(steps.runtime_ready.value, "unavailable:virtual_hid_incompatible")
	end)

	helpers.it("skips what it cannot prove instead of passing it", function()
		local shared = run("owned_start", (mac({ owned = false })))
		helpers.assert_eq(shared.artifact.value, "shared_runtime")
		local alone = run("owned_start", (mac({ others = 0 })))
		helpers.assert_eq(alone.user_karabiner_closed.value, "no_user_karabiner")
		local paused = run("owned_start", (mac({ paused = true })))
		helpers.assert_eq(paused.runtime_ready.value, "paused")
	end)
end)

helpers.describe("field run: Ergopti paused gives the user's Karabiner back", function()
	helpers.it("pauses, stops ours, restores theirs and queues the resume for after the run", function()
		local ports, world = mac({ marker = true, others = 0 })
		local steps, result = run("owned_pause", ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.paused.state, "pass")
		helpers.assert_eq(steps.runtime_stopped.state, "pass")
		helpers.assert_eq(steps.user_karabiner_restored.state, "pass")
		helpers.assert_eq(steps.resume_queued.state, "pass")
		helpers.assert_eq(world.resumes, 0, "the resume reloads the driver, so it never runs inside the run")
		helpers.assert_eq(#world.queued, 1)
		world.queued[1]()
		helpers.assert_eq(world.resumes, 1)
	end)

	helpers.it("fails when the user's Karabiner does not come back", function()
		local steps, result = run("owned_pause", (mac({ marker = true, restores = false })))
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.user_karabiner_restored.state, "fail")
	end)

	helpers.it("leaves an already paused Ergopti paused and skips what was never closed", function()
		local ports, world = mac({ paused = true, state = "stopped" })
		local steps = run("owned_pause", ports)
		helpers.assert_eq(world.pauses, 0)
		helpers.assert_eq(steps.resume_queued.value, "was_paused")
		helpers.assert_eq(steps.user_karabiner_restored.value, "no_user_karabiner")
		helpers.assert_eq(#world.queued, 0)
	end)

	helpers.it("fails a resume the field run refused to queue", function()
		local steps = run("owned_pause", (mac({ after_run = false })))
		helpers.assert_eq(steps.resume_queued.state, "fail")
	end)
end)
