--- tests/unit/modules/keymap/test_registry_mutation_transactions.lua

--- ==============================================================================
--- MODULE: Registry Mutation Transactions
--- DESCRIPTION:
--- Proves that public group/section mutators return an exact boolean commitment
--- and restore both runtime mappings and persistent section settings when a
--- loader or post-load hook fails after mutation has begun.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.personal_menu_caption_fixture")

--- Models the empty boot directory catalogue in registry-only menu fixtures.
--- The actual registry/persistence owners stay live; importing the boot loader
--- would construct an unrelated keymap against the already initialized registry.
--- @param callback function Actual menu transaction and its assertions.
--- @return ... Callback results.
local function with_menu_diagnostics(callback)
	return helpers.with_stub_scope({ "infra.personal_hotstrings" }, function()
		package.loaded["infra.personal_hotstrings"] = {
			unavailable_directories = function() return {} end,
		}
		return callback()
	end)
end


--- Builds an initialized registry bound to a fresh in-memory Hammerspoon stub.
--- @return table state
--- @return table registry
local function fresh_registry()
	package.loaded["adapters.storage"] = nil
	local registry = helpers.load_with_stubs("modules.keymap.registry")
	package.loaded["modules.keymap.state"] = nil
	local State = require("modules.keymap.state")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
	registry.init(state)
	return state, registry
end


--- Registers one mapping owned by a programmatic group.
--- @param registry table
--- @param group_name string
--- @param trigger string
local function add_group_mapping(registry, group_name, trigger)
	registry.set_group_context(group_name)
	registry.add(trigger, trigger:upper(), { is_case_sensitive = true })
	registry.set_group_context(nil)
	registry.sort_mappings()
end


helpers.describe("registry mutations: exact commitment and rollback", function()
	helpers.it("exposes one caller-owned transaction across a registration batch", function()
		local state, registry = fresh_registry()
		local committed = registry.registry_transaction("test_batch", function()
			registry.register_lua_group("prospective", "Prospective", {})
			add_group_mapping(registry, "prospective", "partial")
			return false
		end)

		helpers.assert_eq(committed, false)
		helpers.assert_nil(state.groups.prospective,
			"the public transaction must restore group ownership")
		helpers.assert_eq(#state.mappings, 0,
			"the public transaction must restore every mapping in the batch")
	end)

	helpers.it("withholds private callback failures while preserving rollback visibility", function()
		local _, registry = fresh_registry()
		local Logger = require("infra.logger")
		local lines = {}
		local previous_level = Logger.current_level
		Logger.set_level("DEBUG")
		Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
		local committed = registry.registry_transaction("private_registration", function()
			error("PRIVATE_REGISTRY_SENTINEL", 0)
		end)
		Logger.set_sink(nil)
		Logger.set_level(previous_level)

		helpers.assert_eq(committed, false)
		helpers.assert_true(#lines > 0, "the failed transaction must remain visible")
		local joined = table.concat(lines, "\n")
		helpers.assert_true(joined:find("private_registration", 1, true) ~= nil)
		helpers.assert_true(joined:find("PRIVATE_REGISTRY_SENTINEL", 1, true) == nil,
			"a callback handling personal mappings may carry PII in its error object")
	end)

	helpers.it("returns exact booleans for committed and impossible group states", function()
		local _, registry = fresh_registry()
		registry.register_lua_group("atomic", "Atomic", {})
		add_group_mapping(registry, "atomic", "alpha")

		helpers.assert_eq(registry.disable_group("atomic"), true)
		helpers.assert_eq(registry.disable_group("atomic"), true,
			"an idempotent request still fully satisfies the requested postcondition")
		registry.set_post_load_hook("atomic", function()
			add_group_mapping(registry, "atomic", "alpha")
		end)
		helpers.assert_eq(registry.enable_group("atomic"), true)
		helpers.assert_eq(registry.enable_group("atomic"), true)
		helpers.assert_eq(registry.disable_group("missing"), false)
		helpers.assert_eq(registry.enable_group("missing"), false)
	end)

	helpers.it("rolls back a programmatic enable when its post-load hook throws", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("control", "Control", {})
		add_group_mapping(registry, "control", "omega")
		local control_mapping = state.mappings[1]
		registry.register_lua_group("hooked", "Hooked", {})
		add_group_mapping(registry, "hooked", "stable")
		helpers.assert_eq(registry.disable_group("hooked"), true)
		local seq_before = state.seq_counter

		registry.set_post_load_hook("hooked", function()
			registry.set_group_context("hooked")
			registry.add("partial", "PARTIAL", { is_case_sensitive = true })
			error("injected post-load failure")
		end)

		local ok, committed = pcall(registry.enable_group, "hooked")
		helpers.assert_true(ok, "a public mutator must convert a hook throw into false")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(registry.is_group_enabled("hooked"), false)
		helpers.assert_eq(#state.mappings, 1,
			"the mapping registered before the hook throw must be removed")
		helpers.assert_eq(state.mappings[1], control_mapping,
			"a sibling group's corpus must retain its object identity")
		helpers.assert_eq(state.seq_counter, seq_before,
			"rollback must restore monotonic counters as well as visible mappings")
		helpers.assert_nil(state.current_group,
			"a throwing hook must not leak its group context into later registrations")
		helpers.assert_nil(registry.mappings_for_tail("l"),
			"tail indexes must not retain the hook's partial mapping")
		local control_bucket = registry.mappings_for_tail("a")
		helpers.assert_eq(control_bucket and control_bucket[1], control_mapping,
			"tail indexes must still point at the restored sibling corpus")
		local lookup_count = 0
		for _, mapping in pairs(state.mappings_lookup) do
			lookup_count = lookup_count + 1
			helpers.assert_eq(mapping, control_mapping,
				"the exact lookup must not retain the hook's partial mapping")
		end
		helpers.assert_eq(lookup_count, 1)
	end)

	helpers.it("restores settings and the live group when a section reload cannot parse", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("broken", "Broken", { { name = "one" } })
		state.groups.broken.path = helpers.fixtures_dir() .. "invalid-hotstrings.toml"
		state.groups.broken.kind = "toml"
		add_group_mapping(registry, "broken", "stable")
		local mapping_before = state.mappings[1]
		local key = "ergopti.hotstrings_section_broken_one"
		hs.settings.set(key, false)

		local previous_reader = package.loaded["infra.toml.reader"]
		package.loaded["infra.toml.reader"] = {
			parse = function() error("injected TOML parse failure") end,
		}
		local ok, committed = pcall(registry.enable_section, "broken", "one")
		package.loaded["infra.toml.reader"] = previous_reader

		helpers.assert_true(ok, "parse failure must be contained by the public mutator")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(hs.settings.get(key), false,
			"the persisted section choice must roll back when its live reload fails")
		helpers.assert_eq(registry.is_group_enabled("broken"), true,
			"the group was enabled before the request and must remain enabled")
		helpers.assert_eq(#state.mappings, 1)
		helpers.assert_eq(state.mappings[1], mapping_before,
			"rollback must restore the exact previously-live mapping object")
	end)

	helpers.it("rolls an editor-style TOML reload back to the exact live corpus", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("personal", "Personal", {})
		state.groups.personal.path = "/virtual/personal_hotstrings.toml"
		state.groups.personal.kind = "toml"
		add_group_mapping(registry, "personal", "stable")
		local mapping_before = state.mappings[1]
		local previous_reader = package.loaded["infra.toml.reader"]
		package.loaded["infra.toml.reader"] = {
			parse = function() error("injected editor reload failure", 0) end,
		}

		local ok, committed = pcall(
			registry.reload_toml,
			"personal",
			"/virtual/personal_hotstrings.toml"
		)
		package.loaded["infra.toml.reader"] = previous_reader

		helpers.assert_true(ok, "the public reload must contain parser failures")
		helpers.assert_eq(committed, false)
		helpers.assert_eq(registry.is_group_enabled("personal"), true,
			"a failed editor reload must not leave the group disabled")
		helpers.assert_eq(#state.mappings, 1)
		helpers.assert_eq(state.mappings[1], mapping_before,
			"rollback must restore the exact mapping object visible before Save")
		helpers.assert_eq(registry.mappings_for_tail("e")[1], mapping_before,
			"the hot-path tail index must point back to the restored corpus")
	end)

	helpers.it("does not activate a TOML group that the user disabled before Save", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("personal", "Personal", {})
		add_group_mapping(registry, "personal", "stable")
		helpers.assert_eq(registry.disable_group("personal"), true)
		local previous_reader = package.loaded["infra.toml.reader"]
		package.loaded["infra.toml.reader"] = {
			parse = function() error("disabled groups must not be loaded by Save", 0) end,
		}

		local committed = registry.reload_toml("personal", "/virtual/new-personal.toml")
		package.loaded["infra.toml.reader"] = previous_reader

		helpers.assert_eq(committed, true)
		helpers.assert_eq(registry.is_group_enabled("personal"), false)
		helpers.assert_eq(#state.mappings, 0,
			"saving an intentionally disabled group must not activate its mappings")
		helpers.assert_eq(state.groups.personal.path, "/virtual/new-personal.toml")
		helpers.assert_eq(state.groups.personal.kind, "toml")
	end)

	helpers.it("rolls back a throwing or ineffective settings write by read-back", function()
		-- Enabling writes an explicit true (an absent key means the manifest's
		-- shipped default), so both directions go through `set`.
		for _, operation in ipairs({ "set_false", "set_true" }) do
			for _, mode in ipairs({ "throw_after_write", "nil_noop", "false_noop" }) do
				local state, registry = fresh_registry()
				registry.register_lua_group("settings", "Settings", { { name = "one" } })
				add_group_mapping(registry, "settings", "stable")
				local mapping_before = state.mappings[1]
				local key = "ergopti.hotstrings_section_settings_one"
				local real_set, real_clear = hs.settings.set, hs.settings.clear
				local previous
				if operation == "set_true" then previous = false end
				if previous == false then real_set(key, false) else real_clear(key) end
				local real_operation = real_set
				hs.settings.set = function(write_key, value)
					if mode == "throw_after_write" then
						real_operation(write_key, value)
						error("injected settings failure after write")
					end
					-- Return values are not commitments: set normally returns nil and
					-- clear may return false for an absent key. The no-op is detected
					-- only because the exact read-back still has the old value.
					if mode == "false_noop" then return false end
					return nil
				end

				local action = operation == "set_true" and registry.enable_section or registry.disable_section
				local ok, committed = pcall(action, "settings", "one")
				hs.settings.set, hs.settings.clear = real_set, real_clear
				local label = operation .. "/" .. mode
				helpers.assert_true(ok, label .. " must be contained by the public mutator")
				helpers.assert_eq(committed, false, label .. " must not report commitment")
				helpers.assert_eq(hs.settings.get(key), previous,
					label .. " must restore the previous persistent value")
				helpers.assert_eq(registry.is_group_enabled("settings"), true)
				helpers.assert_eq(#state.mappings, 1)
				helpers.assert_eq(state.mappings[1], mapping_before)
				helpers.assert_true(registry.mappings_for_tail("e") ~= nil,
					label .. " must leave live indexes attached to the old corpus")
			end
		end
	end)

	helpers.it("does not register a Lua group whose file throws after a partial add", function()
		local state, registry = fresh_registry()
		local seq_before = state.seq_counter
		local fixture = helpers.fixtures_dir() .. "partial_hotstrings_failure.lua"
		local committed = registry.load_file("partial", fixture)
		helpers.assert_eq(committed, false)
		helpers.assert_nil(state.groups.partial)
		helpers.assert_eq(#state.mappings, 0)
		helpers.assert_eq(state.seq_counter, seq_before)
	end)
end)

helpers.describe("hotstring category scope: runtime and persistence acknowledgement", function()
	for _, enabled in ipairs({ true, false }) do
		for _, publication in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it("(hotstring-category-owner) " .. tostring(enabled) .. "/" .. publication, function()
				local state, registry = fresh_registry()
				local before = not enabled
				registry.register_lua_group("rolls", "Rolls", { { name = "hc" }, { name = "sx" } })
				registry.register_lua_group("spare", "Spare", {})
				add_group_mapping(registry, "spare", "untouched")
				local spare_mapping = state.mappings[1]
				for _, name in ipairs({ "hc", "sx" }) do
					hs.settings.set("ergopti.hotstrings_section_rolls_" .. name, before)
				end
				registry.set_post_load_hook("rolls", function()
					for _, name in ipairs({ "hc", "sx" }) do
						if registry.is_section_enabled("rolls", name) then add_group_mapping(registry, "rolls", name) end
					end
				end)
				if before then
					add_group_mapping(registry, "rolls", "hc")
					add_group_mapping(registry, "rolls", "sx")
				else
					helpers.assert_eq(registry.disable_group("rolls"), true)
				end
				local previous_mappings = {}
				for index, mapping in ipairs(state.mappings) do previous_mappings[index] = mapping end
				local publications, candidate = 0, {}
				local committed = registry.set_category_scope_enabled({ "rolls" }, enabled, function()
					publications = publications + 1
					candidate.group = registry.is_group_enabled("rolls")
					for _, name in ipairs({ "hc", "sx" }) do
						candidate[name] = registry.is_section_enabled("rolls", name)
					end
					if publication == "throw" then error("injected publication failure") end
					if publication == "nil" then return nil end
					return publication == "true"
				end)
				local accepted = publication == "true"
				local wanted = before
				if accepted then wanted = enabled end
				helpers.assert_eq(committed, accepted)
				helpers.assert_eq(publications, 1)
				helpers.assert_eq(candidate.group, enabled, "the persistence owner sees the complete candidate runtime")
				for _, name in ipairs({ "hc", "sx" }) do helpers.assert_eq(candidate[name], enabled) end
				helpers.assert_eq(registry.is_group_enabled("rolls"), wanted)
				for _, name in ipairs({ "hc", "sx" }) do
					helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_rolls_" .. name), wanted)
				end
				helpers.assert_eq(registry.is_group_enabled("spare"), true)
				helpers.assert_eq(state.mappings[1], spare_mapping, "another group's exact mapping survives")
				helpers.assert_eq(#state.mappings, wanted and 3 or 1)
				if not accepted then
					for index, mapping in ipairs(previous_mappings) do
						helpers.assert_eq(state.mappings[index], mapping, "refusal restores exact native authority")
					end
				end
			end)
		end
	end

	helpers.it("(hotstring-category-owner) rejects an unknown sibling before publication", function()
		local state, registry = fresh_registry()
		registry.register_lua_group("rolls", "Rolls", { { name = "hc" } })
		add_group_mapping(registry, "rolls", "hc")
		local mapping = state.mappings[1]
		local writes = 0
		helpers.assert_eq(registry.set_category_scope_enabled({ "rolls", "missing" }, false,
			function() writes = writes + 1; return true end), false)
		helpers.assert_eq(writes, 0)
		helpers.assert_eq(registry.is_group_enabled("rolls"), true)
		helpers.assert_eq(state.mappings[1], mapping)
	end)
end)

helpers.describe("canonical hotstring cache projection", function()
	local function fixture(source)
		local state, registry = fresh_registry()
		local files = { config = source }
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
			write_if_unchanged = function(path, content, expected)
				if expected.status ~= (files[path] and "ok" or "absent")
					or (expected.status == "ok" and files[path] ~= expected.content) then return false end
				files[path] = content; return true
			end,
		}
		package.loaded["infra.preferences"] = nil
		local preferences = require("infra.preferences")
		registry.register_lua_group("rolls", "Rolls", { { name = "hc" }, { name = "sx" }, { name = "-" } })
		registry.register_lua_group("ext:demo:test", "Extension", { { name = "fast" }, { name = "info", is_module_placeholder = true } })
		return state, registry, preferences, files
	end

	helpers.it("replaces stale section settings with neutral absence before registry use", function()
		local _, registry, preferences = fixture(nil)
		hs.settings.set("ergopti.hotstrings_section_rolls_hc", true)
		hs.settings.set("ergopti.hotstrings_section_ext:demo:test_fast", true)
		local saved, status = preferences.load("config")
		helpers.assert_eq(status, "absent")
		helpers.assert_true(registry.apply_hotstring_preferences(saved))
		helpers.assert_eq(registry.is_group_enabled("rolls"), false)
		helpers.assert_eq(registry.is_group_enabled("ext:demo:test"), false)
		helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), false)
		helpers.assert_eq(registry.is_section_enabled("ext:demo:test", "fast"), false)
	end)

	helpers.it("loads actual group and section readers without claiming unknown neighbors", function()
		local _, registry, preferences, files = fixture('[hotstrings]\ngroups = { rolls = true, future = { keep = 9 } }\nmodules = { rolls = { hc = true, future = { keep = 7 } } }\n')
		local source = files.config
		local saved = preferences.load("config")
		helpers.assert_true(registry.apply_hotstring_preferences(saved))
		helpers.assert_true(registry.is_group_enabled("rolls"))
		helpers.assert_true(registry.is_section_enabled("rolls", "hc"))
		helpers.assert_eq(registry.is_section_enabled("rolls", "sx"), false)
		helpers.assert_eq(files.config, source, "projection is not migration or persistence")
		helpers.assert_nil(hs.settings.get("ergopti.hotstrings_section_rolls_future"))
		helpers.assert_nil(hs.settings.get("ergopti.hotstrings_section_rolls_-"))
		helpers.assert_nil(hs.settings.get("ergopti.hotstrings_section_ext:demo:test_info"))
	end)

	helpers.it("reads an old-shape owned value as neutral absence, never a refused projection (config-outdated-hotstrings)", function()
		-- An outdated choice is never an ERROR or a failed boot sync, and never
		-- guessed on: "yes" is not a switch, so the section keeps its neutral value.
		local _, registry, preferences = fixture('[hotstrings]\nmodules = { rolls = { hc = "yes" } }\n')
		hs.settings.set("ergopti.hotstrings_section_rolls_hc", true)
		local saved = preferences.load("config")
		helpers.assert_true(registry.apply_hotstring_preferences(saved))
		helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), false)
	end)

	helpers.it("refuses a cache write whose native readback did not commit", function()
		local _, registry, preferences = fixture(nil)
		local set = hs.settings.set
		hs.settings.set = function(key, value)
			if key == "ergopti.hotstrings_section_rolls_hc" and value == false then return nil end
			return set(key, value)
		end
		local ok, result = pcall(registry.apply_hotstring_preferences, preferences.load("config"))
		hs.settings.set = set
		helpers.assert_true(ok)
		helpers.assert_eq(result, false)
		helpers.assert_nil(hs.settings.get("ergopti.hotstrings_section_rolls_hc"))
		helpers.assert_true(registry.is_group_enabled("rolls"))
	end)

	helpers.it("retains an already committed corpus when the menu applies the same candidate", function()
		local _, registry, preferences = fixture('[hotstrings]\ngroups = { rolls = true }\nmodules = { rolls = { hc = true } }\n')
		local rebuilds = 0
		registry.set_post_load_hook("rolls", function() rebuilds = rebuilds + 1 end)
		local saved = preferences.load("config")
		helpers.assert_true(registry.apply_hotstring_preferences(saved))
		helpers.assert_eq(rebuilds, 1)
		helpers.assert_true(registry.apply_hotstring_preferences(saved))
		helpers.assert_eq(rebuilds, 1, "boot followed by menu sync must not reload the same group")
	end)

	helpers.it("rolls settings and groups back when a real post-load hook throws", function()
		local _, registry, preferences = fixture('[hotstrings]\ngroups = { rolls = true }\nmodules = { rolls = { hc = true } }\n')
		hs.settings.set("ergopti.hotstrings_section_rolls_hc", false)
		registry.set_post_load_hook("rolls", function() error("injected reload refusal") end)
		helpers.assert_eq(registry.apply_hotstring_preferences(preferences.load("config")), false)
		helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_rolls_hc"), false)
		helpers.assert_true(registry.is_group_enabled("rolls"))
		helpers.assert_true(registry.is_group_enabled("ext:demo:test"))
	end)

	helpers.it("saves sparse choices into inline tables while retaining unknown neighbors", function()
		local _, registry, preferences, files = fixture('[hotstrings]\ngroups = { rolls = true, future = { keep = 9 } }\nmodules = { rolls = { hc = true, future = { keep = 7 } } }\n')
		helpers.assert_true(registry.apply_hotstring_preferences(preferences.load("config")))
		helpers.assert_true(registry.disable_section("rolls", "hc"))
		local state = { hotstrings = { rolls = false, ["ext:demo:test"] = false } }
		helpers.assert_true(preferences.save("config", state, { "rolls", "ext:demo:test" }, { keymap = registry }))
		local decoded = require("toml_codec").decode(files.config)
		helpers.assert_nil(decoded.hotstrings.groups.rolls)
		helpers.assert_nil(decoded.hotstrings.modules.rolls.hc)
		helpers.assert_eq(decoded.hotstrings.groups.future.keep, 9)
		helpers.assert_eq(decoded.hotstrings.modules.rolls.future.keep, 7)
		helpers.assert_true(registry.apply_hotstring_preferences(preferences.load("config")))
		helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), false)
	end)

	helpers.it("projects the canonical source before the actual boot call can start input", function()
		local _, registry = fixture(nil)
		hs.settings.set("ergopti.hotstrings_section_rolls_hc", true)
		local source, read_error = helpers.read_driver_unit("local function has_common_hotstring_groups")
		helpers.assert_type(source, "string", tostring(read_error))
		local body = source:match('(if keymap.apply_hotstring_preferences%(boot_saved_prefs%).-if keymap_started ~= true then.-\nend)')
		helpers.assert_type(body, "string", "the owned boot boundary must exist")
		local starts = 0
		local run = assert(load(body, "hotstring boot boundary", "t", setmetatable({
			boot_saved_prefs = require("infra.preferences").load("config"),
			keymap = {
				apply_hotstring_preferences = registry.apply_hotstring_preferences,
				start = function()
					helpers.assert_eq(registry.is_group_enabled("rolls"), false)
					helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), false)
					starts = starts + 1; return true
				end,
			},
		}, { __index = _G })))
		run()
		helpers.assert_eq(starts, 1)
	end)

	helpers.it("the real menu synchronizer replaces absent canonical section choices", function()
		local _, registry, preferences = fixture(nil)
		hs.settings.set("ergopti.hotstrings_section_rolls_hc", true)
		package.loaded["ui.menu.menu_state"] = nil
		local MenuState = require("ui.menu.menu_state")
		local state = { hotstrings = {}, keymap = false, delays = {}, repeat_key_enabled = false }
		local keymap = setmetatable({ set_llm_model = function() return true end }, { __index = registry })
		local result, report = MenuState.sync_state_to_modules(state, preferences.load("config"), false, {
			keymap = keymap, core_mods = {}, hotstring_editor = {},
		})
		helpers.assert_true(result, helpers.inspect(report))
		helpers.assert_eq(registry.is_group_enabled("rolls"), false)
		helpers.assert_eq(registry.is_section_enabled("rolls", "hc"), false)
	end)
end)

helpers.describe("personal menu: the real category persistence owner", function()
	for _, enabled in ipairs({ true, false }) do
		for _, publication in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it("personal menu transaction " .. tostring(enabled) .. "/" .. publication, function()
				return with_menu_diagnostics(function()
					local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
					local state, registry = fresh_registry()
					local names = { "personal", "personal_ext_work", "custom" }
					for _, group in ipairs(names) do
						registry.register_lua_group(group, group, { { name = "one" }, { name = "two" } })
						for _, section in ipairs({ "one", "two" }) do
							hs.settings.set("ergopti.hotstrings_section_" .. group .. "_" .. section, not enabled)
						end
						registry.set_post_load_hook(group, function()
							for _, section in ipairs({ "one", "two" }) do
								if registry.is_section_enabled(group, section) then add_group_mapping(registry, group, group .. section) end
							end
						end)
						if enabled then helpers.assert_eq(registry.disable_group(group), true) end
					end
					registry.register_lua_group("spare", "Spare", {})
					add_group_mapping(registry, "spare", "untouched")
					local spare_mapping = state.mappings[#state.mappings]
					local menu_state = { hotstrings = {}, keymap = false, trigger_char = "★" }
					for _, group in ipairs(names) do menu_state.hotstrings[group] = not enabled end
					local starts, updates, candidate = 0, 0, {}
					registry.start = function() starts = starts + 1; return true end
					local ctx = { state = menu_state, paused = true, keymap = registry,
						hotfiles = { "personal.toml", "personal_ext_work.toml" },
						get_group_name = function(path) return path:gsub("%.toml$", "") end,
						applyTriggerChar = function(value) return value end,
						hotstring_editor = { open = function() end },
						updateMenu = function() updates = updates + 1 end,
						save_prefs = function()
							for _, group in ipairs(names) do
								candidate[group] = { registry.is_group_enabled(group), menu_state.hotstrings[group],
									registry.is_section_enabled(group, "one"), registry.is_section_enabled(group, "two") }
							end
							if publication == "throw" then error("personal owner publication refused") end
							if publication == "nil" then return nil end
							return publication == "true"
						end,
					}
					local rows = CaptionFixture.build_custom(Custom, ctx, { group_counts = {} }).submenu
					local committed = rows[enabled and 1 or 2].fn()
					local accepted, wanted = publication == "true", not enabled
					if accepted then wanted = enabled end
					helpers.assert_eq(committed, accepted)
					for _, group in ipairs(names) do
						helpers.assert_eq(candidate[group], { enabled, enabled, enabled, enabled }, "one complete candidate reaches publication")
						helpers.assert_eq(registry.is_group_enabled(group), wanted)
						helpers.assert_eq(menu_state.hotstrings[group], wanted)
						for _, section in ipairs({ "one", "two" }) do
							helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_" .. group .. "_" .. section), wanted)
						end
					end
					helpers.assert_eq(registry.is_group_enabled("spare"), true)
					local found_spare = false
					for _, mapping in ipairs(state.mappings) do if mapping == spare_mapping then found_spare = true end end
					helpers.assert_true(found_spare, "an unrelated group's exact native mapping survives")
					helpers.assert_eq({ starts, updates }, { 0, accepted and 1 or 0 })
					helpers.assert_eq(menu_state.keymap, false)
				end)
			end)
		end
	end
end)


--- Builds the real Dynamic registry, module façade and canonical conditional save.
--- @param enabled boolean Requested target, opposite of the initial live posture.
--- @param outcome string Save acknowledgement or actual publication refusal.
--- @param absent boolean|nil Preserve a genuinely absent menu-state module choice.
--- @return table fixture
local function dynamic_personal_scope_fixture(enabled, outcome, absent)
	local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
	local registry_state, registry = fresh_registry()
	package.loaded["modules.dynamic_hotstrings"] = nil
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	local personal = require("modules.dynamic_hotstrings")
	personal.set_enabled(not enabled)
	local original_set = personal.set_enabled
	local module_calls = {}
	personal.set_enabled = function(value)
		module_calls[#module_calls + 1] = value
		return original_set(value)
	end
	local names = { "datelongfr", "datefr", "date", "phoneprefixes", "ssnprefixes", "ibanprefixes" }
	local sections = {}
	for _, name in ipairs(names) do sections[#sections + 1] = { name = name } end
	sections[#sections + 1] = { name = "-" }
	sections[#sections + 1] = { name = "textexpansionpersonalinformation", is_module_placeholder = true }
	registry.register_lua_group("dynamichotstrings", "Dynamic", sections)
	registry.register_lua_group("spare", "Spare", {})
	add_group_mapping(registry, "spare", "untouched")
	local spare_mapping = registry_state.mappings[1]
	for _, name in ipairs(names) do
		hs.settings.set("ergopti.hotstrings_section_dynamichotstrings_" .. name, not enabled)
	end
	registry.set_post_load_hook("dynamichotstrings", function()
		for _, name in ipairs(names) do
			if registry.is_section_enabled("dynamichotstrings", name) then add_group_mapping(registry, "dynamichotstrings", name) end
		end
	end)
	if enabled then
		registry.disable_group("dynamichotstrings")
	else
		for _, name in ipairs(names) do add_group_mapping(registry, "dynamichotstrings", name) end
	end
	local original_mappings = {}
	for _, mapping in ipairs(registry_state.mappings) do original_mappings[#original_mappings + 1] = mapping end
	local menu_state = { hotstrings = { dynamichotstrings = not enabled, spare = true },
		keymap = false, personal_info = not enabled, trigger_char = "★" }
	if absent then menu_state.personal_info = nil end
	local original = "[hotstrings]\nenabled = false\n[hotstrings.modules]\npersonal_info = "
		.. tostring(not enabled) .. "\nfuture_module = { retained = 17 }\n"
	local files = { config = original }
	package.loaded["adapters.file_system"] = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write_if_unchanged = function(path, content, expected)
			if files.refuse or expected.status ~= (files[path] and "ok" or "absent")
				or (expected.status == "ok" and expected.content ~= files[path]) then return false end
			files[path] = content; return true
		end,
	}
	package.loaded["infra.preferences"] = nil
	local preferences = require("infra.preferences")
	preferences.load("config")
	local shared = assert(require("toml_codec").decode(require("tests.support.source_file").read(
		helpers.driver_root() .. "../_shared/modules/hotstrings/_index.toml")))
	local observations, starts, updates, saves = {}, 0, 0, 0
	registry.start = function() starts = starts + 1; return true end
	local ctx = { state = menu_state, paused = true, keymap = registry, personal_info = personal,
		module_sections = shared.modules, updateMenu = function() updates = updates + 1 end }
	ctx.save_prefs = function()
		saves = saves + 1
		observations[#observations + 1] = { personal.is_enabled(), menu_state.personal_info,
			registry.is_group_enabled("dynamichotstrings") }
		if outcome == "false" then return false end
		if outcome == "nil" then return nil end
		if outcome == "throw" then error("owned canonical save refusal") end
		return preferences.save("config", menu_state, { "dynamichotstrings.toml", "spare.toml" }, { keymap = registry })
	end
	local action = Custom.category_scope_fn(ctx, { "dynamichotstrings" }, enabled)
	return { action = action, ctx = ctx, personal = personal, registry = registry, state = registry_state,
		preferences = preferences, files = files, original = original, names = names, module_calls = module_calls,
		observations = observations, spare_mapping = spare_mapping, original_mappings = original_mappings, original_enabled = not enabled,
		counts = function() return starts, updates, saves end }
end


--- Verifies complete selected scope and unrelated native authority outside callbacks.
--- @param f table Fixture.
--- @param desired boolean Expected selected runtime posture.
local function assert_dynamic_personal_scope(f, desired)
	helpers.assert_eq(f.personal.is_enabled(), desired, "the actual external module shares the selected target")
	helpers.assert_eq(f.registry.is_group_enabled("dynamichotstrings"), desired)
	for _, name in ipairs(f.names) do
		helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_dynamichotstrings_" .. name), desired)
	end
	helpers.assert_eq(f.registry.is_group_enabled("spare"), true)
	local retained = false
	for _, mapping in ipairs(f.state.mappings) do if mapping == f.spare_mapping then retained = true end end
	helpers.assert_true(retained, "the unrelated group's exact mapping is preserved")
	if desired == f.original_enabled then
		helpers.assert_eq(#f.state.mappings, #f.original_mappings, "refusal restores the exact native mapping inventory")
		for index, mapping in ipairs(f.original_mappings) do
			helpers.assert_true(f.state.mappings[index] == mapping, "refusal retains each original mapping identity and order")
		end
	end
	helpers.assert_eq(f.ctx.state.keymap, false, "the master remains stopped")
	helpers.assert_eq(f.ctx.paused, true, "the scope does not lift pause")
	helpers.assert_nil(hs.settings.get("ergopti.hotstrings_section_dynamichotstrings_textexpansionpersonalinformation"),
		"an external interceptor never acquires a fake registry section")
end


helpers.describe("Dynamic category admits its real personal-info module owner", function()
	for _, enabled in ipairs({ true, false }) do
		for _, outcome in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it("dynamic personal scope " .. tostring(enabled) .. "/" .. outcome, function()
				local f = dynamic_personal_scope_fixture(enabled, outcome)
				local accepted = f.action()
				local expected = outcome == "true"
				helpers.assert_eq(accepted, expected)
				helpers.assert_eq(f.observations, { { enabled, enabled, enabled } },
					"canonical save observes the complete module/menu/registry candidate")
				local wanted = not enabled
				if expected then wanted = enabled end
				assert_dynamic_personal_scope(f, wanted)
				helpers.assert_eq(f.ctx.state.personal_info, wanted)
				local starts, updates, saves = f.counts()
				helpers.assert_eq({ starts, updates, saves }, { 0, expected and 1 or 0, 1 })
				if expected then
					helpers.assert_eq(f.preferences.load("config").personal_info, enabled)
					local decoded = assert(require("toml_codec").decode(f.files.config))
					helpers.assert_eq(decoded.hotstrings.modules.future_module, { retained = 17 })
				else
					helpers.assert_eq(f.files.config, f.original, "refusal preserves exact canonical source bytes")
				end
			end)
		end
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			helpers.it("dynamic personal scope restores absent state after " .. outcome .. "/" .. tostring(enabled), function()
				local f = dynamic_personal_scope_fixture(enabled, outcome, true)
				helpers.assert_eq(f.action(), false)
				helpers.assert_nil(f.ctx.state.personal_info, "absence is restored rather than converted into a boolean")
				assert_dynamic_personal_scope(f, not enabled)
				helpers.assert_eq(f.files.config, f.original)
			end)
		end
	end

	helpers.it("dynamic personal scope refuses a stale source then retries its acknowledged owner", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.files.config = f.original .. "\n[future]\nexternal = 23\n"
		local external = f.files.config
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, false)
		helpers.assert_eq(f.files.config, external, "a stale save never overwrites the external writer")
		helpers.assert_eq(f.action(), true)
		assert_dynamic_personal_scope(f, true)
		helpers.assert_eq(assert(require("toml_codec").decode(f.files.config)).future.external, 23)
	end)
end)


helpers.describe("Dynamic module acknowledgement and selected-scope isolation", function()
	for _, enabled in ipairs({ true, false }) do
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			helpers.it("dynamic personal module inverse after " .. outcome .. "/" .. tostring(enabled), function()
				local f = dynamic_personal_scope_fixture(enabled, "true")
				local setter, calls = f.personal.set_enabled, 0
				f.personal.set_enabled = function(value)
					calls = calls + 1
					local acknowledged = setter(value)
					if calls > 1 then return acknowledged end
					if outcome == "throw" then error("owned module acknowledgement refusal") end
					if outcome == "nil" then return nil end
					return false
				end
				helpers.assert_eq(f.action(), false)
				assert_dynamic_personal_scope(f, not enabled)
				helpers.assert_eq(f.ctx.state.personal_info, not enabled)
				helpers.assert_eq(f.module_calls, { enabled, not enabled },
					"the partial native choice settles through its exact inverse")
				helpers.assert_eq(f.files.config, f.original)
				helpers.assert_eq({ f.counts() }, { 0, 0, 0 }, "refused module ownership reaches no canonical write")
			end)
		end
		helpers.it("dynamic personal conditional writer refusal then retry " .. tostring(enabled), function()
			local f = dynamic_personal_scope_fixture(enabled, "true")
			f.files.refuse = true
			helpers.assert_eq(f.action(), false)
			assert_dynamic_personal_scope(f, not enabled)
			helpers.assert_eq(f.files.config, f.original)
			f.files.refuse = false
			helpers.assert_eq(f.action(), true)
			assert_dynamic_personal_scope(f, enabled)
			helpers.assert_eq(f.preferences.load("config").personal_info, enabled)
		end)
	end

	helpers.it("dynamic personal scope refuses a missing actual module port before publication", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.ctx.personal_info = nil
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, false)
		helpers.assert_eq(f.files.config, f.original)
		helpers.assert_eq({ f.counts() }, { 0, 0, 0 })
	end)

	helpers.it("dynamic personal scope preserves unsupported declared future placeholders", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		local getter = f.registry.get_sections
		f.registry.get_sections = function(group)
			local rows = getter(group)
			if group ~= "dynamichotstrings" then return rows end
			local copy = {}
			for _, row in ipairs(rows) do copy[#copy + 1] = row end
			copy[#copy + 1] = { name = "future_section", is_module_placeholder = true }
			return copy
		end
		f.ctx.module_sections.dynamichotstrings.future_section = { mod_id = "future_owner" }
		f.ctx.state.future_owner = true
		local foreign_calls = 0
		f.ctx.future_owner = { is_enabled = function() return true end,
			set_enabled = function() foreign_calls = foreign_calls + 1; return true end }
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, false)
		helpers.assert_eq(f.ctx.state.future_owner, true)
		helpers.assert_eq(foreign_calls, 0, "unknown native module authority is never adopted")
		helpers.assert_eq(f.module_calls, {})
		helpers.assert_eq(f.files.config, f.original)
		helpers.assert_eq({ f.counts() }, { 0, 0, 0 })
	end)

	helpers.it("an unrelated category never acquires the personal module or changes its choice", function()
		local f = dynamic_personal_scope_fixture(false, "true")
		local Custom = require("ui.menu.menu_hotstrings_custom")
		helpers.assert_eq(Custom.category_scope_fn(f.ctx, { "spare" }, false)(), true)
		helpers.assert_eq(f.module_calls, {})
		helpers.assert_eq(f.personal.is_enabled(), true)
		helpers.assert_eq(f.ctx.state.personal_info, true)
		helpers.assert_eq(f.registry.is_group_enabled("dynamichotstrings"), true)
		for _, name in ipairs(f.names) do
			helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_dynamichotstrings_" .. name), true)
		end
		helpers.assert_eq(f.registry.is_group_enabled("spare"), false)
		helpers.assert_eq(f.ctx.state.keymap, false)
		helpers.assert_eq(f.ctx.paused, true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
	end)
end)


helpers.describe("Dynamic module checkbox and untouched-runtime authority", function()
	helpers.it("the actual shared Dynamic checkbox includes its personal-info placeholder", function()
		local f = dynamic_personal_scope_fixture(false, "true")
		local Custom = require("ui.menu.menu_hotstrings_custom")
		f.personal.set_enabled(false)
		f.ctx.state.personal_info = false
		f.ctx.paused = false
		local row = Custom.all_sections_row(f.ctx, { "dynamichotstrings" }, function(value)
			return Custom.category_scope_fn(f.ctx, { "dynamichotstrings" }, value)
		end)
		helpers.assert_eq(row.checked, false, "six enabled registry sections cannot hide a disabled external module")
		helpers.assert_eq(row.action(), true)
		helpers.assert_eq(f.personal.is_enabled(), true)
		helpers.assert_eq(Custom.all_sections_on(f.ctx, { "dynamichotstrings" }), true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
		helpers.assert_eq({ f.counts() }, { 0, 1, 1 })
	end)

	helpers.it("a refused real registry selection never acquires the untouched module runtime", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		local Custom = require("ui.menu.menu_hotstrings_custom")
		local action = Custom.category_scope_fn(f.ctx, { "dynamichotstrings", "missing" }, true)
		helpers.assert_eq(action(), false)
		helpers.assert_eq(f.module_calls, {}, "a refused planner never resets the native module's pending state")
		assert_dynamic_personal_scope(f, false)
		helpers.assert_nil(f.ctx.state.hotstrings.missing)
		helpers.assert_eq(f.files.config, f.original)
		helpers.assert_eq({ f.counts() }, { 0, 0, 0 })
	end)

	helpers.it("an already selected module keeps its runtime while its category is acknowledged", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.personal.set_enabled(true)
		f.ctx.state.personal_info = true
		for key in pairs(f.module_calls) do f.module_calls[key] = nil end
		helpers.assert_eq(f.action(), true)
		helpers.assert_eq(f.module_calls, {}, "an unchanged external interceptor is never restarted or reset")
		assert_dynamic_personal_scope(f, true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
		helpers.assert_eq({ f.counts() }, { 0, 1, 1 })
	end)
end)


helpers.describe("Dynamic module acknowledged publication survives UI refresh refusal", function()
	helpers.it("a failed menu refresh cannot undo the acknowledged personal-info file and runtime choice", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.ctx.updateMenu = function() error("owned refresh refusal after canonical acknowledgement") end
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, true)
		helpers.assert_eq(f.ctx.state.personal_info, true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
		helpers.assert_eq(f.module_calls, { true }, "an acknowledged module is never compensated because repaint failed")
		helpers.assert_eq({ f.counts() }, { 0, 0, 1 })
	end)
end)

helpers.describe("registry-only personal menu diagnostics isolation", function()
	helpers.it("restores absent, false and captured boot catalogue caches after success and refusal", function()
		helpers.with_fresh_modules({ "infra.personal_hotstrings" }, function()
			local catalogue = { unavailable_directories = function() return { { label = "foreign" } } end }
			for _, previous in ipairs({ { value = nil }, { value = false }, { value = catalogue } }) do
				for _, refuse in ipairs({ false, true }) do
					package.loaded["infra.personal_hotstrings"] = previous.value
					local ok, result = pcall(with_menu_diagnostics, function()
						local port = require("infra.personal_hotstrings")
						helpers.assert_true(port ~= previous.value)
						helpers.assert_eq(port.unavailable_directories(), {})
						if refuse then error("injected menu fixture refusal", 0) end
						return "completed"
					end)
					helpers.assert_eq(ok, not refuse)
					if not refuse then helpers.assert_eq(result, "completed") end
					helpers.assert_true(package.loaded["infra.personal_hotstrings"] == previous.value,
						"the exact earlier boot catalogue identity must survive the scoped fixture")
				end
			end
		end)
	end)
end)
