--- _shared/tests/lua/core/local_server_fingerprint_contract.lua

--- ==============================================================================
--- MODULE: Local Server Fingerprint Replay
--- DESCRIPTION:
--- Both Lua drivers replay the authored fingerprint vectors against the
--- production catalogue: which row of a shared default address a models
--- listing belongs to, and which rows a sweep keeps, under which name.
--- ==============================================================================

local M = {}
local Auth = require("ai.engine.local_servers.auth")
local Discovery = require("ai.engine.local_servers.discovery")
local Fingerprint = require("ai.engine.local_servers.fingerprint")
local Menu = require("ai.engine.local_servers.menu")

--- Replays every vector through the driver's registered helpers.
--- @param corpus table Authored JSON expectations (local_server_fingerprint.json).
--- @param catalogue table The decoded production local_servers.json.
--- @param helpers table Driver assertion and registration owner.
function M.run(corpus, catalogue, helpers)
	assert(corpus.version == 1 and #corpus.identify == 11 and #corpus.sweeps == 9 and #corpus.refusals == 3,
		"independent fingerprint inventory")
	local order, servers = Auth.catalogue(catalogue, {})
	local identities, refused = Fingerprint.parse(catalogue, order)

	helpers.it("the catalogue's shared addresses and fingerprints are the authored ones", function()
		helpers.assert_eq(#refused, 0, "no catalogue fingerprint is refused: " .. table.concat(refused, "; "))
		local groups, fingerprinted = {}, {}
		for _, id in ipairs(order) do
			if identities[id] then
				groups[id] = identities[id].group
				if identities[id].rule then fingerprinted[#fingerprinted + 1] = id end
			end
		end
		helpers.assert_eq(groups, corpus.groups)
		helpers.assert_eq(fingerprinted, corpus.fingerprinted)
	end)

	for _, case in ipairs(corpus.identify) do
		helpers.it("local server fingerprint: " .. case.name, function()
			local named, reason = Fingerprint.identify(case.body, case.server, identities)
			-- JSON null decodes to nil or to the codec's null sentinel
			helpers.assert_eq(named, type(case.expected) == "string" and case.expected or nil)
			helpers.assert_eq(reason, case.reason)
		end)
	end

	for _, case in ipairs(corpus.sweeps) do
		helpers.it("local server sweep at a shared address: " .. case.name, function()
			local settles = {}
			local controller = Discovery.new({ order = order, identities = identities,
				clock = function() return 0 end, max_age = function() return 1 end })
			controller.sweep(case.targets, function(target, settle)
				settles[target.id] = settle
				return true
			end)
			for _, target in ipairs(case.targets) do settles[target.id](case.answers[target.id]) end
			local expected = case.expected
			helpers.assert_eq(controller.detected(), expected.detected)
			for id, result in pairs(expected.results or {}) do
				helpers.assert_eq(controller.result(id), result, case.name .. " result " .. id)
			end
			if expected.rows then
				local rows = Menu.rows({ order = order, servers = servers, detected = controller.detected(),
					result = controller.result, backend = "ollama", actions = {},
					tr = function(key) return key end, format = function(key, value) return key .. ":" .. tostring(value) end })
				local labels = {}
				for _, row in ipairs(rows) do
					if row.items and row.label ~= "menu.llm.local_servers.other_address" then labels[#labels + 1] = row.label end
				end
				helpers.assert_eq(labels, expected.rows)
			end
		end)
	end

	for _, case in ipairs(corpus.refusals) do
		helpers.it("local server fingerprint refusal: " .. case.name, function()
			local ids = {}
			for id in pairs(case.servers) do ids[#ids + 1] = id end
			table.sort(ids)
			local parsed, reasons = Fingerprint.parse({ servers = case.servers }, ids)
			local fingerprinted = {}
			for _, id in ipairs(ids) do
				if parsed[id] and parsed[id].rule then fingerprinted[#fingerprinted + 1] = id end
			end
			helpers.assert_eq(fingerprinted, case.expected.fingerprinted)
			helpers.assert_eq(#reasons, case.expected.refused)
		end)
	end
end

return M
