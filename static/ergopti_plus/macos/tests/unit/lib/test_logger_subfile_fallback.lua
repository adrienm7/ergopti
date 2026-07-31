--- tests/unit/lib/test_logger_subfile_fallback.lua

--- ==============================================================================
--- MODULE: Logger — Topical Sub-file Routing Always Has a Usable Table
--- DESCRIPTION:
--- Locks down that the topical sub-log fan-out survives a failure to locate the
--- driver root — a stripped or bytecode-compiled build, where the logger's own
--- debug.getinfo(1, "S").source is not a usable path.
---
--- ROOT CAUSE ENCODED: SUB_LOG_NAMES started empty and was populated only by a
--- runtime probe that derived the driver root from that source path, inside a
--- BARE pcall whose every early exit — source not "@"-prefixed, path pattern
--- miss, any throw — discarded the error with no Logger call at all. On any of
--- those paths the table stayed `{}`, so the fan-out loop iterated nothing and
--- ALL TEN topical logs (mlx, ollama, llm, hotstrings, keylogger, karabiner,
--- gestures, menu, notify, boot) silently stopped existing, with no warning
--- anywhere to explain why.
---
--- The first fix seeded the table from a hardcoded fallback list before probing,
--- and warned when the probe failed. That worked, but the fallback was a second
--- copy of the routing data and it had already drifted from the canonical file —
--- it routed gestures on one pattern where the shared TOML declares two.
---
--- The routing table is now generated from the canonical TOML and loaded like
--- any other module, so there is no probe to fail and no fallback to drift. This
--- test keeps its behavioural core unchanged and gets STRONGER for it: the
--- topical log must appear even with the source path unresolvable, and now
--- without any fallback machinery standing behind it.
---
--- This is a BEHAVIORAL test: it makes the logger's own source path
--- unresolvable, then asserts a real topical file appears on disk with the
--- emitted line in it — not merely that some constant exists.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Retention window; irrelevant to this test but required by init_log_path.
local RETENTION_DAYS = 14

--- Creates a directory and every missing ancestor, on both POSIX and Windows.
--- init_log_path() shells its own mkdir through ShellRunner, which is stubbed out
--- under the headless harness, so the test must create the tree itself.
--- @param path string Absolute directory path.
local function mkdir_p(path)
	if package.config:sub(1, 1) == "\\" then
		os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
	else
		os.execute('mkdir -p "' .. path .. '"')
	end
end

helpers.describe("logger — sub-file routing falls back instead of vanishing", function()
	helpers.it("still writes topical logs when the driver root cannot be derived", function()
		local unique    = tostring(os.time()) .. "_" .. tostring(math.random(100000))
		local test_base = "/tmp/ergopti_test_subfile_fallback_" .. unique .. "/"
		local logs_dir  = test_base .. "hammerspoon/logs/"
		pcall(function() mkdir_p(logs_dir) end)

		local L = helpers.load_with_stubs("lib.logger")
		L.set_level("DEBUG")

		-- Pre-load the shell adapter so its own require never runs under the stub.
		pcall(require, "adapters.shell_runner")

		local captured = {}
		L.set_sink(function(line) captured[#captured + 1] = line end)

		-- Make the logger's own source path unresolvable for the duration of the
		-- call, reproducing exactly what a stripped or bytecode-compiled build does.
		local saved_getinfo = debug.getinfo
		debug.getinfo = function() return { source = "=[C]" } end
		local ok_init, init_err = pcall(L.init_log_path, test_base, RETENTION_DAYS)
		debug.getinfo = saved_getinfo
		-- Re-raised rather than asserted as a boolean: pcall is here only to make
		-- sure debug.getinfo is restored before anything else runs, so surfacing
		-- the real error beats reporting "ok_init was false", which says nothing
		-- about what went wrong.
		if not ok_init then error(init_err, 0) end

		L.error("llm.api_mlx", "boom")
		L.set_sink(nil)

		local mlx_path = logs_dir .. "ErgoptiPlus_mlx.log"
		local fh = io.open(mlx_path, "r")
		helpers.assert_true(fh ~= nil,
			"the topical mlx log must exist — an empty SUB_LOG_NAMES makes all ten topical logs vanish")

		local content = fh and fh:read("*a") or ""
		if fh then fh:close() end
		helpers.assert_true(content:find("boom", 1, true) ~= nil,
			"the emitted line must be fanned out into the topical mlx log")

		-- There is no longer a probe that can fail, so there is no warning to look
		-- for. What must hold is stronger and is asserted above: the fan-out works
		-- with the source path unresolvable, because the routing table never
		-- depended on resolving it in the first place. `captured` stays wired so a
		-- future regression that reintroduces a runtime probe has somewhere to
		-- surface.
		helpers.assert_true(#captured > 0,
			"the test sink captured nothing — the logger emitted no line at all and the "
			.. "assertions above would be checking a file written by something else")

		pcall(function() os.remove(mlx_path) end)
	end)
end)
