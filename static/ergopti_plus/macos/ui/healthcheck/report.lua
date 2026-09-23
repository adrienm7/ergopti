--- ui/healthcheck/report.lua

--- ==============================================================================
--- MODULE: GitHub Issue Reports (macOS)
--- DESCRIPTION:
--- The Debug menu's "Report a bug" and "Suggest a feature" rows. A bug report
--- copies the full diagnostics, redacted, to the clipboard, saves them as a
--- Markdown file next to today's errors file and reveals it in Finder, then
--- opens the repository's bug form with the version, the system and a short
--- summary prefilled. GitHub cannot receive a file through a URL and answers
--- 414 a little above 8 KB, which is why the full report travels through the
--- clipboard and the saved file.
---
--- FEATURES & RATIONALE:
--- 1. Every text that leaves the machine goes through diagnostics.redact: the
---    home folder, the account name and token-like secrets are removed from
---    the clipboard, the file and the URL alike.
--- 2. The repository comes from _shared/modules/updater/defaults.json and the
---    forms from _shared/modules/diagnostics/issue_templates.json.
--- 3. Side effects are one table so a test can observe each of them; the
---    browser opens last, after the clipboard holds what it asks for.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("infra.logger")
local Paths       = require("infra.paths")
local Json        = require("json")
local Healthcheck = require("ui.healthcheck.core")
local IssueLink   = require("diagnostics.issue_link")
local IssueReport = require("diagnostics.issue_report")
local Redact      = require("diagnostics.redact")

local LOG = "healthcheck.report"

-- Where reports are saved, under the folder of today's errors file
local REPORT_SUBDIR = "diagnostics"

-- The executable that reveals a file in Finder
local OPEN_BIN = "/usr/bin/open"





-- ================================
-- ================================
-- ======= 1/ Configuration =======
-- ================================
-- ================================

--- Reads and decodes one shared JSON document.
--- @param rel string Path under _shared/.
--- @return table
local function read_shared_json(rel)
	local path = Paths.shared(rel)
	local fh, err = io.open(path, "rb")
	if not fh then error(string.format("%s is unreadable: %s", rel, tostring(err))) end
	local raw = fh:read("*a")
	fh:close()
	local data = Json.decode(raw)
	if type(data) ~= "table" then error(rel .. " is not a JSON object") end
	return data
end

--- The issue forms, the repository and the redaction rules.
--- @return table { templates, repository, redaction }
local function load_config()
	local defaults = read_shared_json("modules/updater/defaults.json")
	return {
		templates  = read_shared_json("modules/diagnostics/issue_templates.json"),
		repository = defaults.github,
		redaction  = read_shared_json("modules/diagnostics/redaction.json"),
	}
end

--- What identifies this machine in paths and text, for redaction.
--- @param effects table
--- @return table { home, user, case_insensitive }
local function redaction_context(effects)
	local identity = effects.identity()
	-- Without the home folder nothing would remove it, and every path under it
	-- would be published
	if type(identity.home) ~= "string" or identity.home == "" then
		error("the home folder is unknown, so the report cannot be redacted")
	end
	-- APFS is case-insensitive by default, and so is every path a user types
	return { home = identity.home, user = identity.user, case_insensitive = true }
end





-- ===============================
-- ===============================
-- ======= 2/ Side Effects =======
-- ===============================
-- ===============================

--- Creates a folder and its parents in-process.
--- @param dir string Absolute folder path.
--- @return boolean created True when the folder exists afterwards.
local function make_dir(dir)
	local built = dir:sub(1, 1) == "/" and "/" or ""
	for part in dir:gmatch("[^/]+") do
		built = built .. part .. "/"
		pcall(hs.fs.mkdir, built)
	end
	local ok, attrs = pcall(hs.fs.attributes, dir)
	return ok and type(attrs) == "table" and attrs.mode == "directory"
end

--- The production side effects; a test replaces any of them.
local DEFAULT_EFFECTS = {
	copy = function(text) return require("adapters.clipboard").write(text) end,
	save = function(dir, name, text)
		if not make_dir(dir) then return nil, "cannot create " .. dir end
		local path = dir .. "/" .. name
		local fh, err = io.open(path, "wb")
		if not fh then return nil, tostring(err) end
		local ok, write_err = fh:write(text)
		fh:close()
		if not ok then return nil, tostring(write_err) end
		return path
	end,
	reveal = function(path)
		local handle = require("adapters.shell_runner").spawn(OPEN_BIN, { "-R", path }, nil)
		return handle.start()
	end,
	open_url = function(url) return (require("adapters.shell_runner").open(url)) end,
	notify = function(title, body, kind)
		return require("adapters.notifier").send(title, { body = body, kind = kind })
	end,
	now = os.time,
	identity = function() return { home = os.getenv("HOME"), user = os.getenv("USER") } end,
}

--- Merges test overrides over the production effects.
--- @param overrides table|nil
--- @return table
local function effects_with(overrides)
	local effects = {}
	for name, fn in pairs(DEFAULT_EFFECTS) do effects[name] = fn end
	for name, fn in pairs(overrides or {}) do effects[name] = fn end
	return effects
end





-- ==========================
-- ==========================
-- ======= 3/ Reports =======
-- ==========================
-- ==========================

--- The report's identity fields, from a healthcheck snapshot.
--- @param snapshot table
--- @param now number Epoch seconds.
--- @return table
local function report_info(snapshot, now)
	local sys = type(snapshot.sys) == "table" and snapshot.sys or {}
	local os_name = "macOS " .. tostring(sys.os_version or "unknown")
	if sys.arch then os_name = os_name .. " (" .. tostring(sys.arch) .. ")" end
	local commit = tostring(sys.git_hash or "unknown")
	if sys.commit_source then commit = commit .. " (" .. tostring(sys.commit_source) .. ")" end
	return {
		driver        = "macos",
		version       = tostring(snapshot.version or "unknown"),
		commit        = commit,
		os            = os_name,
		generated_utc = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
		file_stamp    = os.date("!%Y%m%dT%H%M%SZ", now),
		warn_count    = snapshot.warn_count or 0,
		err_count     = snapshot.err_count or 0,
		last_error    = type(snapshot.last_error) == "string" and snapshot.last_error or "",
	}
end

--- The folder reports are saved in: beside today's errors file.
--- @return string
local function report_dir()
	local errors_file = tostring(Logger.ERRORS_LOG_FILE)
	local dir = errors_file:match("^(.*)/[^/]*$")
	if not dir then error("the errors file path has no folder: " .. errors_file) end
	return dir .. "/" .. REPORT_SUBDIR
end

--- Tells the user the report could not be prepared.
--- @param effects table
--- @param title_key string The menu row that was clicked.
local function notify_failure(effects, title_key)
	local I18n = require("infra.i18n")
	effects.notify(I18n.get(title_key), I18n.get("notify.github_report_failed"), "error")
end

--- Prepares a bug report and opens the GitHub bug form.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return boolean prepared True when the form was opened with its report.
function M.report_bug(overrides)
	Logger.start(LOG, "Preparing a bug report…")
	local effects = effects_with(overrides)
	local ok, result = xpcall(function()
		local config = load_config()
		local context = redaction_context(effects)
		local snapshot = Healthcheck.run()
		local info = report_info(snapshot, effects.now())
		local name = IssueReport.file_name(info)
		local function redact(text) return Redact.apply(text, config.redaction, context) end
		local markdown = redact(IssueReport.markdown(info, IssueReport.dump(snapshot)))

		if not effects.copy(markdown) then error("the clipboard refused the report") end
		local path, save_err = effects.save(report_dir(), name, markdown)
		if not path then error("the report could not be saved: " .. tostring(save_err)) end
		if not effects.reveal(path) then Logger.warn(LOG, "The saved report could not be revealed in Finder.") end

		local url = IssueLink.build_url(config.templates, config.repository, "bug", {
			version     = redact(info.version),
			os          = redact(info.os),
			driver      = info.driver,
			diagnostics = redact(IssueReport.summary(info, name)),
		})
		if not effects.open_url(url) then error("the browser could not be opened") end
		return path
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Bug report failed: %s", tostring(result))
		notify_failure(effects, "menu.debug.report_bug")
		return false
	end
	local I18n = require("infra.i18n")
	effects.notify(I18n.get("notify.report_bug_title"), I18n.get("notify.report_bug_body"), "info")
	Logger.success(LOG, "Bug report prepared (%s) and the GitHub form opened.", tostring(result))
	return true
end

--- Opens the GitHub feature form with the version and the system prefilled.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return boolean opened
function M.suggest_feature(overrides)
	Logger.start(LOG, "Opening the feature request form…")
	local effects = effects_with(overrides)
	local ok, err = xpcall(function()
		local config = load_config()
		local context = redaction_context(effects)
		local info = report_info(Healthcheck.run(), effects.now())
		local url = IssueLink.build_url(config.templates, config.repository, "feature", {
			version = Redact.apply(info.version, config.redaction, context),
			os      = Redact.apply(info.os, config.redaction, context),
			driver  = info.driver,
		})
		if not effects.open_url(url) then error("the browser could not be opened") end
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Feature request failed: %s", tostring(err))
		notify_failure(effects, "menu.debug.suggest_feature")
		return false
	end
	Logger.success(LOG, "Feature request form opened.")
	return true
end

return M
