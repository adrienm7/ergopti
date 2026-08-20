--- tests/unit/meta/test_no_method_call_on_plain_function.lua

--- ==============================================================================
--- MODULE: A Module Table Is Not a Self
--- DESCRIPTION:
--- No driver code may call a dot-defined module function as if it were a method.
---
--- THE DEFECT THIS PINS:
--- `llm:set_model(model)` and `pcall(state.llm.set_model, state.llm, model)` are
--- the same mistake written two ways: both pass the module table where the
--- function expects its first real argument, so the argument the caller meant to
--- pass is silently dropped.
---
--- Nineteen sites had it. What made it invisible is the shape of the receiving
--- code — `if type(model_name) ~= "string" then return end` — a fail-fast guard
--- doing exactly its job, on an argument that was never the caller's fault. The
--- guard returns, nothing is logged, the menu row closes, and the model is
--- unchanged. The tray's only LLM control did nothing at all, and so did the
--- model browser's select, its refresh, its download, its provider URL, and the
--- onboarding page's model choice.
---
--- WHY A SOURCE SCAN AND NOT A BEHAVIOURAL TEST:
--- Each of the nineteen is one line in a different bridge, and a behavioural
--- test would need nineteen harnesses to prove a property that is visible in the
--- text. The class is what matters here, not any one instance.
---
--- WHAT IT DOES NOT COVER: a module that genuinely defines `function M:foo()`
--- and is called with a colon. Those are correct and are not matched — the scan
--- looks for the two shapes above, not for every colon in the driver.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Where a bridge's injected module lives. All of them follow the same shape, so
-- a new one is covered the day it lands rather than the day someone adds it here.
local RECEIVERS = { "state.llm", "state.keylogger", "state.gestures", "state.shortcuts" }

--- Every .lua file under the driver, tests excluded.
--- @return table Array of { path, source }.
local function driver_files()
	local root = helpers.driver_root and helpers.driver_root() or "."
	local out = {}
	-- Shelling out rather than lfs, and BOTH spellings: the suite is developed on
	-- Windows and gated on Linux, so a POSIX-only `find` reports zero files on the
	-- machine the author is sitting at — which the floor below caught the first
	-- time this ran. tests/run.lua branches the same way for the same reason.
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s\\*.lua"', root:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", root)
	end
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for path in pipe:lines() do
		local normalised = path:gsub("\\", "/")
		if not normalised:find("/tests/", 1, true) then
			local fh = io.open(path, "r")
			if fh then
				out[#out + 1] = { path = normalised, source = fh:read("*a") }
				fh:close()
			end
		end
	end
	pipe:close()
	return out
end




-- =================================================================
-- =================================================================
-- ======= 1/ The two shapes =======================================
-- =================================================================
-- =================================================================

helpers.describe("module calls: the table is never passed as self", function()

	local files = driver_files()

	helpers.it("scans the driver at all", function()
		helpers.assert_true(#files > 30,
			"found " .. #files .. " Lua file(s) — the scan is broken, and an empty "
				.. "scan reports zero offenders and reads exactly like success")
	end)

	helpers.it("passes no receiver as an extra first argument", function()
		local offenders = {}
		for _, file in ipairs(files) do
			for _, receiver in ipairs(RECEIVERS) do
				local pattern = receiver:gsub("%.", "%%.") .. "%.[a-z_]+, " .. receiver:gsub("%.", "%%.")
				for line in file.source:gmatch("[^\n]+") do
					if not line:match("^%s*%-%-") and line:find(pattern) then
						offenders[#offenders + 1] = file.path .. ": " .. line:gsub("^%s+", "")
					end
				end
			end
		end
		helpers.assert_eq(#offenders, 0,
			"the module table lands where the first real argument belongs, so that "
				.. "argument is dropped and the receiving guard returns silently:\n      "
				.. table.concat(offenders, "\n      "))
	end)

	helpers.it("calls no injected module with a colon", function()
		local offenders = {}
		for _, file in ipairs(files) do
			for line in file.source:gmatch("[^\n]+") do
				if not line:match("^%s*%-%-") then
					-- `llm:set_x(`, `state.llm:set_x(` and friends. Restricted to the
					-- known receivers so a legitimate `self:method()` inside an object
					-- module is not swept up with them.
					for _, receiver in ipairs({ "llm", "keylogger", "gestures", "shortcuts", "updater" }) do
						if line:find("%f[%w]" .. receiver .. ":[a-z_]+%(") then
							offenders[#offenders + 1] = file.path .. ": " .. line:gsub("^%s+", "")
						end
					end
				end
			end
		end
		helpers.assert_eq(#offenders, 0,
			"these modules return a plain table of functions, so a colon call shifts "
				.. "every argument by one:\n      " .. table.concat(offenders, "\n      "))
	end)

end)
