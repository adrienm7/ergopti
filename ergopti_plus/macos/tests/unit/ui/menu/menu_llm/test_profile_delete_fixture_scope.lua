--- tests/unit/ui/menu/menu_llm/test_profile_delete_fixture_scope.lua

--- ==============================================================================
--- MODULE: Profile Deletion Fixture Isolation
--- DESCRIPTION:
--- Verifies exact native and module restoration across fixture outcomes and
--- proves real timer consumers bind to each fresh fixture's native clock.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.profile_delete_fixture")

local function snapshot()
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	return saved
end

local function with_observer(callback)
	local saved, native = snapshot(), _G.hs
	local loader = package.preload["ui.menu.menu_llm.profiles_manager"]
	local outcome = table.pack(xpcall(callback, debug.traceback))
	package.preload["ui.menu.menu_llm.profiles_manager"] = loader
	_G.hs = native
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("Profile deletion fixture ownership (profile-delete-fixture-scope)", function()
	for _, initial in ipairs({ "absent", "false", "existing" }) do
		for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
			helpers.it("restores " .. initial .. " profile owners after " .. mode, function()
				with_observer(function()
					local sentinel
					if initial == "false" then sentinel = false end
					if initial == "existing" then sentinel = {} end
					for _, name in ipairs({ "adapters.timer_scheduler", "ui.menu.preferences_transaction",
						"ui.menu.menu_llm.prediction_lock_registry", "ui.menu.menu_llm.profiles_manager",
						"ui.menu.menu_llm.trigger_orchestrator", "infra.logger" }) do
						package.loaded[name] = sentinel
					end
					_G.hs = sentinel
					local expected = snapshot()
					local marker = "injected profile fixture failure"
					local constructions, callbacks = 0, 0
					if mode == "construction failure" then
						package.preload["ui.menu.menu_llm.profiles_manager"] = function()
							constructions = constructions + 1
							error(marker, 0)
						end
					end
					local ok, reason = pcall(Fixture.with_delete_fixture, { real_switcher = true },
						function(fixture, delete_action)
							callbacks = callbacks + 1
							helpers.assert_type(delete_action, "function")
							helpers.assert_type(fixture.switcher.set_llm_profile, "function")
							if mode == "callback failure" then error(marker, 0) end
						end)
					helpers.assert_eq(ok, mode == "success", tostring(reason))
					if mode ~= "success" then
						helpers.assert_true(tostring(reason):find(marker, 1, true) ~= nil,
							"the original injected failure must propagate")
					end
					helpers.assert_eq(constructions, mode == "construction failure" and 1 or 0)
					helpers.assert_eq(callbacks, mode == "construction failure" and 0 or 1)
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

	helpers.it("rebinds the real timer consumer on consecutive profile fixtures", function()
		with_observer(function()
			package.loaded["adapters.timer_scheduler"] = nil
			local previous
			for attempt = 1, 2 do
				Fixture.with_delete_fixture({ real_switcher = true }, function()
					local reads = 0
					_G.hs.timer.secondsSinceEpoch = function()
						reads = reads + 1
						return attempt * 101
					end
					local timer = require("adapters.timer_scheduler")
					helpers.assert_eq(timer.now(), attempt * 101)
					helpers.assert_eq(reads, 1, "the current native clock must receive the call")
					if previous then helpers.assert_true(timer ~= previous) end
					previous = timer
				end)
			end
		end)
	end)
end)
