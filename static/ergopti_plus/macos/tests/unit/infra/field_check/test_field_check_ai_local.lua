--- tests/unit/infra/field_check/test_field_check_ai_local.lua

--- ==============================================================================
--- MODULE: Field Run Local AI Probe
--- DESCRIPTION:
--- The field run's local AI check over scripted ports:
--- 1. the owned Ollama binary passes only a strict signature check, and a
---    broken one names codesign's cause;
--- 2. a server that does not answer is a skip, never a start, and a Mac with
---    no catalogue model installed skips the prediction (no download);
--- 3. the prediction uses the installed model and the check's own text, and
---    a failed or slow answer fails it by name;
--- 4. the MLX runtime and its installed catalogue models are information.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local OLLAMA = "/Users/someone/Library/Application Support/Ergopti/ollama-native-http/ollama"

--- Builds scripted ports; `world` records every call.
--- @return table ports, table world
local function make_ports()
	local world = {
		commands = {},
		codesign = { 0, "", "" },
		facts = { ollama_path = OLLAMA, mlx_runtime = true, mlx_installed = 2 },
		listed = true,
		installed = "qwen3:0.6b",
		answer = { true, nil, 812.6 },
		refreshes = 0,
	}
	local ports = {
		exec = function(executable, args, _, callback)
			world.commands[#world.commands + 1] = executable .. " " .. table.concat(args, " ")
			callback(world.codesign[1], world.codesign[2], world.codesign[3])
		end,
		ai_facts = function() return world.facts end,
		ollama_refresh = function(callback)
			world.refreshes = world.refreshes + 1
			callback(world.listed)
		end,
		ollama_installed_model = function() return world.installed end,
		ollama_predict = function(model, text, callback)
			world.prediction = { model = model, text = text }
			callback(world.answer[1], world.answer[2], world.answer[3])
		end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id.
--- @param ports table Ports.
--- @return table steps, table result
local function run(ports)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("ai_local", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("local AI probe", function()
	helpers.it("passes a signed binary, a listing server and a one-token answer", function()
		local ports, world = make_ports()
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(world.commands[1], "/usr/bin/codesign --verify --strict --verbose=2 " .. OLLAMA)
		helpers.assert_eq(steps.ollama_binary.value, "signature_valid")
		helpers.assert_eq(steps.ollama_listing.value, "listed")
		helpers.assert_eq(steps.ollama_prediction.value, "812ms")
		helpers.assert_eq(world.prediction.model, "qwen3:0.6b")
		helpers.assert_eq(world.prediction.text, "1 2 3 4", "only the check's own text is sent")
		helpers.assert_eq(steps.mlx_runtime.value, "installed")
		helpers.assert_eq(steps.mlx_models_installed.value, "2")
	end)

	helpers.it("fails a broken binary signature with its cause", function()
		local ports, world = make_ports()
		world.codesign = { 1, "", OLLAMA .. ": code object is not signed at all\n" }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.ollama_binary.value, "exit_1:not_signed")
		helpers.assert_eq(steps.ollama_listing.state, "pass", "the listing still runs")
	end)

	helpers.it("skips a server that is not running and a Mac without an installed model", function()
		local ports, world = make_ports()
		world.listed = false
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.ollama_listing.value, "not_running")
		helpers.assert_eq(steps.ollama_prediction.state, "skip")
		helpers.assert_nil(world.prediction)
		world.listed = true
		world.installed = nil
		steps = run(ports)
		helpers.assert_eq(steps.ollama_installed.value, "none_of_the_catalogue")
		helpers.assert_eq(steps.ollama_prediction.value, "no_installed_model")
		helpers.assert_nil(world.prediction)
	end)

	helpers.it("fails a prediction that fails or times out, by name", function()
		local ports, world = make_ports()
		world.answer = { false, "request_failed", 30 }
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.ollama_prediction.value, "request_failed")
		world.answer = { false, "timeout", 60000 }
		helpers.assert_eq(run(ports).ollama_prediction.value, "timeout")
	end)

	helpers.it("skips the binary without an owned Ollama and reads unknown MLX facts", function()
		local ports, world = make_ports()
		world.facts = {}
		local steps = run(ports)
		helpers.assert_eq(steps.ollama_binary.value, "not_installed")
		helpers.assert_eq(#world.commands, 0)
		helpers.assert_eq(steps.mlx_runtime.value, "unknown")
		helpers.assert_eq(steps.mlx_models_installed.value, "unknown")
	end)
end)
