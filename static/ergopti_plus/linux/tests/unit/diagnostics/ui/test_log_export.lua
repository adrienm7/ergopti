--- tests/unit/diagnostics/ui/test_log_export.lua

--- ==============================================================================
--- MODULE: Export the Logs as One Zip (Linux)
--- DESCRIPTION:
--- « Export the logs (zip) » from the Debug menu, through the real listing,
--- scrub, ZIP writer and publication, with the clipboard, notifier and file
--- manager replaced by recorders.
---
--- ROOT CAUSE ENCODED:
--- Testers had to send dozens of log files, with their typed text in them. The
--- export writes one archive of exactly the selected files, scrubbed, says
--- where it is, and never leaves a partial archive or fails silently.
--- ==============================================================================

local helpers = require("tests.helpers")
local Shell = require("core.process.adapters.shell_runner")
local AppDirs = require("core.fs.engine.app_dirs")

--- A fresh private folder.
local function private_dir()
	local dir = os.tmpname()
	os.remove(dir)
	assert(Shell.run("mkdir -p " .. Shell.quote(dir)))
	return dir
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(text))
	assert(handle:close())
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Little-endian integer of `size` bytes at `at` (1-based).
local function le(bytes, at, size)
	local value = 0
	for index = size, 1, -1 do value = value * 256 + bytes:byte(at + index - 1) end
	return value
end

--- The stored entries of an archive, by name, read from its central directory.
local function zip_entries(bytes)
	local eocd = #bytes - 21
	assert(bytes:sub(eocd, eocd + 3) == "PK\5\6", "not a ZIP archive")
	local entries, at = {}, le(bytes, eocd + 16, 4) + 1
	for _ = 1, le(bytes, eocd + 10, 2) do
		local name_length = le(bytes, at + 28, 2)
		local name = bytes:sub(at + 46, at + 45 + name_length)
		local size = le(bytes, at + 24, 4)
		local local_at = le(bytes, at + 42, 4) + 1
		local data_at = local_at + 30 + le(bytes, local_at + 26, 2) + le(bytes, local_at + 28, 2)
		entries[name] = bytes:sub(data_at, data_at + size - 1)
		at = at + 46 + name_length
	end
	return entries
end

--- The names of a folder.
local function names(dir)
	local list = {}
	for _, entry in ipairs(assert(require("core.fs.engine.native_directory").entries(dir))) do list[#list + 1] = entry.name end
	table.sort(list)
	return list
end

--- Runs the export against fixture folders and recorders.
local function export(logs, default, destination)
	local Export = helpers.load_module("diagnostics.ui.log_export")
	local record = { notices = {}, copies = {}, reveals = {} }
	Export._set_services({
		logs_dir = function() return logs end,
		default_dir = function() return default end,
		destination_dir = function() return destination, destination and nil or "no destination" end,
		now = function() return { year = 2026, month = 11, day = 25, hour = 9, min = 7, sec = 3 } end,
		translate = function(key) return key == "log_export.done" and "done %s" or key end,
		notify = function(message, title, level)
			record.notices[#record.notices + 1] = { message = message, title = title, level = level }
			return true
		end,
		copy = function(text) record.copies[#record.copies + 1] = text; return true end,
		reveal = function(folder) record.reveals[#record.reveals + 1] = folder; return true end,
	})
	local ok, result = pcall(Export.run)
	Export._set_services(nil)
	if not ok then error(result, 0) end
	record.result = result
	return record
end

--- The local date `offset` calendar days before today (noon anchor, DST-safe).
local function day(offset)
	local now = os.date("*t")
	return os.date("%Y-%m-%d", os.time({ year = now.year, month = now.month, day = now.day - offset, hour = 12 }))
end

--- Fills a logs folder with five days of logs and the files around them.
local function fill(logs, default)
	local files = AppDirs.files
	for offset = 0, 4 do
		local date = day(offset)
		write(logs .. "/" .. files.unified_prefix .. date .. files.extension,
			date .. " 10:00:00:000 [DEBUG] [hotstrings] Auto-expand: 'secret' → 'Secret'.\n"
			.. date .. " 10:00:01:000 [INFO] [boot] day " .. offset .. " marker\n")
		write(logs .. "/" .. files.errors_prefix .. date .. files.extension,
			date .. " 10:00:02:000 [ERROR] [x] error " .. offset .. "\n")
	end
	write(logs .. "/" .. files.retired_topical_logs[1], "retired\n")
	write(logs .. "/notes.txt", "user notes\n")
	assert(Shell.run("mkdir -p " .. Shell.quote(logs .. "/" .. AppDirs.crash_reports_dir)))
	write(logs .. "/" .. AppDirs.crash_reports_dir .. "/crash.json", "{\"line\":\"ok\"}\n")
	write(default .. "/" .. files.bootstrap_log, "session_lock_refused\n")
end

helpers.describe("linux log export", function()
	helpers.it("writes one scrubbed zip of exactly the selected files and says where it is", function()
		local root = private_dir()
		local logs, default, downloads = root .. "/logs", root .. "/default", root .. "/Downloads"
		assert(Shell.run("mkdir -p " .. Shell.quote(logs) .. " " .. Shell.quote(default) .. " " .. Shell.quote(downloads)))
		fill(logs, default)
		local ok, err = pcall(function()
			local record = export(logs, default, downloads)
			helpers.assert_true(record.result, "the export succeeds")
			local name = "Ergopti-logs_2026-11-25_09-07-03.zip"
			helpers.assert_eq(names(downloads), { name }, "one archive and no temporary file")
			local path = downloads .. "/" .. name
			local entries = zip_entries(assert(read(path)))
			helpers.assert_eq(require("luv").fs_stat(path).mode % 512, 384, "the archive is owner-only")
			local expected, files = {}, AppDirs.files
			for offset = 0, 2 do
				local date = day(offset)
				expected[#expected + 1] = files.unified_prefix .. date .. files.extension
				expected[#expected + 1] = files.errors_prefix .. date .. files.extension
			end
			expected[#expected + 1] = files.bootstrap_log
			expected[#expected + 1] = AppDirs.crash_reports_dir .. "/crash.json"
			local got = {}
			for entry_name, data in pairs(entries) do
				got[#got + 1] = entry_name
				helpers.assert_true(not data:find("secret", 1, true) and not data:find("Secret", 1, true),
					entry_name .. " must not carry typed text")
			end
			table.sort(got)
			table.sort(expected)
			helpers.assert_eq(got, expected)
			helpers.assert_contains(entries[files.unified_prefix .. os.date("%Y-%m-%d") .. files.extension], "day 0 marker")
			helpers.assert_eq(record.copies, { path })
			helpers.assert_eq(record.reveals, { downloads })
			helpers.assert_eq(#record.notices, 1)
			helpers.assert_eq(record.notices[1].message, "done " .. path)
			helpers.assert_eq(record.notices[1].title, "log_export.done_title")
		end)
		assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
		if not ok then error(err, 0) end
	end)

	helpers.it("notifies the failure and leaves no file when the archive cannot be written", function()
		local root = private_dir()
		local logs, default, downloads = root .. "/logs", root .. "/default", root .. "/Downloads"
		assert(Shell.run("mkdir -p " .. Shell.quote(logs) .. " " .. Shell.quote(default) .. " " .. Shell.quote(downloads)))
		fill(logs, default)
		-- The archive's name is already taken: publication never replaces a file.
		write(downloads .. "/Ergopti-logs_2026-11-25_09-07-03.zip", "someone else's file")
		local ok, err = pcall(function()
			local record = export(logs, default, downloads)
			helpers.assert_eq(record.result, false)
			helpers.assert_eq(names(downloads), { "Ergopti-logs_2026-11-25_09-07-03.zip" }, "no temporary file is left")
			helpers.assert_eq(read(downloads .. "/Ergopti-logs_2026-11-25_09-07-03.zip"), "someone else's file")
			helpers.assert_eq(record.notices, { { message = "log_export.failed", title = "log_export.failed_title", level = "error" } })
			helpers.assert_eq(record.copies, {})
			helpers.assert_eq(record.reveals, {})
		end)
		assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
		if not ok then error(err, 0) end
	end)

	helpers.it("notifies the failure when there is no destination folder", function()
		local root = private_dir()
		local logs = root .. "/logs"
		assert(Shell.run("mkdir -p " .. Shell.quote(logs)))
		fill(logs, logs)
		local ok, err = pcall(function()
			local record = export(logs, logs, nil)
			helpers.assert_eq(record.result, false)
			helpers.assert_eq(record.notices[1].message, "log_export.failed")
		end)
		assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
		if not ok then error(err, 0) end
	end)

	helpers.it("says there is nothing to export for an empty logs folder", function()
		local root = private_dir()
		local ok, err = pcall(function()
			local record = export(root .. "/absent", root .. "/absent", root)
			helpers.assert_eq(record.result, false)
			helpers.assert_eq(record.notices, { { message = "log_export.empty", title = "log_export.failed_title", level = "warning" } })
			helpers.assert_eq(names(root), {}, "no archive is written")
		end)
		assert(Shell.run("rm -rf -- " .. Shell.quote(root)))
		if not ok then error(err, 0) end
	end)
end)
