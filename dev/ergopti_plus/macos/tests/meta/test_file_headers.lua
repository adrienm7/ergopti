--- tests/meta/test_file_headers.lua

--- ==============================================================================
--- MODULE: File Header Invariant Test
--- DESCRIPTION:
--- Ensures every Lua source file under the Hammerspoon driver starts with a
--- comment line containing its own relative path, as required by the project
--- coding conventions documented in copilot-instructions.md.
---
--- FAILURE POLICY:
--- - Hard fail: a Lua file's first non-blank line is not a comment.
--- - Warning : the declared path doesn't exactly match the file's actual path.
---   Reported via `print` but doesn't fail the suite, so a renamed-but-unupdated
---   header is visible without breaking CI on day one of a refactor.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local SRC_DIRS    = { "lib", "modules", "ui" }

--- Returns true if the file path is a Lua source file we expect to validate.
--- @param path string Absolute path.
--- @return boolean
local function is_target_file(path)
	if not path:match("%.lua$") then return false end
	if path:match("[/\\]vendor[/\\]hs_asm[/\\]") then return false end
	if path:match("[/\\]tests[/\\]") then return false end
	return true
end

--- Walks a directory recursively and lists Lua files.
--- @param dir string Absolute directory.
--- @return table List of absolute paths.
local function list_files(dir)
	local files = {}
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", dir)
	end
	local pipe = io.popen(cmd)
	if not pipe then return files end
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("\\", "/")
		if is_target_file(line) then files[#files + 1] = line end
	end
	pipe:close()
	return files
end

helpers.describe("meta: file headers", function()
	local checked = 0
	local mismatches = 0

	for _, sub in ipairs(SRC_DIRS) do
		for _, abs in ipairs(list_files(DRIVER_ROOT .. sub)) do
			helpers.it(abs:match("[^/]+$"), function()
				checked = checked + 1
				local fh = io.open(abs, "r")
				assert(fh, "cannot open " .. abs)
				local first = fh:read("*l") or ""
				fh:close()
				-- Strip UTF-8 BOM if present so files saved by VS Code with BOM still pass
				first = first:gsub("^\239\187\191", "")
				-- Header must be a Lua comment
				helpers.assert_true(first:match("^%-%-") ~= nil,
					"first line is not a Lua comment: " .. first)
				-- Path must appear inside the comment (warning-only mismatch).
				local rel = abs:sub(#DRIVER_ROOT + 1)
				if not first:find(rel, 1, true) and not first:find(rel:gsub("\\", "/"), 1, true) then
					mismatches = mismatches + 1
					print(string.format("  WARN: header in %s does not name itself: %q",
						rel, first))
				end
			end)
		end
	end

	helpers.it("at least one file checked", function()
		helpers.assert_true(checked > 0, "no source files were located — check SRC_DIRS")
	end)

	if mismatches > 0 then
		print(string.format("  -> %d header path mismatch(es) (warning only)", mismatches))
	end
end)
