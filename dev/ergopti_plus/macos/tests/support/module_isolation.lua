--- tests/support/module_isolation.lua

--- ==============================================================================
--- MODULE: Test Module Isolation
--- DESCRIPTION:
--- Removes every cached production module whose source resolves inside either
--- the Hammerspoon driver or the shared Lua tree before the next test file.
--- Namespace strings are deliberately not enumerated: a new shared sibling must
--- inherit the same isolation automatically.
--- ==============================================================================

local M = {}

local function normalize(path)
	if type(path) ~= "string" then return nil end
	return path:gsub("\\", "/"):gsub("/+$", "")
end

local function is_within(path, root)
	path = normalize(path)
	root = normalize(root)
	if not path or not root or root == "" then return false end
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function resolves_inside_project(module_name, driver_root, shared_lua)
	if module_name:match("^tests?%.") then return false end
	if type(package.searchpath) ~= "function" then
		error("package.searchpath is required for cross-file test isolation", 2)
	end
	local source_path = package.searchpath(module_name, package.path)
	return source_path ~= nil
		and (is_within(source_path, driver_root) or is_within(source_path, shared_lua))
end

--- Cold-starts every production module for the next test file.
--- The bare shared logger core retains its process-lifetime identity, but its
--- cross-test diagnostic state is cleared below.
--- @param driver_root string Absolute Hammerspoon driver root.
--- @param shared_lua string Absolute shared Lua root.
function M.purge(driver_root, shared_lua)
	if type(driver_root) ~= "string" or driver_root == "" then
		error("driver_root must be a non-empty string", 2)
	end
	if type(shared_lua) ~= "string" or shared_lua == "" then
		error("shared_lua must be a non-empty string", 2)
	end

	local purge_keys = {}
	for key in pairs(package.loaded) do
		if type(key) == "string"
			and key ~= "logger"
			and resolves_inside_project(key, driver_root, shared_lua)
		then
			purge_keys[#purge_keys + 1] = key
		end
	end
	for _, key in ipairs(purge_keys) do package.loaded[key] = nil end

	package.loaded["hs"] = nil
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local ok_core, core = pcall(require, "logger")
	if ok_core and type(core) == "table" then
		pcall(core.reset_dedup)
		pcall(core.ring_buffer_clear)
	end
end

return M
