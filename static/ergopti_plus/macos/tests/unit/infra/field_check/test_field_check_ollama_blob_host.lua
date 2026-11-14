--- tests/unit/infra/field_check/test_field_check_ollama_blob_host.lua

--- ==============================================================================
--- MODULE: Field Run Ollama Blob Host Probe (ollama-blob-host)
--- DESCRIPTION:
--- The daemon's pull is routed by the route inventory; behind a PAC a blob
--- host the inventory does not plan is fetched on the wrong route. The probe
--- asks the helper for the smallest catalogue model's blob redirect:
--- 1. the helper gets the model's runtime name, and both verdicts are steps;
--- 2. an unplanned host fails, an absent answer fails as no_answer;
--- 3. no catalogue model skips, a helper that cannot start fails.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "core.logger.engine.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local function make_ports()
	local world = { code = 0, output = "", model = { name = "Tiny", runtime_name = "tiny:0.5b", download_gb = 0.4 } }
	local ports = {
		smallest_ollama_model = function() return world.model end,
		blob_host = function(model, callback)
			world.asked = model
			callback(world.code, world.output)
		end,
	}
	return ports, world
end

local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("ollama_blob_host", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("Ollama blob host probe (ollama-blob-host)", function()
	helpers.it("passes a planned blob host and asks for the smallest model's runtime name", function()
		local ports, world = make_ports()
		world.output = "step blob_manifest pass http_200\nstep blob_host pass planned\n"
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(world.asked, "tiny:0.5b")
		helpers.assert_eq(steps.blob_manifest.value, "http_200")
		helpers.assert_eq(steps.blob_host.value, "planned")
	end)

	helpers.it("(ollama-blob-range) reports whether the network honours a range, and never hides a failure", function()
		local ports, world = make_ports()
		world.output = "step blob_manifest pass http_200\nstep blob_host pass planned\nstep blob_range info ignored\n"
		local steps, result = run(ports)
		helpers.assert_true(result.passed, "the daemon copes with an ignored range")
		helpers.assert_eq(steps.blob_range.state, "info")
		helpers.assert_eq(steps.blob_range.value, "ignored")
		world.output = "step blob_manifest pass http_200\nstep blob_host pass planned\nstep blob_range fail wrong_range\n"
		local failed, failed_result = run(ports)
		helpers.assert_true(not failed_result.passed, "a range served at another offset fails")
		helpers.assert_eq(failed.blob_range.value, "wrong_range")
	end)

	helpers.it("fails an unplanned blob host and a missing answer", function()
		local ports, world = make_ports()
		world.output = "step blob_manifest pass http_200\nstep blob_host fail unplanned_host\n"
		local steps, result = run(ports)
		helpers.assert_true(not result.passed, "an unplanned blob host fails the check")
		helpers.assert_eq(steps.blob_host.value, "unplanned_host")
		world.output = "step blob_manifest pass http_200\n"
		helpers.assert_eq(run(ports).blob_host.value, "no_answer")
	end)

	helpers.it("skips without a catalogue model and fails a helper that cannot start", function()
		local ports, world = make_ports()
		world.model = nil
		local steps, result = run(ports)
		helpers.assert_true(result.passed, "no model to probe is not a failure")
		helpers.assert_eq(steps.blob_host.state, "skip")
		helpers.assert_nil(world.asked, "no request without a model")
		world.model = { name = "Tiny", runtime_name = "tiny:0.5b", download_gb = 0.4 }
		world.code = nil
		local failed = run(ports)
		helpers.assert_eq(failed.blob_manifest.value, "helper_unavailable")
		helpers.assert_eq(failed.blob_host.value, "helper_unavailable")
	end)
end)
