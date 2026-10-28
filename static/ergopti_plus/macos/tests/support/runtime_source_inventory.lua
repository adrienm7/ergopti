--- tests/support/runtime_source_inventory.lua

--- ==============================================================================
--- MODULE: Runtime Source Inventory
--- DESCRIPTION:
--- Keeps production translation units separate and reports every unreadable
--- source. The owning guard rejects the complete unreadable list before use.
--- ==============================================================================

local Discovery = require("test.runner_discovery")
local NativePath = require("native_path")
local SourceFile = require("tests.support.source_file")
local M = {}

local RUNTIME_EXTENSIONS = {
	lua = true, sh = true, bash = true, zsh = true, command = true,
	swift = true, py = true, applescript = true, js = true, rb = true,
	pl = true, fish = true, m = true, mm = true, c = true, h = true,
	hpp = true, cc = true, cpp = true,
}

local CODEX_PREFIX = ".codex-"
local EXCLUDED_DIRECTORIES = setmetatable({ tests = true, [".venv"] = true, [".pytest_cache"] = true }, {
	__index = function(names, name)
		local lower = name:lower()
		return rawget(names, lower) == true or lower:sub(1, #CODEX_PREFIX) == CODEX_PREFIX
	end,
})

local function extension(path)
	return assert(NativePath.basename(path), "runtime source path requires a basename"):lower():match("%.([^./]+)$")
end

--- Enumerates complete native runtime sources and records every file read error.
--- @param root string Driver root.
--- @return table units Production { path, body } records.
--- @return table unreadable Path and diagnostic for each failed source read.
function M.read(root)
	assert(type(root) == "string" and root ~= "", "runtime inventory requires a driver root")
	local files, detail = Discovery.files(root, function(name)
		local lower = name:lower()
		local suffix = extension(name)
		return lower:sub(1, #CODEX_PREFIX) ~= CODEX_PREFIX and (RUNTIME_EXTENSIONS[suffix] or suffix == nil)
	end, EXCLUDED_DIRECTORIES)
	assert(files, detail)
	local windows = package.config:sub(1, 1) == "\\"
	local paths = {}
	for _, path in ipairs(files) do
		-- Only Windows separators have a display spelling; POSIX backslashes are data.
		paths[#paths + 1] = { native = path, display = windows and path:gsub("\\", "/") or path }
	end
	table.sort(paths, function(a, b) return a.display < b.display end)
	local units, unreadable = {}, {}
	for _, path in ipairs(paths) do
		local ok, body = pcall(SourceFile.read, path.native)
		if ok then
			if RUNTIME_EXTENSIONS[extension(path.native)] or body:sub(1, 2) == "#!" then
				units[#units + 1] = { path = path.display, body = body }
			end
		else
			unreadable[#unreadable + 1] = path.display .. ": " .. tostring(body)
		end
	end
	return units, unreadable
end

return M
