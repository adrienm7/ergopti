--- tests/support/runtime_source_inventory.lua

--- ==============================================================================
--- MODULE: Runtime Source Inventory
--- DESCRIPTION:
--- Keeps production translation units separate and reports every unreadable
--- source. The owning guard rejects the complete unreadable list before use.
--- ==============================================================================

local CommandLines = require("tests.support.command_lines")
local SourceFile = require("tests.support.source_file")
local M = {}

local RUNTIME_EXTENSIONS = {
	lua = true, sh = true, bash = true, zsh = true, command = true,
	swift = true, py = true, applescript = true, js = true, rb = true,
	pl = true, fish = true, m = true, mm = true, c = true, h = true,
	hpp = true, cc = true, cpp = true,
}

--- Enumerates runtime sources, rejecting failed commands and recording file errors.
--- @param root string Driver root.
--- @return table units Production { path, body } records.
--- @return table unreadable Path and diagnostic for each failed source read.
function M.read(root)
	assert(type(root) == "string" and root ~= "", "runtime inventory requires a driver root")
	local command
	if package.config:sub(1, 1) == "\\" then
		local native_root = root:gsub("/", "\\"):gsub("\\+$", "")
		command = 'dir /b /s /a-d "' .. native_root .. '\\*" 2>nul'
	else
		command = 'find "' .. root:gsub('"', '\\"') .. '" -type f'
	end
	local paths = {}
	for _, path in ipairs(CommandLines.read(command)) do
		local normalized = path:gsub("\\", "/")
		local lower = normalized:lower()
		local extension = lower:match("%.([^./]+)$")
		if (RUNTIME_EXTENSIONS[extension] or extension == nil)
			and not lower:find("/tests/", 1, true)
			and not lower:find("/.codex-", 1, true)
			and not lower:find("/.venv/", 1, true)
			and not lower:find("/.pytest_cache/", 1, true) then
			paths[#paths + 1] = { native = path, normalized = normalized }
		end
	end
	table.sort(paths, function(a, b) return a.normalized < b.normalized end)
	local units, unreadable = {}, {}
	for _, path in ipairs(paths) do
		local ok, body = pcall(SourceFile.read, path.native)
		if ok then
			local extension = path.normalized:lower():match("%.([^./]+)$")
			if RUNTIME_EXTENSIONS[extension] or body:sub(1, 2) == "#!" then
				units[#units + 1] = { path = path.normalized, body = body }
			end
		else
			unreadable[#unreadable + 1] = path.normalized .. ": " .. tostring(body)
		end
	end
	return units, unreadable
end

return M
