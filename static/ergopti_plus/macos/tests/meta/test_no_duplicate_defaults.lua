--- tests/meta/test_no_duplicate_defaults.lua

--- ==============================================================================
--- MODULE: Duplicate Defaults Test
--- DESCRIPTION:
--- Heuristic scan for the same default value being declared in two different
--- modules — a smell that violates the "single source of truth" rule
--- (conventions §5.2). Reports findings as warnings rather than failures
--- because some duplicates (constants like 0/1 etc) are legitimate.
---
--- The whitelist below skips well-known pattern-level duplicates such as the
--- standard alpha=1.0 value used in every color literal.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local WHITELIST_VALUES = {
	["0"] = true, ["1"] = true, ["1.0"] = true, ["true"] = true, ["false"] = true,
	["nil"] = true, ['""'] = true, ["0.0"] = true, ["100"] = true,
}

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

helpers.describe("meta: duplicate default values", function()
	-- Map of "varname=value" -> list of files declaring it
	local seen = {}
	for _, sub in ipairs({ "lib", "modules" }) do
		for _, abs in ipairs(list_lua_files(DRIVER_ROOT .. sub)) do
			local fh = io.open(abs, "r") ; if fh then
				local body = fh:read("*a") ; fh:close()
				-- Only scan inside DEFAULT_STATE or DEFAULTS literal tables
				local default_block = body:match("DEFAULT_STATE%s*=%s*({.-\n})")
					or body:match("DEFAULTS%s*=%s*({.-\n})")
				if default_block then
					for k, v in default_block:gmatch("(%w+)%s*=%s*([^,\n}]+)") do
						local norm = (v:gsub("%s+$", ""))
						if not WHITELIST_VALUES[norm] then
							local key = k .. "=" .. norm
							seen[key] = seen[key] or {}
							seen[key][#seen[key] + 1] = abs:sub(#DRIVER_ROOT + 1)
						end
					end
				end
			end
		end
	end
	local dup_count = 0
	for key, files in pairs(seen) do
		if #files > 1 then
			dup_count = dup_count + 1
			print(string.format("  WARN: default %s declared in: %s", key, table.concat(files, ", ")))
		end
	end
	helpers.it(string.format("duplicate-defaults scan complete (%d duplicates)", dup_count), function() end)
end)
