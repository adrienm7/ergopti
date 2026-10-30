--- tests/unit/infra/field_check/test_field_check_local_servers.lua

--- ==============================================================================
--- MODULE: Field Check, Local AI Servers
--- DESCRIPTION:
--- The field run names every server of local_servers.json, read-only: the
--- catalogue fails when a declared server has no discovery descriptor, and each
--- server's step says what the sweep found and where its port came from
--- (field-local-servers).
--- ==============================================================================

local helpers = require("tests.helpers")
local Report = require("field_check_report")
local Check = require("infra.field_check_local_servers")
local Json = require("json")

local function run(catalogue, views)
	local report = Report.new_report("local_servers")
	local finished = 0
	Check.local_servers({
		local_server_catalogue = function() return catalogue end,
		local_servers_detect = function(on_done) on_done(views) end,
	}, report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1)
	local steps = {}
	for _, step in ipairs(report.result().steps) do steps[step.id] = step end
	return steps
end

helpers.describe("field check local servers: every declared server named, read-only (field-local-servers)", function()
	helpers.it("names each server of the shipped list with its verdict and port source", function()
		local path = helpers.shared("modules/llm/local_servers.json")
		local handle = assert(io.open(path, "rb"))
		local root = Json.decode(handle:read("*a"))
		handle:close()
		local discovery = {}
		for _, id in ipairs(root.server_order) do discovery[id] = {} end
		local views = {
			{ id = root.server_order[1], status = "up", port_source = "cli", models = { "a", "b" } },
			{ id = root.server_order[2], status = "down", reason = "not_running", port_source = "default" },
		}
		local steps = run({ order = root.server_order, discovery = discovery, published = true }, views)
		helpers.assert_eq(steps.servers_catalogue.state, Report.STATE_PASS)
		helpers.assert_eq(steps.servers_catalogue.value, tostring(#root.server_order))
		helpers.assert_eq(steps["server_" .. root.server_order[1]].value, "up:cli:2")
		helpers.assert_eq(steps["server_" .. root.server_order[2]].value, "not_running:default")
		for index = 3, #root.server_order do
			helpers.assert_eq(steps["server_" .. root.server_order[index]].value, "not_swept")
		end
		helpers.assert_eq(steps.servers_found.value, "1")
	end)

	helpers.it("fails the catalogue when a declared server cannot be probed", function()
		local steps = run({ order = { "vllm", "exo" }, discovery = { vllm = {} }, published = true }, {})
		helpers.assert_eq(steps.servers_catalogue.state, Report.STATE_FAIL)
		helpers.assert_eq(steps.servers_catalogue.value, "undescribed_1")
	end)

	helpers.it("fails the sweep it could not start", function()
		local steps = run({ order = {}, discovery = {}, published = true }, nil)
		helpers.assert_eq(steps.servers_sweep.state, Report.STATE_FAIL)
	end)
end)
