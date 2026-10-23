--- tests/unit/ui/healthcheck/test_healthcheck_report_issue.lua

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
--- runs that report action on a fresh snapshot, without the window.
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
		reveal = function(path, done) calls.reveal[#calls.reveal + 1] = path; done({ ok = true, code = 0 }) end,
		make_dir = function(dir) calls.make_dir[#calls.make_dir + 1] = dir; return true end,
		exists = function() return true end,
		open = function(target, done) calls.open[#calls.open + 1] = target; done({ ok = true, code = 0 }) end,
		open_url = function(url, done) calls.open_url[#calls.open_url + 1] = url; done({ ok = true, code = 0 }) end,
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

--- Receives the explicit completion from these deliberately inline effect ports.
local function completed(Report, action, paths, config, context, overrides, snapshot)
	local answer
	Report.perform(action, paths, config, context, overrides, snapshot, {
		current = function() return true end, complete = function(result) answer = result end,
	})
	assert(answer ~= nil, "the inline fixture must deliver its completion")
	return answer
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
	return completed(Report, action, paths, documents(), Report.redaction_context(overrides), overrides, snapshot), calls
end

helpers.describe("healthcheck page actions (linux)", function()
	helpers.it("report copies, then opens the bug form with the whole report, all redacted (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = {
			version = "2.4.0", os = "Fedora Linux 41 (/home/jdoe)", driver = "linux",
		} })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(calls.copy, { approved_text(false) })
		helpers.assert_eq(result.path, calls.reveal[1], "the complete local attachment is returned")
		helpers.assert_eq(query_value(calls.open_url[1], "diagnostics"), nil,
			"the form receives no query default that could reset an edit")
		helpers.assert_eq(query_value(calls.open_url[1], "os"), "linux")
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&version=2.4.0&os=linux&driver=linux"
		helpers.assert_eq(calls.open_url[1], prefix, "the canonical bug URL contains only stable host metadata")
		helpers.assert_eq(query_value(calls.open_url[1], "driver"), "linux")
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
		helpers.assert_eq(query_value(url, "version"), "2.4.0", "only validated host identity is prefilled")
		local prefilled = query_value(url, "diagnostics")
		helpers.assert_eq(prefilled, nil, "long output never prefills or resets the issue form")
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
			return completed(Report, { action = "open_path", id = "errors_today" },
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
	--- Runs Debug > Report a bug over a stubbed bridge and recorded effects.
	--- @param adjust function|nil Edits the recorded overrides.
	--- @return boolean|nil outcome, table calls, boolean window_opened
	local function menu_report_bug(adjust)
		local Report = helpers.load_module("ui.healthcheck.report")
		local calls = {}
		local overrides = recording(calls)
		ordered(calls, overrides)
		if adjust then adjust(overrides) end
		local window_opened = false
		local previous_bridge = package.loaded["ui.healthcheck.bridge"]
		local previous_manager = package.loaded["ui.webview_manager"]
		package.loaded["ui.healthcheck.bridge"] = { DRIVER = "linux", config = documents,
			open = function() window_opened = true; return true end,
			build_snapshot = function()
				local snapshot = host_snapshot(false)
				snapshot.sections.paths = { diagnostics_dir = LOGS_DIR .. "/diagnostics" }
				return snapshot
			end }
		package.loaded["ui.webview_manager"] = { get_daemon_state = function() return {} end }
		local ok, result = pcall(function()
			local outcome
			Report.report_bug(overrides, function(value) outcome = value end)
			return outcome
		end)
		package.loaded["ui.healthcheck.bridge"] = previous_bridge
		package.loaded["ui.webview_manager"] = previous_manager
		helpers.assert_true(ok, tostring(result))
		return result, calls, window_opened
	end

	-- The menu row only opened the diagnostics window and never reached GitHub
	-- (menu-report-bug).
	helpers.it("Report a bug copies, saves and opens the prefilled bug form (menu-report-bug)", function()
		local result, calls, window_opened = menu_report_bug()
		helpers.assert_eq(result, true)
		helpers.assert_eq(window_opened, false, "the menu reports without the diagnostics window")
		helpers.assert_eq(calls.order, { "copy", "save", "reveal", "open_url" })
		helpers.assert_eq(calls.copy[1], approved_text(false), "the clipboard holds the approved report")
		helpers.assert_eq(calls.save[1].text, approved_text(false), "the attachment holds the same report")
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
			.. "/issues/new?template=bug_report.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix, "not a bare URL: the bug template is selected")
		helpers.assert_eq(query_value(calls.open_url[1], "version"), "2.4.0")
		helpers.assert_eq(query_value(calls.open_url[1], "os"), "linux")
		helpers.assert_eq(query_value(calls.open_url[1], "driver"), "linux")
		helpers.assert_eq(query_value(calls.open_url[1], "diagnostics"), nil, "the editable field stays out of the URL")
		helpers.assert_true(not calls.open_url[1]:find("jdoe", 1, true), "the URL carries no account name")
	end)

	helpers.it("Report a bug notifies instead of opening the form when the clipboard refuses (menu-report-bug)", function()
		local result, calls = menu_report_bug(function(overrides)
			overrides.copy = function() return false end
		end)
		helpers.assert_eq(result, false)
		helpers.assert_eq(#calls.open_url, 0, "the browser must not open without the report")
		helpers.assert_eq(calls.notify, { "error" })
	end)

	helpers.it("Suggest a feature opens the feature form with the version and the system", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local calls = {}
		local previous_bridge = package.loaded["ui.healthcheck.bridge"]
		local previous_manager = package.loaded["ui.webview_manager"]
		package.loaded["ui.healthcheck.bridge"] = { DRIVER = "linux", config = documents,
			build_snapshot = function() return host_snapshot(false) end }
		package.loaded["ui.webview_manager"] = { get_daemon_state = function() return {} end }
		local ok, result = pcall(function()
			local outcome
			Report.suggest_feature(recording(calls), function(value) outcome = value end)
			return outcome
		end)
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
				if reveal_ok == false then overrides.reveal = function(_, done) done({ ok = false, code = 23 }) end end
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
			function(overrides) overrides.open_url = function(_, done) done({ ok = false, code = 23 }) end end)
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(#calls.save, 1)
		helpers.assert_eq(calls.save[1].text, calls.copy[1])
	end)
end)

helpers.describe("stable-metadata report URL", function()
	helpers.it("stable-metadata report URL keeps complete output local and rejects page-derived query fields", function()
		local result, calls = perform({ action = "report", text = REPORT,
			fields = { diagnostics = "private query text", title = "PRIVATE_TITLE", description = "PRIVATE_DESCRIPTION", reproduction = "PRIVATE_REPRODUCTION", version = "9.9.9", os = "private host", driver = "foreign" } })
		helpers.assert_eq(result.ok, true)
		local repo = documents().repository
		helpers.assert_eq(calls.open_url[1], "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&version=2.4.0&os=linux&driver=linux")
		for _, id in ipairs({ "title", "description", "reproduction", "diagnostics", "architecture" }) do helpers.assert_nil(query_value(calls.open_url[1], id)) end
		helpers.assert_eq(calls.save[1].text, calls.copy[1])
		helpers.assert_eq(calls.copy[1], approved_text(false))
		helpers.assert_eq(calls.order, { "copy", "save", "reveal", "open_url" })
	end)
end)

helpers.describe("retained installed-page observations", function()
	helpers.it("keeps useful page outcomes without qualifying suites and refuses stale identity", function()
		local config = documents()
		local rows = {}
		for _, spec in ipairs(config.schema.diagnostic_checks.items) do
			rows[spec.id] = spec.reason and { state = "not_run", scope = spec.scope, reason = spec.reason }
				or { state = "ok", scope = spec.scope, ms = 3 }
		end
		local observed = assert(Share.page_checks(rows, config.schema))
		local snapshot = host_snapshot(false)
		snapshot.export_revision = 1
		local action = { page_check_observations = observed, generated_at = snapshot.generated_at, snapshot_revision = 2 }
		helpers.assert_eq(Share.capture_page_checks(snapshot, action), false)
		helpers.assert_eq(snapshot.page_check_observations, nil)
		action.snapshot_revision = 1
		helpers.assert_eq(Share.capture_page_checks(snapshot, action), true)
		local doc = Share.document(snapshot, config.schema, "PRIVATE_LOCALE")
		helpers.assert_contains(doc.text, "installed_page_reported (unqualified)")
		helpers.assert_contains(doc.text, "page_check_observations.results.redaction.ms")
		helpers.assert_eq(doc.snapshot.page_check_observations.results.driver_suites.state, "not_run")
		rows.redaction.text = "PRIVATE_TEXT"
		helpers.assert_eq(Share.page_checks(rows, config.schema), nil)
	end)
end)

helpers.describe("closed recent error facts", function()
	helpers.it("keeps observed technical failure codes and excludes every private message", function()
		local config = documents()
		local corpus = shared_json("tests/corpus/healthcheck/recent_error_fact_vectors.json")
		for _, vector in ipairs(corpus.vectors) do
			local original = Json.encode(vector.snapshot)
			local doc = Share.document(vector.snapshot, config.schema, "PRIVATE_LOCALE")
			helpers.assert_eq(doc.snapshot.sections.issues.recent_error_facts, vector.expected)
			for _, canary in ipairs(corpus.canaries) do
				helpers.assert_true(not doc.text:find(canary, 1, true), canary)
			end
			helpers.assert_contains(doc.text, "lease_watchdog_exit")
			helpers.assert_contains(doc.text, "log_observation_only")
			for _, action in ipairs({ "copy", "save", "report" }) do
				local Report = helpers.load_module("ui.healthcheck.report")
				local calls = {}
				local overrides = recording(calls)
				ordered(calls, overrides)
				local outcome = completed(Report, { action = action, text = doc.text, name = doc.name, fields = {} },
					{ logs_dir = LOGS_DIR, diagnostics_dir = LOGS_DIR .. "/diagnostics" }, config,
					Report.redaction_context(overrides), overrides, vector.snapshot)
				helpers.assert_eq(outcome.ok, true, "the real report sink receives the retained fact snapshot")
				if action ~= "save" then helpers.assert_eq(calls.copy[1], doc.text) end
				if action ~= "copy" then helpers.assert_eq(calls.save[1].text, doc.text) end
				for _, canary in ipairs(corpus.canaries) do
					-- The fixed public GitHub scheme is intentional; private identities remain forbidden.
					if canary ~= "https://" then
						for _, url in ipairs(calls.open_url) do helpers.assert_true(not url:find(canary, 1, true), canary) end
					end
				end
			end
			helpers.assert_eq(Json.encode(vector.snapshot), original)
		end
	end)
end)


--- Real private launcher children; the only substituted boundary maps the
--- production argv executable to an owned file, never to a desktop handler.
local function with_native_opener(script, controls, body)
	local uv = require("luv")
	local old_owned, old_desktop = package.loaded["adapters.owned_process"], package.loaded["adapters.desktop_opener"]
	local old_report = package.loaded["ui.healthcheck.report"]
	local timer, native = require("infra.native_timer"), {}
	local timeout = require("infra.timings").ms("ui", "desktop_open_timeout_ms")
	for key, value in pairs(uv) do native[key] = value end
	function native.timer_start(handle, ms, interval, callback)
		if ms == timeout then
			return timer.start(uv, handle, controls.timeout and 1 or ms, interval, callback)
		end
		return uv.timer_start(handle, ms, interval, callback)
	end
	local Owned = helpers.load_module_with_dependency("adapters.owned_process", "luv", native)
	local Desktop = helpers.load_module("adapters.desktop_opener")
	local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/diagnostic_opener_XXXXXX"))
	local executable, target = root .. "/private-opener", root .. "/report.md"
	local function write(path, text)
		local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
	end
	write(executable, "#!/bin/sh\n" .. script); assert(uv.fs_chmod(executable, 448)); write(target, "synthetic report\n")
	local state = { outcomes = {}, requests = 0, current = true, root = root, target = target }
	Desktop._set_deps_for_test({ start = function(program, args, options, done)
		helpers.assert_eq(program, uv.exepath())
		helpers.assert_eq(args, { require("infra.paths").driver_root() .. "/adapters/desktop_opener_worker.lua", target, tostring(timeout) })
		helpers.assert_eq(options.timeout_ms, timeout)
		state.requests = state.requests + 1
		if controls.refuse then return nil, "controlled opener admission refused" end
		return Owned.start(executable, { target }, options, done)
	end })
	local Report = helpers.load_module("ui.healthcheck.report")
	function state.start()
		state.operation = Report.perform({ action = "open_path", id = "log_today" }, { log_today = target }, {}, {}, nil, nil, {
			current = function() return state.current end,
			complete = function(result) state.outcomes[#state.outcomes + 1] = result end,
		})
	end
	function state.drain(until_result)
		local deadline = uv.hrtime() + (until_result and 2000000000 or 50000000)
		repeat uv.run("nowait"); uv.sleep(1) until (until_result and #state.outcomes > 0) or uv.hrtime() >= deadline
	end
	function state.release() write(target .. ".release", "release\n") end
	local ok, detail = xpcall(function() body(state) end, debug.traceback)
	local cleaned, cleanup_err = pcall(function()
		if state.operation then state.operation.cancel() end
		local deadline = uv.hrtime() + 2000000000
		repeat uv.run("nowait"); uv.sleep(1) until Desktop.shutdown() == true or uv.hrtime() >= deadline
		assert(Desktop.shutdown() == true, "private opener still owns physical cleanup debt")
		Desktop._set_deps_for_test(nil)
		for _, path in ipairs({ target .. ".release", target, executable }) do if uv.fs_lstat(path) then assert(uv.fs_unlink(path)) end end
		assert(uv.fs_rmdir(root))
	end)
	package.loaded["adapters.owned_process"], package.loaded["adapters.desktop_opener"] = old_owned, old_desktop
	package.loaded["ui.healthcheck.report"] = old_report
	if not cleaned then error(cleanup_err, 0) end
	if not ok then error(detail, 0) end
end

helpers.describe("diagnostic opener actual child completion", function()
	for _, status in ipairs({ 0, 23 }) do
		helpers.it("(diagnostic-opener-native) receives private child exit " .. status, function()
			with_native_opener("exit " .. status .. "\n", {}, function(s)
				s.start(); helpers.assert_eq(#s.outcomes, 0, "admission cannot acknowledge completion")
				s.drain(true); helpers.assert_eq(#s.outcomes, 1)
				helpers.assert_eq(s.outcomes[1].ok, status == 0); helpers.assert_eq(s.outcomes[1].exit_code, status)
			end)
		end)
	end
	-- This control owns only its launcher. A builtin wait creates no orphaned
	-- sleep; descendant-group retirement has separate canonical subreaper probes.
	local held = 'while [ ! -f "$1.release" ]; do :; done\nexit 23\n'
	helpers.it("(diagnostic-opener-native) keeps the loop live while awaiting the owned child", function()
		with_native_opener(held, {}, function(s)
			s.start(); s.drain(false); helpers.assert_eq(#s.outcomes, 0)
			local heartbeat = false; local uv = require("luv"); local tick = assert(uv.new_timer())
			assert(uv.timer_start(tick, 1, 0, function() heartbeat = true; uv.close(tick) end))
			s.drain(false); helpers.assert_true(heartbeat, "other native work runs while the launcher waits")
			s.release(); s.drain(true); helpers.assert_eq(s.outcomes[1].ok, false); helpers.assert_eq(s.outcomes[1].exit_code, 23)
		end)
	end)
	helpers.it("(diagnostic-opener-native) receives the controlled native deadline without a blocking fallback", function()
		with_native_opener(held, { timeout = true }, function(s)
			s.start(); s.drain(true); helpers.assert_eq(#s.outcomes, 1); helpers.assert_eq(s.outcomes[1].ok, false)
		end)
	end)
	helpers.it("(diagnostic-opener-native) cancellation retires the child without a completion", function()
		with_native_opener(held, {}, function(s)
			s.start(); s.operation.cancel(); s.drain(false); helpers.assert_eq(#s.outcomes, 0)
		end)
	end)
	helpers.it("(diagnostic-opener-native) refuses unavailable spawn without inventing a child result", function()
		with_native_opener("exit 0\n", { refuse = true }, function(s)
			s.start(); helpers.assert_eq(#s.outcomes, 1); helpers.assert_eq(s.outcomes[1].ok, false)
			helpers.assert_nil(s.outcomes[1].exit_code); helpers.assert_eq(s.requests, 1)
		end)
	end)
end)

helpers.describe("feature opener cancellation ownership", function()
	helpers.it("(feature-opener-cancel) a nested request survives cancellation of its predecessor", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local old_bridge, old_manager = package.loaded["ui.healthcheck.bridge"], package.loaded["ui.webview_manager"]
		package.loaded["ui.healthcheck.bridge"] = { config = documents, build_snapshot = function() return host_snapshot(false) end }
		package.loaded["ui.webview_manager"] = { get_daemon_state = function() return {} end }
		local calls, outcomes, cancellations, reenter = {}, {}, 0, true
		local effects = recording({})
		effects.open_url = function(_, done)
			calls[#calls + 1] = done
			return { cancel = function()
				cancellations = cancellations + 1
				if reenter then reenter = false; Report.suggest_feature(effects, function(value) outcomes[#outcomes + 1] = value end) end
			end }
		end
		local ok, detail = xpcall(function()
			Report.suggest_feature(effects, function(value) outcomes[#outcomes + 1] = value end)
			Report.suggest_feature(effects, function(value) outcomes[#outcomes + 1] = value end)
			helpers.assert_eq(#calls, 2); helpers.assert_eq(cancellations, 1)
			calls[1]({ ok = true, code = 0 }); helpers.assert_eq(#outcomes, 0)
			calls[2]({ ok = false, code = 23, error = "private opener refused" })
			helpers.assert_eq(outcomes, { false })
		end, debug.traceback)
		package.loaded["ui.healthcheck.bridge"], package.loaded["ui.webview_manager"] = old_bridge, old_manager
		if not ok then error(detail, 0) end
	end)
end)

helpers.describe("diagnostic opener late port failure", function()
	helpers.it("(diagnostic-opener-late) logs an exception after inline completion without a second outcome", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local Logger = require("logger.shim")
		local held, errors, results = Logger.error, {}, {}
		Logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
		local ok, detail = xpcall(function()
			Report.perform({ action = "open_path", id = "log_today" }, { log_today = "/controlled/log" }, {}, {}, {
				exists = function() return true end,
				open = function(_, done) done({ ok = true, code = 0 }); error("independent late opener failure") end,
			}, nil, { current = function() return true end, complete = function(value) results[#results + 1] = value end })
		end, debug.traceback)
		Logger.error = held
		if not ok then error(detail, 0) end
		helpers.assert_eq(#results, 1); helpers.assert_eq(results[1].ok, true)
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("independent late opener failure", 1, true) ~= nil)
	end)
end)

helpers.describe("redaction context carries the configuration directory (config-dir-masking)", function()
	helpers.it("a hotstring pack name under the configuration directory never reaches a report (config-dir-masking)", function()
		local Report = helpers.load_module("ui.healthcheck.report")
		local dir = HOME .. "/.config/ergopti"
		local overrides = recording({})
		overrides.identity = function() return { home = HOME, user = "jdoe", config_dir = dir } end
		local context = Report.redaction_context(overrides)
		helpers.assert_eq(context.config_dir, dir)
		helpers.assert_eq(
			require("diagnostics.redact").apply("read '" .. dir .. "/hotstrings/my_pack/a.toml'", documents().redaction, context),
			"read '<config>/hotstrings/<name>/<name>'")
	end)
end)

--- Runs one action over the recorded effects to its explicit completion.
local function completed_action_for(Report, action, config, context, overrides, snapshot)
	local paths = { logs_dir = LOGS_DIR, diagnostics_dir = LOGS_DIR .. "/diagnostics" }
	return completed(Report, action, paths, config, context, overrides, snapshot)
end

helpers.describe("opt-in day log in the report actions (day-log-host)", function()
	local DayLogHost = require("healthcheck.day_log")
	local LOG_TEXT = "2026-09-24 09:00:00:001 [INFO] [A] opened /home/jdoe/x\n2026-09-24 09:00:01:002 [INFO] [B] token=abcdefghijkl\n"
	local REDACTED = "2026-09-24 09:00:00:001 [INFO] [A] opened ~/x\n2026-09-24 09:00:01:002 [INFO] [B] token=<secret>\n"

	--- A host fixture: the report module over recorded effects, a snapshot and its documents.
	local function fixture()
		local Report = helpers.load_module("ui.healthcheck.report")
		local calls = {}
		local overrides = recording(calls)
		local config = documents()
		config.day_log = shared_json("modules/diagnostics/day_log.json")
		local snapshot = host_snapshot(false)
		local context = Report.redaction_context(overrides)
		local function run(action)
			return completed_action_for(Report, action, config, context, overrides, snapshot)
		end
		local function text(with_log)
			return Share.document(snapshot, config.schema, require("infra.i18n").get(config.schema.share_policy.notice_key),
				with_log).text
		end
		return { calls = calls, config = config, snapshot = snapshot, context = context, run = run, text = text }
	end

	local function read_log(text)
		return function() return { found = true, size = #text, text = text } end
	end

	helpers.it("collecting redacts the log, keeps its text away from the snapshot and records only the closed record (day-log-host)", function()
		local f = fixture()
		local reply = DayLogHost.prepare(f.snapshot, f.config, f.context, read_log(LOG_TEXT))
		helpers.assert_eq(reply.state, "ready")
		helpers.assert_eq(reply.lines, 2)
		helpers.assert_eq(reply.bytes, #REDACTED)
		helpers.assert_eq(f.snapshot.day_log_attachment, { included = true, bytes = #REDACTED, lines = 2 })
		helpers.assert_true(not Json.encode(f.snapshot):find("abcdefghijkl", 1, true), "the snapshot never holds the log")
		DayLogHost.discard(f.snapshot)
		helpers.assert_eq(f.snapshot.day_log_attachment, nil)
	end)

	helpers.it("a log over the cap, an empty one and a missing one are refused with their reason (day-log-host)", function()
		local f = fixture()
		f.config.day_log.max_bytes = 10
		helpers.assert_eq(DayLogHost.prepare(f.snapshot, f.config, f.context, read_log(LOG_TEXT)).state, "too_large")
		helpers.assert_eq(f.snapshot.day_log_attachment, nil)
		f.config.day_log.max_bytes = 4194304
		helpers.assert_eq(DayLogHost.prepare(f.snapshot, f.config, f.context, read_log("")).state, "empty")
		helpers.assert_eq(DayLogHost.prepare(f.snapshot, f.config, f.context,
			function() return { found = false, size = 0, text = "" } end).state, "missing")
	end)

	helpers.it("save writes the log first, then the report, and the report records the log (day-log-host)", function()
		local f = fixture()
		DayLogHost.prepare(f.snapshot, f.config, f.context, read_log(LOG_TEXT))
		local text = f.text(true)
		helpers.assert_true(text:find("day_log_attachment.included | true", 1, true) ~= nil, "the report records the attachment")
		local document = Share.document(f.snapshot, f.config.schema,
			require("infra.i18n").get(f.config.schema.share_policy.notice_key), true)
		local result = f.run({ action = "save", text = text, name = document.name, day_log = true })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#f.calls.save, 2)
		helpers.assert_eq(f.calls.save[1].name, "ergopti-day-log-linux-2026-09-24T10_00_00Z.log")
		helpers.assert_eq(f.calls.save[1].text, REDACTED)
		helpers.assert_eq(f.calls.save[2].name, document.name)
		helpers.assert_eq(f.calls.save[2].text, text)
	end)

	helpers.it("without the flag nothing about the log is saved or recorded, even when it was prepared (day-log-host)", function()
		local f = fixture()
		DayLogHost.prepare(f.snapshot, f.config, f.context, read_log(LOG_TEXT))
		local text = f.text(false)
		helpers.assert_true(not text:find("day_log_attachment", 1, true), "the report omits the record")
		local result = f.run({ action = "save", text = text, name = "x" })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#f.calls.save, 1)
	end)

	helpers.it("copy never carries the log and an unprepared log is refused before any file is written (day-log-host)", function()
		local f = fixture()
		DayLogHost.prepare(f.snapshot, f.config, f.context, read_log(LOG_TEXT))
		helpers.assert_eq(f.run({ action = "copy", text = f.text(true), day_log = true }).ok, false)
		helpers.assert_eq(#f.calls.copy, 0)
		local g = fixture()
		helpers.assert_eq(g.run({ action = "report", text = g.text(false), fields = {}, day_log = true }).ok, false)
		helpers.assert_eq(#g.calls.save, 0)
		helpers.assert_eq(#g.calls.copy, 0)
	end)

	helpers.it("a collection prepared for another snapshot is never saved (day-log-host)", function()
		local f = fixture()
		DayLogHost.prepare(f.snapshot, f.config, f.context, read_log(LOG_TEXT))
		local other = host_snapshot(false)
		other.day_log_attachment = { included = true, bytes = #REDACTED, lines = 2 }
		helpers.assert_true(not pcall(DayLogHost.file, other, f.config, { driver = "linux" }),
			"the file of an unprepared snapshot is refused")
	end)

	helpers.it("reading the file distinguishes missing, unreadable, too large and read (day-log-host)", function()
		local function fake(size, content)
			return function()
				local handle = {}
				function handle:seek(whence, offset)
					if whence == "end" then return size end
					return offset or 0
				end
				function handle:read() return content end
				function handle:close() return true end
				return handle
			end
		end
		helpers.assert_eq(DayLogHost.read_file("x", 100, function() return nil, "No such file", 2 end).found, false)
		helpers.assert_true(not pcall(DayLogHost.read_file, "x", 100, function() return nil, "Permission denied", 13 end),
			"an unreadable file is an error, not a missing one")
		local big = DayLogHost.read_file("x", 5, fake(6, "abcdef"))
		helpers.assert_eq({ big.found, big.size, big.text }, { true, 6, "" })
		local ok = DayLogHost.read_file("x", 100, fake(3, "abc"))
		helpers.assert_eq({ ok.found, ok.size, ok.text }, { true, 3, "abc" })
		helpers.assert_true(not pcall(DayLogHost.read_file, "x", 100, fake(5, "abc")), "a short read is an error")
	end)
end)
