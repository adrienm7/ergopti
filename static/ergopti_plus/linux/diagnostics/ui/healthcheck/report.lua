--- diagnostics/ui/healthcheck/report.lua

--- ==============================================================================
--- MODULE: Diagnostics Exports And GitHub Forms (Linux)
--- DESCRIPTION:
--- What the diagnostics page's buttons do on this machine once
--- healthcheck.actions accepted them: copy the report, save it as a Markdown
--- file under the logs folder and open that folder, report it on GitHub (copy
--- it, then save and reveal its attachment before opening the bug template) or
--- a file. Also the Debug menu's "Report a bug", which runs that same report
--- action on a fresh snapshot without the window, and "Suggest a feature".
---
--- FEATURES & RATIONALE:
--- 1. Shared output is rebuilt from the host snapshot through a closed typed
---    policy. Free text, paths and unknown fields are excluded regardless of
---    the page or details checkbox. Only approved technical content leaves.
--- 2. The clipboard and attachment hold the complete approved report.
---    The form is prefilled with the host version, OS and driver and the compact
---    report (tables, no JSON block), cut to the URL budget with a note that the
---    complete report is on the clipboard and in the saved file. The browser opens
---    after attachment reveal.
--- 3. Paths come from the snapshot the host collected, by field id; a folder
---    that does not exist yet is created before it is opened; a file that does
---    not exist yet (today's errors file before the day's first warning) is
---    said to the page, not logged as a failure.
--- 4. Side effects are one table so a test can observe each of them; the
---    browser opens last, after the clipboard holds what it asks for, and
---    nothing follows it that could take the focus back.
--- 5. Without a window (no lgi or WebKitGTK 4.1, or a refused native window)
---    the same approved report is written as a self-contained HTML file and
---    opened in the browser: the diagnostics never depend on the component
---    they diagnose.
--- ==============================================================================

local M = {}

local Logger      = require("core.logger.engine.shim")
local IssueLink   = require("diagnostics.engine.reports.issue_link")
local Redact      = require("diagnostics.engine.reports.redact")
local Share       = require("diagnostics.engine.healthcheck.share")
local ReportRunner = require("diagnostics.engine.healthcheck.report")
local ConfigKeys = require("settings.engine.keys")

local LOG = "diagnostics.engine.healthcheck.report"
local EEXIST = 17 -- Linux exclusive-create collision receipt.





-- ===============================
-- ===============================
-- ======= 1/ Side Effects =======
-- ===============================
-- ===============================

--- Receives the launcher exit and both closed streams without blocking GTK.
--- @param target string A path or a URL.
--- @param done function Receives the real native exit receipt.
--- @param current function Exact page/action authority.
--- @return table|nil cancellable native request
local function xdg_open(target, done, current)
	return require("apps.adapters.desktop_opener").open(target, done, current)
end

--- The production side effects; a test replaces any of them.
local DEFAULT_EFFECTS = {
	copy = function(text) return require("clipboard.adapters.clipboard").write(text) == true end,
	make_dir = function(dir)
		local Shell = require("core.process.adapters.shell_runner")
		return Shell.run("mkdir -p " .. Shell.quote(dir))
	end,
	save = function(dir, name, text)
		local Shell = require("core.process.adapters.shell_runner")
		if not Shell.run("mkdir -p " .. Shell.quote(dir)) then return nil, "cannot create " .. dir end
		local stem, extension = name:match("^(.*)(%.[^.]+)$")
		stem, extension = stem or name, extension or ""
		local files = require("core.fs.adapters.file_system")
		for index = 0, 999 do
			local path = dir .. "/" .. stem .. (index == 0 and "" or "-" .. index) .. extension
			local written, errno = files.write_new(path, text)
			if written == true then return path end
			if errno ~= EEXIST and errno ~= "EEXIST" then return nil, "cannot complete writing " .. path end
		end
		return nil, "no unused diagnostic report name"
	end,
	exists = function(path)
		local called, kind = pcall(require("core.fs.engine.native_directory").target_kind, path)
		return called and kind ~= nil
	end,
	-- No portable "select this file" exists across file managers; the folder
	-- holding it is the next best thing
	reveal = function(path, done, current) return xdg_open(path:match("^(.*)/[^/]*$") or path, done, current) end,
	open = xdg_open,
	open_url = xdg_open,
	notify = function(title, body, level)
		require("platform.focus.application_notifier").send(body ~= "" and body or title, { title = title, level = level })
		return true
	end,
	identity = function()
		return {
			home = require("settings.engine.paths").home(),
			user = os.getenv("USER") or os.getenv("LOGNAME"),
			config_dir = require("settings.engine.paths").get_config_dir(),
		}
	end,
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

--- What identifies this machine in paths and text, for redaction. Linux file
--- systems compare paths case-sensitively.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return table { home, user, config_dir, case_insensitive }
function M.redaction_context(overrides)
	local identity = effects_with(overrides).identity()
	-- Without the home folder nothing would remove it, and every path under it
	-- would be published
	if type(identity.home) ~= "string" or identity.home == "" then
		error("the home folder is unknown, so nothing could be redacted")
	end
	return { home = identity.home, user = identity.user, config_dir = identity.config_dir, case_insensitive = false }
end





-- ===============================
-- ===============================
-- ======= 2/ Page Actions =======
-- ===============================
-- ===============================

-- The diagnostics runner shared with the other desktop driver; this driver
-- supplies its effects and how a failed folder reveal is judged.
local Runner = ReportRunner.new({
	logger = Logger,
	log = LOG,
	effects_with = effects_with,
	url_effects = {},
	module_current = function() return package.loaded["diagnostics.ui.healthcheck.report"] == M end,
	perform_requires_loaded_owner = false,
	reveal_outcome = function(receipt)
		if receipt.ok ~= true then
			Logger.warn(LOG, "The saved report's folder could not be opened (status=%s, reason=%s).",
				tostring(receipt.code), tostring(receipt.error))
		end
		return false
	end,
})

--- Performs one action through an explicit completion and retained owner.
--- @param owner table { current = function(): boolean, complete = function(result) }
--- @return table operation { cancel = function() }
function M.perform(action, paths, documents, context, overrides, snapshot, owner)
	return Runner.perform(action, paths, documents, context, overrides, snapshot, owner)
end





-- =============================
-- =============================
-- ======= 3/ Debug Menu =======
-- =============================
-- =============================

local menu_request = Runner.menu_request

--- The daemon's snapshot without the window, the probes not run.
--- @return table snapshot, table documents
local function menu_snapshot(complete_local)
	local bridge = require("diagnostics.ui.healthcheck.bridge")
	return bridge.build_snapshot(require("core.ui.ui.webview_manager").get_daemon_state(), false, false, complete_local == true),
		bridge.config()
end

--- Reports a bug exactly as the diagnostics page's report button does, without
--- the window: the approved report of a fresh snapshot is copied, saved and its
--- folder opened, then the bug form opens with the host version, OS and driver.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @return table|nil cancellable request
function M.report_bug(overrides, complete)
	return menu_request(ConfigKeys.COMMAND.REPORT_BUG, overrides, complete, function(owner)
		local snapshot, documents = menu_snapshot(true)
		assert(type(snapshot) == "table" and type(snapshot.sections) == "table"
			and type(snapshot.sections.paths) == "table", "the diagnostics snapshot has no paths section")
		local document = Share.document(snapshot, documents.schema,
			require("core.i18n.engine.i18n").get(documents.schema.share_policy.notice_key))
		return M.perform({ action = "report", text = document.text, fields = document.fields },
			snapshot.sections.paths, documents, M.redaction_context(overrides), overrides, snapshot, owner)
	end)
end

--- Opens the bug form for a finished field report
--- (diagnostics/ui/field_check/field_report.lua): this machine's version, OS
--- and driver and the run's evidence line, the redacted report on the clipboard.
--- @param line string The run's evidence line.
--- @param text string The complete report.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @return table|nil cancellable request
function M.report_field_run(line, text, overrides, complete)
	return Runner.report_field_run(line, text, function()
		local snapshot, documents = menu_snapshot()
		return snapshot, documents, M.redaction_context(overrides)
	end, overrides, complete)
end

--- Escapes text for an HTML element or attribute.
--- @param text string
--- @return string
local function escape_html(text)
	return (text:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

--- The report as one self-contained page: no script, no asset, no network, so
--- any browser shows it whatever the desktop lacks.
--- @param title string The page title (the diagnostics window's name).
--- @param lead string The sentence that says why this is a file.
--- @param text string The approved report.
--- @param locale string The page language.
--- @return string html
function M.render_html(title, lead, text, locale)
	return table.concat({
		"<!doctype html>",
		'<html lang="' .. escape_html(locale) .. '">',
		'<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
		"<title>" .. escape_html(title) .. "</title>",
		-- No colour of its own: the browser's light and dark defaults apply
		"<style>:root{color-scheme:light dark}"
			.. "body{font:15px/1.5 system-ui,sans-serif;margin:2em auto;max-width:60em;padding:0 1em}"
			.. "pre{white-space:pre-wrap;word-break:break-word;border:1px solid;padding:1em;border-radius:6px}</style>",
		"</head><body>",
		"<h1>" .. escape_html(title) .. "</h1>",
		"<p>" .. escape_html(lead) .. "</p>",
		"<pre>" .. escape_html(text) .. "</pre>",
		"</body></html>",
		"",
	}, "\n")
end

--- Delivers the diagnostics report when no window can show it: the approved
--- report of a fresh snapshot is written as a self-contained HTML file in the
--- logs' diagnostics folder, opened in the default browser, and a notice names
--- the file. The diagnostics must never depend on the component they diagnose.
--- @param info table { component = string|nil, locale = string } from the webview manager.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return boolean delivered Whether the file was written and its opening started.
function M.deliver_without_window(info, overrides)
	local effects = effects_with(overrides)
	local I18n = require("core.i18n.engine.i18n")
	local component = type(info) == "table" and info.component or nil
	local locale = type(info) == "table" and type(info.locale) == "string" and info.locale or I18n.get_locale()
	-- The diagnostics window's own name titles the page and the notice
	local title = I18n.get(require("core.ui.engine.window_titles").key_for_app("healthcheck"))
	Logger.start(LOG, "Writing the diagnostics report to a file: no window can show it…")
	local ok, path = xpcall(function()
		local snapshot, documents = menu_snapshot(true)
		local dir = snapshot.sections.paths.diagnostics_dir
		if type(dir) ~= "string" or dir == "" then error("the diagnostics folder is unknown") end
		local document = Share.document(snapshot, documents.schema, I18n.get(documents.schema.share_policy.notice_key))
		local suffix = documents.schema.report.name_suffix
		assert(document.name:sub(-#suffix) == suffix, "the report name does not end with the schema's suffix")
		local html = M.render_html(title, I18n.get("healthcheck.file_fallback.lead"), document.text, locale)
		local written, detail = effects.save(dir, document.name:sub(1, -#suffix - 1) .. ".html", html)
		if not written then error("the report could not be saved: " .. tostring(detail)) end
		return written
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "The diagnostics report could not be written to a file: %s", tostring(path))
		return false
	end
	Logger.success(LOG, "Diagnostics report written to %s.", path)
	local request, refusal = effects.open(path, function(receipt)
		if type(receipt) ~= "table" or receipt.ok ~= true then
			Logger.warn(LOG, "The browser did not open the diagnostics report (status=%s, reason=%s).",
				tostring(type(receipt) == "table" and receipt.code), tostring(type(receipt) == "table" and receipt.error))
		end
	end, function() return true end)
	if request == nil then
		Logger.warn(LOG, "The browser could not be asked to open the diagnostics report: %s.", tostring(refusal))
	end
	local body = I18n.get(component and "healthcheck.file_fallback.notice_missing" or "healthcheck.file_fallback.notice")
		:gsub("{1}", function() return path end)
		:gsub("{2}", function() return component or "" end)
	effects.notify(title, body, "info")
	return true
end

--- Opens the GitHub feature form with the version and the system prefilled.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @return table|nil cancellable request; completion receives the child outcome.
function M.suggest_feature(overrides, complete)
	return menu_request(ConfigKeys.COMMAND.SUGGEST_FEATURE, overrides, complete, function(owner)
		local snapshot, documents = menu_snapshot()
		local document = Share.document(snapshot, documents.schema,
			require("core.i18n.engine.i18n").get(documents.schema.share_policy.notice_key))
		local url = IssueLink.build_url(documents.templates, documents.repository, "feature", document.fields)
		return M.perform({ action = ConfigKeys.COMMAND.SUGGEST_FEATURE, url = url }, {}, documents, {}, overrides, nil, owner)
	end)
end

return M
