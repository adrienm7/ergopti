--- _shared/tests/lua/diagnostics/redact_work.lua

--- ==============================================================================
--- MODULE: Redaction Work Contract
--- DESCRIPTION:
--- The macOS and Linux loggers redact every line they write. A line holds none
--- of the needles most passes look for, and the redactor folded the whole line
--- to lower case and rebuilt it once per pass: about 0.4 ms a line under Lua 5.4
--- (boot-log-redaction-prepare-2026-11-22). An unmatched line now costs one fold
--- and no rebuild, and a matched one is still redacted.
--- ==============================================================================

return function(helpers, json, shared_root)
	local Redact = require("diagnostics.engine.reports.redact")

	local file = assert(io.open(shared_root .. "/diagnostics/data/redaction.json", "rb"))
	local RULES = assert(json.decode(file:read("*a")))
	file:close()
	local CONTEXT = { home = "/Users/workowner", user = "workowner", case_insensitive = true,
		config_dir = "/Users/workowner/.config/ergopti" }

	helpers.describe("Redaction work per line (boot-log-redaction-prepare-2026-11-22)", function()
		helpers.it("folds an unmatched line once and rebuilds it never", function()
			local line = "2026-11-22 12:00:00 [INFO] [Layout] Shift layer registered (49 entries)."
			-- The first line resolves the context once, as a logger's first line does.
			Redact.apply("2026-11-22 12:00:00 [INFO] [Logger] Session opened.", RULES, CONTEXT)
			local before = Redact.work_counts()
			helpers.assert_eq(Redact.apply(line, RULES, CONTEXT), line)
			local after = Redact.work_counts()
			helpers.assert_eq(after.folds - before.folds, 1, "an unmatched line is folded once")
			helpers.assert_eq(after.rebuilds - before.rebuilds, 0, "an unmatched line is never rebuilt")
		end)

		helpers.it("still redacts a matched line", function()
			local line = "Read /Users/workowner/.config/ergopti/Secret Pack/p.toml for workowner"
			local got = Redact.apply(line, RULES, CONTEXT)
			helpers.assert_eq(got:find("workowner", 1, true), nil, "the account name reached the line: " .. got)
			helpers.assert_eq(got:find("Secret Pack", 1, true), nil, "a configuration name reached the line: " .. got)
		end)
	end)
end
