--- _shared/lua/test/menu_separators_contract.lua

--- ==============================================================================
--- MODULE: Menu Separator Rules Contract
--- DESCRIPTION:
--- Replays the shared separator vectors against `menu.separators`, the rule the
--- renderer applies to every menu it returns. The existing menu_separators
--- check proves the renderer output stays clean. Registered by both drivers.
--- ==============================================================================

local M = {}

--- Returns a deep copy, so a vector survives the in-place rule.
local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end

--- Structural equality over plain data.
local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not same(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

--- Registers the contract on a driver's test helpers.
--- @param helpers table The driver's test helpers (describe/it/assert_*).
--- @param vectors_path string Path of separator_normalization_vectors.json.
function M.register(helpers, vectors_path)
	local Separators = require("menu.separators")

	helpers.describe("menu separator rules (shared contract)", function()
		helpers.it("normalises every shared vector to its expected rows", function()
			local handle = assert(io.open(vectors_path, "rb"))
			local decoded = assert(require("json").decode(handle:read("*a")))
			handle:close()
			helpers.assert_true(#decoded.vectors > 0, "the corpus holds vectors")
			for _, vector in ipairs(decoded.vectors) do
				local got = Separators.normalize(copy(vector.input))
				helpers.assert_true(same(got, vector.expected), vector.name)
			end
		end)

		helpers.it("is idempotent and returns the array it was given", function()
			local items = { { title = "-" }, { title = "a" }, { title = "-" }, { title = "-" }, { title = "b" } }
			helpers.assert_true(Separators.normalize(items) == items, "same table")
			local once = copy(items)
			helpers.assert_true(same(Separators.normalize(items), once), "second pass changes nothing")
		end)
	end)
end

return M
