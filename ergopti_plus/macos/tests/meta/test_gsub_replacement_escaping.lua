--- tests/meta/test_gsub_replacement_escaping.lua

--- ==============================================================================
--- MODULE: gsub-Replacement Escaping Guard Meta Test
--- DESCRIPTION:
--- Class-wide guard: any value that originates outside the codebase must be
--- escaped before it is used as the REPLACEMENT argument of gsub.
---
--- ROOT CAUSE ENCODED:
--- Lua treats "%" specially on the replacement side — "%1".."%9" are capture
--- references and "%" followed by anything else RAISES "invalid use of '%' in
--- replacement string". Every value interpolated into a template this way is
--- attacker- or user-controlled in practice: a third-party app name ("100% Orange
--- Juice"), the user-configurable magic key, a percent-encoded URL fragment, a
--- release tag.
---
--- This class has now bitten FOUR times, each time as a forgotten sibling:
---   ad7c7fd55  fixed app_picker and updater's menu label
---   this audit  found registry.add (a "%" magic key aborted ALL hotstring
---               registration) and gestures search_web (url_encode_query emits
---               "%20", whose "%2" reads as capture 2 — it threw for any selection
---               containing a space, inside a timer callback where the error
---               reached only the HS Console)
---   and then    updater's tray-notification BODY, three lines from the label the
---               original commit did escape
---
--- A per-site fix has demonstrably not held, so this guard enumerates the whole
--- class: every gsub whose replacement is a bare identifier must route through
--- text_utils.escape_gsub_replacement (or a local alias of it).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Subtrees that ship in the driver.
local SOURCE_DIRS = { "adapters", "infra", "modules", "platform", "ui" }

-- Replacement expressions that are safe by construction and need no escaping:
-- string literals, and calls that already escape.
local SAFE_REPLACEMENT = {
	["escape_replacement"]           = true,
	["text_utils.escape_gsub_replacement"] = true,
}





-- ====================================
-- ====================================
-- ======= 1/ Source Collection =======
-- ====================================
-- ====================================

--- Recursively lists every .lua file under a driver subtree.
--- @param dir string Absolute directory to walk.
--- @param out table Accumulator.
local function collect(dir, out)
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(path)
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					local full = path .. "/" .. entry
					local attr = lfs.attributes(full)
					if attr and attr.mode == "directory" then walk(full)
					elseif entry:match("%.lua$") then out[#out + 1] = full end
				end
			end
		end
		walk(dir)
		return
	end
	local cmd = (package.config:sub(1, 1) == "\\")
		and ('cmd /c dir /b /s /a-d "' .. dir:gsub("/", "\\") .. '\\*.lua"')
		or ("find '" .. dir .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return end
	for line in pipe:lines() do
		local t = line:gsub("%s+$", ""):gsub("\\", "/")
		if t:match("%.lua$") then out[#out + 1] = t end
	end
	pipe:close()
end





-- =============================================
-- =============================================
-- ======= 2/ Every Replacement Is Safe ========
-- =============================================
-- =============================================

helpers.describe("gsub replacements built from external values are escaped", function()
	helpers.it("no driver source interpolates a bare identifier as a gsub replacement", function()
		local root  = helpers.driver_root()
		local files = {}
		for _, d in ipairs(SOURCE_DIRS) do collect(root .. d, files) end
		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local offenders = {}
		for _, path in ipairs(files) do
			local fh = io.open(path, "r")
			if fh then
				local src = fh:read("*a") ; fh:close()
				local line_no = 0
				for line in (src .. "\n"):gmatch("([^\n]*)\n") do
					line_no = line_no + 1
					local stripped = line:gsub("%-%-.*$", "")
					-- Two replacement shapes reach the same hazard:
					--   gsub("<literal>", <bare identifier or dotted name>)
					--   gsub("<literal>", <call(...)>)   e.g. tostring(err)
					-- The call form was missed by an identifier-only pattern, which is how
					-- karabiner/onboarding.lua kept an unescaped payload after this guard
					-- first landed. Both are checked.
					for _, pat in ipairs({
						':gsub%(%b"",%s*([%w_%.]+)%s*%)',
						':gsub%(%b"",%s*([%w_%.]+%b())%s*%)',
					}) do
						for repl in stripped:gmatch(pat) do
							local callee = repl:match("^([%w_%.]+)%(") or repl
							-- A numeric literal cannot carry a percent sign.
							if not SAFE_REPLACEMENT[repl] and not SAFE_REPLACEMENT[callee]
								and not tonumber(repl) then
								offenders[#offenders + 1] = string.format("%s:%d (%s)",
									path:gsub("^.*/macos/", ""), line_no, repl)
							end
						end
					end
				end
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d gsub call(s) use an unescaped value as the REPLACEMENT argument. Lua treats "
			.. "'%%' specially there, so a percent in the value raises 'invalid use of %%%%' and "
			.. "takes down whatever path it sits on. Route it through "
			.. "text_utils.escape_gsub_replacement: %s",
			#offenders, table.concat(offenders, ", ")))
	end)
end)
