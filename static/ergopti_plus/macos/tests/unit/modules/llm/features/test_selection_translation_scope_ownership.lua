--- tests/unit/modules/llm/features/test_selection_translation_scope_ownership.lua

--- ==============================================================================
--- MODULE: Selection Translation Fixture Scope Ownership
--- DESCRIPTION:
--- Builds the real selection pipeline with a cold MLX retirement dependency.
--- Successful construction and an assertion failure must restore every exact
--- package entry, native hs identity and the preloaded logger/profile owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.modules.llm.selection_translation_fixture")
local Scope = require("tests.support.modules.llm.selection_translation_scope")
local SharedLogger = require("logger")
local NATIVE_GLOBALS = {
	"ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME", "ERGOPTI_TOUCH_DEVICES",
	"ERGOPTI_TOUCH_WATCHERS", "ERGOPTI_TOUCH_WATCHER_TOKENS", "lfs",
}

--- Owns only the test's explicit native-global preconditions, even on failure.
--- @param cold boolean Whether the five native globals must initially be absent.
--- @param scenario function Receives the old sentinel owners.
local function with_native_globals(cold, scenario)
	local previous, sentinels = {}, {}
	for index, name in ipairs(NATIVE_GLOBALS) do
		previous[index] = rawget(_G, name)
		local value
		if not cold then value = index == 1 and true or {} end
		sentinels[index] = value
		rawset(_G, name, value)
	end
	local result = table.pack(xpcall(function() scenario(sentinels) end, debug.traceback))
	for index, name in ipairs(NATIVE_GLOBALS) do rawset(_G, name, previous[index]) end
	if not result[1] then error(result[2], 0) end
end

--- Captures exact cache identities without clearing unrelated owners.
--- @return table snapshot
local function snapshot()
	local entries = {}
	for name, value in pairs(package.loaded) do entries[name] = value end
	local globals = {}
	for name, value in pairs(_G) do globals[name] = value end
	return { entries = entries, globals = globals, hs = rawget(_G, "hs"), logger = package.loaded["infra.logger"] }
end

--- Checks both removed entries and newly published values without rewriting them.
--- @param before table Exact prior namespace.
--- @param after table Current namespace.
--- @param label string Diagnostic namespace.
local function assert_entries(before, after, label)
	local changed = {}
	for name, value in pairs(before) do
		if not rawequal(after[name], value) then changed[name] = true end
	end
	for name, value in pairs(after) do
		if not rawequal(before[name], value) then changed[name] = true end
	end
	local names = {}
	for name in pairs(changed) do names[#names + 1] = name end
	table.sort(names)
	helpers.assert_eq(#names, 0, "fixture changed " .. label .. ": " .. table.concat(names, ", "))
end

--- Checks every cache/global identity before the outer precondition cleanup.
--- @param before table Snapshot from before fixture construction.
local function assert_restored(before)
	assert_entries(before.entries, package.loaded, "package.loaded entries")
	assert_entries(before.globals, _G, "globals")
	helpers.assert_true(rawequal(rawget(_G, "hs"), before.hs), "fixture changed the native hs identity")
	helpers.assert_true(rawequal(package.loaded["infra.logger"], before.logger), "fixture replaced the native logger owner")
	helpers.assert_true(rawequal(package.loaded.logger, SharedLogger), "fixture replaced the preloaded shared logger")
end

--- Exercises the actual fixture without letting outer cleanup mask its leaks.
--- @param cold boolean Native owners start absent instead of pre-existing.
--- @param forced boolean Raise the exact assertion after fixture construction.
local function check_scope(cold, forced)
	with_native_globals(cold, function(sentinels)
		if cold then
			for _, name in ipairs(NATIVE_GLOBALS) do
				helpers.assert_nil(rawget(_G, name), "native precondition must be cold: " .. name)
			end
		end
		-- These are fixture preconditions, not a whole-cache rollback. The inner
		-- scope itself must restore its cold dependency and a pre-existing owner.
		helpers.with_fresh_modules({ "modules.llm.profiles", "modules.llm.mlx_stream_retirement", "adapters.event_provenance",
			"json", "llm.translate", "compat.utf8", "tests.support.modules.llm.selection_translation_destination" }, function()
			local profile = {}
			package.loaded["modules.llm.profiles"] = profile
			for _, name in ipairs({ "modules.llm.mlx_stream_retirement", "adapters.event_provenance",
				"json", "llm.translate", "compat.utf8", "tests.support.modules.llm.selection_translation_destination" }) do
				helpers.assert_nil(package.loaded[name], "the transitive fixture owner must start cold: " .. name)
			end
			local before = snapshot()
			local ok, detail = pcall(function()
				Scope.run(function()
					local world = World.build_world()
					helpers.assert_type(world.flow.run, "function", "the actual selection pipeline must be constructed")
					helpers.assert_type(package.loaded["modules.llm.mlx_stream_retirement"], "table",
						"the real MLX transport must acquire its transitive retirement helper")
					for _, name in ipairs(NATIVE_GLOBALS) do
						local owner = rawget(_G, name)
						if type(owner) == "table" then owner.__scope_fixture_write = true end
					end
					if forced then helpers.assert_true(false, "forced selection fixture scope failure") end
				end)
			end)
			if forced then
				helpers.assert_true(not ok and tostring(detail):find("forced selection fixture scope failure", 1, true) ~= nil,
					"the fixture must unwind the intended assertion failure")
			else
				helpers.assert_true(ok, tostring(detail))
			end
			assert_restored(before)
			if not cold then
				for index = 2, #NATIVE_GLOBALS do
					helpers.assert_nil(next(sentinels[index]), "fixture mutated a pre-existing native owner: " .. NATIVE_GLOBALS[index])
				end
			end
			helpers.assert_true(rawequal(package.loaded["modules.llm.profiles"], profile), "the exact prior profile must survive")
		end)
	end)
end

helpers.describe("selection translation fixture restores transitive owners", function()
	for _, cold in ipairs({ true, false }) do
		for _, forced in ipairs({ false, true }) do
			helpers.it("restores " .. (cold and "cold" or "pre-existing") .. " native owners after "
				.. (forced and "an assertion failure" or "successful construction"), function() check_scope(cold, forced) end)
		end
	end
end)
