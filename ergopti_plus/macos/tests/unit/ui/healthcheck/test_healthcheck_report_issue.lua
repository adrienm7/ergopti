--- tests/unit/ui/healthcheck/test_healthcheck_report_issue.lua

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
--- runs that report action on a fresh snapshot, without the window.
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
	local schema = shared_json("modules/diagnostics/schema.json")
	schema.export_strings = shared_json("data/locales/en.json")
	return {
		schema     = schema,
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

--- Adapts the existing synchronous effect fixtures to explicit completion.
local function async_effects(overrides)
	local effects = {}
	for key, value in pairs(overrides or {}) do effects[key] = value end
	for _, key in ipairs({ "open", "reveal", "open_url" }) do
		local effect = effects[key]
		if effect then effects[key] = function(target, done)
			done({ ok = effect(target) == true })
			return { cancel = function() end }
		end end
	end
	return effects
end

--- Receives the inline terminal produced by the existing synchronous fixtures.
local function completed_action(Report, action, paths, config, context, overrides, snapshot)
	local result
	Report.perform(action, paths, config, context, async_effects(overrides), snapshot, {
		current = function() return true end,
		complete = function(receipt) result = receipt end,
	})
	assert(result ~= nil, "The synchronous fixture must complete inline")
	return result
end

-- Direct injections and the timing reader's native path consumer form one fixture.
local NATIVE_MODULES = {
	"adapters.shell_runner", "adapters.timer_scheduler", "ui.healthcheck.report",
	"infra.logger", "infra.timings", "infra.paths",
}

--- Keeps the complete asynchronous fixture body under one restoration boundary.
--- @param body function Construction, callbacks and assertions.
local function with_native_opener(body)
	return helpers.with_stub_scope(NATIVE_MODULES, body)
end

--- Runs one native-opener subject with its complete fixture lifetime.
local function native_case(name, body)
	helpers.it(name, function() return with_native_opener(body) end)
end

--- Captures the native opener without opening any desktop application.
local function native_opener()
	local Report, calls, overrides = load_report()
	local native = { tasks = {}, timers = {}, callbacks = {}, current = true, errors = {} }
	package.loaded["infra.logger"].error = function(_, message, ...)
		native.errors[#native.errors + 1] = string.format(message, ...)
	end
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, callback)
			if native.timer_throw then error("controlled timer refusal") end
			local timer = { callback = callback, delay = delay }
			native.timers[#native.timers + 1] = timer
			if native.timer_hook then native.timer_hook() end
			return timer, native.timer_refuse ~= true
		end,
		cancel = function(timer) timer.cancelled = true; return true end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(bin, args, done)
			if native.construct_throw then error("controlled construction refusal") end
			if native.construct_refuse then return nil end
			local task = { bin = bin, args = args, done = done, started = false, settled = false, stopped = 0 }
			function task.start()
				task.deadline_count_at_start = #native.timers
				if native.start_throw then error("controlled start refusal") end
				task.started = native.start_refuse ~= true
				if native.start_complete_throw then task.finish(0); error("controlled completed start exception") end
				return task.started
			end
			function task.isSettled() return task.settled end
			function task.onSettled(callback) task.observer = callback; return true end
			function task.terminate()
				task.stopped = task.stopped + 1
				if native.cancel_hook then native.cancel_hook(task) end
				return native.terminate_refuse ~= true, "pending"
			end
			function task.finish(code)
				task.settled = true
				if done then done(code, "", "controlled opener") end
				if task.observer then task.observer() end
			end
			native.tasks[#native.tasks + 1] = task
			return task
		end,
	}
	local function run()
		return Report.perform({ action = "open_path", id = "errors_today" },
			{ errors_today = "/synthetic/errors.log" }, {}, {}, { exists = function() return true end }, nil, {
				current = function() return native.current end,
				complete = function(result) native.callbacks[#native.callbacks + 1] = result end,
			})
	end
	return native, run, Report, calls, overrides
end

helpers.describe("macOS diagnostics native opener completion (macos-opener-terminal)", function()
	native_case("refuses a throwing timing reader before constructing a native capability", function()
		local native, run = native_opener()
		local previous = package.loaded["infra.timings"]
		package.loaded["infra.timings"] = { sec = function() error("controlled timing admission refusal") end }
		local ok, detail = pcall(run)
		package.loaded["infra.timings"] = previous
		helpers.assert_true(ok, tostring(detail))
		helpers.assert_eq(#native.callbacks, 1)
		helpers.assert_eq(native.callbacks[1].ok, false)
		helpers.assert_eq(#native.tasks, 0, "a missing deadline must not pin a prepared native task")
	end)

	native_case("receives exit 23 instead of acknowledging start", function()
		local native, run = native_opener()
		run()
		helpers.assert_eq(#native.callbacks, 0, "native admission cannot complete an action")
		native.tasks[1].finish(23)
		helpers.assert_eq(#native.callbacks, 1, "the genuine terminal reaches the owner")
		helpers.assert_eq(native.callbacks[1].ok, false)
	end)

	native_case("admits the canonical deadline before starting the native opener", function()
		local native, run = native_opener()
		run()
		helpers.assert_eq(#native.timers, 1, "an accepted opener requires its deadline")
		native.timers[1].callback()
		helpers.assert_eq(native.tasks[1].stopped, 1, "deadline retains the exact child for retirement")
		native.tasks[1].finish(0)
		helpers.assert_eq(native.callbacks[1].ok, false, "late exit zero cannot erase the deadline")
	end)

	native_case("cancel fences completion while retaining pending native retirement", function()
		local native, run = native_opener()
		local request = run()
		helpers.assert_true(type(request.cancel) == "function", "the action retains cancellation authority")
		request.cancel()
		helpers.assert_eq(native.tasks[1].stopped, 1)
		native.tasks[1].finish(0)
		helpers.assert_eq(#native.callbacks, 0)
	end)

	native_case("independent current owners retain both concurrent opener children", function()
		local native, run = native_opener()
		run()
		run()
		helpers.assert_eq(native.tasks[1].stopped, 0, "another current owner's opener is not cleanup debt")
		native.tasks[1].finish(0)
		native.tasks[2].finish(23)
		helpers.assert_eq(#native.callbacks, 2)
		helpers.assert_eq(native.callbacks[1].ok, true)
		helpers.assert_eq(native.callbacks[2].ok, false)
	end)

	native_case("cancelling one concurrent opener cannot cancel its independent sibling", function()
		local native, run = native_opener()
		local first = run()
		run()
		first.cancel()
		helpers.assert_eq(native.tasks[1].stopped, 1)
		helpers.assert_eq(native.tasks[2].stopped, 0)
		native.tasks[2].finish(0)
		helpers.assert_eq(#native.callbacks, 1)
	end)
	native_case("an inline terminal followed by start throw logs once without a second outcome", function()
		local native, run = native_opener()
		native.start_complete_throw = true
		run()
		helpers.assert_eq(#native.callbacks, 1)
		helpers.assert_eq(native.callbacks[1].ok, true)
		helpers.assert_eq(#native.errors, 1, "the exception remains observable after terminal success")
		helpers.assert_contains(native.errors[1], "controlled completed start exception")
	end)

	for _, refusal in ipairs({ "timer_refuse", "timer_throw", "construct_refuse", "construct_throw", "start_refuse", "start_throw" }) do
		native_case("native opener admission refuses without hanging: " .. refusal, function()
			local native, run = native_opener()
			native[refusal] = true
			run()
			helpers.assert_eq(#native.callbacks, 1)
			helpers.assert_eq(native.callbacks[1].ok, false)
			if refusal:match("^timer") then helpers.assert_eq(native.tasks[1].started, false) end
		end)
	end

	native_case("deadline exists before native start and uses the shared timing", function()
		local native, run = native_opener()
		run()
		helpers.assert_eq(native.tasks[1].deadline_count_at_start, 1)
		helpers.assert_eq(native.timers[1].delay, require("infra.timings").sec("ui", "desktop_open_timeout_ms"))
		native.tasks[1].finish(0)
		helpers.assert_true(native.timers[1].cancelled)
		helpers.assert_eq(native.callbacks[1].ok, true)
	end)

	native_case("timer admission reentry cannot start a retired owner's opener", function()
		local native, run = native_opener()
		native.timer_hook = function() native.current = false end
		run()
		helpers.assert_eq(native.tasks[1].started, false)
		native.tasks[1].finish(0)
		helpers.assert_eq(#native.callbacks, 0)
	end)

	native_case("a duplicate child terminal cannot acknowledge twice", function()
		local native, run = native_opener()
		run()
		native.tasks[1].finish(0)
		native.tasks[1].finish(23)
		helpers.assert_eq(#native.callbacks, 1)
		helpers.assert_eq(native.callbacks[1].ok, true)
	end)

	native_case("retained cleanup retries only a retired child and preserves its successor", function()
		local native, run = native_opener()
		native.terminate_refuse = true
		local first = run()
		first.cancel()
		helpers.assert_eq(native.tasks[1].stopped, 1)
		native.terminate_refuse = false
		run()
		helpers.assert_eq(native.tasks[1].stopped, 2)
		helpers.assert_eq(native.tasks[2].stopped, 0)
		native.tasks[2].finish(0)
		native.tasks[1].finish(23)
		helpers.assert_eq(#native.callbacks, 1)
	end)

	native_case("a timed-out reveal with pending retirement never opens the browser", function()
		local native, _, Report, calls, overrides = native_opener()
		local config = documents()
		local snapshot = { driver = "macos", sections = { versions = { ergopti_version = "2.4.0" } } }
		local doc = Share.document(snapshot, config.schema)
		overrides.reveal = nil
		Report.perform({ action = "report", text = doc.text }, { diagnostics_dir = "/synthetic/diagnostics" },
			config, {}, async_effects(overrides), snapshot, {
				current = function() return true end,
				complete = function(result) native.callbacks[#native.callbacks + 1] = result end,
			})
		native.timers[1].callback()
		helpers.assert_eq(#calls.open_url, 0, "pending cleanup is not a reveal terminal")
		helpers.assert_eq(native.callbacks[1].ok, false)
		native.tasks[1].finish(0)
		helpers.assert_eq(#calls.open_url, 0, "late retirement cannot revive a refused report")
	end)

	native_case("report waits for reveal terminal and preserves its warning-only refusal", function()
		local native, _, Report, calls, overrides = native_opener()
		local config = documents()
		local snapshot = { driver = "macos", sections = { versions = { ergopti_version = "2.4.0" } } }
		local doc = Share.document(snapshot, config.schema)
		overrides.reveal = nil
		Report.perform({ action = "report", text = doc.text }, { diagnostics_dir = "/synthetic/diagnostics" },
			config, {}, async_effects(overrides), snapshot, {
				current = function() return true end,
				complete = function(result) native.callbacks[#native.callbacks + 1] = result end,
			})
		helpers.assert_eq(#calls.copy, 1)
		helpers.assert_eq(#calls.save, 1)
		helpers.assert_eq(#calls.open_url, 0, "browser must wait for the exact reveal receipt")
		helpers.assert_eq(#native.callbacks, 0)
		native.tasks[1].finish(23)
		helpers.assert_eq(#calls.open_url, 1, "failed reveal retains the existing warning policy")
		helpers.assert_eq(native.callbacks[1].ok, true)
	end)

end)

helpers.describe("native opener fixture restoration", function()
	helpers.it("restores exact native modules and global state after an assertion throws", function()
		local saved, saved_hs = {}, rawget(_G, "hs")
		for _, name in ipairs(NATIVE_MODULES) do saved[name] = package.loaded[name] end
		local ok, detail = pcall(with_native_opener, function()
			native_opener()
			error("controlled native-opener assertion failure")
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(detail), "controlled native-opener assertion failure")
		for _, name in ipairs(NATIVE_MODULES) do
			helpers.assert_true(rawequal(package.loaded[name], saved[name]), "exact module restored after throw: " .. name)
		end
		helpers.assert_true(rawequal(rawget(_G, "hs"), saved_hs), "the prior native stub owner is restored")
	end)
end)

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
	return completed_action(Report, action, paths(), documents(), context, overrides, snapshot), calls
end

helpers.describe("healthcheck page actions (report-bug-flow)", function()
	helpers.it("report copies, then opens the bug form with the whole report, all redacted (report-bug-flow)", function()
		local result, calls = perform({ action = "report", text = REPORT, fields = {
			version = "2.4.0", os = "macOS 15.1 (/Users/jdoe)", driver = "macos",
		} })
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#calls.copy, 1)
		helpers.assert_eq(calls.copy[1], approved_text(false))
		helpers.assert_eq(result.path, calls.reveal[1], "the complete local attachment is returned")

		local url = calls.open_url[1]
		helpers.assert_eq(query_value(url, "diagnostics"), nil,
			"the form receives no query default that could reset an edit")
		helpers.assert_eq(query_value(url, "os"), "macos")
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&version=2.4.0&os=macos&driver=macos"
		helpers.assert_eq(url, prefix, "the canonical bug URL contains only stable host metadata")
		helpers.assert_eq(query_value(url, "driver"), "macos")
		helpers.assert_true(not url:find("jdoe", 1, true), "the URL carries no account name: " .. url)
		helpers.assert_true(not url:find("%2FUsers%2F", 1, true), "the URL carries no home folder: " .. url)
	end)

	-- The report used to be saved and revealed in Finder too: the reveal
	-- finished after the browser opened, so Finder took the focus from the
	-- form (report-focus)
	helpers.it("report saves its attachment and opens the browser last (report-focus)", function()
		local _, calls = perform({ action = "report", text = REPORT, fields = { driver = "macos" } })
		helpers.assert_eq(#calls.save, 1, "a report saves the complete local attachment")
		helpers.assert_eq(#calls.reveal, 1, "the attachment is revealed before the browser")
		helpers.assert_eq(#calls.open, 0, "a report opens no folder")
		helpers.assert_eq(calls.order, { "copy", "save", "reveal", "open_url" }, "the browser opens last, after the clipboard and local attachment")
	end)

	helpers.it("report cuts a long report in the URL and keeps it whole in the clipboard (report-bug-flow)", function()
		local long = REPORT .. string.rep("line of diagnostics é\n", 2000)
		local result, calls = perform({ action = "report", text = long, fields = { version = "2.4.0", driver = "macos" } })
		helpers.assert_eq(result.ok, true)
		local templates = documents().templates
		helpers.assert_eq(#calls.copy[1] > templates.max_url_bytes, true, "the fixture exceeds the URL budget")
		local url = calls.open_url[1]
		helpers.assert_true(#url <= templates.max_url_bytes, "the URL fits its budget")
		helpers.assert_eq(query_value(url, "version"), "2.4.0", "only validated host identity is prefilled")
		local prefilled = query_value(url, "diagnostics")
		helpers.assert_eq(prefilled, nil, "long output never prefills or resets the issue form")
		helpers.assert_true(#url < 1200, "the editable URL stays short independently of report length")
		helpers.assert_eq(calls.save[1].text, calls.copy[1], "the saved attachment preserves the whole report")
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
		local result = completed_action(Report, { action = "open_path", id = "errors_today" },
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
	--- Runs Debug > Report a bug over a stubbed core and recorded effects.
	--- @param adjust function|nil Edits the recorded overrides.
	--- @return boolean|nil outcome, table calls, table probe
	local function menu_report_bug(adjust)
		local Report, calls, overrides = load_report()
		if adjust then adjust(overrides) end
		local probe = { window_opened = false }
		package.loaded["ui.healthcheck.core"] = {
			DRIVER = "macos",
			config = documents,
			show_window = function() probe.window_opened = true; return true end,
			run = function(opts)
				probe.run_opts = opts
				local snapshot = host_snapshot(false)
				snapshot.sections.paths = paths()
				return snapshot
			end,
		}
		local completed
		local ok, err = pcall(Report.report_bug, { state = probe }, async_effects(overrides),
			function(value) completed = value end)
		package.loaded["ui.healthcheck.core"] = nil
		helpers.assert_true(ok, tostring(err))
		return completed, calls, probe
	end

	-- The menu row only opened the diagnostics window and never reached GitHub
	-- (menu-report-bug).
	helpers.it("Report a bug copies, saves and opens the prefilled bug form (menu-report-bug)", function()
		local completed, calls, probe = menu_report_bug()
		helpers.assert_eq(completed, true)
		helpers.assert_eq(probe.window_opened, false, "the menu reports without the diagnostics window")
		helpers.assert_true(probe.run_opts.state == probe, "the menu state reaches the features section")
		helpers.assert_eq(calls.order, { "copy", "save", "reveal", "open_url" })
		helpers.assert_eq(calls.copy[1], approved_text(false), "the clipboard holds the approved report")
		helpers.assert_eq(calls.save[1].text, approved_text(false), "the attachment holds the same report")
		local repo = documents().repository
		local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
			.. "/issues/new?template=bug_report.yml&"
		helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix, "not a bare URL: the bug template is selected")
		helpers.assert_eq(query_value(calls.open_url[1], "version"), "2.4.0")
		helpers.assert_eq(query_value(calls.open_url[1], "os"), "macos")
		helpers.assert_eq(query_value(calls.open_url[1], "driver"), "macos")
		helpers.assert_eq(query_value(calls.open_url[1], "diagnostics"), nil, "the editable field stays out of the URL")
		helpers.assert_true(not calls.open_url[1]:find("jdoe", 1, true), "the URL carries no account name")
	end)

	helpers.it("Report a bug notifies instead of opening the form when the clipboard refuses (menu-report-bug)", function()
		local notified = {}
		local completed, calls = menu_report_bug(function(overrides)
			overrides.copy = function() return false end
			overrides.notify = function(_, _, kind) notified[#notified + 1] = kind; return true end
		end)
		helpers.assert_eq(completed, false)
		helpers.assert_eq(#calls.open_url, 0, "the browser must not open without the report")
		helpers.assert_eq(notified, { "error" })
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
		local completed
		Report.suggest_feature(async_effects(overrides), function(ok) completed = ok end)
		helpers.assert_eq(completed, true)
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

helpers.describe("default attachment completion", function()
	helpers.it("requires write and close acknowledgement before reveal or browser", function()
		for _, refusal in ipairs({ "none", "write", "close", "both" }) do
			local config = documents()
			local snapshot = host_snapshot(false)
			local doc = Share.document(snapshot, config.schema, "ignored")
			local Report, calls, overrides = load_report()
			overrides.save = nil -- Exercise the actual production default, not an effect replacement.
			local original_open = io.open
			local original_attributes = hs.fs.attributes
			local writes, closes = 0, 0
			hs.fs.attributes = function() return "directory" end
			io.open = function(_, mode)
				assert(mode == "wb", "only the attachment write is admitted")
				return {
					write = function(_, text)
						writes = writes + 1
						assert(text == doc.text, "the complete approved text reaches the real save owner")
						if refusal == "write" or refusal == "both" then return nil, "write-refused" end
						return true
					end,
					close = function()
						closes = closes + 1
						if refusal == "close" or refusal == "both" then return nil, "close-refused" end
						return true
					end,
				}
			end
			local ok, err = xpcall(function()
				local result = completed_action(Report, { action = "report", text = doc.text, fields = {} },
					paths(), config, Report.redaction_context(overrides), overrides, snapshot)
				helpers.assert_eq(result.ok, refusal == "none")
				helpers.assert_eq(writes, 1)
				helpers.assert_eq(closes, 1, "a failed write still closes its exact file")
				helpers.assert_eq(#calls.reveal, refusal == "none" and 1 or 0)
				helpers.assert_eq(#calls.open_url, refusal == "none" and 1 or 0)
			end, debug.traceback)
			io.open = original_open
			hs.fs.attributes = original_attributes
			if not ok then error(err, 0) end
		end
	end)
end)

helpers.describe("stable-metadata report URL", function()
	helpers.it("stable-metadata report URL keeps complete output local and rejects page-derived query fields", function()
		local result, calls = perform({ action = "report", text = REPORT,
			fields = { diagnostics = "private query text", title = "PRIVATE_TITLE", description = "PRIVATE_DESCRIPTION", reproduction = "PRIVATE_REPRODUCTION", version = "9.9.9", os = "private host", driver = "foreign" } })
		helpers.assert_eq(result.ok, true)
		local repo = documents().repository
		helpers.assert_eq(calls.open_url[1], "https://github.com/" .. repo.owner .. "/" .. repo.repo .. "/issues/new?template=bug_report.yml&version=2.4.0&os=macos&driver=macos")
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
				local Report, calls, overrides = load_report()
				local outcome = completed_action(Report, { action = action, text = doc.text, name = doc.name, fields = {} },
					paths(), config, Report.redaction_context(overrides), overrides, vector.snapshot)
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
