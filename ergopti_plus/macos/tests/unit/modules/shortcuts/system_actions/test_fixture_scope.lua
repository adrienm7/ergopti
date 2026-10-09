--- tests/unit/modules/shortcuts/system_actions/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: System Action Fixture Isolation
--- DESCRIPTION:
--- Proves exact restoration and current-host calls through real native consumers.
--- ==============================================================================

local helpers = require("tests.helpers")
local support = require("tests.support.system_actions_fixture")
local OWNERS = {
	"hs", "tests.stubs.hs", "modules.shortcuts.actions.system",
	"modules.shortcuts.actions.screenshot_save", "modules.shortcuts.actions.text",
	"modules.gestures", "infra.keycodes", "infra.logger", "infra.notifications",
	"adapters.event_provenance", "adapters.file_system", "adapters.key_state",
	"adapters.shell_runner", "adapters.synthetic_input", "adapters.timer_scheduler",
	"adapters.storage", "adapters.task_lifecycle", "adapters.mouse_control",
	"infra.deferred_work", "infra.fs_dir", "modules.keymap.utils",
	"modules.keymap.terminator_replay", "adapters.text_sender", "adapters.clipboard",
}

local function with_observer(callback)
	helpers.with_stub_scope(OWNERS, function()
		local preload = package.preload["modules.shortcuts.actions.system"]
		local describe = helpers.describe
		local outcome = table.pack(xpcall(callback, debug.traceback))
		package.preload["modules.shortcuts.actions.system"] = preload
		helpers.describe = describe
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

local function mount()
	return support.load_h01_system({ logger = helpers.make_logger_stub() })
end

helpers.describe("System action fixture isolation", function()
	for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
		helpers.it("(system-fixture-scope) restores native and dependency owners after " .. mode, function()
			with_observer(function()
				local native = rawget(_G, "hs")
				local marker = "system fixture injected failure"
				if mode == "construction failure" then
					package.preload["modules.shortcuts.actions.system"] = function() error(marker, 0) end
				end
				local constructed = false
				local ok, result = pcall(support.with_fixture, function()
					local fixture = mount()
					constructed = true
					helpers.assert_type(fixture.system.toggle_awake, "function")
					if mode == "callback failure" then error(marker, 0) end
					return "completed"
				end)
				helpers.assert_eq(constructed, mode ~= "construction failure")
				helpers.assert_eq(ok, mode == "success", tostring(result))
				if mode == "success" then
					helpers.assert_eq(result, "completed")
				else
					helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil)
				end
				helpers.assert_true(rawequal(rawget(_G, "hs"), native), "native host must be restored")
				for _, name in ipairs(OWNERS) do helpers.assert_nil(package.loaded[name], name) end
			end)
		end)
	end

	for _, consumer in ipairs({ "storage", "mouse", "deferred work", "directory", "task" }) do
		helpers.it("(system-fixture-scope) rebinds real " .. consumer .. " on an intra-case remount", function()
			with_observer(function()
				support.with_fixture(function()
					local calls = { [11] = 0, [22] = 0 }
					local function configure(host, marker)
						host.settings.get = function() return marker end
						host.mouse.absolutePosition = function() return { x = marker, y = 0 } end
						local native_new = host.timer.new
						host.timer.new = function(...)
							calls[marker] = calls[marker] + 1
							return native_new(...)
						end
						host.fs.dir = function(path)
							helpers.assert_eq(path, "system-fixture-directory")
							local state = { delivered = false }
							return function(actual)
								helpers.assert_true(actual == state)
								if state.delivered then return nil end
								state.delivered = true
								return tostring(marker)
							end, state
						end
						local task_new = host.task.new
						host.task.new = function(...)
							calls[marker] = calls[marker] + 1
							return task_new(...)
						end
					end
					local first = mount()
					configure(first.hs, 11)
					local previous_key_state = require("adapters.key_state")
					local previous_notifications = require("infra.notifications")
					local second = mount()
					configure(second.hs, 22)
					calls[11], calls[22] = 0, 0
					if consumer == "storage" then
						helpers.assert_eq(require("adapters.storage").get("fixture_probe"), 22)
					elseif consumer == "mouse" then
						helpers.assert_eq(require("adapters.mouse_control").getPos().x, 22)
					elseif consumer == "directory" then
						local entries, listed = require("infra.fs_dir").try_entries("system-fixture-directory")
						helpers.assert_eq(listed, true)
						helpers.assert_eq(#entries, 1)
						helpers.assert_eq(entries[1], "22")
					elseif consumer == "task" then
						local task = require("adapters.task_lifecycle").native(
							"fixture_probe", "/fixture-task", function() end, {})
						helpers.assert_not_nil(task)
						helpers.assert_eq(calls[11], 0, "retired native constructor must not run")
						helpers.assert_eq(calls[22], 1)
					else
						local delivered = 0
						helpers.assert_eq(require("infra.deferred_work").after(0, function()
							delivered = delivered + 1
						end, "fixture_probe"), true)
						helpers.assert_eq(calls[11], 0, "retired native timer must not run")
						helpers.assert_eq(calls[22], 1)
						support.fire_latest_timer(second.hs)
						helpers.assert_eq(delivered, 1)
					end
					helpers.assert_true(require("adapters.key_state") ~= previous_key_state)
					helpers.assert_true(require("infra.notifications") ~= previous_notifications)
				end)
				for _, name in ipairs(OWNERS) do helpers.assert_nil(package.loaded[name], name) end
			end)
		end)
	end

	helpers.it("(system-fixture-scope) registers suites without changing native dependencies", function()
		with_observer(function()
			local expected = {}
			for _, name in ipairs(OWNERS) do
				expected[name] = {}
				package.loaded[name] = expected[name]
			end
			local native = rawget(_G, "hs")
			local modules = {
				"tests.support.system_actions_fixture",
				"tests.unit.modules.shortcuts.test_actions_system",
			}
			for _, suffix in ipairs({ "capslock", "keep_awake", "wrap_decisions", "screenshots",
				"selection_cache", "random_bounds", "provenance_fences" }) do
				modules[#modules + 1] = "tests.unit.modules.shortcuts.system_actions.test_" .. suffix
			end
			local registrations = 0
			helpers.describe = function() registrations = registrations + 1 end
			helpers.with_fresh_modules(modules, function()
				for _, name in ipairs(modules) do require(name) end
			end)
			helpers.assert_eq(registrations, 9)
			helpers.assert_true(rawequal(rawget(_G, "hs"), native))
			for _, name in ipairs(OWNERS) do
				helpers.assert_true(package.loaded[name] == expected[name], name .. " must remain unchanged")
			end
		end)
	end)
end)
