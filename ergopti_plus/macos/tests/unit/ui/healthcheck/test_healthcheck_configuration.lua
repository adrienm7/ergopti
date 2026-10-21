--- tests/unit/ui/healthcheck/test_healthcheck_configuration.lua

--- ==============================================================================
--- MODULE: Diagnostics Configuration Reducer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/healthcheck/configuration_vectors.json through
--- healthcheck.configuration: booleans, numbers and manifest enum values are
--- exact, every other string keeps only its length, every list only its item
--- count, and a key the manifest does not declare never becomes a row. The
--- Windows suite replays the same vectors through its AHK port.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Configuration = require("healthcheck.configuration")
local Toml = require("toml_codec")

--- The shared corpus.
--- @return table
local function corpus()
	local fh = assert(io.open(helpers.shared("tests/corpus/healthcheck/configuration_vectors.json"), "rb"))
	local data = Json.decode(fh:read("*a"))
	fh:close()
	return data
end

local CORPUS = corpus()
local SHARED_ROOT = helpers.shared("") .. "/"

helpers.describe("diagnostics configuration reducer", function()
	for _, vector in ipairs(CORPUS.vectors) do
		helpers.it("reduces " .. vector.id, function()
			local rows = Configuration.rows(CORPUS.features, Toml.decode(vector.toml), vector.driver, 800)
			helpers.assert_eq(rows, vector.expected, vector.id)
			local encoded = Json.encode(rows)
			for _, canary in ipairs(CORPUS.canaries) do
				helpers.assert_true(not encoded:find(Json.encode(canary):sub(2, -2), 1, true),
					vector.id .. " leaked " .. canary)
			end
		end)
	end

	helpers.it("bounds the number of rows", function()
		local rows = Configuration.rows(CORPUS.features,
			Toml.decode("[script]\nlog_level = \"INFO\"\nshow_error_dialog = true\n\n[metrics]\nkeep_days = 3\n"),
			"windows", 2)
		helpers.assert_eq(#rows, 2)
	end)

	helpers.it("refuses an unknown driver", function()
		helpers.assert_true(not pcall(Configuration.rows, CORPUS.features, {}, "beos", 10))
	end)
end)

helpers.describe("diagnostics configuration sharing", function()
	local Share = require("healthcheck.share")

	--- Reads a shared JSON document.
	--- @param rel string Path under _shared/.
	--- @return table
	local function shared_json(rel)
		local fh = assert(io.open(SHARED_ROOT .. rel, "rb"))
		local data = Json.decode(fh:read("*a"))
		fh:close()
		return data
	end

	local schema = shared_json("modules/diagnostics/schema.json")
	schema.export_strings = shared_json("data/locales/en.json")
	local controls = shared_json("tests/corpus/healthcheck/configuration_share_vectors.json")

	--- A minimal host snapshot carrying only the configuration sections.
	--- @param driver string
	--- @param rows table
	--- @param files table
	--- @return table
	local function snapshot_of(driver, rows, files)
		return {
			schema_version = 2, driver = driver, generated_at = "2026-10-20T10:00:00Z",
			detailed = false, extensive = false,
			sections = { configuration = { items = rows }, configuration_files = { items = files } },
		}
	end

	for _, driver in ipairs({ "windows", "macos", "linux" }) do
		for _, vector in ipairs(controls.vectors) do
			helpers.it(driver .. ": " .. vector.id, function()
				local snapshot = snapshot_of(driver, vector.items, controls.files)
				local safe = Share.snapshot(snapshot, schema)
				helpers.assert_eq(safe.sections.configuration.items, vector.expected, vector.id)
				helpers.assert_eq(safe.sections.configuration_files.items, controls.expected_files, vector.id .. " files")
				local document = Share.document(snapshot, schema, "notice")
				for _, canary in ipairs(controls.canaries) do
					helpers.assert_true(not document.text:find(canary, 1, true), vector.id .. " leaked " .. canary)
				end
				for _, row in ipairs(vector.expected) do
					helpers.assert_contains(document.text, "| " .. row.setting .. " | " .. row.type .. ": " .. row.value .. " |")
				end
			end)
		end
	end

	helpers.it("bounds the shared configuration rows", function()
		local rows = {}
		for index = 1, 801 do rows[index] = { setting = "script.k" .. index, type = "boolean", value = "true" } end
		local safe = Share.snapshot(snapshot_of("linux", rows, {}), schema)
		helpers.assert_eq(#safe.sections.configuration.items, 800)
	end)

	helpers.it("shares nothing a collector's own canaries could carry, end to end", function()
		for _, vector in ipairs(CORPUS.vectors) do
			local rows = Configuration.rows(CORPUS.features, Toml.decode(vector.toml), vector.driver, 800)
			local document = Share.document(snapshot_of(vector.driver, rows, {}), schema, "notice")
			for _, canary in ipairs(CORPUS.canaries) do
				helpers.assert_true(not document.text:find(canary, 1, true), vector.id .. " leaked " .. canary)
			end
		end
	end)
end)

helpers.describe("diagnostics configuration files", function()
	--- An io.open replacement serving fixed outcomes by path.
	--- @param table_of table path -> { text = string } | { errno = number } | { read_fails = true }
	--- @return function
	local function fake_open(table_of)
		return function(path)
			local entry = table_of[path]
			if entry.errno then return nil, "refused", entry.errno end
			return {
				read = function() if entry.read_fails then return nil, "Is a directory" end return entry.text end,
				close = function() return true end,
			}
		end
	end

	local function path_of(id) return "/cfg/" .. id .. ".toml" end
	local IDS = { "defaults", "config", "layers", "tap_hold" }

	helpers.it("reports ok, missing and unreadable in resolution order", function()
		local items, document = Configuration.read_files(IDS, path_of, Toml.decode, fake_open({
			["/cfg/config.toml"] = { text = '[script]\nlog_level = "INFO"\n' },
			["/cfg/layers.toml"] = { errno = 2 },
			["/cfg/tap_hold.toml"] = { read_fails = true },
		}))
		helpers.assert_eq(items, {
			{ id = "defaults", state = "ok" }, { id = "config", state = "ok" },
			{ id = "layers", state = "missing" }, { id = "tap_hold", state = "unreadable" },
		})
		helpers.assert_eq(document.script.log_level, "INFO")
	end)

	helpers.it("reports a permission failure as unreadable, never as missing", function()
		local items = Configuration.read_files({ "config" }, path_of, Toml.decode,
			fake_open({ ["/cfg/config.toml"] = { errno = 13 } }))
		helpers.assert_eq(items[1].state, "unreadable")
	end)

	helpers.it("reports a config.toml that does not decode as invalid and yields no setting", function()
		local result = Configuration.collect({ configuration = { files = { linux = { "defaults", "config" } }, max_rows = 800 } },
			"linux", CORPUS.features, path_of,
			function() error("malformed TOML") end,
			fake_open({ ["/cfg/config.toml"] = { text = "[script\n" } }))
		helpers.assert_eq(result.files.items[2].state, "invalid")
		helpers.assert_eq(#result.settings.items, 0)
	end)

	helpers.it("collects the shareable rows of a readable config.toml", function()
		local result = Configuration.collect({ configuration = { files = { linux = { "defaults", "config" } }, max_rows = 800 } },
			"linux", CORPUS.features, path_of, Toml.decode,
			fake_open({ ["/cfg/config.toml"] = { text = '[script]\nlocale = "/home/PRIVATE_USER_ZEBRA/notes"\n' } }))
		helpers.assert_eq(result.settings.items, { { setting = "script.locale", type = "text", value = "30" } })
	end)
end)

-- ===========================================
-- The configuration is a probe, never phase A
-- ===========================================

-- Reloaded under the stubbed runtime and restored after the case
local PROBE_MODULES = {
	"tests.stubs.hs", "infra.logger", "ui.healthcheck.core", "ui.healthcheck.helpers", "ui.healthcheck.probes",
	"adapters.system_info", "adapters.key_state", "adapters.network_info", "adapters.accessibility_permission",
	"adapters.screen_capture", "adapters.timer_scheduler", "healthcheck.configuration",
}

--- Runs a case under the stubbed Hammerspoon runtime.
--- @param body function(hs_stub)
local function under_stub(body)
	local ok, err = pcall(helpers.with_stub_scope, PROBE_MODULES, function()
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		hs_stub.execute = function() return "", false end
		hs_stub.host.vmStat = function() return { memSize = 17179869184, pagesFree = 1000, pageSize = 16384 } end
		hs_stub.usb = { attachedDevices = function() return {} end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		body(hs_stub)
	end)
	if not ok then error(err, 0) end
end

--- Replaces the reducer module with a fake slow reader: each entry point records
--- its name and costs slow_ms, so a synchronous collection is caught by the
--- duration as well as by the call.
--- @param calls table Receives the names called.
--- @param slow_ms number What one entry point costs.
local function slow_configuration_reader(calls, slow_ms)
	local guard = {}
	for _, name in ipairs({ "rows", "read_files", "collect", "probe", "complete" }) do
		guard[name] = function()
			calls[#calls + 1] = name
			local until_clock = os.clock() + slow_ms / 1000
			while os.clock() < until_clock do end
			return { files = { items = {} }, settings = { items = {} } }
		end
	end
	package.loaded["healthcheck.configuration"] = guard
end

helpers.describe("diagnostics configuration is collected by a probe, not by phase A", function()
	helpers.it("phase A never reads the configuration and says the probe is pending", function()
		under_stub(function()
			local calls = {}
			-- The stubbed phase A has its own cost on a test host, far over the
			-- real budget: the slow reader costs three of those plus twenty
			-- budgets, so waiting for it shows in the measured duration
			slow_configuration_reader(calls, 0)
			local baseline = require("ui.healthcheck.core").run().sections.developer.phase_a_ms
			local slow_ms = 3 * baseline + 20 * require("ui.healthcheck.core").config().schema.phase_a_budget_ms
			slow_configuration_reader(calls, slow_ms)
			local snapshot = require("ui.healthcheck.core").run()
			helpers.assert_true(snapshot.sections.developer.phase_a_ms < baseline + slow_ms / 2,
				"phase A took " .. tostring(snapshot.sections.developer.phase_a_ms) .. " ms against " .. tostring(baseline)
					.. " ms without the reader: it waited for the slow reader")
			helpers.assert_eq(calls, {}, "phase A reached the configuration reader")
			helpers.assert_eq(snapshot.sections.configuration, { items = {} })
			helpers.assert_eq(snapshot.sections.configuration_files, { items = {} })
			helpers.assert_eq(snapshot.probes.configuration.state, "pending")
			helpers.assert_eq(snapshot.probes.github_api, { state = "not_run", reason = "opt_in_required" })
		end)
	end)

	helpers.it("every probe is pending when the extensive checks are chosen", function()
		under_stub(function()
			slow_configuration_reader({}, 0)
			local snapshot = require("ui.healthcheck.core").run({ extensive = true })
			for id, result in pairs(snapshot.probes) do helpers.assert_eq(result.state, "pending", id) end
		end)
	end)

	helpers.it("a report from the Debug menu completes the configuration after phase A", function()
		under_stub(function()
			local completed = {}
			package.loaded["healthcheck.configuration"] = {
				complete = function(snapshot)
					completed[#completed + 1] = snapshot
					snapshot.probes.configuration = { state = "ok", cleanup = "settled", ms = 1 }
				end,
			}
			local snapshot = require("ui.healthcheck.core").run({ complete_local = true })
			helpers.assert_eq(#completed, 1)
			helpers.assert_eq(snapshot.probes.configuration.state, "ok")
		end)
	end)

	--- Starts the probe with scripted timers and a scripted clock.
	--- @param clock_step number Milliseconds the clock advances per reading.
	--- @param extra table|nil Extra overrides.
	--- @return table published, table timers, table run
	local function start_local(clock_step, extra)
		local published, timers = {}, {}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(seconds, fn)
				local handle = { seconds = seconds, fn = fn }
				timers[#timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle) handle.cancelled = true; return true end,
			onSettled = function() return true end,
		}
		local now = 0
		local overrides = {
			features = function() return CORPUS.features end,
			path_of = function(id) return "/cfg/" .. id .. ".toml" end,
			clock = function() now = now + clock_step; return now end,
			open_fn = function(path)
				if path:find("config.toml", 1, true) then
					return { read = function() return '[script]\nlocale = "/home/PRIVATE_USER_ZEBRA/notes"\n' end,
						close = function() end }
				end
				return nil, "absent", 2
			end,
		}
		for key, value in pairs(extra or {}) do overrides[key] = value end
		local schema = require("ui.healthcheck.core").config().schema
		local run = require("ui.healthcheck.probes").start(schema, { sections = {}, detailed = false },
			function(id, result, sections) published[#published + 1] = { id = id, result = result, sections = sections } end,
			{ local_only = true, overrides = overrides })
		return published, timers, run
	end

	helpers.it("the probe answers on a timer, alone, with both sections", function()
		under_stub(function()
			local published, timers = start_local(10)
			helpers.assert_eq(#published, 0, "nothing is published before the timer fires")
			helpers.assert_eq(#timers, 2, "the watchdog and the collection timer, no other probe")
			timers[2].fn()
			helpers.assert_eq(#published, 1)
			helpers.assert_eq(published[1].id, "configuration")
			helpers.assert_eq(published[1].result.state, "ok")
			helpers.assert_eq(published[1].result.cleanup, "settled")
			helpers.assert_eq(published[1].sections.configuration.items,
				{ { setting = "script.locale", type = "text", value = "30" } })
			helpers.assert_eq(published[1].sections.configuration_files.items[2], { id = "config", state = "ok" })
			helpers.assert_eq(published[1].sections.configuration_files.items[3], { id = "layers", state = "missing" })
		end)
	end)

	helpers.it("a slow reader past the deadline is a timeout that publishes no section", function()
		under_stub(function()
			local deadline = require("ui.healthcheck.core").config().schema.probes.configuration.timeout_ms
			local published, timers = start_local(deadline + 1)
			timers[2].fn()
			helpers.assert_eq(#published, 1)
			helpers.assert_eq(published[1].result.state, "timeout")
			helpers.assert_eq(published[1].result.detail, "deadline_expired")
			helpers.assert_eq(published[1].result.cleanup, "settled")
			helpers.assert_true(published[1].sections == nil or next(published[1].sections) == nil,
				"a late answer must not fill the sections")
		end)
	end)

	helpers.it("a reader that raises is an error state, never an empty success", function()
		under_stub(function()
			local published, timers = start_local(1, { open_fn = function() error("disk on fire") end })
			timers[2].fn()
			helpers.assert_eq(published[1].result.state, "error")
		end)
	end)

	helpers.it("cancelling the run before the timer publishes nothing", function()
		under_stub(function()
			local published, timers, run = start_local(1)
			run.cancel()
			if timers[2].fn then pcall(timers[2].fn) end
			helpers.assert_eq(#published, 0)
			helpers.assert_true(timers[2].cancelled == true, "the collection timer is cancelled")
		end)
	end)
end)
