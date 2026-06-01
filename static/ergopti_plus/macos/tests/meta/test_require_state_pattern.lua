--- tests/meta/test_require_state_pattern.lua

--- ==============================================================================
--- MODULE: require_state Pattern Test
--- DESCRIPTION:
--- Stateful modules — those that hold a `_state`, `_registry`, or similar
--- module-level table — must define a `require_state` guard helper as
--- specified in section 5.8 of the coding conventions. Files missing the guard
--- are flagged as violations and cause the test to fail, unless they are listed
--- in the pre-existing allowlist below.
---
--- HOW TO USE THE ALLOWLIST:
--- These files violate the rule but existed before this check was enforced.
--- TODO: remove each entry as the corresponding module is brought into
--- compliance with section 5.8 of the coding conventions.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Pre-existing violations present at the time this check was tightened.
-- DO NOT add new entries — fix the module instead.
-- TODO: refactor all entries below to add a require_state guard (section 5.8).
local KNOWN_VIOLATIONS = {
	["modules/dynamic_hotstrings/personal_info.lua"] = true,
	["modules/gestures/actions.lua"]                 = true,
	["modules/gestures/engine.lua"]                  = true,
	["modules/keylogger/init.lua"]                   = true,
	["modules/keylogger/kc_bridge.lua"]              = true,
	["modules/keylogger/rotation.lua"]               = true,
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

helpers.describe("meta: require_state pattern", function()
	local new_violations = 0
	local known_count    = 0

	for _, abs in ipairs(list_lua_files(DRIVER_ROOT .. "modules")) do
		local fh = io.open(abs, "r") ; if fh then
			local body = fh:read("*a") ; fh:close()
			-- Looks stateful when it declares `local _state` or `_state = nil` at module scope
			local stateful = body:match("\nlocal%s+_state%s*=") or body:match("^local%s+_state%s*=")
			if stateful and not body:find("require_state", 1, true) then
				-- Relative path used as the allowlist key (forward-slash normalised)
				local rel = abs:sub(#DRIVER_ROOT + 1)
				if KNOWN_VIOLATIONS[rel] then
					known_count = known_count + 1
					print(string.format("  KNOWN: %s — pending fix (see allowlist TODO)", rel))
				else
					new_violations = new_violations + 1
					print(string.format("  FAIL: %s declares _state but defines no require_state guard", rel))
				end
			end
		end
	end

	helpers.it(
		string.format("no NEW stateful modules missing require_state guard (%d known legacy violation(s))", known_count),
		function()
			helpers.assert_true(new_violations == 0,
				string.format(
					"%d new module(s) declare _state without a require_state guard — add the guard per section 5.8",
					new_violations))
		end)
end)
