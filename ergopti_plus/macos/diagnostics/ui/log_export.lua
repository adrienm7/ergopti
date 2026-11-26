--- diagnostics/ui/log_export.lua

--- ==============================================================================
--- MODULE: Export The Logs (macOS)
--- DESCRIPTION:
--- « Export the logs (zip) » in the Debug menu: one archive a tester sends
--- instead of dozens of files (maintainer decision, 2026-11-25). It holds the
--- daily logs and errors mirrors of the last days, the files written before the
--- logger starts (boot journal, launcher.log, fatal report, reload breadcrumb,
--- bootstrap.log, all in the default logs folder) and the crash reports, each
--- copied without the user's typed text; it lands in ~/Downloads (else
--- ~/Desktop), is revealed in Finder, and its path is put on the clipboard.
---
--- FEATURES & RATIONALE:
--- 1. One selection and one scrub for macOS and Linux:
---    core/logger/engine/log_export.lua decides which files enter and what each
---    keeps; this module only lists, reads and publishes.
--- 2. Never silent: an empty selection, a refused read, archive or write each
---    end in a translated notice and an English log line; no partial archive is
---    ever left behind (diagnostics/adapters/log_export_files.lua).
--- 3. Side effects are one table, replaced by the tests.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Export = require("core.logger.engine.log_export")
local Zip = require("core.fs.engine.zip_writer")
local AppDirs = require("core.fs.engine.app_dirs")

local LOG = "diagnostics.ui.log_export"

--- The production side effects; a test replaces any of them.
local DEFAULT_EFFECTS = {
	files = function() return require("diagnostics.adapters.log_export_files") end,
	logs_dir = function() return Logger.logs_dir() end,
	default_logs_dir = function() return Logger.FALLBACK_LOG_DIR end,
	home = function() return os.getenv("HOME") end,
	now = function() return os.date("*t") end,
	copy = function(text) return require("clipboard.adapters.clipboard").write(text) == true end,
	reveal = function(path, done)
		return require("diagnostics.ui.healthcheck.report").reveal_in_finder(path, done, function() return true end)
	end,
	notify = function(title, body, kind)
		return require("platform.focus.application_notifier").send(title, { body = body, kind = kind })
	end,
}


--- Folder path with exactly one trailing slash.
local function folder(path) return (tostring(path):gsub("/+$", "")) .. "/" end

--- Builds the archive entries: each selected file, read and scrubbed.
--- @param effects table
--- @param files table The file effects.
--- @return table|nil entries
--- @return string|nil error_message
local function collect(effects, files)
	local logs, default = folder(effects.logs_dir()), folder(effects.default_logs_dir())
	local crash = logs .. AppDirs.crash_reports_dir .. "/"
	local listings = {}
	for key, dir in pairs({ logs = logs, default = default, crash_reports = crash }) do
		local names, list_error = files.list_regular_files(dir)
		if not names then return nil, list_error end
		listings[key] = names
	end
	local stamp = effects.now()
	local selected = Export.select({
		platform = "hs", today = string.format("%04d-%02d-%02d", stamp.year, stamp.month, stamp.day),
		logs = listings.logs, default = listings.default, crash_reports = listings.crash_reports,
	})
	local roots = { logs = logs, default = default, crash_reports = crash }
	local entries = {}
	for _, item in ipairs(selected) do
		local bytes, read_error = files.read(roots[item.folder] .. item.name)
		if not bytes then return nil, "cannot read " .. item.archive .. ": " .. tostring(read_error) end
		entries[#entries + 1] = { name = item.archive, data = Export.scrub_text(bytes) }
	end
	return entries
end

--- Exports the logs as one zip, reveals it and copies its path.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return string|nil path The archive, or nil when nothing was exported.
function M.export(overrides)
	-- Test overrides replace production effects one by one.
	local effects = require("core.text.engine.table_util").shallow_copy(DEFAULT_EFFECTS)
	for name, fn in pairs(overrides or {}) do effects[name] = fn end
	local i18n = require("core.i18n.engine.i18n")
	Logger.start(LOG, "Exporting the logs as one archive…")
	local function fail(detail)
		Logger.error(LOG, "The logs could not be exported: %s.", tostring(detail))
		effects.notify(i18n.get("log_export.failed_title"), i18n.get("log_export.failed"), "error")
		return nil
	end
	local files = effects.files()
	local collected, entries, collect_error = pcall(collect, effects, files)
	if not collected then return fail(entries) end
	if not entries then return fail(collect_error) end
	if #entries == 0 then
		Logger.warn(LOG, "No log file to export in %s.", tostring(effects.logs_dir()))
		effects.notify(i18n.get("log_export.failed_title"), i18n.get("log_export.empty"), "warn")
		return nil
	end
	local stamp = effects.now()
	local built, bytes = pcall(Zip.build, entries, stamp)
	if not built then return fail(bytes) end
	local target = files.target_folder(effects.home())
	if not target then return fail("neither ~/Downloads nor ~/Desktop is a folder") end
	local path, write_error = files.write_atomic(target, Export.archive_name(stamp), bytes)
	if not path then return fail(write_error) end
	if not effects.copy(path) then
		Logger.warn(LOG, "The archive path could not be copied to the clipboard.")
	end
	effects.reveal(path, function(receipt)
		if type(receipt) ~= "table" or receipt.ok ~= true then
			Logger.warn(LOG, "The archive could not be revealed in Finder (reason=%s).",
				tostring(type(receipt) == "table" and receipt.error or receipt))
		end
	end)
	-- The shared text holds %s, as Windows and Linux read it; i18n.format only fills {1}.
	local done = (i18n.get("log_export.done"):gsub("%%s", function() return path end))
	effects.notify(i18n.get("log_export.done_title"), done, "info")
	Logger.success(LOG, "Exported %d log file(s) to %s.", #entries, path)
	return path
end

return M
