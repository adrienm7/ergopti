--- tests/unit/ui/test_healthcheck_report_issue.lua

--- ==============================================================================
--- MODULE: Diagnostics Page Actions And Report A Bug (Linux)
--- DESCRIPTION:
--- The diagnostics page asks, the host does (ui.healthcheck.report.perform):
--- copy the report, save it as a Markdown file under the logs folder and open
--- that folder, report it on GitHub (copy the report, then open the bug form
--- with that whole report prefilled, the browser last so the form keeps the
--- focus), open a folder it collected.
--- Whatever the page sent, the home folder and the account name reach neither
--- the clipboard, the file nor the URL (report-bug-flow). Debug > Report a bug
--- opens the window at its preview.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Share = require("healthcheck.share")

local HOME = "/home/jdoe"
local LOGS_DIR = "/var/tmp/ergopti_report_logs"
local NAME = "ergopti-diagnostics-linux-2026-09-24T10_00_00Z.md"
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
	local schema = shared_json("modules/diagnostics/schema.json")
	schema.export_strings = shared_json("data/locales/en.json")
	return {
		schema     = schema,
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

--- Wraps recorded side effects so their order is kept in calls.order.
--- @param calls table
--- @param overrides table
local function ordered(calls, overrides)
	calls.order = {}
	for name, fn in pairs(overrides) do
		if name ~= "identity" then
			overrides[name] = function(...)
				calls.order[#calls.order + 1] = name
				return fn(...)
			end
		end
	end
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

local function host_snapshot(long)
	local snapshot = { schema_version = 2, driver = "linux", generated_at = "2026-09-24T10:00:00Z",
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
--- @param adjust function|nil Changes the recorded side effects.
--- @return table result, table calls
local function perform(action, adjust)
	local Report = helpers.load_module("ui.healthcheck.report")
	local calls = {}
	local overrides = recording(calls)
	ordered(calls, overrides)
	if adjust then adjust(overrides) end
	local paths = { logs_dir = LOGS_DIR, diagnostics_dir = LOGS_DIR .. "/diagnostics" }
	local snapshot = host_snapshot(type(action.text) == "string" and #action.text > documents().templates.max_url_bytes)
	if action.action == "copy" or action.action == "save" or action.action == "report" then
		local request = {}
		for key, value in pairs(action) do request[key] = value end
		request.text = approved_text(type(action.text) == "string" and #action.text > documents().templates.max_url_bytes)
		action = request
	end
	return Report.perform(action, paths, documents(), Report.redaction_context(overrides), overrides, snapshot), calls
end

helpers.describe("healthcheck page actions (linux)", function()
	helpers.it("report copies, then opens the bug form with the whole report, all redacted (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = {
			version = "2.4.0", os = "Fedora Linux 41 (/home/jdoe)", driver = "linux",
		} })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.copy, { approved_text(false) })
		helpers.assert_eq(result.path, calls.reveal[1], "the complete local attachment is returned")
		helpers.assert_eq(query_value(calls.open_url[1], "diagnostics"), Share.document(host_snapshot(false), documents().schema, "ignored locale").summary,
			"the form receives only the short English attachment summary")
		helpers.assert_eq(query_value(calls.open_url[1], "os"), "linux")
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
		helpers.assert_contains(calls.open_url[1], "driver=linux")
		helpers.assert_true(not calls.open_url[1]:find("jdoe", 1, true), "the URL carries no account name")
	end)

	-- The report used to be saved and its folder opened too: the file manager
	-- came up after the browser and took the focus from the form (report-focus)
	helpers.it("report saves its attachment and opens the browser last (report-focus)", function()
		local _, calls = perform({ action = "report", text = REPORT, fields = { driver = "linux" } })
		helpers.assert_eq(#calls.save, 1, "a report saves the complete local attachment")
		helpers.assert_eq(#calls.reveal, 1, "the attachment is revealed before the browser")
		helpers.assert_eq(#calls.open, 0, "a report opens no folder")
		helpers.assert_eq(#calls.notify, 0, "a report raises no notification")
		helpers.assert_eq(calls.order, { "copy", "save", "reveal", "open_url" }, "the browser opens last, after the clipboard and local attachment")
	end)

	helpers.it("report cuts a long report in the URL and keeps it whole in the clipboard (report-bug-flow)", function()
		local long = REPORT .. string.rep("line of diagnostics é\n", 2000)
		local result, calls = perform({ action = "report", text = long, fields = { version = "2.4.0", driver = "linux" } })
		helpers.assert_eq(result.ok, true)
		local templates = documents().templates
		helpers.assert_true(#calls.copy[1] > templates.max_url_bytes, "the fixture exceeds the URL budget")
		local url = calls.open_url[1]
		helpers.assert_true(#url <= templates.max_url_bytes, "the URL fits its budget")
		helpers.assert_eq(query_value(url, "version"), "2.4.0", "the identity fields survive the cut")
		local prefilled = query_value(url, "diagnostics")
		helpers.assert_eq(prefilled, Share.document(host_snapshot(true), documents().schema, "ignored locale").summary, "long output never expands the issue form")
		helpers.assert_true(#url < 1200, "the editable URL stays short independently of report length")
		helpers.assert_eq(calls.save[1].text, calls.copy[1], "the saved attachment preserves the whole report")
	end)

	helpers.it("report stops before the browser when the clipboard refuses (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = { driver = "linux" } },
			function(overrides) overrides.copy = function() return false end end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.save, 0, "nothing is saved")
		helpers.assert_eq(#calls.open_url, 0, "the form never opens without its report")
	end)

	helpers.it("save still writes the redacted report and opens its folder", function()
		local result, calls = perform({ action = "save", text = REPORT, name = NAME })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#calls.copy, 0, "saving leaves the clipboard alone")
		helpers.assert_eq(calls.save[1].dir, LOGS_DIR .. "/diagnostics")
		helpers.assert_true(not calls.save[1].text:find(HOME, 1, true), "the file carries no home folder")
		helpers.assert_eq(calls.reveal, { LOGS_DIR .. "/diagnostics/" .. NAME })
	end)

	helpers.it("open_path opens the folder the host collected, creating it first", function()
		local result, calls = perform({ action = "open_path", id = "diagnostics_dir" })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.make_dir, { LOGS_DIR .. "/diagnostics" })
		helpers.assert_eq(calls.open, { LOGS_DIR .. "/diagnostics" })
	end)

	-- Today's errors file exists only once something went wrong today, so
	-- asking to open it earlier is no failure of the program. It was logged as
	-- an ERROR, which created that very file, counted as a session error and
	-- would raise the error dialog (open-missing-file)
	helpers.it("open_path on a file not created yet says so, without an error (open-missing-file)", function()
		local Logger = require("logger")
		local emitted = 0
		Logger.set_sink(function(_, variant)
			if variant == "warn" or variant == "error" then emitted = emitted + 1 end
		end)
		local ok, result, calls = pcall(function()
			local Report = helpers.load_module("ui.healthcheck.report")
			local recorded = {}
			local overrides = recording(recorded)
			overrides.exists = function() return false end
			return Report.perform({ action = "open_path", id = "errors_today" },
				{ errors_today = LOGS_DIR .. "/ergopti_plus_errors_2026-09-24.log" }, documents(),
				Report.redaction_context(overrides), overrides), recorded
		end)
		Logger.set_sink(nil)
		helpers.assert_true(ok, tostring(result))
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.missing, true, "the page is told the file does not exist yet")
		helpers.assert_eq(#calls.open, 0)
		helpers.assert_eq(#calls.make_dir, 0, "a file is never created")
		helpers.assert_eq(emitted, 0, "a file not created yet is neither an error nor a warning")
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
		local previous_bridge = package.loaded["ui.healthcheck.bridge"]
		local previous_manager = package.loaded["ui.webview_manager"]
		package.loaded["ui.healthcheck.bridge"] = { DRIVER = "linux", config = documents,
			build_snapshot = function() return host_snapshot(false) end }
		package.loaded["ui.webview_manager"] = { get_daemon_state = function() return {} end }
		local ok, result = pcall(Report.suggest_feature, recording(calls))
		package.loaded["ui.healthcheck.bridge"] = previous_bridge
		package.loaded["ui.webview_manager"] = previous_manager
		helpers.assert_true(ok, tostring(result))
		helpers.assert_eq(result, true)
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
			.. "/issues/new?template=feature_request.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
		helpers.assert_contains(calls.open_url[1], "driver=linux")
		helpers.assert_eq(#calls.copy, 0, "a feature request copies nothing")
	end)
end)


-- These adapter receipts are simulated; the native fixture separately exercises
-- real regular-file write and close failures through the production save effect.
helpers.describe("healthcheck checked save receipts (linux)", function()
	local function default_save(write, mkdir_ok, reveal_ok)
		local saved_fs = package.loaded["adapters.file_system"]
		local saved_shell = package.loaded["adapters.shell_runner"]
		local writes, directories = {}, {}
		package.loaded["adapters.file_system"] = { write = function(path, text)
			writes[#writes + 1] = { path = path, text = text }
			return write(path, text)
		end }
		package.loaded["adapters.shell_runner"] = {
			quote = function(value) return "'" .. value .. "'" end,
			run = function(command) directories[#directories + 1] = command; return mkdir_ok ~= false end,
		}
		local ok, result, calls = pcall(function()
			return perform({ action = "save", text = REPORT, name = NAME }, function(overrides)
				overrides.save = nil
				if reveal_ok == false then overrides.reveal = function() return false end end
			end)
		end)
		package.loaded["adapters.file_system"] = saved_fs
		package.loaded["adapters.shell_runner"] = saved_shell
		helpers.assert_true(ok, tostring(result))
		return result, calls, writes, directories
	end

	helpers.it("save requires the filesystem's completed write receipt (report-save-receipt)", function()
		local result, calls, writes, directories = default_save(function() return true end)
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(writes, { { path = LOGS_DIR .. "/diagnostics/" .. NAME,
			text = approved_text(false) } })
		helpers.assert_eq(#directories, 1)
		helpers.assert_eq(calls.reveal, { result.path })
	end)

	for _, receipt in ipairs({ "false", "nil", "zero", "string", "throw" }) do
		helpers.it("save refuses the filesystem " .. receipt .. " receipt before reveal (report-save-receipt)", function()
			local result, calls, writes = default_save(function()
				if receipt == "false" then return false end
				if receipt == "nil" then return nil end
				if receipt == "zero" then return 0 end
				if receipt == "string" then return "true" end
				error("simulated adapter exception")
			end)
			helpers.assert_eq(#writes, 1)
			helpers.assert_eq(result.ok, false)
			helpers.assert_nil(result.path)
			helpers.assert_eq(#calls.reveal, 0)
		end)
	end

	helpers.it("save refuses directory creation before acquiring a write (report-save-receipt)", function()
		local result, calls, writes = default_save(function() return true end, false)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#writes, 0)
		helpers.assert_eq(#calls.reveal, 0)
	end)

	helpers.it("save keeps a completed file successful when revealing its folder fails (report-save-receipt)", function()
		local result, _, writes = default_save(function() return true end, true, false)
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(result.path, LOGS_DIR .. "/diagnostics/" .. NAME)
		helpers.assert_eq(#writes, 1)
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
				assert(readable:find("## " .. config.schema.export_strings["healthcheck.section." .. id], 1, true), "readable section omitted")
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

helpers.describe("English attachment export boundaries", function()
	helpers.it("does not consult localized labels or copy free private fields", function()
		local config = documents()
		local doc = Share.document(host_snapshot(false), config.schema, "LOCALIZED-EXPORT-CANARY")
		helpers.assert_true(not doc.text:find("LOCALIZED-EXPORT-CANARY", 1, true))
		helpers.assert_contains(doc.text, config.schema.export_strings[config.schema.share_policy.notice_key])
		helpers.assert_true(not doc.text:find(HOME, 1, true))
	end)
	helpers.it("retains clipboard and refuses browser when attachment save fails", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = {} },
			function(overrides) overrides.save = function() return nil, "inert write refusal" end end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.copy, 1)
		helpers.assert_eq(#calls.reveal, 0)
		helpers.assert_eq(#calls.open_url, 0)
	end)
	helpers.it("browser refusal never claims successful report after saving attachment", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = {} },
			function(overrides) overrides.open_url = function() return false end end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.save, 1)
		helpers.assert_eq(calls.save[1].text, calls.copy[1])
	end)
end)
