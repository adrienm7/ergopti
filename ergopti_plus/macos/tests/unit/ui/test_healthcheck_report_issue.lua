--- tests/unit/ui/test_healthcheck_report_issue.lua

--- ==============================================================================
--- MODULE: Diagnostics Page Actions And Report A Bug (macOS)
--- DESCRIPTION:
--- The diagnostics page asks, the host does (ui.healthcheck.report.perform):
--- copy the report, save it as a Markdown file under the logs folder and
--- reveal it, report it on GitHub (copy the report, then open the bug form
--- with that whole report prefilled, the browser last so the form keeps the
--- focus), open a folder it collected or a settings page the schema declares.
--- Whatever the page sent, the home folder and the account name reach neither
--- the clipboard, the file nor the URL (report-bug-flow). Debug > Report a bug
--- opens the window at its preview.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Share = require("healthcheck.share")

local HOME = "/Users/jdoe"
local LOGS = HOME .. "/Library/Logs/ergopti_plus"
local NAME = "ergopti-diagnostics-macos-2026-09-24T10_00_00Z.md"
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
	-- Every side effect in the order it ran, to prove what runs last
	calls.order = {}
	for name, fn in pairs(overrides) do
		if name ~= "identity" then
			overrides[name] = function(...)
				calls.order[#calls.order + 1] = name
				return fn(...)
			end
		end
	end
	return Report, calls, overrides
end

--- Decodes one percent-encoded query parameter of a URL.
--- @param url string
--- @param key string
--- @return string|nil
local function query_value(url, key)
	local raw = url:match("[?&]" .. key .. "=([^&]*)")
	if raw == nil then return nil end
	return (raw:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
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

local function host_snapshot(long)
	local snapshot = { schema_version = 2, driver = "macos", generated_at = "2026-09-24T10:00:00Z",
		sections = { versions = { ergopti_version = "2.4.0" }, issues = { recent = REPORT } },
		probes = { github_api = { state = "error", cleanup = "pending", ms = 1 } } }
	if long then
		snapshot.retired_probes = {}
		for index = 1, 300 do
			snapshot.retired_probes[index] = { probes = { github_api = { state = "timeout", cleanup = "unknown", ms = index } } }
		end
	end
	return snapshot
end

local function approved_text(long)
	local config = documents()
	return Share.document(host_snapshot(long), config.schema,
		require("infra.i18n").get(config.schema.share_policy.notice_key)).text
end

--- Performs one action as the bridge does.
--- @param action table
--- @return table result, table calls
local function perform(action, adjust)
	local Report, calls, overrides = load_report()
	if adjust then adjust(overrides) end
	local context = Report.redaction_context(overrides)
	local snapshot = host_snapshot(type(action.text) == "string" and #action.text > documents().templates.max_url_bytes)
	if action.action == "copy" or action.action == "save" or action.action == "report" then
		local request = {}
		for key, value in pairs(action) do request[key] = value end
		request.text = approved_text(type(action.text) == "string" and #action.text > documents().templates.max_url_bytes)
		action = request
	end
	return Report.perform(action, paths(), documents(), context, overrides, snapshot), calls
end

helpers.describe("healthcheck page actions (report-bug-flow)", function()
	helpers.it("report copies, then opens the bug form with the whole report, all redacted (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = {
			version = "2.4.0", os = "macOS 15.1 (/Users/jdoe)", driver = "macos",
		} })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#calls.copy, 1)
		helpers.assert_eq(calls.copy[1], approved_text(false))
		helpers.assert_eq(result.path, nil, "a report names no file")

		local url = calls.open_url[1]
		helpers.assert_eq(query_value(url, "diagnostics"), calls.copy[1],
			"the form's diagnostics field is the report the clipboard holds")
		helpers.assert_eq(query_value(url, "os"), "macos")
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&"
		helpers.assert_eq(url:sub(1, #prefix), prefix)
		helpers.assert_contains(url, "driver=macos")
		helpers.assert_true(not url:find("jdoe", 1, true), "the URL carries no account name: " .. url)
		helpers.assert_true(not url:find("%2FUsers%2F", 1, true), "the URL carries no home folder: " .. url)
	end)

	-- The report used to be saved and revealed in Finder too: the reveal
	-- finished after the browser opened, so Finder took the focus from the
	-- form (report-focus)
	helpers.it("report saves nothing, reveals nothing and opens the browser last (report-focus)", function()
		local _, calls = perform({ action = "report", text = REPORT, fields = { driver = "macos" } })
		helpers.assert_eq(#calls.save, 0, "a report saves no file")
		helpers.assert_eq(#calls.reveal, 0, "a report reveals nothing in Finder")
		helpers.assert_eq(#calls.open, 0, "a report opens no folder")
		helpers.assert_eq(calls.order, { "copy", "open_url" }, "the browser opens last, after the clipboard")
	end)

	helpers.it("report cuts a long report in the URL and keeps it whole in the clipboard (report-bug-flow)", function()
		local long = REPORT .. string.rep("line of diagnostics é\n", 2000)
		local result, calls = perform({ action = "report", text = long, fields = { version = "2.4.0", driver = "macos" } })
		helpers.assert_eq(result.ok, true)
		local templates = documents().templates
		helpers.assert_eq(#calls.copy[1] > templates.max_url_bytes, true, "the fixture exceeds the URL budget")
		local url = calls.open_url[1]
		helpers.assert_true(#url <= templates.max_url_bytes, "the URL fits its budget")
		helpers.assert_eq(query_value(url, "version"), "2.4.0", "the identity fields survive the cut")
		local prefilled = query_value(url, "diagnostics")
		local marker = templates.truncation_marker
		helpers.assert_eq(prefilled:sub(-#marker), marker, "the cut report ends with the truncation marker")
		local kept = prefilled:sub(1, #prefilled - #marker)
		helpers.assert_eq(calls.copy[1]:sub(1, #kept), kept, "the prefill is the start of the copied report")
	end)

	helpers.it("report stops before the browser when the clipboard refuses (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = { driver = "macos" } },
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
				return { driver = "macos", sections = { versions = { ergopti_version = "2.4.0" }, system = { os = "macOS 15.1" } } }
			end,
		}
		helpers.assert_eq(Report.suggest_feature(overrides), true)
		package.loaded["ui.healthcheck.core"] = nil
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
			.. "/issues/new?template=feature_request.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
		helpers.assert_contains(calls.open_url[1], "version=2.4.0")
		helpers.assert_contains(calls.open_url[1], "os=macos")
		helpers.assert_contains(calls.open_url[1], "driver=macos")
		helpers.assert_eq(#calls.copy, 0, "a feature request copies nothing")
	end)
end)


helpers.describe("closed diagnostic sharing corpus", function()
	helpers.it("excludes synthetic private fields on all driver snapshots", function()
		local corpus = shared_json("tests/corpus/healthcheck/share_vectors.json")
		local config = documents()
		for _, vector in ipairs(corpus.vectors) do
			local document = Share.document(vector.snapshot, config.schema,
				require("infra.i18n").get(config.schema.share_policy.notice_key))
			for _, canary in ipairs(vector.canaries) do
				helpers.assert_true(not document.text:find(canary, 1, true), vector.name)
			end
			local readable = document.text:match("^(.-)```json")
			for _, id in ipairs({ "versions", "hardware", "system", "input", "ai", "permissions", "issues" }) do
				assert(readable:find("## " .. require("infra.i18n").get("healthcheck.section." .. id), 1, true), "readable section omitted")
			end
			assert(readable:find("| probes.appleevent_transport.native_status | -1744 |", 1, true))
			assert(readable:find("| probes.appleevent_transport.cleanup | pending |", 1, true))
			assert(readable:find("| retired_probes.1.probes.appleevent_transport.cleanup | unknown |", 1, true))
			helpers.assert_eq(document.snapshot.probes.appleevent_transport.state, "timeout")
			helpers.assert_eq(document.snapshot.probes.appleevent_transport.cleanup, "pending")
			helpers.assert_eq(document.snapshot.probes.appleevent_transport.native_status, -1744)
		end
	end)
end)
