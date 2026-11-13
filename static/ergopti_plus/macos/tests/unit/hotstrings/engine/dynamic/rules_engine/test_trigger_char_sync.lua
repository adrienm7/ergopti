--- tests/unit/hotstrings/engine/dynamic/rules_engine/test_trigger_char_sync.lua

--- ==============================================================================
--- MODULE: Regression — dynamic_hotstrings sources the trigger from keymap (F-HIGH-8)
--- DESCRIPTION:
--- hotstrings/engine/dynamic/core.lua used to source the RulesEngine's "global" trigger
--- character from PersonalInfo.get_trigger_char() — itself just personal_info.toml's
--- own independent default — instead of keymap_module.get_trigger_char(), the real
--- user-configurable magic key backed by CoreState.magic_key. Changing the magic
--- key via the menu never reached RulesEngine, permanently orphaning every
--- date/prefix rule the moment a user customized it.
---
--- Fix: M.start() now sources the trigger from keymap_module.get_trigger_char(),
--- and a live RulesEngine.set_trigger_char(char) is wired into menu_state.lua's
--- sync so a later magic-key change also reaches this engine without a reload.
---
--- This test drives the REAL boot order (modules.dynamic_hotstrings.M.start) with
--- a fake keymap module whose get_trigger_char() returns a custom character, and
--- asserts the interceptor captured via register_interceptor fires on that custom
--- character, not the "★" default that personal_info.toml would have supplied.
--- ==============================================================================

local helpers = require("tests.helpers")
local NBSP = string.char(0xC2, 0xA0)

-- Each boot owns a fresh programmable facade as well as both builtin engines.
-- Otherwise the cached default-off owner still names the preceding fake keymap
-- and correctly refuses a second startup against an unrelated native identity.
local active_fixture = nil
local function with_dynamic_fixture(body)
	helpers.with_stub_scope({ "hotstrings.engine.dynamic", "hotstrings.engine.dynamic.rules_engine",
		"hotstrings.engine.dynamic.personal_info", "hotstrings.engine.dynamic.user_code",
		"hotstrings.engine.dynamic.core", "hotstrings.engine.dynamic.user_source", "platform.input.synthetic_input",
		"core.events.timer_scheduler", "diagnostics.adapters.event_provenance", "hotstrings.engine.expander.utils",
		"core.fs.adapters.file_system", "settings.engine.paths", "platform.focus.application_notifier" }, function()
		local previous = active_fixture
		local fixture = { captures = 0, factory_loads = 0 }
		active_fixture = fixture
		local Source = require("hotstrings.engine.dynamic.user_source")
		local load = Source.load
		Source.load = function(...)
			fixture.factory_loads = fixture.factory_loads + 1
			return load(...)
		end
		local ok, problem = xpcall(body, debug.traceback)
		local Dyn = package.loaded["hotstrings.engine.dynamic"]
		local User = package.loaded["hotstrings.engine.dynamic.user_code"]
		local closed = User and User.is_enabled() == false and User.count() == 0
		-- Repair only the fixture's deliberate preview-stop refusal after all
		-- builtin trigger assertions, then require actual lifecycle retirement.
		if fixture.keymap then fixture.keymap.invalidate_hotstring_preview = function() return true end end
		local stopped = Dyn and Dyn.stop() == true
		Source.load = load
		active_fixture = previous
		if not ok then error(problem, 0) end
		helpers.assert_true(stopped, "this exact fake keymap's lifecycle must retire before cache restoration")
		helpers.assert_true(closed, "default-off programmable metadata must remain unadmitted")
		helpers.assert_eq(fixture.factory_loads, 0, "builtin trigger checks must never execute a user factory")
		helpers.assert_eq(fixture.captures, 0, "unavailable programmable native input must never be admitted")
	end)
end

local function empty_temp_file()
	local path = os.tmpname()
	local fh, err = io.open(path, "w")
	helpers.assert_not_nil(fh, "the RulesEngine fixture must materialize its empty TOML: " .. tostring(err))
	fh:close()
	return path
end

-- A fake keymap module exposing exactly what PersonalInfo.start / RulesEngine.start
-- consume, mirroring the shape used by test_date_rule_respects_group_disable.lua.
-- get_trigger_char() is the load-bearing addition: it returns a magic key distinct
-- from "★" so the test can prove RulesEngine listens to IT, not to personal_info.toml.
local function make_fake_keymap(custom_trigger)
	local captured_interceptor = nil
	local injected_count = 0
	return {
		-- No physical programmable destination exists in a builtin trigger fixture.
		capture_user_hotstring = function()
			active_fixture.captures = active_fixture.captures + 1
			return nil
		end,
		owns_user_hotstring = function() return false end,
		owns_user_hotstring_publication = function() return false end,
		owns_user_hotstring_publication_cached = function() return false end,
		commit_user_hotstring = function() return false end,
		has_registered_magic_action = function() return false end,
		get_trigger_char          = function() return custom_trigger end,
		is_section_enabled        = function() return true end,
		is_group_enabled          = function() return true end,
		register_lua_group        = function() end,
		set_post_load_hook        = function() end,
		set_group_context         = function() end,
		sort_mappings             = function() end,
		-- register_prefix_entries() registers the default personal-info phone/SSN/IBAN
		-- prefixes via _km.add() — a no-op here since this test only cares about the
		-- interceptor's trigger-char gate, not the registered mappings themselves.
		add                       = function() end,
		register_interceptor      = function(fn) captured_interceptor = fn end,
		dynamic_rule_within_delay      = function() return true end,
		register_preview_provider = function() end,
		registry_transaction      = function(_, mutation) return mutation() == true end,
		get_interceptor           = function() return captured_interceptor end,
		inject_dynamic            = function(delete_count, replacement, emitter, source, is_private)
			helpers.assert_eq(delete_count, 2, "the matched 'td' suffix must delete two characters")
			helpers.assert_true(type(replacement) == "string" and replacement ~= "",
				"the date rule must resolve to non-empty text")
			helpers.assert_eq(type(emitter), "function")
			helpers.assert_eq(source, "dynamic")
			helpers.assert_eq(is_private, true)
			injected_count = injected_count + 1
			return true
		end,
		get_injected_count        = function() return injected_count end,
	}
end

--- Builds a fake hs.eventtap.event that reports the given character.
--- @param char string The character the event should report via getCharacters.
--- @return table Fake event.
local function make_key_event(char)
	return {
		getFlags      = function() return { cmd = false, ctrl = false } end,
		getCharacters = function() return char end,
	}
end




-- ==============================================================================================
-- ==============================================================================================
-- ======= 1/ dynamic_hotstrings.start sources the trigger from keymap (F-HIGH-8 fix) ==========
-- ==============================================================================================
-- ==============================================================================================

helpers.describe("dynamic_hotstrings.start: RulesEngine listens to keymap's trigger, not personal_info's (F-HIGH-8)", function()

	helpers.it("interceptor fires on the fake keymap's custom trigger char, not the personal_info.toml default '★'", function()
		with_dynamic_fixture(function()
			-- Fresh module instances so no other test's captured interceptor/trigger leaks in.
			package.loaded["hotstrings.engine.dynamic"]             = nil
			package.loaded["hotstrings.engine.dynamic.rules_engine"] = nil
			package.loaded["hotstrings.engine.dynamic.personal_info"] = nil
			local DynHot = helpers.load_with_stubs("hotstrings.engine.dynamic")

			-- A scratch path with no [trigger_char] override, so PersonalInfo's own
			-- config load falls back to its DEFAULT_CONFIG.trigger_char = "★" — this
			-- is the wrong value the bug used to leak into RulesEngine.
			local scratch_toml = empty_temp_file()

			local CUSTOM_TRIGGER = "%"
			local fake_km = make_fake_keymap(CUSTOM_TRIGGER)
			active_fixture.keymap = fake_km

			local ok, started = pcall(DynHot.start, "/tmp/", fake_km, scratch_toml)
			os.remove(scratch_toml)
			helpers.assert_true(ok, "dynamic_hotstrings.start must not raise with a fake keymap")
			helpers.assert_true(started, "and must report an exact committed terminal")

			local interceptor = fake_km.get_interceptor()
			helpers.assert_true(type(interceptor) == "function",
				"dynamic_hotstrings.start must register an interceptor via the keymap module")

			-- The "★" default must NOT fire the interceptor's trigger-char gate anymore —
			-- proving RulesEngine is no longer listening to personal_info.toml's value.
			local star_result = interceptor(make_key_event("★"), "td", { start_is_word_boundary = true })
			helpers.assert_true(star_result == nil,
				"interceptor must NOT fire on the personal_info.toml default '★' once the keymap trigger differs")
			helpers.assert_eq(fake_km.get_injected_count(), 0,
				"the rejected trigger must not reach the replacement transaction")

			-- The keymap's custom trigger char DOES fire the gate (reaches match_buffer;
			-- returning "consume" for the registered "td" date rule proves the trigger
			-- comparison at rules_engine.lua's interceptor passed).
			local custom_result = interceptor(make_key_event(CUSTOM_TRIGGER), "td", { start_is_word_boundary = true })
			helpers.assert_eq(custom_result, "consume",
				"interceptor must fire and consume on the keymap's custom trigger char")
			helpers.assert_eq(fake_km.get_injected_count(), 1,
				"the accepted trigger must execute exactly one replacement transaction")
		end)
	end)

	helpers.it("accepts the French composite event for a punctuation trigger", function()
		with_dynamic_fixture(function()
			package.loaded["hotstrings.engine.dynamic"] = nil
			package.loaded["hotstrings.engine.dynamic.rules_engine"] = nil
			package.loaded["hotstrings.engine.dynamic.personal_info"] = nil
			local DynHot = helpers.load_with_stubs("hotstrings.engine.dynamic")
			local fake_km = make_fake_keymap(":")
			active_fixture.keymap = fake_km
			local scratch_toml = empty_temp_file()
			local started = DynHot.start("/tmp/", fake_km, scratch_toml)
			os.remove(scratch_toml)
			helpers.assert_eq(started, true,
				"the composite fixture must commit both engines before invoking the interceptor")

			local result = fake_km.get_interceptor()(make_key_event(NBSP .. ":"), "td", { start_is_word_boundary = true })
			helpers.assert_eq(result, "consume",
				"the date engine must accept the layout's single NBSP+colon keyDown payload")
			helpers.assert_eq(fake_km.get_injected_count(), 1)
		end)
	end)
end)

helpers.describe("dynamic date calendar observation", function()
	helpers.it("keeps the shared long-date expansion and previews on one calendar instant", function()
		helpers.with_stub_scope({ "dynamic_hotstrings" }, function()
			local engine = require("hotstrings.engine.dynamic.core")
			engine.reset_rules(); engine.register_date_rules("\\")
			local old_date, old_time = os.date, os.time
			local boundary = old_time({ year = 2024, month = 12, day = 31, hour = 23, min = 59, sec = 59 })
			local calls = 0
			os.time = function() return boundary end
			os.date = function(format, instant)
				if instant == nil then calls = calls + 1; instant = boundary + (calls > 1 and 1 or 0) end
				return old_date(format, instant)
			end
			local ok, err = pcall(function()
				local match = assert(engine.match_buffer("date", "dynamic", nil, true))
				helpers.assert_eq(match.result, "mardi 31 décembre 2024")
				calls = 0
				local dates = engine.today_date_strings()
				helpers.assert_eq(dates.iso, "2024_12_31")
				helpers.assert_eq(dates.fr, "31/12/2024")
				helpers.assert_eq(dates.long_fr, "mardi 31 décembre 2024")
			end)
			os.date, os.time = old_date, old_time
			if not ok then error(err, 0) end
		end)
	end)
end)
