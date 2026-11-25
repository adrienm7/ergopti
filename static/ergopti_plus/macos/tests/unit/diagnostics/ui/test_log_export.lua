--- tests/unit/diagnostics/ui/test_log_export.lua

--- ==============================================================================
--- MODULE: « Export the logs (zip) » (macOS)
--- DESCRIPTION:
--- Drives diagnostics/ui/log_export.lua with in-memory logs folders: the archive
--- holds exactly the selected files, without typed text, lands in Downloads,
--- and its path reaches the clipboard, Finder and the notification; an empty
--- folder and a refused write each end in their notice, never in silence and
--- never in a partial archive. The atomic writer is exercised on real files.
---
--- ROOT CAUSE ENCODED:
--- Testers had to send dozens of log files by hand (maintainer decision,
--- 2026-11-25), and nothing kept their typed text out of them.
--- ==============================================================================

local helpers = require("tests.helpers")

local Export = helpers.load_with_stubs("diagnostics.ui.log_export")
local Files = require("diagnostics.adapters.log_export_files")

local LOGS = "/Users/tester/Library/Logs/Ergopti/"
local STAMP = { year = 2026, month = 11, day = 25, hour = 9, min = 30, sec = 5 }

--- Names stored in a ZIP archive, read from its central directory.
local function archive_names(bytes)
	local names, at = {}, 1
	while true do
		local found = bytes:find("PK\1\2", at, true)
		if not found then break end
		local length = bytes:byte(found + 28) + bytes:byte(found + 29) * 256
		names[#names + 1] = bytes:sub(found + 46, found + 45 + length)
		at = found + 46 + length
	end
	table.sort(names)
	return names
end

--- In-memory file effects over a table of folders.
local function fake_files(folders, write_refusal)
	local written = {}
	local files = {
		list_regular_files = function(dir)
			local names = {}
			for name in pairs(folders[dir] or {}) do names[#names + 1] = name end
			table.sort(names)
			return names
		end,
		read = function(path)
			local dir, name = path:match("^(.*/)([^/]+)$")
			return (folders[dir] or {})[name]
		end,
		target_folder = function() return "/Users/tester/Downloads" end,
		write_atomic = function(dir, name, bytes)
			if write_refusal then return nil, write_refusal end
			written[dir .. "/" .. name] = bytes
			return dir .. "/" .. name
		end,
	}
	return files, written
end

--- Runs one export and records every side effect.
local function run(folders, write_refusal)
	local files, written = fake_files(folders, write_refusal)
	local seen = { copies = {}, reveals = {}, notices = {} }
	local path = Export.export({
		files = function() return files end,
		logs_dir = function() return LOGS end,
		default_logs_dir = function() return LOGS end,
		home = function() return "/Users/tester" end,
		now = function() return STAMP end,
		copy = function(text) seen.copies[#seen.copies + 1] = text; return true end,
		reveal = function(target, done) seen.reveals[#seen.reveals + 1] = target; done({ ok = true }) end,
		notify = function(title, body, kind)
			seen.notices[#seen.notices + 1] = { title = title, body = body, kind = kind }
			return true
		end,
	})
	return path, written, seen
end

helpers.describe("log export: one archive of the logs (macOS)", function()
	helpers.it("archives exactly the selected files, scrubbed, and hands its path over", function()
		local typed = "2026-11-25 09:00:00:000 [DEBUG] [hotstrings] Auto-expand: 'secret' → 'Secret'.\n"
		local logs = {
			["ErgoptiPlus_2026-11-25.log"] = typed .. "2026-11-25 09:00:01:000 [INFO] [init] Ready.\n",
			["ErgoptiPlus_2026-11-24.log"] = "day before\n",
			["ErgoptiPlus_2026-11-23.log"] = "two days before\n",
			["ErgoptiPlus_2026-11-22.log"] = "too old\n",
			["ErgoptiPlus_2026-11-21.log"] = "too old\n",
			["ErgoptiPlus_errors_2026-11-25.log"] = "warning\n",
			["ErgoptiPlus_errors_2026-11-20.log"] = "too old\n",
			["ErgoptiPlus_karabiner.log"] = "retired topical file\n",
			["notes.txt"] = "user file\n",
			["launcher.log"] = "launcher\n",
			["boot_journal.log"] = "boot stages\n",
		}
		local path, written, seen = run({
			[LOGS] = logs,
			[LOGS .. "crash_reports/"] = { ["crash_1.json"] = "{}\n" },
		})
		helpers.assert_eq(path, "/Users/tester/Downloads/Ergopti-logs_2026-11-25_09-30-05.zip")
		local bytes = written[path]
		helpers.assert_true(type(bytes) == "string", "the archive must be written")
		helpers.assert_eq(table.concat(archive_names(bytes), ","), table.concat({
			"ErgoptiPlus_2026-11-23.log", "ErgoptiPlus_2026-11-24.log", "ErgoptiPlus_2026-11-25.log",
			"ErgoptiPlus_errors_2026-11-25.log", "boot_journal.log", "crash_reports/crash_1.json", "launcher.log",
		}, ","))
		helpers.assert_true(not bytes:find("secret", 1, true) and not bytes:find("Secret", 1, true),
			"no typed text may leave the machine")
		helpers.assert_true(bytes:find("Auto-expand: <text withheld>", 1, true) ~= nil)
		helpers.assert_true(bytes:find("[INFO] [init] Ready.", 1, true) ~= nil, "ordinary lines stay")
		helpers.assert_eq(seen.copies[1], path)
		helpers.assert_eq(seen.reveals[1], path)
		helpers.assert_eq(#seen.notices, 1)
		helpers.assert_eq(seen.notices[1].title, "log_export.done_title")
		helpers.assert_eq(seen.notices[1].kind, "info")
	end)

	helpers.it("says so when there is no log to export", function()
		local path, written, seen = run({ [LOGS] = { ["notes.txt"] = "user file\n" } })
		helpers.assert_nil(path)
		helpers.assert_eq(next(written), nil, "nothing is written")
		helpers.assert_eq(#seen.notices, 1)
		helpers.assert_eq(seen.notices[1].body, "log_export.empty")
		helpers.assert_eq(#seen.copies + #seen.reveals, 0)
	end)

	helpers.it("notifies a refused write and hands over no path", function()
		local path, written, seen = run({ [LOGS] = { ["ErgoptiPlus_2026-11-25.log"] = "line\n" } },
			"Permission denied")
		helpers.assert_nil(path)
		helpers.assert_eq(next(written), nil)
		helpers.assert_eq(#seen.notices, 1)
		helpers.assert_eq(seen.notices[1].title, "log_export.failed_title")
		helpers.assert_eq(seen.notices[1].kind, "error")
		helpers.assert_eq(#seen.copies + #seen.reveals, 0, "a failed export hands no path over")
	end)

	helpers.it("publishes an archive atomically and leaves nothing on a refused write", function()
		local dir = helpers.temp_dir() .. "/ergopti_log_export_" .. tostring(os.time()) .. tostring(math.random(1e6))
		assert(os.execute("mkdir -p '" .. dir .. "'"))
		local path, write_error = Files.write_atomic(dir, "logs.zip", "PK")
		local read_back = path and Files.read(path)
		-- A folder already holds the final name, so the rename is refused.
		assert(os.execute("mkdir -p '" .. dir .. "/taken.zip'"))
		local refused, refusal = Files.write_atomic(dir, "taken.zip", "PK")
		local leftover = io.open(dir .. "/.taken.zip.partial", "rb")
		if leftover then leftover:close() end
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_eq(path, dir .. "/logs.zip", tostring(write_error))
		helpers.assert_eq(read_back, "PK")
		helpers.assert_nil(refused)
		helpers.assert_true(type(refusal) == "string", "a refused write names its cause")
		helpers.assert_nil(leftover, "no partial file is left behind")
	end)
end)
