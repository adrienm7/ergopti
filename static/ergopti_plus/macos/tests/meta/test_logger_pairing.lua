--- tests/meta/test_logger_pairing.lua

--- ==============================================================================
--- MODULE: Logger Lifecycle Pairing Test
--- DESCRIPTION:
--- For each Lua source file, counts Logger.start vs Logger.success and
--- Logger.trace vs Logger.done occurrences. Imbalances are flagged as warnings
--- (not errors) because legitimate control flow (early return, error path)
--- can produce many success calls per single start, or vice versa.
---
--- The test always passes; its value is the printed report attached to CI logs.
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

local function count_pattern(body, pattern)
	local n = 0
	for _ in body:gmatch(pattern) do n = n + 1 end
	return n
end

helpers.describe("meta: logger pairing", function()
	local imbalanced = 0
	for _, sub in ipairs({ "lib", "modules" }) do
		for _, abs in ipairs(list_lua_files(DRIVER_ROOT .. sub)) do
			local fh = io.open(abs, "r") ; if fh then
				local body = fh:read("*a") ; fh:close()
				local n_start   = count_pattern(body, "Logger%.start%(")
				local n_success = count_pattern(body, "Logger%.success%(")
				local n_trace   = count_pattern(body, "Logger%.trace%(")
				local n_done    = count_pattern(body, "Logger%.done%(")
				-- Heuristic: warn only when start count > 0 and success is exactly zero
				if n_start > 0 and n_success == 0 then
					imbalanced = imbalanced + 1
					print(string.format("  WARN: %s has %d Logger.start but 0 Logger.success",
						abs:sub(#DRIVER_ROOT + 1), n_start))
				end
				if n_trace > 0 and n_done == 0 then
					imbalanced = imbalanced + 1
					print(string.format("  WARN: %s has %d Logger.trace but 0 Logger.done",
						abs:sub(#DRIVER_ROOT + 1), n_trace))
				end
			end
		end
	end
	helpers.it(string.format("logger pairing scan complete (%d warnings)", imbalanced), function() end)
end)
