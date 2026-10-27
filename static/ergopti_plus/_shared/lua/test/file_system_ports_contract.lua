--- _shared/lua/test/file_system_ports_contract.lua

--- ==============================================================================
--- MODULE: FileSystem Port Spec Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/file_system/port_vectors.json through
--- file_system.ports on both Lua drivers, then checks the driver's real owner
--- (adapters.file_system) against the spec and against the capabilities the
--- corpus declares for it.
--- ==============================================================================

local M = {}

local function function_owner(corpus, vector)
	local owner = {}
	local function add(name) owner[name] = function() end end
	for _, name in ipairs(corpus.required) do add(name) end
	for _, name in ipairs(vector.without or {}) do owner[name] = nil end
	for _, capability in ipairs(vector.with_capabilities or {}) do
		for _, name in ipairs(corpus.capabilities[capability]) do add(name) end
	end
	for _, name in ipairs(vector.extra or {}) do add(name) end
	for _, name in ipairs(vector.non_functions or {}) do owner[name] = "not a function" end
	return owner
end

--- Registers the port spec checks in a driver's existing owner.
--- @param helpers table The driver's describe/it/assertion functions.
--- @param driver string "macos" or "linux": the owner the real-owner check inspects.
--- @param count number How many vectors the corpus must hold.
--- @param load_owner function Returns the driver's real owner under that suite's stubs.
function M.register(helpers, driver, count, load_owner)
	local Json = require("json")
	local Ports = require("file_system.ports")
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/file_system/port_vectors.json"), "rb"))
	local corpus = assert(Json.decode(file:read("*a")))
	file:close()
	assert(#corpus.vectors == count, "port_vectors.json holds another number of vectors")
	helpers.describe("FileSystem port spec (file-system-port-spec)", function()
		for _, vector in ipairs(corpus.vectors) do
			local case = vector
			helpers.it(case.id .. " (file-system-port-spec)", function()
				local owner = function_owner(corpus, case)
				local ok, result = pcall(Ports.check_owner, owner)
				if case.expect.error ~= nil then
					helpers.assert_eq(ok, false)
					helpers.assert_true(tostring(result):find(case.expect.error, 1, true) ~= nil,
						"expected '" .. case.expect.error .. "', got: " .. tostring(result))
				else
					helpers.assert_true(ok, tostring(result))
					helpers.assert_eq(result, case.expect.offered)
				end
			end)
		end
		helpers.it("the spec lists the methods the corpus names (file-system-port-spec)", function()
			local listed = {}
			for name in pairs(Ports.CONTRACTS.FileSystem) do listed[#listed + 1] = name end
			table.sort(listed)
			local required = {}
			for index, name in ipairs(corpus.required) do required[index] = name end
			table.sort(required)
			helpers.assert_eq(listed, required)
			for capability, names in pairs(corpus.capabilities) do
				local spec = {}
				for name in pairs(Ports.CAPABILITIES[capability] or {}) do spec[#spec + 1] = name end
				table.sort(spec)
				local expected = {}
				for index, name in ipairs(names) do expected[index] = name end
				table.sort(expected)
				helpers.assert_eq(spec, expected)
			end
		end)
		helpers.it("the real " .. driver .. " owner satisfies the spec and offers the declared capabilities (file-system-port-spec)", function()
			local owner = load_owner()
			helpers.assert_eq(Ports.check_owner(owner), corpus.drivers[driver])
		end)
		helpers.it("an owner missing a required method is refused, whatever the driver (file-system-port-spec)", function()
			local owner = {}
			for name, method in pairs(load_owner()) do owner[name] = method end
			owner.write_if_unchanged = nil
			local ok, err = pcall(Ports.check_owner, owner)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("FileSystem lacks: write_if_unchanged", 1, true) ~= nil, tostring(err))
		end)
	end)
end

return M
