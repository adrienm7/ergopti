--- tests/unit/ui/test_healthcheck_report_issue.lua

--- ==============================================================================
--- MODULE: Diagnostics Page Actions And Report A Bug (macOS)
--- DESCRIPTION:
--- The diagnostics page asks, the host does (ui.healthcheck.report.perform):
--- copy the report, save it as a Markdown file under the logs folder and
--- reveal it, report it on GitHub (copy, save, reveal, then open the bug form
--- with the page's short summary), open a folder it collected or a settings
--- page the schema declares. Whatever the page sent, the home folder and the
--- account name reach neither the clipboard, the file nor the URL
--- (report-bug-flow). Debug > Report a bug opens the window at its preview.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local HOME = "/Users/jdoe"
local LOGS = HOME .. "/Library/Logs/ergopti_plus"
local NAME = "ergopti-diagnostics-macos-2.4.0-20260924T100000Z.md"
local REPORT = "# ErgoptiPlus diagnostics\n\nconfig_dir: /Users/jdoe/.config/ergopti_plus (jdoe)\n"

--- Reads a shared JSON document.
--- @param rel string Path under _shared/.
--- @return table
local function shared_json(rel)
	local fh = assert(io.open(helpers.shared(rel), "rb"))
	local data = Json.decode(fh:read("*a"))
	fh:close()
	return data
end

--- The documents a host works from, read from their single sources.
--- @return table
local function documents()
	return {
		schema     = shared_json("modules/diagnostics/schema.json"),
		templates  = shared_json("modules/diagnostics/issue_templates.json"),
		redaction  = shared_json("modules/diagnostics/redaction.json"),
		repository = shared_json("modules/updater/defaults.json").github,
	}
end

--- Loads the report module with every side effect recorded.
--- @return table Report, table calls, table overrides
local function load_report()
	helpers.load_with_stubs("infra.logger")
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["ui.healthcheck.report"] = nil
	local Report = require("ui.healthcheck.report")
	local calls = { copy = {}, save = {}, reveal = {}, open = {}, open_url = {}, make_dir = {} }
	local overrides = {
		identity = function() return { home = HOME, user = "jdoe" } end,
		copy = function(text) calls.copy[#calls.copy + 1] = text; return true end,
		save = function(dir, name, text)
			calls.save[#calls.save + 1] = { dir = dir, name = name, text = text }
			return dir .. "/" .. name
		end,
		reveal = function(path) calls.reveal[#calls.reveal + 1] = path; return true end,
		make_dir = function(dir) calls.make_dir[#calls.make_dir + 1] = dir; return true end,
		exists = function() return true end,
		open = function(target) calls.open[#calls.open + 1] = target; return true end,
		open_url = function(url) calls.open_url[#calls.open_url + 1] = url; return true end,
		notify = function() return true end,
	}
	return Report, calls, overrides
end

--- The snapshot's paths section of the fixture.
--- @return table
local function paths()
	return {
		config_dir = HOME .. "/.config/ergopti_plus",
		logs_dir = LOGS,
		diagnostics_dir = LOGS .. "/diagnostics",
	}
end

--- Performs one action as the bridge does.
--- @param action table
--- @return table result, table calls
local function perform(action, adjust)
	local Report, calls, overrides = load_report()
	if adjust then adjust(overrides) end
	local context = Report.redaction_context(overrides)
	return Report.perform(action, paths(), documents(), context, overrides), calls
end

helpers.describe("healthcheck page actions (report-bug-flow)", function()
	helpers.it("report copies, saves, reveals, then opens the bug form, all redacted (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, name = NAME, fields = {
			version = "2.4.0", os = "macOS 15.1", driver = "macos",
			diagnostics = "Errors: 1 — log at /Users/jdoe/Library/Logs",
		} })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#calls.copy, 1)
		helpers.assert_eq(calls.copy[1], "# ErgoptiPlus diagnostics\n\nconfig_dir: ~/.config/ergopti_plus (<user>)\n")
		helpers.assert_eq(calls.save[1].dir, LOGS .. "/diagnostics")
		helpers.assert_eq(calls.save[1].name, NAME)
		helpers.assert_eq(calls.save[1].text, calls.copy[1], "the saved file is what was copied")
		helpers.assert_eq(calls.reveal[1], LOGS .. "/diagnostics/" .. NAME)
		helpers.assert_eq(result.path, LOGS .. "/diagnostics/" .. NAME)

		local url = calls.open_url[1]
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&"
		helpers.assert_eq(url:sub(1, #prefix), prefix)
		helpers.assert_contains(url, "driver=macos")
		helpers.assert_true(not url:find("jdoe", 1, true), "the URL carries no account name: " .. url)
		helpers.assert_true(not url:find("%2FUsers%2F", 1, true), "the URL carries no home folder: " .. url)
	end)

	helpers.it("report stops before the browser when the clipboard refuses (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, name = NAME, fields = { driver = "macos" } },
			function(overrides) overrides.copy = function() return false end end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.save, 0, "nothing is saved")
		helpers.assert_eq(#calls.open_url, 0, "the form never opens without its report")
	end)

	helpers.it("save writes the redacted report under the diagnostics folder and reveals it", function()
		local result, calls = perform({ action = "save", text = REPORT, name = NAME })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#calls.copy, 0, "saving leaves the clipboard alone")
		helpers.assert_true(not calls.save[1].text:find(HOME, 1, true), "the file carries no home folder")
		helpers.assert_eq(calls.reveal[1], LOGS .. "/diagnostics/" .. NAME)
	end)

	helpers.it("open_path opens the folder the host collected, creating it first", function()
		local result, calls = perform({ action = "open_path", id = "diagnostics_dir" })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.make_dir, { LOGS .. "/diagnostics" })
		helpers.assert_eq(calls.open, { LOGS .. "/diagnostics" })
	end)

	helpers.it("open_path refuses a field the snapshot has no value for", function()
		local result, calls = perform({ action = "open_path", id = "crash_dir" })
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.open, 0)
	end)

	-- Today's errors file exists only once something went wrong today, so
	-- asking to open it earlier is no failure of the program. It was logged as
	-- an ERROR, which created that very file, counted as a session error and
	-- would raise the error dialog (open-missing-file)
	helpers.it("open_path on a file not created yet says so, without an error (open-missing-file)", function()
		local Report, calls, overrides = load_report()
		local logged = {}
		local Logger = package.loaded["infra.logger"]
		Logger.error = function(_, message, ...) logged[#logged + 1] = string.format(message, ...) end
		Logger.warn = Logger.error
		overrides.exists = function() return false end
		local result = Report.perform({ action = "open_path", id = "errors_today" },
			{ errors_today = LOGS .. "/ErgoptiPlus_errors_2026-09-24.log" }, documents(),
			Report.redaction_context(overrides), overrides)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.missing, true, "the page is told the file does not exist yet")
		helpers.assert_eq(#calls.open, 0)
		helpers.assert_eq(#calls.make_dir, 0, "a file is never created")
		helpers.assert_eq(logged, {}, "a file not created yet is neither an error nor a warning")
	end)

	helpers.it("open_settings opens the page the schema declares", function()
		local result, calls = perform({ action = "open_settings", id = "input_monitoring",
			url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.open, { "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" })
	end)

	helpers.it("refuses to redact without the home folder (report-bug-flow)", function()
		local Report, _, overrides = load_report()
		-- Nothing could remove the home folder, so every path under it would leak
		overrides.identity = function() return { user = "jdoe" } end
		local ok, err = pcall(Report.redaction_context, overrides)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(err), "home folder")
	end)
end)

helpers.describe("healthcheck debug menu reports (report-bug-flow)", function()
	helpers.it("Report a bug opens the diagnostics window at its preview", function()
		local Report = load_report()
		local opened = nil
		package.loaded["ui.healthcheck.core"] = { show_window = function(opts) opened = opts; return true end }
		local state = { keymap = true }
		helpers.assert_eq(Report.report_bug({ state = state }), true)
		helpers.assert_eq(opened.mode, "report")
		helpers.assert_true(opened.state == state, "the menu state reaches the features section")
		package.loaded["ui.healthcheck.core"] = nil
	end)

	helpers.it("Suggest a feature opens the feature form with the version and the system", function()
		local Report, calls, overrides = load_report()
		package.loaded["ui.healthcheck.core"] = {
			DRIVER = "macos",
			config = documents,
			run = function()
				return { sections = { versions = { ergopti_version = "2.4.0" }, system = { os = "macOS 15.1" } } }
			end,
		}
		helpers.assert_eq(Report.suggest_feature(overrides), true)
		package.loaded["ui.healthcheck.core"] = nil
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
			.. "/issues/new?template=feature_request.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
		helpers.assert_contains(calls.open_url[1], "version=2.4.0")
		helpers.assert_contains(calls.open_url[1], "os=macOS%2015.1")
		helpers.assert_contains(calls.open_url[1], "driver=macos")
		helpers.assert_eq(#calls.copy, 0, "a feature request copies nothing")
	end)
end)
