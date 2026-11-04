--- adapters/physical_context_probe.lua

--- Actual native context reads for one fenced physical permission sample.
--- Native objects stay within the caller frame; no permissions or readiness are granted.
local M = {}
local APIS = {
	{ "application", "frontmostApplication", "frontmost_application" },
	{ "window", "focusedWindow", "focused_window" },
	{ "axuielement", "applicationElementForPID", "application_element" },
}

--- Retains exact native API leaves for one caller-owned sample frame.
--- This is observation custody only; it neither queries nor grants AX permission.
---@return table probe Exact native readers and current identity predicate.
function M.snapshot()
	local native = rawget(_G, "hs")
	local leaves = {}
	for _, api in ipairs(APIS) do
		local namespace = type(native) == "table" and rawget(native, api[1]) or nil
		local operation = type(namespace) == "table" and rawget(namespace, api[2]) or nil
		assert(type(operation) == "function", "Physical native context API unavailable")
		leaves[#leaves + 1] = { namespace = namespace, operation = operation, api = api }
	end
	local function current()
		if not rawequal(rawget(_G, "hs"), native) then return false end
		for _, leaf in ipairs(leaves) do
			if not rawequal(rawget(native, leaf.api[1]), leaf.namespace)
				or not rawequal(rawget(leaf.namespace, leaf.api[2]), leaf.operation) then return false end
		end
		return true
	end
	local probe = { current = current }
	for _, leaf in ipairs(leaves) do
		probe[leaf.api[3]] = function(...)
			assert(current(), "Physical native context API changed")
			local result = table.pack(leaf.operation(...))
			assert(current(), "Physical native context API changed")
			return table.unpack(result, 1, result.n)
		end
	end
	return probe
end

return M
