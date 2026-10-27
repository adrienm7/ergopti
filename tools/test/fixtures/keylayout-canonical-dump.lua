-- tools/test/fixtures/keylayout-canonical-dump.lua

--- ==============================================================================
--- MODULE: Keylayout Canonical Dump
--- DESCRIPTION:
--- Prints the canonical form of one .keylayout as compact JSON, read by
--- test-keylayout-canonical-parity.cjs: `lua keylayout-canonical-dump.lua
--- <_shared dir> <file.keylayout>`. Numbers are integers, empty tables are arrays,
--- and object keys are sorted so the output is stable.
--- ==============================================================================

package.path = arg[1] .. "/lua/?.lua;" .. arg[1] .. "/lua/?/init.lua;" .. package.path
local Keylayout = require("layouts.keylayout")

local SHORT = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }

local function encode(value)
	local kind = type(value)
	if kind == "string" then
		return '"' .. value:gsub('[%c"\\]', function(c)
			return SHORT[c] or string.format("\\u%04x", c:byte())
		end) .. '"'
	elseif kind == "number" then
		return string.format("%d", value)
	elseif kind == "boolean" then
		return tostring(value)
	end
	if next(value) == nil or value[1] ~= nil then
		local parts = {}
		for i, item in ipairs(value) do parts[i] = encode(item) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for k in pairs(value) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for i, k in ipairs(keys) do parts[i] = encode(k) .. ":" .. encode(value[k]) end
	return "{" .. table.concat(parts, ",") .. "}"
end

local handle = assert(io.open(arg[2], "rb"))
local parsed, err = Keylayout.parse(handle:read("*a"))
handle:close()
if not parsed then
	io.stderr:write(err, "\n")
	os.exit(2)
end
io.write(encode(parsed))
