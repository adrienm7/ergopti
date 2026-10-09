--- tests/meta/test_shell_interpolation_is_quoted.lua

--- ==============================================================================
--- MODULE: Guard — no hand-quoted value reaches a shell command
--- DESCRIPTION:
--- Wrapping an interpolated value in escaped double quotes looks like quoting and
--- is not: /bin/sh still expands $, backticks and ! inside double quotes, and a
--- value containing a double quote closes the string outright. Every path the
--- driver passes to a shell is user-configurable — a config directory, a
--- downloads folder, a screenshot filename, a URL from a gesture binding.
---
--- ROOT CAUSE ENCODED:
--- The sibling guard test_shell_quoting_not_lua_q.lua catches string.format("%q")
--- but not the `"cmd \"" .. value .. "\""` form, which is how eleven further
--- sites shipped. This guard covers that shape across the whole driver, so the
--- next one cannot arrive unnoticed.
---
--- NOT flagged: %q writing a LUA or PYTHON literal (toml_cache's precompiled
--- chunks, the MLX downloader's generated script). Those are literal escapes for
--- the language that will parse them, which is exactly what %q is for.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Sites where the interpolated value is a driver-internal numeric and the escaped
-- quotes belong to shell syntax the command deliberately owns. Matched by CONTENT,
-- because the concatenated source carries no file names to match on.
local ALLOWED_SIGNATURES = {
	"lsof %-tiTCP",   -- numeric MLX port into a deliberate $(…) pipeline
}

helpers.describe("shell interpolation: no hand-quoted value reaches /bin/sh", function()

	helpers.it("every shell command quotes its interpolated values through the escaper", function()
		local src = helpers.read_driver_source("hs.execute")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the driver source must be readable or this guard asserts nothing")

		-- The offending shape: an execute/popen call on a line that also carries an
		-- escaped double quote, without the blessed quoter anywhere on that line.
		local offenders = 0
		local offending_sample = ""
		for line in src:gmatch("[^\n]+") do
			local is_shell = line:find("hs.execute", 1, true)
				or line:find("os.execute", 1, true)
				or line:find("io.popen", 1, true)
			local hand_quoted = line:find('\\"', 1, true) ~= nil
			local quoted = line:find("shell_quote", 1, true) ~= nil
			local allowed = false
			for _, sig in ipairs(ALLOWED_SIGNATURES) do
				if line:find(sig) then allowed = true end
			end
			if is_shell and hand_quoted and not quoted and not allowed then
				offenders = offenders + 1
				if offending_sample == "" then
					offending_sample = "first offender: " .. line:sub(1, 140) .. " | "
				end
			end
		end

		helpers.assert_eq(offenders, 0, offending_sample ..
			"a value wrapped in escaped double quotes is NOT shell-quoted: /bin/sh still "
			.. "expands $, backticks and ! inside them, and a value containing a quote closes "
			.. "the string. Use text_utils.shell_quote — every path here is user-configurable")
	end)

end)
