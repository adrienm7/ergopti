--- _shared/lua/test/network_route_plan_contract.lua

--- ==============================================================================
--- MODULE: Network Route Plan Contract
--- DESCRIPTION:
--- Runs the shared per-origin route plan over the vector corpus the Go and shell
--- twins answer too, and pins the closed refusal enum to the origin inventory.
--- ==============================================================================

local M = {}
local Json = require("json")
local RoutePlan = require("network.route_plan")

--- Registers the route plan controls through the calling driver's path reader.
--- @param read function Reads a file below the shared root by relative path.
--- @param helpers table The driver's test helpers.
function M.register(read, helpers)
	local vectors = Json.decode(assert(read("tests/corpus/network/route_plan_vectors.json")))
	local origins = Json.decode(assert(read("modules/network/route_origins.json")))

	helpers.describe("shared_route_plan: per-origin route plan", function()
		helpers.it("answers every plan vector", function()
			for _, case in ipairs(vectors.plans) do
				local plan, reason = RoutePlan.plan(case.entries)
				if case.expect.reason then
					helpers.assert_nil(plan, case.name)
					helpers.assert_eq(reason, case.expect.reason, case.name)
				else
					helpers.assert_nil(reason, case.name)
					helpers.assert_eq(plan.proxy, case.expect.proxy, case.name)
					helpers.assert_eq(plan.no_proxy(), case.expect.no_proxy, case.name)
				end
			end
		end)

		helpers.it("re-evaluates every redirect target against the plan", function()
			local plan = assert(RoutePlan.plan(vectors.redirects.plan))
			for _, case in ipairs(vectors.redirects.targets) do
				local route, reason = plan.redirect(case.url)
				if case.expect.reason then
					helpers.assert_nil(route, case.name)
					helpers.assert_eq(reason, case.expect.reason, case.name)
				else
					helpers.assert_nil(reason, case.name)
					helpers.assert_eq(route, case.expect.route, case.name)
				end
			end
		end)

		helpers.it("only emits the closed refusal enum and never echoes a URL", function()
			local closed = {}
			for _, reason in ipairs(origins.refusals) do closed[reason] = true end
			helpers.assert_eq(closed[RoutePlan.EMPTY], true)
			helpers.assert_eq(closed[RoutePlan.INVALID], true)
			helpers.assert_eq(closed[RoutePlan.CONFLICT], true)
			helpers.assert_eq(closed[RoutePlan.UNPLANNED_HOST], true)
			local count = 0
			for _ in pairs(closed) do count = count + 1 end
			helpers.assert_eq(count, 4)
			for _, case in ipairs(vectors.plans) do
				local _, reason = RoutePlan.plan(case.entries)
				if reason then helpers.assert_eq(closed[reason], true, case.name) end
			end
		end)

		helpers.it("plans every shipped client inventory from valid origins", function()
			for client, list in pairs(origins.clients) do
				local entries = {}
				for index, origin in ipairs(list) do
					entries[index] = { origin = origin, route = "direct" }
				end
				local plan, reason = RoutePlan.plan(entries)
				helpers.assert_nil(reason, client)
				helpers.assert_eq(plan.proxy, "direct", client)
			end
		end)
	end)
end

return M
