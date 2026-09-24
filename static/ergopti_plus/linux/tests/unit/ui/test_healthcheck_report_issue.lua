--- tests/unit/ui/test_healthcheck_report_issue.lua

--- ==============================================================================
--- MODULE: Diagnostics Page Actions And Report A Bug (Linux)
--- DESCRIPTION:
--- The diagnostics page asks, the host does (ui.healthcheck.report.perform):
--- copy the report, save it as a Markdown file under the logs folder and open
--- that folder, report it on GitHub (copy, save, open the folder, then open the
--- bug form with the page's short summary), open a folder it collected.
--- Whatever the page sent, the home folder and the account name reach neither
--- the clipboard, the file nor the URL (report-bug-flow). Debug > Report a bug
--- opens the window at its preview.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local HOME = "/home/jdoe"
local LOGS_DIR = "/var/tmp/ergopti_report_logs"
local NAME = "ergopti-diagnostics-linux-2.4.0-20260924T100000Z.md"
local REPORT = "# ErgoptiPlus diagnostics\n\nconfig_dir: /home/jdoe/.config/ergopti_plus (jdoe)\n"

--- Reads a shared JSON document.
--- @param rel string Path under _shared/.
--- @return table
local function shared_json(rel)
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/" .. rel, "rb"))
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

--- Side effects that record every call instead of acting.
--- @param calls table Receives the calls by name.
--- @return table overrides
local function recording(calls)
	for _, name in ipairs({ "copy", "save", "reveal", "make_dir", "open", "open_url", "notify" }) do calls[name] = {} end
	return {
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
		notify = function(_, _, level) calls.notify[#calls.notify + 1] = level; return true end,
	}
end

--- Performs one action as the bridge does.
--- @param action table
--- @param adjust function|nil Changes the recorded side effects.
--- @return table result, table calls
local function perform(action, adjust)
	local Report = helpers.load_module("ui.healthcheck.report")
	local calls = {}
	local overrides = recording(calls)
	if adjust then adjust(overrides) end
	local paths = { logs_dir = LOGS_DIR, diagnostics_dir = LOGS_DIR .. "/diagnostics" }
	return Report.perform(action, paths, documents(), Report.redaction_context(overrides), overrides), calls
end

helpers.describe("healthcheck page actions (linux)", function()
	helpers.it("report copies, saves, reveals, then opens the bug form, all redacted (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, name = NAME, fields = {
			version = "2.4.0", os = "Fedora Linux 41", driver = "linux",
			diagnostics = "Errors: 1 — log at /home/jdoe/.local/state",
		} })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.copy, { "# ErgoptiPlus diagnostics\n\nconfig_dir: ~/.config/ergopti_plus (<user>)\n" })
		helpers.assert_eq(calls.save[1].dir, LOGS_DIR .. "/diagnostics")
		helpers.assert_eq(calls.save[1].text, calls.copy[1], "the saved file is what was copied")
		helpers.assert_eq(calls.reveal[1], LOGS_DIR .. "/diagnostics/" .. NAME)
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
		helpers.assert_contains(calls.open_url[1], "driver=linux")
		helpers.assert_true(not calls.open_url[1]:find("jdoe", 1, true), "the URL carries no account name")
	end)

	helpers.it("report stops before the browser when the clipboard refuses (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, name = NAME, fields = { driver = "linux" } },
			function(overrides) overrides.copy = function() return false end end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.save, 0, "nothing is saved")
		helpers.assert_eq(#calls.open_url, 0, "the form never opens without its report")
	end)

	helpers.it("open_path opens the folder the host collected, creating it first", function()
		local result, calls = perform({ action = "open_path", id = "diagnostics_dir" })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.make_dir, { LOGS_DIR .. "/diagnostics" })
		helpers.assert_eq(calls.open, { LOGS_DIR .. "/diagnostics" })
	end)

	helpers.it("refuses to redact without the home folder (report-bug-flow)", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local ok, err = pcall(Report.redaction_context, { identity = function() return { user = "jdoe" } end })
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(err), "home folder")
	end)
end)

helpers.describe("healthcheck debug menu reports (linux)", function()
	helpers.it("Report a bug opens the diagnostics window at its preview", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local saved = package.loaded["ui.healthcheck.bridge"]
		local mode = nil
		package.loaded["ui.healthcheck.bridge"] = { open = function(value) mode = value; return true end }
		local ok, opened = pcall(Report.report_bug)
		package.loaded["ui.healthcheck.bridge"] = saved
		helpers.assert_true(ok, tostring(opened))
		helpers.assert_eq(opened, true)
		helpers.assert_eq(mode, "report")
	end)

	helpers.it("Suggest a feature opens the feature form with the version and the system", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local calls = {}
		helpers.assert_eq(Report.suggest_feature(recording(calls)), true)
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
			.. "/issues/new?template=feature_request.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
		helpers.assert_contains(calls.open_url[1], "driver=linux")
		helpers.assert_eq(#calls.copy, 0, "a feature request copies nothing")
	end)
end)
