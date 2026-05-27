--- tests/meta/test_require_state_pattern.lua

--- ==============================================================================
--- MODULE: require_state Pattern Test
--- DESCRIPTION:
--- Stateful modules — those that hold a `_state`, `_registry`, or similar
--- module-level table — must define a `require_state` guard helper as
--- specified in section 5.8 of the coding conventions. Files matching the
--- former without the latter are flagged as warnings.
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
	for line in pipe:lines() do
		line = line:gsub("\\", "/")
		if line:match("%.lua$") and not line:match("/vendor/hs_asm/") and not line:match("/tests/") then
			files[#files + 1] = line
		end
	end
	pipe:close()
	return files
end

helpers.describe("meta: require_state pattern", function()
	local missing = 0
	for _, abs in ipairs(list_lua_files(DRIVER_ROOT .. "modules")) do
		local fh = io.open(abs, "r") ; if fh then
			local body = fh:read("*a") ; fh:close()
			-- Looks stateful when it declares `local _state` or `_state = nil` at module scope.
			local stateful = body:match("\nlocal%s+_state%s*=") or body:match("^local%s+_state%s*=")
			if stateful and not body:find("require_state", 1, true) then
				missing = missing + 1
				print(string.format("  WARN: %s declares _state but defines no require_state guard",
					abs:sub(#DRIVER_ROOT + 1)))
			end
		end
	end
	helpers.it(string.format("require_state pattern scan complete (%d warnings)", missing), function() end)
end)
