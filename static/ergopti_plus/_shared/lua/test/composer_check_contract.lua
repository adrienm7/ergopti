--- _shared/lua/test/composer_check_contract.lua

--- Exercises the Debug check « Test the composed layout » (docs/layout-composer.md)
--- over a driver's real layout registry with the shared check composition:
--- a fresh run installs, verifies and removes it; a user's own composition is
--- only read; every way the host can fail is a failed step, never a silent pass.
--- The native installation, transport and input-source ports stay controlled by
--- the driver's manager fixture.
return function(helpers, Json, ports)
	local Report = require("field_check_report")
	local Check = require("layouts.composer_check")
	local fixture_dir = helpers.driver_root() .. "/../_shared/modules/layouts/composer_check/"

	local function shipped(name)
		local handle = assert(io.open(fixture_dir .. name, "rb"))
		local text = handle:read("*a")
		handle:close()
		return text
	end
	local DECLARATION = shipped("composition.json")
	local KEYLAYOUT = shipped("composed.keylayout")
	local DECLARATION_PATH = ports.config_dir .. "layout_composer/composition.json"

	--- A digest that depends on the content, so a tampered copy is noticed.
	local function content_digest(text)
		local sum = 0
		for index = 1, #text do sum = (sum * 31 + text:byte(index)) % 4294967291 end
		return string.rep(string.format("%08x", sum), 8)
	end

	--- A fresh manager whose digest follows the content.
	local function fresh(options)
		options = options or {}
		options.files = options.files or ports.files()
		for key, value in pairs(ports.manager_options or {}) do
			if options[key] == nil then options[key] = value end
		end
		local registry, deps, state = ports.manager(options)
		deps.config_dir = ports.config_dir
		deps.transport.sha256 = function(text, callback) callback(content_digest(text), nil) end
		if ports.prepare then ports.prepare(deps, state) end
		return registry, deps, state
	end

	--- Runs the shared check over a registry; returns the steps line, the result and the log line.
	local function run_check(registry, deps, state, extra)
		extra = extra or {}
		local settings = assert(registry.composer_settings())
		local env = assert(ports.env({
			registry = extra.registry or registry,
			deps = deps,
			settings = settings,
			config_dir = ports.config_dir,
			read = deps.read,
			exists = deps.exists,
			sha256 = deps.transport.sha256,
			active_sources = deps.active_sources,
			read_fixture = extra.read_fixture or function()
				return { declaration = DECLARATION, keylayout = KEYLAYOUT }
			end,
		}, state))
		local report = Report.new_report(Check.CHECK_ID)
		local finished = 0
		Check.run(env, report, function() finished = finished + 1 end)
		helpers.assert_eq(finished, 1, "the check settles exactly once")
		local result = report.result()
		local parts = {}
		for _, step in ipairs(result.steps) do
			parts[#parts + 1] = step.id .. "=" .. step.state .. (step.value and (":" .. step.value) or "")
		end
		return table.concat(parts, " "), result, Report.format_log_line(result)
	end

	local function save_fixture(registry, deps)
		local result = {}
		registry.composer_save({ declaration = DECLARATION, keylayout = KEYLAYOUT, use = false },
			function(ok, code, detail) result.ok, result.code, result.detail = ok, code, detail end, deps)
		helpers.assert_true(result.ok, "the user's composition must install: " .. tostring(result.detail or result.code))
	end

	local FRESH = "composer_fixture=pass composer_mode=info:fresh composer_install=pass composer_copy=pass "
		.. ports.ready_step .. " composer_cleanup=pass"

	helpers.describe("composer check (" .. ports.name .. "): a fresh run", function()
		helpers.it("installs, verifies and removes the check composition (composer-check)", function()
			local registry, deps, state = fresh()
			local steps, result = run_check(registry, deps, state)
			helpers.assert_eq(steps, FRESH)
			helpers.assert_true(result.passed)
			helpers.assert_nil(state.files[ports.installed_copy], "the layout file is gone")
			helpers.assert_nil(state.files[DECLARATION_PATH], "and so is its declaration")
			helpers.assert_nil(registry.snapshot(deps).installed.composed, "and its record")
		end)

		helpers.it("selects nothing and runs again (composer-check)", function()
			local registry, deps, state = fresh()
			run_check(registry, deps, state)
			helpers.assert_eq(ports.selections(state), 0, "the check never selects the layout")
			local steps = run_check(registry, deps, state)
			helpers.assert_eq(steps, FRESH, "a second run is as clean as the first")
		end)

		helpers.it("records one compact line that leaks no path, URL or name (composer-check)", function()
			local registry, deps, state = fresh()
			local _, _, line = run_check(registry, deps, state)
			helpers.assert_eq(line, "check=composer verdict=pass steps=6 " .. FRESH)
			helpers.assert_eq(line:find("/", 1, true), nil, "no path")
			helpers.assert_eq(line:find("http", 1, true), nil, "no URL")
		end)
	end)

	helpers.describe("composer check (" .. ports.name .. "): the user's composition", function()
		helpers.it("only reads a composition that already exists (composer-check)", function()
			local registry, deps, state = fresh()
			save_fixture(registry, deps)
			local before = {}
			for path, text in pairs(state.files) do before[path] = text end
			state.deleted = {}
			local steps = run_check(registry, deps, state)
			helpers.assert_eq(steps, "composer_fixture=pass composer_mode=info:existing composer_install=skip:kept "
				.. "composer_copy=pass " .. ports.existing_ready_step .. " composer_cleanup=skip:kept")
			helpers.assert_eq(#state.deleted, 0, "nothing is deleted")
			for path, text in pairs(before) do
				helpers.assert_eq(state.files[path], text, "an existing composition is never rewritten: " .. path)
			end
		end)

		helpers.it("never saves or removes through the host when a composition exists (composer-check)", function()
			local registry, deps, state = fresh()
			save_fixture(registry, deps)
			local calls = {}
			local spy = setmetatable({
				composer_save = function() calls[#calls + 1] = "save" end,
				composer_remove = function() calls[#calls + 1] = "remove" end,
			}, { __index = registry })
			run_check(registry, deps, state, { registry = spy })
			helpers.assert_eq(#calls, 0)
		end)

		helpers.it("fails when the installed copy no longer matches its record (composer-check)", function()
			local registry, deps, state = fresh()
			save_fixture(registry, deps)
			state.files[ports.installed_copy] = state.files[ports.installed_copy] .. " "
			local steps, result = run_check(registry, deps, state)
			helpers.assert_true(steps:find("composer_copy=fail:digest_mismatch composer_ready=skip:no_copy", 1, true) ~= nil,
				steps)
			helpers.assert_true(not result.passed)
		end)

		helpers.it("fails when a recorded copy is gone (composer-check)", function()
			local registry, deps, state = fresh()
			save_fixture(registry, deps)
			state.files[ports.installed_copy] = nil
			local steps, result = run_check(registry, deps, state)
			helpers.assert_true(steps:find("composer_mode=info:existing composer_install=skip:kept composer_copy=fail:unreadable", 1, true) ~= nil, steps)
			helpers.assert_true(not result.passed)
		end)
	end)

	helpers.describe("composer check (" .. ports.name .. "): host failures", function()
		helpers.it("fails the install step when the host refuses the composition, and cleans up (composer-check)", function()
			local registry, deps, state = fresh()
			local steps, result = run_check(registry, deps, state, {
				read_fixture = function()
					return { declaration = DECLARATION, keylayout = KEYLAYOUT:gsub("Composer Check", "Other", 1) }
				end,
			})
			helpers.assert_true(steps:find("composer_install=fail:invalid", 1, true) ~= nil, steps)
			helpers.assert_true(steps:find("composer_cleanup=pass", 1, true) ~= nil, "the cleanup still ran: " .. steps)
			helpers.assert_true(not result.passed)
			helpers.assert_nil(state.files[ports.installed_copy])
		end)

		helpers.it("fails when the removal leaves the layout behind (composer-check)", function()
			local registry, deps, state = fresh()
			local lying = setmetatable({
				composer_remove = function(on_done) on_done(true) end,
			}, { __index = registry })
			local steps, result = run_check(registry, deps, state, { registry = lying })
			helpers.assert_true(steps:find("composer_cleanup=fail:left_behind", 1, true) ~= nil, steps)
			helpers.assert_true(not result.passed)
			registry.composer_remove(function() end, deps)
		end)

		helpers.it("fails the install step when the host cannot dispatch the save (composer-check)", function()
			local registry, deps, state = fresh()
			local broken = setmetatable({
				composer_save = function() error("host exploded") end,
			}, { __index = registry })
			local steps, result = run_check(registry, deps, state, { registry = broken })
			helpers.assert_true(steps:find("composer_install=fail:refused", 1, true) ~= nil, steps)
			helpers.assert_true(not result.passed)
		end)

		helpers.it("fails before touching the host when the shipped files are missing (composer-check)", function()
			local registry, deps, state = fresh()
			local calls = 0
			local spy = setmetatable({
				composer_save = function() calls = calls + 1 end,
			}, { __index = registry })
			local steps = run_check(registry, deps, state, {
				registry = spy,
				read_fixture = function() return nil, "missing" end,
			})
			helpers.assert_eq(steps, "composer_fixture=fail:unreadable")
			helpers.assert_eq(calls, 0)
		end)

		if ports.readiness_failure then
			helpers.it("fails the readiness step when the host cannot use the layout (composer-check)", function()
				local registry, deps, state = ports.readiness_failure(fresh)
				local steps, result = run_check(registry, deps, state)
				helpers.assert_true(steps:find(ports.readiness_failure_step, 1, true) ~= nil, steps)
				helpers.assert_true(steps:find("composer_cleanup=pass", 1, true) ~= nil, "and the layout is removed: " .. steps)
				helpers.assert_true(not result.passed)
			end)
		end
	end)
end
