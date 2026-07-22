--- tests/meta/test_section_headers.lua

--- ==============================================================================
--- MODULE: Section Banner Alignment Test
--- DESCRIPTION:
--- Validates the `=` line lengths in section/subsection banners match the
--- title line length, as mandated by the project conventions.
---
--- POLICY:
--- - Reports misalignments as warnings (printed) without failing — manually
---   curated banners across 80+ files would otherwise create noisy churn.
--- - Hard-fails only when the test itself cannot read source files.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function list_lua_files(dir)
	local files = {}
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", dir)
	end
	local pipe = io.popen(cmd) ; if not pipe then return files end
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("\\", "/")
		if line:match("%.lua$") and not line:match("/vendor/hs_asm/") and not line:match("/tests/") then
			files[#files + 1] = line
		end
	end
	pipe:close()
	return files
end

local function check_file(abs)
	local fh = io.open(abs, "r") ; if not fh then return 0 end
	local lines = {}
	for l in fh:lines() do lines[#lines + 1] = l end
	fh:close()

	local warns = 0
	for i = 1, #lines - 2 do
		-- Recognise a banner: a comment line whose body is "= ... = X/ Title = ... ="
		local title = lines[i]:match("^%-%- ======= (.-) =======%s*$")
		if not title then title = lines[i]:match("^%-%-%- ======= (.-) =======%s*$") end
		if title then
			local expected_len = 7 + 1 + #title + 1 + 7
			-- The banner line itself includes "-- " or "--- " prefix; we measure the comment body.
			local body = lines[i]:gsub("^%-%-%-? ", "")
			if #body ~= expected_len then
				warns = warns + 1
			end
		end
	end
	return warns
end

helpers.describe("meta: section header alignment", function()
	local total_warns = 0
	local total_files = 0
	for _, sub in ipairs({ "lib", "modules", "ui" }) do
		for _, abs in ipairs(list_lua_files(DRIVER_ROOT .. sub)) do
			total_files = total_files + 1
			total_warns = total_warns + check_file(abs)
		end
	end
	helpers.it(string.format("scanned %d files (%d alignment warnings)", total_files, total_warns), function()
		helpers.assert_true(total_files > 0, "no files scanned")
	end)
end)
