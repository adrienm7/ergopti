--- tests/unit/modules/hotstrings/magic_key/test_magic_key_catalogue.lua

--- ==============================================================================
--- MODULE: Magic-Key Catalogue Substitution
--- DESCRIPTION:
--- Proves that the configured magic key replaces the shipped suffix across the
--- complete static catalogue, both on live reload and on a fresh manager.
--- ==============================================================================

local helpers = require("tests.helpers")

local function ends_with(value, suffix)
	return type(value) == "string" and type(suffix) == "string"
		and suffix ~= "" and #value >= #suffix and value:sub(-#suffix) == suffix
end

local function pack(name)
	return require("core.fs.engine.paths").shared("hotstrings/data/catalogue/" .. name)
end

helpers.describe("magic key: static catalogue ownership", function()

	helpers.it("moves every shipped magic-key trigger and leaves every other trigger intact", function()
		local Loader = helpers.load_module("modules.hotstrings.loader")
		-- The French pack carries most of the ★ abbreviations since the language split.
		local paths = { pack("magickey.toml"), pack("french/magickey.toml"), pack("sfbsreduction.toml") }
		local canonical = Loader.load_catalogue(paths).mappings
		local custom = Loader.load_catalogue(paths, {
			magic_key = "§",
			canonical_magic_key = "★",
		}).mappings

		helpers.assert_eq(#custom, #canonical, "substitution must neither add nor drop mappings")
		local moved = 0
		for index, before in ipairs(canonical) do
			local after = custom[index]
			if ends_with(before.trigger, "★") then
				moved = moved + 1
				local base = before.trigger:sub(1, #before.trigger - #"★")
				helpers.assert_eq(after.trigger, base .. "§",
					"owned trigger did not move at catalogue index " .. index)
				helpers.assert_eq(ends_with(after.trigger, "★"), false,
					"an owned trigger remained on the shipped key")
			else
				helpers.assert_eq(after.trigger, before.trigger,
					"a trigger with no magic-key suffix must stay byte-identical")
			end
		end
		helpers.assert_true(moved >= 900,
			"the full shipped pack must be covered, not a small fixture; moved " .. moved)
	end)

	helpers.it("applies a new key on reload and after a fresh config-manager start", function()
		local temporary = os.tmpname()
		os.remove(temporary)
		local path = temporary .. "_magic_key.toml"
		local file = assert(io.open(path, "w"))
		file:write([=[
[[probe]]
"alpha★" = { output = "expanded", is_word = false, auto_expand = true }
"plain" = { output = "unchanged", is_word = false, auto_expand = true }
]=])
		file:close()

		-- The group switches below are preferences: keep them out of the real config.toml.
		local preferences = require("infra.hotstring_preferences")
		local preferences_path = temporary .. "_preferences.toml"
		assert(preferences._set_file_for_test(preferences_path))
		-- Category and section switches go through the configuration owner's own
		-- choices file: without this route they landed in the real config.toml.
		local choices_path = temporary .. "_choices.toml"
		local user_config = require("settings.engine.paths").config("config.toml")
		local before = io.open(user_config, "rb")
		local before_bytes = before and before:read("*a")
		if before then before:close() end

		local ok, err = pcall(function()
			local loaded = nil
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			local load = engine.load_mappings
			engine.load_mappings = function(self, mappings) loaded = mappings; return load(self, mappings) end
			helpers.assert_true(Config._set_config_file_for_test(choices_path))
			Config.init(engine, path, nil)
			helpers.assert_true(Config.set_magic_key("§", "★"))
			Config.load_all()
			for category in pairs(Config.get_categories()) do
				helpers.assert_true(Config.set_all_sections(category, true))
			end
			helpers.assert_eq(loaded[1].trigger, "alpha§", "startup must use the configured key")
			helpers.assert_eq(loaded[2].trigger, "plain", "unowned triggers must stay unchanged")

			-- Exercise the actual preference and catalogue owners with a declined reload.
			helpers.assert_true(preferences.set("hotstrings.trigger_char", "§"))
			local Magic = require("modules.hotstrings.magic_key")
			local scope = require("infra.hotstrings_scope").new_magic({ path = preferences_path,
				backup_path = temporary .. "_scope.bak", config = Config, preferences = preferences,
				magic_key = Magic, reload = function() return false end })
			local applied = scope.apply_updates({ { section = "hotstrings", key = "trigger_char", value = "◆" } })
			helpers.assert_eq(applied, false)
			helpers.assert_eq(Magic.get(), "§")
			helpers.assert_eq(loaded[1].trigger, "alpha§", "the old real matcher remains active")
			helpers.assert_eq(scope.pending(), false)
			local accepted = require("infra.hotstrings_scope").new_magic({ path = preferences_path,
				backup_path = temporary .. "_scope2.bak", config = Config, preferences = preferences,
				magic_key = Magic, reload = function() local _, committed = Config.reload(); return committed end })
			helpers.assert_true(accepted.apply_updates({ { section = "hotstrings", key = "trigger_char", value = "◆" } }))
			helpers.assert_eq(Magic.get(), "◆")
			helpers.assert_eq(loaded[1].trigger, "alpha◆")
			os.remove(temporary .. "_scope2.bak")
			os.remove(temporary .. "_scope.bak")

			helpers.assert_true(Config.set_magic_key("◆", "★"))
			Config.reload()
			helpers.assert_eq(loaded[1].trigger, "alpha◆", "live reload must retire the previous key")
			helpers.assert_eq(ends_with(loaded[1].trigger, "★"), false)
			helpers.assert_eq(ends_with(loaded[1].trigger, "§"), false)

			loaded = nil
			Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			local load = engine.load_mappings
			engine.load_mappings = function(self, mappings) loaded = mappings; return load(self, mappings) end
			helpers.assert_true(Config._set_config_file_for_test(choices_path))
			Config.init(engine, path, nil)
			helpers.assert_true(Config.set_magic_key("§", "★"))
			Config.load_all()
			helpers.assert_eq(loaded[1].trigger, "alpha§",
				"a fresh process must reconstruct the same configured catalogue")
		end)

		local owner = package.loaded["modules.hotstrings.hotstrings_config"]
		if owner then owner._set_config_file_for_test(nil) end
		preferences._set_file_for_test(nil)
		os.remove(preferences_path)
		os.remove(choices_path)
		os.remove(choices_path .. ".tmp")
		os.remove(path)
		local after = io.open(user_config, "rb")
		local after_bytes = after and after:read("*a")
		if after then after:close() end
		helpers.assert_eq(after_bytes, before_bytes, "the scenario must not write the user's config.toml")
		if not ok then error(err, 0) end
	end)

end)

helpers.describe("magic-key transactional publication", function()
	local function scenario(restore_refused, accept_reload, notification_refused)
		local path = os.tmpname()
		local initial = '[hotstrings]\ntrigger_char = "★"\n'
		local file = assert(io.open(path, "wb")); assert(file:write(initial)); assert(file:close())
		local current, active, locked, preference_locked = "★", "★", false, false
		local fail_restore, fail_notice, restore_calls = restore_refused, notification_refused, 0
		local Config = {
			acquire = function() locked = true; return true end,
			release = function() locked = false; return true end,
			configuration_snapshot = function() return { value = active } end,
			set_magic_key = function(value) active = value; return true end,
			restore_configuration = function(_, snapshot)
				restore_calls = restore_calls + 1
				if fail_restore then return false end
				active = snapshot.value; return true
			end,
		}
		local Preferences = {
			acquire = function() preference_locked = true; return true end,
			release = function() preference_locked = false; return true end,
			snapshot = function() return { value = current } end,
			adopt = function(_, document) current = document.hotstrings.trigger_char or "★"; return true end,
			restore = function(_, snapshot) current = snapshot.value; return true end,
		}
		local Magic = { get = function() return current end, default = function() return "★" end,
			validate = function(value) return value == "★" or value == "§" end }
		local owner = require("infra.hotstrings_scope").new_magic({ path = path, backup_path = path .. ".bak",
			config = Config, preferences = Preferences, magic_key = Magic, reload = function() return accept_reload == true end,
			after_restore = function() return not fail_notice end })
		local ok, error_message = owner.apply_updates({ { section = "hotstrings", key = "trigger_char", value = "§" } })
		if accept_reload then
			helpers.assert_true(ok, tostring(error_message))
			helpers.assert_eq(current, "§")
			helpers.assert_eq(active, "§")
			local input = assert(io.open(path, "rb")); local bytes = input:read("*a"); input:close()
			helpers.assert_true(bytes:find("§", 1, true) ~= nil, "the accepted key is persisted")
			helpers.assert_eq(owner.pending(), false)
			os.remove(path); os.remove(path .. ".bak")
			return
		end
		helpers.assert_eq(ok, false, "a refused catalogue cannot publish the new key")
		local input = assert(io.open(path, "rb")); local bytes = input:read("*a"); input:close()
		helpers.assert_eq(bytes, initial, "the file keeps the previous choice")
		if notification_refused then
			helpers.assert_true(owner.pending(), "a refused notification remains pending")
			helpers.assert_true(locked and preference_locked, "the owners stay fenced until notification succeeds")
			helpers.assert_eq(restore_calls, 1)
			fail_notice = false
			helpers.assert_true(owner.retry_restore())
			helpers.assert_eq(restore_calls, 1, "retry must not repeat the acknowledged catalogue inverse")
		end
		if restore_refused then
			helpers.assert_true(owner.pending(), "a refused inverse remains debt: " .. tostring(error_message))
			helpers.assert_true(locked and preference_locked, "both owners remain fenced")
			fail_restore = false
			helpers.assert_true(owner.retry_restore())
		end
		helpers.assert_eq(current, "★")
		helpers.assert_eq(active, "★")
		helpers.assert_eq(owner.pending(), false)
		helpers.assert_eq(locked or preference_locked, false)
		os.remove(path); os.remove(path .. ".bak")
	end
	helpers.it("retains an unacknowledged programmable cancellation", function()
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); file:write('[hotstrings]\ntrigger_char = "★"\n'); file:close()
		local trigger, cancelling, init_calls = "★", true, 0
		local config = { acquire = function() return true end, release = function() return true end,
			configuration_snapshot = function() return {} end, set_magic_key = function() return true end,
			restore_configuration = function() return true end }
		local preferences = { acquire = function() return true end, release = function() return true end,
			snapshot = function() return {} end, adopt = function(_, doc) trigger = doc.hotstrings.trigger_char; return true end,
			restore = function() trigger = "★"; return true end }
		local magic = { get = function() return trigger end, default = function() return "★" end,
			validate = function() return true end }
		local dynamic = { user_code_time_activation = function() return 1 end,
			user_code_scope_snapshot = function() return {} end, user_code_scope_current = function() return true end,
			refresh = function() return not cancelling, "programmable-refused" end,
			get_rules_count = function() return 1 end,
			init = function() init_calls = init_calls + 1; return true end }
		local owner = require("infra.hotstrings_scope").new_magic({ path = path, backup_path = path .. ".bak",
			config = config, preferences = preferences, magic_key = magic, dynamic = dynamic,
			reload = function() error("a cancellation refusal must stop the reload") end })
		helpers.assert_eq(owner.apply_updates({ { section = "hotstrings", key = "trigger_char", value = "§" } }), false)
		helpers.assert_true(owner.pending())
		helpers.assert_eq(init_calls, 0, "no dynamic reset while cancellation is unacknowledged")
		cancelling = false
		helpers.assert_true(owner.retry_restore())
		helpers.assert_eq(trigger, "★")
		helpers.assert_eq(init_calls, 1)
		os.remove(path); os.remove(path .. ".bak")
	end)

	helpers.it("publishes the accepted choice to the catalogue and file", function() scenario(false, true) end)
	helpers.it("keeps the old choice when catalogue reload refuses", function() scenario(false) end)
	helpers.it("retains both fences until a refused restoration settles", function() scenario(true) end)
	helpers.it("retains notification debt without repeating restored state", function() scenario(false, false, true) end)
end)

helpers.describe("magic-key restoration after publication refusal", function()
	helpers.it("restores real matcher prefixes and menu after a successful candidate reload", function()
		local temporary = os.tmpname(); os.remove(temporary)
		local path, rules, info, backup = temporary .. "_preferences.toml", temporary .. "_rules.toml",
			temporary .. "_info.toml", temporary .. "_backup.toml"
		local function write(name, content)
			local f = assert(io.open(name, "wb")); assert(f:write(content)); assert(f:close())
		end
		write(rules, '[[probe]]\n"alpha★" = { output = "expanded", is_word = false, auto_expand = true }\n')
		write(info, '[info]\nphone_number = "0750123456"\n')
		local Preferences = require("infra.hotstring_preferences")
		local Writer = require("core.text.engine.toml_codec.writer")
		local original_publish = Writer.publish_if_unchanged
		local old_manager, old_engine = package.loaded["modules.dynamic_hotstrings.manager"], package.loaded["hotstrings.engine.dynamic.core"]
		local old_user_code = package.loaded["modules.dynamic_hotstrings.user_code"]
		local old_config = package.loaded["modules.hotstrings.hotstrings_config"]
		local Config
		local ok, err = xpcall(function()
			assert(Preferences._set_file_for_test(path))
			assert(Preferences.set("hotstrings.dynamic.enabled", true))
			package.loaded["hotstrings.engine.dynamic.core"] = nil
			package.loaded["modules.dynamic_hotstrings.user_code"] = nil
			local Dynamic = helpers.load_module("modules.dynamic_hotstrings.manager")
			assert(Dynamic.set_rule_enabled("phoneprefixes", true))
			assert(Dynamic.init({ trigger_char = "★", personal_info_path = info }))
			local wrapped = setmetatable({ init = function(options)
				return Dynamic.init({ trigger_char = options.trigger_char, personal_info_path = info })
			end }, { __index = Dynamic })
			local Magic = require("modules.hotstrings.magic_key")
			local menu, loaded, saw_candidate = nil, nil, false
			local engine = require("hotstrings.engine.matcher").new()
			local load = engine.load_mappings
			engine.load_mappings = function(self, mappings) loaded = mappings; return load(self, mappings) end
			Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			assert(Config._set_config_file_for_test(path))
			Config.init(engine, rules, function() menu = Magic.get() end)
			assert(Config.set_extra_mappings_provider(Dynamic.prefix_mappings))
			assert(Config.set_magic_key("★", "★"))
			local _, initial = Config.load_all(); assert(initial)
			local function has(trigger)
				for _, entry in ipairs(loaded) do if entry.trigger == trigger then return true end end
				return false
			end
			assert(has("07★"), "real provider must install the original prefix")
			local owner = require("infra.hotstrings_scope").new_magic({ path = path, backup_path = backup,
				config = Config, preferences = Preferences, magic_key = Magic, dynamic = wrapped,
				reload = function()
					local _, committed = Config.reload()
					saw_candidate = committed == true and has("07§") and menu == "§"
					return committed
				end,
				after_restore = function() menu = Magic.get(); return true end })
			Writer.publish_if_unchanged = function(target, ...)
				if target == path then return false, "controlled publication refusal" end
				return original_publish(target, ...)
			end
			local committed = owner.apply_updates({ { section = "hotstrings", key = "trigger_char", value = "§" } })
			Writer.publish_if_unchanged = original_publish
			helpers.assert_eq(committed, false)
			helpers.assert_true(saw_candidate, "the candidate matcher and menu must have actually been published")
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(Magic.get(), "★")
			helpers.assert_eq(Dynamic.get_trigger_char(), "★")
			helpers.assert_true(has("07★"), "the restored matcher must contain the original prefix")
			helpers.assert_eq(has("07§"), false, "the candidate prefix must be retired")
			helpers.assert_eq(menu, "★", "the menu must be notified after restoration")
		end, debug.traceback)
		Writer.publish_if_unchanged = original_publish
		if Config then Config._set_config_file_for_test(nil) end
		Preferences._set_file_for_test(nil)
		package.loaded["modules.dynamic_hotstrings.manager"], package.loaded["hotstrings.engine.dynamic.core"] = old_manager, old_engine
		package.loaded["modules.dynamic_hotstrings.user_code"] = old_user_code
		package.loaded["modules.hotstrings.hotstrings_config"] = old_config
		for _, name in ipairs({ path, rules, info, backup }) do os.remove(name) end
		if not ok then error(err, 0) end
	end)
end)
