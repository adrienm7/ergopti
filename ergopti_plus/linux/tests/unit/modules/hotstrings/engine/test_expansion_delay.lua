--- tests/unit/modules/hotstrings/engine/test_expansion_delay.lua

--- ==============================================================================
--- MODULE: The Per-Category Expansion Delay Actually Governs an Expansion
--- DESCRIPTION:
--- Covers the resolution half of the delay cascade, and pins the SEMANTICS the
--- daemon applies against the ones macOS applies.
---
--- WHY THIS EXISTS:
--- `hotstrings_config.resolve()` had no production caller on Linux until
--- 2026-08-05. The five-rung precedence, the shared DelayResolver both drivers
--- use, and every override the settings window persisted to disk resolved into
--- nothing: a user set a delay, the file recorded it, and expansions fired
--- exactly as before. The feature existed at every layer except the one where it
--- would have had an effect.
---
--- WHAT THE DELAY MEANS, because guessing would have produced a driver that
--- disagrees with macOS while looking implemented:
--- it is the maximum PAUSE BETWEEN CONSECUTIVE KEYSTROKES for which a trigger
--- stays live — `dt = now - last_key_time` in macos/modules/keymap/init.lua, and
--- the expansion fires only when `allowed_delay == 0 or dt <= allowed_delay`.
--- Zero means "always active". It is not a delay BEFORE expanding, and it is not
--- a total time budget for typing the trigger; both readings are plausible from
--- the name and both would be wrong.
---
--- The behavioural consequence is the one a user would describe: type half a
--- trigger, stop to think, come back — and the rest of the word must not turn
--- into an expansion you had stopped intending.
--- ==============================================================================

local helpers = require("tests.helpers")

local Config = helpers.load_module("modules.hotstrings.hotstrings_config")


--- The resolved delay for a category, in seconds.
--- @param category string
--- @param section string|nil
--- @return number|nil
local function delay_of(category, section)
	local resolved = Config.resolve(category, section)
	return type(resolved) == "table" and tonumber(resolved.delay) or nil
end





-- =========================================================
-- =========================================================
-- ======= 1/ An override reaches the resolver =============
-- =========================================================
-- =========================================================

helpers.describe("expansion delay: what the settings window writes is what resolves", function()

	helpers.it("a category override wins over the global default", function()
		Config._set_overrides_for_test({})
		local shipped = delay_of("rolls")
		helpers.assert_true(type(shipped) == "number",
			"every category must resolve to a number — the injector cannot compare against nil")

		-- The seam takes the stored form: seconds added to the base (0.75 s here).
		Config._set_overrides_for_test({ rolls = { delay_offset = 0.75, sections = {} } })
		helpers.assert_eq(delay_of("rolls"), 1.5,
			"the value the user typed in the settings window must be the one that resolves")
		Config._set_overrides_for_test({})
	end)

	helpers.it("a section override wins over its category", function()
		Config._set_overrides_for_test({
			rolls = { delay_offset = 0.75, sections = { fast = { delay_offset = -0.55 } } },
		})
		helpers.assert_eq(delay_of("rolls", "fast"), 0.2,
			"the narrower override must win, or a per-section setting is decoration")
		helpers.assert_eq(delay_of("rolls"), 1.5,
			"and it must not leak upward onto the category itself")
		Config._set_overrides_for_test({})
	end)

	helpers.it("clearing an override returns the shipped value, not zero", function()
		Config._set_overrides_for_test({ rolls = { delay_offset = 0.75, sections = {} } })
		local overridden = delay_of("rolls")
		Config._set_overrides_for_test({})
		local restored = delay_of("rolls")
		helpers.assert_true(restored ~= overridden,
			"clearing must actually change the resolved value")
		-- Zero means "always active" to the daemon, so a clear that resolved to 0
		-- would silently disable the window rather than restore the default.
		helpers.assert_true(restored ~= 0,
			"and must not resolve to 0, which the daemon reads as 'never expires'")
	end)

end)





-- =========================================================
-- =========================================================
-- ======= 2/ The window the daemon applies ================
-- =========================================================
-- =========================================================

-- The daemon's rule, extracted so the semantics can be asserted without driving
-- the whole keystroke path. It mirrors ergopti_hotstrings.lua: a gap LONGER than
-- the delay kills the match, a delay of 0 never does, and the very first
-- keystroke of a session has no previous timestamp to compare against.
--- @param delay_sec number|nil
--- @param last_ms number|nil
--- @param now_ms number
--- @return boolean Whether the expansion still fires.
local function fires(delay_sec, last_ms, now_ms)
	if not delay_sec or delay_sec <= 0 or not last_ms then return true end
	return ((now_ms - last_ms) / 1000) <= delay_sec
end


helpers.describe("expansion delay: the gap between keystrokes decides", function()

	helpers.it("fires when the user kept typing inside the window", function()
		helpers.assert_true(fires(0.75, 1000, 1400),
			"400 ms inside a 750 ms window is ordinary typing")
	end)

	helpers.it("does not fire when the user paused longer than the window", function()
		helpers.assert_true(not fires(0.75, 1000, 2000),
			"a second's pause means the user stopped; finishing the word must not expand it")
	end)

	helpers.it("fires exactly at the boundary", function()
		-- macOS compares with <=, so the boundary case fires. An exclusive
		-- comparison here would make the two drivers disagree on precisely the
		-- keystroke a user tuning their delay is testing with.
		helpers.assert_true(fires(0.75, 1000, 1750),
			"the comparison is <=, matching keymap/init.lua")
	end)

	helpers.it("a delay of zero never expires", function()
		helpers.assert_true(fires(0, 1000, 999999),
			"0 means 'always active' — the shipped behaviour for categories with no delay")
	end)

	helpers.it("the first keystroke of a session always fires", function()
		helpers.assert_true(fires(0.75, nil, 1000),
			"with no previous timestamp there is no gap, and refusing here would make the "
				.. "first expansion after every start silently fail")
	end)

end)





-- =========================================================
-- =========================================================
-- ======= 3/ The base delay and the offsets of it =========
-- =========================================================
-- =========================================================

--- Runs a body against an isolated configuration folder holding these files.
--- @param files table Map of file name to content, created before init.
--- @param body function Called with (config, directory, read).
local function with_config(files, body)
	local shell = helpers.load_module("adapters.shell_runner")
	shell._reset_runner()
	package.loaded["adapters.shell_runner"] = shell
	local directory = os.tmpname()
	os.remove(directory)
	assert(shell.run("mkdir -p " .. shell.quote(directory)))
	for name, content in pairs(files) do
		local handle = assert(io.open(directory .. "/" .. name, "wb"))
		assert(handle:write(content))
		assert(handle:close())
	end
	local function read(name)
		local handle = io.open(directory .. "/" .. name, "rb")
		if not handle then return nil end
		local content = handle:read("*a")
		handle:close()
		return content
	end
	local preferences = require("infra.hotstring_preferences")
	local fresh = helpers.load_module("modules.hotstrings.hotstrings_config")
	local ok, failure = xpcall(function()
		assert(preferences._set_file_for_test(directory .. "/config.toml"))
		assert(fresh._set_override_config_dir_for_test(directory))
		assert(fresh._set_config_file_for_test(directory .. "/config.toml"))
		assert(fresh.init(nil, directory .. "/catalogue.toml"))
		body(fresh, directory, read)
	end, debug.traceback)
	preferences._set_file_for_test(nil)
	fresh._set_override_config_dir_for_test(nil)
	fresh._set_config_file_for_test(nil)
	shell.run("rm -rf " .. shell.quote(directory))
	if not ok then error(failure, 0) end
end

helpers.describe("expansion delay: the base is a config.toml leaf and overrides are offsets of it", function()

	helpers.it("reads the user's hotstrings.expansion_delay and falls back to the shared default", function()
		with_config({ ["config.toml"] = "[hotstrings]\nexpansion_delay = 1.2\n" }, function(config)
			helpers.assert_eq(config.get_base_delay(), 1.2)
			helpers.assert_eq(config.has_base_delay_override(), true)
			helpers.assert_eq(config.resolve("rolls", nil).delay, 1.2, "a category with no delay of its own waits the base")
			helpers.assert_eq(config.get_global_default_delay_ms(), 1200, "the settings window shows the base")
		end)
		with_config({ ["config.toml"] = "[hotstrings]\nexpansion_delay = -3\n" }, function(config)
			helpers.assert_eq(config.get_base_delay(), 0.75, "a value the owner refuses is read as absent")
		end)
		with_config({}, function(config)
			helpers.assert_eq(config.get_base_delay(), 0.75)
			helpers.assert_eq(config.has_base_delay_override(), false)
		end)
	end)

	helpers.it("stores a delay override as an offset of the base and keeps it when the base moves", function()
		with_config({}, function(config, _, read)
			helpers.assert_eq(config.set_override("rolls", nil, "delay", 1.2), true)
			helpers.assert_contains(read("hotstrings_overrides.toml"), "delay_offset = 0.45")
			helpers.assert_nil(read("hotstrings_overrides.toml"):find("\ndelay = ", 1, true))
			helpers.assert_eq(config.resolve("rolls", nil).delay, 1.2)
			helpers.assert_eq(config.get_user_override("rolls").delay, 1.2, "the window reads the effective seconds")

			helpers.assert_eq(config.set_base_delay(1.0), true)
			helpers.assert_contains(read("config.toml"), "expansion_delay = 1")
			helpers.assert_eq(config.resolve("rolls", nil).delay, 1.45, "the override follows the base")
			helpers.assert_eq(config.get_user_override("rolls").delay, 1.45)
			helpers.assert_contains(read("hotstrings_overrides.toml"), "delay_offset = 0.45",
				"the file holds the offset, which a base change leaves alone")

			helpers.assert_eq(config.set_base_delay(nil), true)
			helpers.assert_eq(config.has_base_delay_override(), false, "restoring the default drops the leaf")
			helpers.assert_eq(config.resolve("rolls", nil).delay, 1.2)
			helpers.assert_eq(config.clear_override("rolls", nil, "delay"), true)
			helpers.assert_nil(config.get_user_override("rolls").delay)
			helpers.assert_eq(config.resolve("rolls", nil).delay, 0.75)
		end)
	end)

	helpers.it("keeps an unlimited delay unlimited whatever the base", function()
		with_config({}, function(config, _, read)
			helpers.assert_eq(config.set_override("rolls", nil, "delay", 0), true)
			helpers.assert_contains(read("hotstrings_overrides.toml"), "delay_unlimited = true")
			helpers.assert_eq(config.resolve("rolls", nil).delay, 0)
			helpers.assert_eq(config.set_base_delay(2.5), true)
			helpers.assert_eq(config.resolve("rolls", nil).delay, 0, "0 is not an offset of the base")
		end)
	end)

	helpers.it("never lets an offset that cancels the base become the unlimited delay", function()
		with_config({ ["hotstrings_overrides.toml"] = "[rolls]\ndelay_offset = -0.75\n" }, function(config)
			helpers.assert_eq(config.resolve("rolls", nil).delay, 0.001,
				"0.75 s - 0.75 s is one millisecond, not 'never expires'")
		end)
	end)

	helpers.it("replays the shared base delay corpus the other drivers replay", function()
		local path = assert(helpers.load_module("infra.paths").shared("tests/corpus/hotstrings/base_delay_vectors.json"))
		local handle = assert(io.open(path, "rb"))
		local corpus = require("json").decode(handle:read("*a"))
		handle:close()
		helpers.assert_true(#corpus.vectors > 0, "a corpus with no vectors proves nothing")
		for _, vector in ipairs(corpus.vectors) do
			with_config({}, function(config, _, read)
				for _, step in ipairs(vector.steps) do
					if step.op == "set" then
						helpers.assert_eq(config.set_override(step.category, step.section, "delay", step.delay), true, vector.id)
					elseif step.op == "clear" then
						helpers.assert_eq(config.clear_override(step.category, step.section, "delay"), true, vector.id)
					else
						helpers.assert_eq(step.op, "base", vector.id)
						helpers.assert_eq(config.set_base_delay(step.seconds), true, vector.id)
					end
				end
				for _, expected in ipairs(vector.expect) do
					helpers.assert_eq(config.resolve(expected.category, expected.section).delay, expected.delay,
						vector.id .. ": effective delay of " .. expected.category .. "." .. tostring(expected.section))
				end
				local decoded = require("toml_codec").decode(read("hotstrings_overrides.toml") or "")
				for key, leaves in pairs(vector.stored) do
					local category, section = key:match("^([^.]+)%.?(.*)$")
					local record = section ~= "" and decoded[category][section] or decoded[category]
					for leaf, value in pairs(leaves) do
						helpers.assert_eq(record[leaf], value, vector.id .. ": stored " .. key .. "." .. leaf)
					end
				end
				if next(vector.stored) == nil then
					helpers.assert_nil(next(decoded.rolls or {}), vector.id .. ": no value left in the file")
				end
			end)
		end
	end)

	helpers.it("migrates the absolute delays and the default delay of earlier builds without changing any", function()
		local legacy = "# my notes\n[_global]\ndelay = 1.5\n[rolls]\ndelay = 2.0\ncolor = \"#112233\"\n"
			.. "[rolls.ct]\ndelay = 0\n[magickey]\ndelay_offset = 0.25\n"
		with_config({ ["hotstrings_overrides.toml"] = legacy }, function(config, _, read)
			helpers.assert_eq(config.resolve("rolls", nil).delay, 2.0, "an absolute delay applies as it was before the migration")
			helpers.assert_eq(config.resolve("rolls", "ct").delay, 0)
			config.migrate_legacy_delays()
			helpers.assert_eq(config.get_base_delay(), 1.5, "the old default delay is the base now")
			helpers.assert_contains(read("config.toml"), "expansion_delay = 1.5")
			helpers.assert_eq(config.resolve("rolls", nil).delay, 2.0)
			helpers.assert_eq(config.resolve("rolls", "ct").delay, 0)
			helpers.assert_eq(config.resolve("magickey", nil).delay, 1.75, "an offset already stored follows the migrated base")
			local text = read("hotstrings_overrides.toml")
			helpers.assert_contains(text, "delay_offset = 0.5")
			helpers.assert_contains(text, "delay_unlimited = true")
			helpers.assert_contains(text, "# my notes", "the user's comments survive")
			helpers.assert_contains(text, '#112233')
			helpers.assert_nil(text:find("\ndelay = ", 1, true), "no absolute delay remains")
			helpers.assert_nil(text:find("_global", 1, true), "the old default delay record is gone")
			local before = text
			config.migrate_legacy_delays()
			helpers.assert_eq(read("hotstrings_overrides.toml"), before, "a second pass changes nothing")
		end)
	end)

end)
