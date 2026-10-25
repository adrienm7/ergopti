--- tests/support/ui/metrics/typing/publication.lua

--- ==============================================================================
--- MODULE: Typing Metrics Publication Decoder
--- DESCRIPTION:
--- Decodes the dashboard's JSON.parse data boundary for native delivery fixtures.
--- Quoted payload bytes and publication metadata remain independently observable.
--- ==============================================================================

local Json = require("json")
local M = {}
local CALL = "window.publishTypingMetricsData("
local PREFIX = CALL .. "JSON.parse("

--- Reads a publication, refusing malformed or obsolete object-literal arguments.
--- @param code string Actual JavaScript submitted to the native webview.
--- @return table|nil payload, table|nil metadata, string|nil encoded_payload
function M.decode(code)
	if code:sub(1, #CALL) ~= CALL then return nil end
	assert(code:sub(1, #PREFIX) == PREFIX, "Typing publication requires the JSON.parse boundary")
	local start = #PREFIX + 1
	assert(code:sub(start, start) == '"', "Typing publication requires a quoted JSON payload")
	local cursor = start + 1
	while cursor <= #code do
		local char = code:sub(cursor, cursor)
		if char == "\\" then
			cursor = cursor + 2
		elseif char == '"' then
			break
		else
			cursor = cursor + 1
		end
	end
	assert(code:sub(cursor, cursor + 2) == '"),', "Typing publication requires complete JSON.parse arguments")
	assert(code:sub(-2) == ");", "Typing publication requires a complete call")
	local encoded_payload = assert(Json.decode(code:sub(start, cursor)))
	assert(type(encoded_payload) == "string", "Typing publication payload must decode to a string")
	local payload = assert(Json.decode(encoded_payload))
	local metadata = assert(Json.decode(code:sub(cursor + 3, -3)))
	assert(type(payload) == "table" and type(metadata) == "table", "Typing publication requires payload and metadata objects")
	return payload, metadata, encoded_payload
end

return M
