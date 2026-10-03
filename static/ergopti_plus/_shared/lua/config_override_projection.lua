--- _shared/lua/config_override_projection.lua

--- ==============================================================================
--- MODULE: Legacy Configuration Override Projection
--- DESCRIPTION:
--- Projects decoded feature paths onto legacy flat settings without losing their
--- source identity. Competing literal and nested spellings refuse as one batch.
--- ==============================================================================

local M = {}

local function is_scalar(value)
	local kind = type(value)
	return kind == "string" or kind == "number" or kind == "boolean"
end

local function keys(values)
	local result = {}
	for key in pairs(values) do result[#result + 1] = key end
	table.sort(result, function(left, right) return tostring(left) < tostring(right) end)
	return result
end

local function dictionary(value)
	if type(value) ~= "table" or next(value) == nil then return false end
	for key in pairs(value) do if type(key) ~= "string" then return false end end
	return true
end

local function append(path, key)
	local result = {}
	for index, segment in ipairs(path) do result[index] = segment end
	result[#result + 1] = key
	return result
end

--- Builds every owned candidate before native settings or read marks publish.
--- Script overrides stay flat; feature dictionaries project scalar leaves.
--- Arrays and empty dictionaries remain non-scalar override candidates.
--- @param decoded table Parsed configuration document.
--- @return table|nil rows Exact section, setting key, value and source segments.
--- @return string|nil error Reason a legacy setting identity is ambiguous.
function M.prepare(decoded)
	if type(decoded) ~= "table" then return nil, "Override document is not a table" end
	local rows = {}
	local script = decoded.script
	if type(script) == "table" then
		for _, key in ipairs(keys(script)) do
			rows[#rows + 1] = {
				section = "script", key = key, path = { key }, value = script[key],
				accepted = type(key) == "string" and key ~= "" and is_scalar(script[key]),
			}
		end
	end
	local projected = {}
	local function feature(value, path)
		if dictionary(value) then
			for _, key in ipairs(keys(value)) do
				local ok, detail = feature(value[key], append(path, key))
				if not ok then return false, detail end
			end
			return true
		end
		local accepted = is_scalar(value)
		for _, segment in ipairs(path) do if segment == "" then accepted = false end end
		local setting = table.concat(path, ".")
		if accepted then
			if projected[setting] then return false, "Ambiguous legacy feature setting: " .. setting end
			projected[setting] = true
		end
		rows[#rows + 1] = { section = "features", key = setting, path = path, value = value, accepted = accepted }
		return true
	end
	if type(decoded.features) == "table" then
		for _, key in ipairs(keys(decoded.features)) do
			if type(key) == "string" then
				local ok, detail = feature(decoded.features[key], { key })
				if not ok then return nil, detail end
			end
		end
	end
	return rows
end

return M
