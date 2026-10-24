--- infra/route_origins.lua

--- ==============================================================================
--- MODULE: Linux Route Origin Inventory Binding
--- DESCRIPTION:
--- Reads the shared inventory of the origins each environment-driven download
--- client contacts (route_origins.json), redirect targets included, through the
--- native path owner. The per-origin route plan looks each one up; a client
--- the inventory does not name is refused, never guessed.
--- ==============================================================================

local M = {}
local Paths = require("infra.paths")
local Json = require("json")

-- The inventory is a few hundred bytes; a larger file is not the shipped one.
local MAX_INVENTORY_BYTES = 16384

local initialized, inventory, refusal = false, nil, nil

--- Loads and validates the shared inventory exactly once.
--- @return table|nil inventory, string|nil reason
local function load()
	if initialized then return inventory, refusal end
	initialized = true
	local path = Paths.shared("modules/network/route_origins.json")
	local file = path and io.open(path, "rb")
	if not file then refusal = "route-origins-unavailable"; return nil, refusal end
	local bytes = file:read(MAX_INVENTORY_BYTES + 1)
	local closed = file:close()
	if type(bytes) ~= "string" or #bytes > MAX_INVENTORY_BYTES or not closed then
		refusal = "route-origins-unavailable"
		return nil, refusal
	end
	local decoded, data = pcall(Json.decode, bytes)
	if not decoded or type(data) ~= "table" or data.schema_version ~= 1 or type(data.clients) ~= "table" then
		refusal = "route-origins-invalid"
		return nil, refusal
	end
	inventory = data
	return inventory, nil
end

--- Returns a copy of the ordered https origins of one download client.
--- @param client string Key of route_origins.json "clients".
--- @return table|nil origins, string|nil reason
function M.client(client)
	local data, reason = load()
	if not data then return nil, reason end
	local list = data.clients[client]
	if type(list) ~= "table" or #list == 0 then return nil, "route-origins-invalid" end
	local origins = {}
	for index, origin in ipairs(list) do
		if type(origin) ~= "string" or not origin:match("^https://[%w%.%-]+$") then
			return nil, "route-origins-invalid"
		end
		origins[index] = origin
	end
	return origins, nil
end

return M
