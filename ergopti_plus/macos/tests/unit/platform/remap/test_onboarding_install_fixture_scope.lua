--- tests/unit/platform/remap/test_onboarding_install_fixture_scope.lua

--- ==============================================================================
--- MODULE: Onboarding Installer Fixture Isolation
--- DESCRIPTION:
--- Exercises construction and scenario failures while independently observing
--- filesystem functions, native globals, and exact module cache restoration.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")

local function snapshot()
	local result = {}
	for name, value in pairs(package.loaded) do result[name] = value end
	return result
end

local function with_observer(callback)
	local saved = snapshot()
	local native, open, remove, rename = _G.hs, io.open, os.remove, os.rename
	local loader = package.preload["adapters.task_lifecycle"]
	local outcome = table.pack(xpcall(callback, debug.traceback))
	package.preload["adapters.task_lifecycle"] = loader
	_G.hs, io.open, os.remove, os.rename = native, open, remove, rename
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("Onboarding fixture ownership (onboarding-fixture-scope)", function()
	for _, initial in ipairs({ "absent", "false", "existing" }) do
		for _, mode in ipairs({ "success", "scenario failure", "construction failure" }) do
			helpers.it("restores " .. initial .. " boundaries after " .. mode, function()
				with_observer(function()
					local sentinel
					if initial == "false" then sentinel = false end
					if initial == "existing" then sentinel = {} end
					for _, name in ipairs({ "platform.remap.onboarding", "adapters.task_lifecycle",
						"adapters.task_environment", "infra.launcher_environment",
						"adapters.timer_scheduler", "infra.logger", "hs", "tests.stubs.hs" }) do
						package.loaded[name] = sentinel
					end
					_G.hs = sentinel
					local expected = snapshot()
					local open, remove, rename = io.open, os.remove, os.rename
					local marker = "injected onboarding fixture failure"
					local constructions, scenarios = 0, 0
					if mode == "construction failure" then
						package.preload["adapters.task_lifecycle"] = function()
							constructions = constructions + 1
							error(marker, 0)
						end
					end
					local ok, reason = pcall(Fixture.with_fixture, {}, function(onboarding)
						scenarios = scenarios + 1
						helpers.assert_type(onboarding.install_karabiner_elements, "function")
						if mode == "scenario failure" then error(marker, 0) end
					end)
					helpers.assert_eq(ok, mode == "success")
					if mode ~= "success" then
						helpers.assert_true(tostring(reason):find(marker, 1, true) ~= nil,
							"the original failure must propagate")
					end
					helpers.assert_eq(constructions, mode == "construction failure" and 1 or 0)
					helpers.assert_eq(scenarios, mode == "construction failure" and 0 or 1)
					helpers.assert_true(io.open == open, "restore io.open after construction")
					helpers.assert_true(os.remove == remove, "restore os.remove after construction")
					helpers.assert_true(os.rename == rename, "restore os.rename after construction")
					helpers.assert_true(rawequal(_G.hs, sentinel), "restore native identity")
					for name, value in pairs(expected) do
						helpers.assert_true(rawequal(package.loaded[name], value), "restore module: " .. name)
					end
					for name in pairs(package.loaded) do
						helpers.assert_true(expected[name] ~= nil, "no module residue: " .. name)
					end
				end)
			end)
		end
	end
end)
