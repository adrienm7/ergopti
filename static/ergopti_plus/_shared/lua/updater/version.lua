--- _shared/lua/updater/version.lua
---
--- Cross-driver pure version-comparison functions extracted from
--- macos/infra/updater.lua so they can be shared by macOS, Linux, and
--- any future driver without duplicating the parsing/comparison logic.
---
--- Canonical algorithm: _shared/modules/updater/version.js
--- Test vectors:     _shared/modules/updater/version_vectors.json
---
--- This module is PURE Lua — no driver imports, no io/network, no OS calls.
--- It can be require()d by any driver (Hammerspoon Lua, LuaJIT, etc.).

local M = {}
local TextUtils = require("text_utils")

--- Strip leading 'v'/'V' and surrounding whitespace.
--- @param tag string|nil
--- @return string
function M.normalize_tag(tag)
	if type(tag) ~= "string" then return "" end
	local t = TextUtils.trim(tag)
	if t:sub(1, 1):lower() == "v" then t = t:sub(2) end
	return t
end

--- Parse a semver tag into its components.
--- @param tag string
--- @return table|nil  {major=string, minor=string, patch=string, prerelease=string[]|nil}
local function parse_version(tag)
	local norm = M.normalize_tag(tag)
	local maj, min, pat, suffix = norm:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
	if not maj then return nil end
	local pre = nil
	if suffix ~= "" then
		if suffix:sub(1, 1) ~= "-" or #suffix == 1 or suffix:find("[\r\n]")
			or suffix:find("\226\128\168", 1, true) or suffix:find("\226\128\169", 1, true) then return nil end
		pre = suffix:sub(2)
		if pre:sub(1, 1) == "." or pre:sub(-1) == "." or pre:find("..", 1, true) then return nil end
	end
	return {
		major = maj,
		minor = min,
		patch = pat,
		prerelease = pre and (function()
			local parts = {}
			for part in pre:gmatch("[^%.]+") do table.insert(parts, part) end
			return parts
		end)() or nil,
	}
end

--- Compare arbitrary-length decimal strings without numeric conversion.
--- @param a string Decimal digits.
--- @param b string Decimal digits.
--- @return integer
local function compare_decimal(a, b)
	local ai, bi = a:gsub("^0+", ""), b:gsub("^0+", "")
	if #ai ~= #bi then return #ai > #bi and 1 or -1 end
	if ai > bi then return 1 end
	if ai < bi then return -1 end
	return 0
end

--- Compare two prerelease identifiers using semver rules.
--- @param a string
--- @param b string
--- @return integer 1 | -1 | 0
local function compare_prerelease_id(a, b)
	local a_num = a:match("^%d+$") ~= nil
	local b_num = b:match("^%d+$") ~= nil
	if a_num ~= b_num then return a_num and -1 or 1 end
	if a_num and b_num then
		return compare_decimal(a, b)
	end
	if a > b then return 1 end
	if a < b then return -1 end
	return 0
end

--- Compare two prerelease arrays using semver rules.
--- @param a string[]|nil
--- @param b string[]|nil
--- @return integer 1 | -1 | 0
local function compare_prerelease(a, b)
	if not a and not b then return 0 end
	if not a and b then return 1 end
	if a and not b then return -1 end
	local len = math.max(#a, #b)
	for i = 1, len do
		local ai, bi = a[i], b[i]
		if not ai then return -1 end
		if not bi then return 1 end
		local cmp = compare_prerelease_id(ai, bi)
		if cmp ~= 0 then return cmp end
	end
	return 0
end

--- Compare two version tags using full semver rules.
--- @param a string
--- @param b string
--- @return integer 1 (a > b), -1 (a < b), 0 (equal or incomparable)
function M.compare_versions(a, b)
	local pa, pb = parse_version(a), parse_version(b)
	if not pa or not pb then
		-- Non-semver tags: fail-closed (return 0 = "not newer") rather
		-- than guess lexicographically — "10" vs "9" and other ambiguous
		-- tags must never trigger or suppress an update by accident.
		-- Mirrors _shared/modules/updater/version.js and AHK
		-- _Updater_CompareVersions; the three are locked by the
		-- version-compare parity gate (D-1).
		return 0
	end
	for _, key in ipairs({ "major", "minor", "patch" }) do
		local order = compare_decimal(pa[key], pb[key])
		if order ~= 0 then return order end
	end
	return compare_prerelease(pa.prerelease, pb.prerelease)
end

--- @param latest string
--- @param current string
--- @return boolean
function M.is_newer_version(latest, current)
	return M.compare_versions(latest, current) > 0
end

return M
