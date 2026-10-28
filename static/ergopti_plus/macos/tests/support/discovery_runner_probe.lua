--- tests/support/discovery_runner_probe.lua

--- ==============================================================================
--- MODULE: Native Test Discovery Failure Probe
--- DESCRIPTION:
--- Keeps the real runner, native bootstrap, clock and process exit. Only the
--- existing native directory-enumeration ports supply controlled inventories.
--- ==============================================================================

local mode = assert(arg[1], "a discovery probe mode is required")
assert(mode == "empty" or mode == "failed" or mode == "refused" or mode == "native-empty"
	or mode == "group-empty", "invalid discovery probe mode")
local Native = require("luv")
local source = assert(Native.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
if package.config:sub(1, 1) == "\\" then source = source:gsub("\\", "/") end
local root = assert(source:match("^(.*)/tests/support/discovery_runner_probe%.lua$"))
local provider = {}
for name, value in pairs(Native) do provider[name] = value end
local scans = {}
local groups = {
	["tests/meta"] = { { "harness", "directory" } },
	["tests/meta/harness"] = { { "test_runner_fixture_selection.lua", "file" } },
	["tests/unit"] = { { "modules", "directory" } },
	["tests/unit/modules"] = { { "keymap", "directory" } },
	["tests/unit/modules/keymap"] = { { "layout", "directory" } },
	["tests/unit/modules/keymap/layout"] = { { "test_input_sources_bounded_mutations.lua", "file" } },
}

provider.fs_scandir = function(path, ...)
	if path:sub(1, #root + 7) ~= root .. "/tests/" then return Native.fs_scandir(path, ...) end
	if mode == "refused" then return nil, "controlled discovery refusal" end
	local relative = path:sub(#root + 2)
	local entries = {}
	if mode == "group-empty" then entries = groups[relative] or {}
	elseif mode == "native-empty" and (relative == "tests/meta" or relative == "tests/unit") then
		entries = { { "empty", "directory" } }
	elseif mode == "failed" then entries = { { "test_partial.lua", "file" } } end
	local scan = {}
	scans[scan] = { entries = entries, index = 0 }
	return scan
end
provider.fs_scandir_next = function(scan, ...)
	local state = scans[scan]
	if not state then return Native.fs_scandir_next(scan, ...) end
	state.index = state.index + 1
	if mode == "failed" and state.index == 2 then
		print("DISCOVERY ITERATOR REFUSED failed")
		return nil, "controlled discovery iteration refusal"
	end
	local entry = state.entries[state.index]
	if entry then return entry[1], entry[2] end
	return nil
end
package.loaded.luv = provider
arg = mode == "group-empty" and { "--module", "ui" } or {}
dofile(root .. "/tests/run.lua")
