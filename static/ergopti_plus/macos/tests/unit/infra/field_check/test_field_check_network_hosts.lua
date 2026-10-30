--- tests/unit/infra/field_check/test_field_check_network_hosts.lua

--- ==============================================================================
--- MODULE: Field Run Network Hosts Probe
--- DESCRIPTION:
--- The field run's host reachability check over a scripted helper:
--- 1. every host of _shared/data/identifiers.json is its own step, named by
---    its key, in key order, whatever order the helper printed;
--- 2. a host the helper failed, or did not answer for, fails by its key while
---    the others keep their verdict;
--- 3. a helper that could not start fails every host as helper_unavailable,
---    and a line outside the grammar is ignored.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

--- Builds a scripted helper.
--- @return table ports, table world
local function make_ports()
	local world = { code = 0, output = "" }
	local ports = {
		host_heads = function(callback)
			world.calls = (world.calls or 0) + 1
			callback(world.code, world.output)
		end,
	}
	return ports, world
end

--- Runs the check and returns its steps keyed by id and in order.
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
		assert(Engine.run("network_hosts", ports, function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

--- The declared host keys, sorted.
--- @return table keys
local function host_keys()
	local keys = {}
	for key in pairs(require("identifiers").hosts) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

helpers.describe("network hosts probe", function()
	helpers.it("reports every declared host by key, in key order", function()
		local ports, world = make_ports()
		local lines = {}
		local keys = host_keys()
		for index = #keys, 1, -1 do lines[#lines + 1] = "step host_" .. keys[index] .. " pass http_200" end
		world.output = table.concat(lines, "\n") .. "\n"
		local steps, result = run(ports)
		helpers.assert_true(result.passed)
		helpers.assert_eq(#result.steps, #keys)
		for index, key in ipairs(keys) do
			helpers.assert_eq(result.steps[index].id, "host_" .. key)
			helpers.assert_eq(steps["host_" .. key].value, "http_200")
		end
		helpers.assert_true(#keys >= 5, "the declared hosts include GitHub, Hugging Face and the Ollama registry")
	end)

	helpers.it("fails the host the helper failed or skipped, by its key", function()
		local ports, world = make_ports()
		world.output = "step host_github pass http_200\nstep host_huggingface fail proxy\n"
			.. "step host_ollama https://registry.ollama.ai/ redacted\n"
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.host_github.state, "pass")
		helpers.assert_eq(steps.host_huggingface.value, "proxy")
		helpers.assert_eq(steps.host_ollama.value, "no_answer", "a line outside the grammar is ignored")
		helpers.assert_eq(steps.host_ollama_registry.value, "no_answer")
	end)

	helpers.it("fails every host when the helper cannot start", function()
		local ports, world = make_ports()
		world.code = nil
		local steps, result = run(ports)
		helpers.assert_true(not result.passed)
		for _, key in ipairs(host_keys()) do
			helpers.assert_eq(steps["host_" .. key].value, "helper_unavailable")
		end
	end)
end)
