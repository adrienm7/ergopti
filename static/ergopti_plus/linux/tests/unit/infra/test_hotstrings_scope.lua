--- tests/unit/infra/test_hotstrings_scope.lua

--- ==============================================================================
--- MODULE: Hotstrings Scope Transaction (Linux)
--- DESCRIPTION:
--- Runs « restore recommended » and « clear » through the real hotstring owners,
--- the real engine and both real files, with only publication refusals and the
--- dynamic and preview ports controlled. Pins the delay contract: a restored
--- section resolves to the manifest recommendation even where the corpus
--- inherits another value, and a cleared one resolves to its corpus inheritance.
--- ==============================================================================

local helpers = require("tests.helpers")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local CONFIG = '[hotstrings]\nunknown = "kept"\ngroups = { rolls = false, foreign = true }\n'
	.. 'trigger_char = "§"\npreview_ai_enabled = true\n'
	.. '[hotstrings.dynamic.date]\nenabled = true\n[other]\nvalue = 1\n'
-- Independently authored current runtime preimage: the former caps family is
-- now three owned tables, each with the same explicit 9 s override.
local COMMON_FAMILIES = { "names", "abbreviations", "technical_terms" }
local COMMON_TRIGGERS = {
	{ trigger = "cq", replacement = "names-result" },
	{ trigger = "aq", replacement = "abbreviations-result" },
	{ trigger = "tq", replacement = "technical-terms-result" },
}
local OVERRIDES = '[autocorrection]\ndelay = 3\ncolor = "#111111"\n\n'
	.. '[autocorrection.names]\ndelay = 9\n\n'
	.. '[autocorrection.abbreviations]\ndelay = 9\n\n'
	.. '[autocorrection.technical_terms]\ndelay = 9\n\n'
	.. '[rolls.hc]\npriority = 5\n\n[foreign]\ndelay = 4\nunknown_field = "kept"\n\n[_global]\ndelay = 2\n'

--- The catalogue the stub loader publishes: real category ids, corpus delays
--- that differ from and agree with the manifest recommendations, and a
--- personal pack whose section shares a name with a manifest row.
local CATEGORIES = {
	autocorrection = { id = "autocorrection", delay = 1.0,
		sections_order = { "names", "abbreviations", "technical_terms" },
		sections = { names = { count = 1 }, abbreviations = { count = 1 }, technical_terms = { count = 1 } } },
	french_autocorrection = { id = "french_autocorrection", delay = 1.0, sections_order = { "accents" },
		sections = { accents = { count = 1 } } },
	rolls = { id = "rolls", delay = 0.5, sections_order = { "hc" }, sections = { hc = { count = 1 } } },
	personal = { id = "personal", delay = 2.0, sections_order = { "code" }, sections = { code = { count = 1 } } },
}
local MAPPINGS = {
	{ trigger = "cq", replacement = "names-result", group = "autocorrection", section = "names", auto_expand = true },
	{ trigger = "aq", replacement = "abbreviations-result", group = "autocorrection", section = "abbreviations", auto_expand = true },
	{ trigger = "tq", replacement = "technical-terms-result", group = "autocorrection", section = "technical_terms", auto_expand = true },
	{ trigger = "hq", replacement = "rolls-result", group = "rolls", section = "hc", auto_expand = true },
}

local function read(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

local function write(path, content)
	local handle = assert(io.open(path, "w"))
	handle:write(content)
	handle:close()
end

local function fires(engine, trigger, replacement)
	engine:reset()
	local result
	for char in trigger:gmatch(".") do result = engine:on_char(char) end
	return result ~= nil and result.replacement == replacement
end

--- Runs body with every owner loaded fresh against a private configuration folder.
--- @param body function body(context)
--- @param source string|nil Initial config.toml bytes; CONFIG by default.
local function with_scope(body, source)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	-- The shared delimiter catalogue outlives every module cache reset.
	local Terminators = require("modules.hotstrings.terminator_settings")
	local catalogue = Terminators.snapshot()
	local directory = string.format("%s/ergopti_hotstrings_scope_%d_%d",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	assert(os.execute("mkdir -p '" .. directory .. "'"))
	local ok, err = pcall(function()
		for _, name in ipairs({ "modules.hotstrings.hotstrings_config", "infra.hotstring_preferences",
			"modules.hotstrings.repeat_key", "modules.hotstrings.magic_key", "modules.hotstrings.preview_settings",
			"modules.hotstrings.terminator_settings", "infra.hotstrings_scope" }) do
			package.loaded[name] = nil
		end
		-- The real path owner, with only the configuration folder moved.
		local paths = {}
		for key, value in pairs(require("infra.config_paths")) do paths[key] = value end
		paths.config = function(rel) return rel and (directory .. "/" .. rel) or directory end
		paths.home = function() return directory end
		package.loaded["infra.config_paths"] = paths
		package.loaded["modules.hotstrings.loader"] = {
			find_toml_files = require("modules.hotstrings.loader").find_toml_files,
			list_subdirs = function() return {} end,
			read_file = function() return nil end,
			load_catalogue = function()
				local categories, mappings = {}, {}
				for id, category in pairs(CATEGORIES) do categories[id] = category end
				for index, mapping in ipairs(MAPPINGS) do
					mappings[index] = {}
					for key, value in pairs(mapping) do mappings[index][key] = value end
				end
				return { committed = true, errors = 0, categories = categories, mappings = mappings }
			end,
		}
		local config_path, override_path = directory .. "/config.toml", directory .. "/hotstrings_overrides.toml"
		write(config_path, source or CONFIG)
		write(override_path, OVERRIDES)
		local context = { config_path = config_path, override_path = override_path, directory = directory,
			published = {}, dynamic_calls = {}, preview = {}, paused = false }
		local Config = require("modules.hotstrings.hotstrings_config")
		local engine = require("hotstring_engine").new()
		local publish = engine.load_mappings
		engine.load_mappings = function(self, mappings)
			if context.refuse_engine then return false end
			return publish(self, mappings)
		end
		assert(Config.init(engine, "virtual.toml"), "the fixture configuration must be readable")
		local _, committed = Config.load_all()
		assert(committed, "the fixture catalogue must publish")
		context.files = {
			read_with_status = function(target) return Writer.read_classified(target) end,
			write = function() error("an unconditional publication") end,
			write_if_unchanged = function(target, content, expected)
				context.published[#context.published + 1] = target
				if context.before_publish then context.before_publish(target) end
				if context.refuse == target then return false, "injected publication refusal" end
				return Writer.publish_if_unchanged(target, content, nil, expected)
			end,
		}
		context.dynamic = {
			init = function(options)
				context.dynamic_calls[#context.dynamic_calls + 1] = "init:" .. options.trigger_char
				return true
			end,
			refresh = function()
				context.dynamic_calls[#context.dynamic_calls + 1] = "refresh"
				return true
			end,
			get_rules_count = function() return 3 end,
		}
		context.preview_port = { set_enabled = function(name, value) context.preview[name] = value end }
		context.Config, context.engine = Config, engine
		context.Preferences = require("infra.hotstring_preferences")
		context.RepeatKey = require("modules.hotstrings.repeat_key")
		context.MagicKey = require("modules.hotstrings.magic_key")
		context.Terminators = require("modules.hotstrings.terminator_settings")
		assert(context.Terminators.load(), "the fixture delimiters must load")
		context.suffix = ".hotstrings-test.bak"
		context.scope = require("infra.hotstrings_scope").new({
			path = config_path, backup_suffix = context.suffix, files = context.files,
			is_paused = function() return context.paused end,
			config = Config, preferences = context.Preferences, repeat_key = context.RepeatKey,
			magic_key = context.MagicKey, preview_settings = require("modules.hotstrings.preview_settings"),
			terminators = context.Terminators, dynamic = context.dynamic, preview = context.preview_port,
		})
		body(context)
	end)
	assert(Terminators.restore_configuration(catalogue), "the delimiter catalogue must be put back")
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	os.execute("rm -rf '" .. directory .. "'")
	if not ok then error(err, 0) end
end

helpers.describe("hotstrings scope: restore recommended", function()
	helpers.it("enables the loaded catalogue, measures delays and keeps unknown entries", function()
		with_scope(function(c)
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 9, "fixture override: " .. family)
			end
			local committed, detail = c.scope.apply("recommended")
			helpers.assert_true(committed, tostring(detail))

			local config = Codec.decode(read(c.config_path))
			for id in pairs(CATEGORIES) do helpers.assert_eq(config.hotstrings.groups[id], true, id) end
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(config.hotstrings.modules.autocorrection[family], true, family)
			end
			helpers.assert_eq(config.hotstrings.groups.foreign, true, "an unknown category choice survives")
			helpers.assert_eq(config.hotstrings.unknown, "kept")
			helpers.assert_eq(config.other.value, 1)
			helpers.assert_eq(config.hotstrings.dynamic.enabled, true)
			helpers.assert_nil(config.hotstrings.dynamic.date.enabled, "a family recommended off is removed")
			helpers.assert_eq(config.hotstrings.repeat_key_enabled, true)
			helpers.assert_eq(config.hotstrings.preview_star_enabled, true)
			helpers.assert_eq(config.hotstrings.preview_ai_enabled, true, "restore never touches AI consent")
			helpers.assert_nil(config.hotstrings.trigger_char, "the recommended key is the neutral one")
			helpers.assert_nil(config.hotstrings.personal, "a Windows feature row is never set here")
			helpers.assert_nil(config.hotstrings.magic_key, "a Windows feature row is never set here")

			local overrides = Codec.decode(read(c.override_path))
			helpers.assert_nil(overrides.autocorrection.delay)
			helpers.assert_nil(overrides.autocorrection.color)
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(overrides.autocorrection[family].delay, 0.5,
					"deleting would inherit the corpus 1.0 s, so the recommendation is written: " .. family)
			end
			helpers.assert_eq(overrides.french_autocorrection.accents.delay, 0.5)
			helpers.assert_nil((overrides.rolls or {}).hc and overrides.rolls.hc.delay,
				"an inheritance equal to the recommendation stays sparse")
			helpers.assert_nil((overrides.rolls or {}).hc and overrides.rolls.hc.priority)
			helpers.assert_nil(overrides._global.delay)
			helpers.assert_eq(overrides.foreign.delay, 4, "an unknown category override survives")
			helpers.assert_eq(overrides.foreign.unknown_field, "kept")
			helpers.assert_nil((overrides.personal or {}).code, "user packs receive no recommendation")

			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 0.5, family)
			end
			helpers.assert_eq(c.Config.resolve("rolls", "hc").delay, 0.5)
			helpers.assert_eq(c.Config.resolve("french_autocorrection", "accents").delay, 0.5)
			for _, mapping in ipairs(COMMON_TRIGGERS) do
				helpers.assert_true(fires(c.engine, mapping.trigger, mapping.replacement), "the restored catalogue reaches the engine")
			end
			helpers.assert_true(c.RepeatKey.is_enabled())
			helpers.assert_eq(c.MagicKey.get(), c.MagicKey.default())
			helpers.assert_eq(c.preview.star, true)
			helpers.assert_eq(c.dynamic_calls[1], "init:" .. c.MagicKey.default(), "a changed key re-registers the rules")
			helpers.assert_eq(read(c.config_path .. c.suffix), CONFIG, "config.toml backup is exact")
			helpers.assert_eq(read(c.override_path .. c.suffix), OVERRIDES, "override backup is exact")
			helpers.assert_eq(c.scope.pending(), false)
			helpers.assert_true(c.Config.disable_group("rolls"), "ordinary setters resume after the scope")
		end)
	end)
end)

helpers.describe("hotstrings scope: clear", function()
	helpers.it("returns every choice to neutral and every section to its corpus delay", function()
		with_scope(function(c)
			helpers.assert_true(c.Config.enable_group("autocorrection"))
			for index, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_true(c.Config.toggle_section("autocorrection", family))
				local mapping = COMMON_TRIGGERS[index]
				helpers.assert_true(fires(c.engine, mapping.trigger, mapping.replacement))
			end
			local committed, detail = c.scope.apply("clear")
			helpers.assert_true(committed, tostring(detail))
			local config = Codec.decode(read(c.config_path))
			helpers.assert_nil(config.hotstrings.groups.autocorrection)
			helpers.assert_eq(config.hotstrings.groups.foreign, true, "an unknown category choice survives")
			for _, sections in pairs(config.hotstrings.modules or {}) do
				for _, family in ipairs(COMMON_FAMILIES) do
					helpers.assert_nil(sections[family], "a known section choice is removed: " .. family)
				end
			end
			helpers.assert_nil(config.hotstrings.trigger_char)
			helpers.assert_nil(config.hotstrings.preview_ai_enabled, "clear revokes the AI preview")
			helpers.assert_nil(config.hotstrings.dynamic.date.enabled)
			helpers.assert_eq(config.hotstrings.unknown, "kept")
			local overrides = Codec.decode(read(c.override_path))
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_nil(overrides.autocorrection[family].delay, family)
			end
			helpers.assert_eq(overrides.foreign.unknown_field, "kept")
			for index, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 1.0,
					"a cleared section resolves to its corpus inheritance: " .. family)
				local mapping = COMMON_TRIGGERS[index]
				helpers.assert_eq(fires(c.engine, mapping.trigger, mapping.replacement), false, "nothing fires after clear")
			end
			helpers.assert_eq(c.RepeatKey.is_enabled(), false)
			helpers.assert_eq(c.preview.ai, false)
		end)
	end)
end)

helpers.describe("hotstrings scope: refusals", function()
	helpers.it("restores both files and the runtime when config.toml publication is refused", function()
		with_scope(function(c)
			c.refuse = c.config_path
			local committed = c.scope.apply("recommended")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(read(c.config_path), CONFIG)
			helpers.assert_eq(read(c.override_path), OVERRIDES, "the published override file is put back")
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 9, "the runtime is back: " .. family)
			end
			helpers.assert_eq(c.MagicKey.get(), "§")
			helpers.assert_eq(c.scope.pending(), false)
			helpers.assert_true(c.Config.enable_group("rolls"), "a settled refusal releases the owners")
		end)
	end)

	helpers.it("refuses a configuration an external editor changed during the scope", function()
		with_scope(function(c)
			local external = CONFIG .. "external = 9\n"
			c.before_publish = function(target)
				if target == c.config_path then write(c.config_path, external) end
			end
			helpers.assert_eq(c.scope.apply("clear"), false)
			helpers.assert_eq(read(c.config_path), external, "the external edit wins")
			helpers.assert_eq(read(c.override_path), OVERRIDES)
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 9, family)
			end
		end)
	end)

	helpers.it("publishes neither file when the engine refuses the candidate catalogue", function()
		with_scope(function(c)
			c.refuse_engine = true
			helpers.assert_eq(c.scope.apply("recommended"), false)
			helpers.assert_eq(read(c.config_path), CONFIG)
			helpers.assert_eq(read(c.override_path), OVERRIDES)
			helpers.assert_eq(c.scope.pending(), true,
				"an engine that also refuses the previous catalogue leaves the inverse retained")
			c.refuse_engine = false
			helpers.assert_true(c.scope.retry_restore())
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 9, family)
			end
			helpers.assert_true(c.Config.toggle_group("rolls"), "the settled inverse releases the owners")
		end)
	end)

	helpers.it("retains a refused restoration, fences ordinary setters and retries it", function()
		with_scope(function(c)
			c.refuse = c.config_path
			local candidate = nil
			c.before_publish = function(target)
				-- A second writer replaces the override file after the scope published
				-- it, so putting the exact source back must be refused and retained.
				if target == c.config_path then
					candidate = read(c.override_path)
					write(c.override_path, "[foreign]\ndelay = 7\n")
				end
			end
			helpers.assert_eq(c.scope.apply("recommended"), false)
			helpers.assert_eq(c.scope.pending(), true, "the unsettled inverse is retained")
			helpers.assert_eq(c.Config.toggle_group("rolls"), false, "ordinary setters wait for the inverse")
			helpers.assert_eq(c.Preferences.set("hotstrings.preview_star_enabled", true), false)
			local config_bytes = read(c.config_path)
			helpers.assert_eq(c.Config.set_override("autocorrection", nil, "delay", 5), false)
			helpers.assert_eq(c.Config.set_global_delay(4), false)
			helpers.assert_eq(c.Config.clear_override("autocorrection"), false)
			helpers.assert_eq(read(c.override_path), "[foreign]\ndelay = 7\n", "override setters wait for the inverse")
			helpers.assert_eq(c.RepeatKey.set_enabled(not c.RepeatKey.is_enabled()), false)
			helpers.assert_eq(read(c.config_path), config_bytes, "the repeat key waits for the inverse")
			helpers.assert_eq(c.Terminators.persist(), false, "the word delimiters wait for the inverse")
			helpers.assert_eq(c.scope.retry_restore(), false, "the foreign bytes still block the inverse")
			helpers.assert_eq(c.scope.pending(), true)
			c.before_publish = nil
			write(c.override_path, candidate)
			helpers.assert_true(c.scope.retry_restore(), "the inverse completes once its precondition holds")
			helpers.assert_eq(read(c.override_path), OVERRIDES)
			for _, family in ipairs(COMMON_FAMILIES) do
				helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 9, family)
			end
			helpers.assert_eq(c.scope.pending(), false)
			helpers.assert_true(c.Config.toggle_group("rolls"), "a settled inverse releases the owners")
		end)
	end)

	-- Neither row asks: the maintainer retired the clear's question on
	-- 2026-09-30, the scope owner's backups being the way back.
	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("routes the rendered " .. mode .. " request to the public terminal", function()
			with_scope(function(c)
				local renderer = require("infra.manifest_menu")
				local root = renderer.get_root()
				local top, execute = root.top_level, os.execute
				local key = mode == "clear" and "common.clear_to_system" or "common.restore_recommended"
				local changed, questions = 0, 0
				local passed, err = pcall(function()
					-- The real hotstrings_menu declaration: the rows are the manifest's.
					root.top_level = { { id = "hotstrings" } }
					os.execute = function(command)
						if command:find("zenity", 1, true) then
							questions = questions + 1
							return 0
						end
						return execute(command)
					end
					local menu = require("ui.menu.menu_builder").build({ config = c.Config, paused = false,
						is_paused = function() return false end, dyn_hotstrings = c.dynamic,
						tooltip_preview = c.preview_port, on_menu_changed = function() changed = changed + 1 end })
					-- A direct row of the Hotstrings submenu: the word-delimiter
					-- submenu nested under the parameters has a restore row of its own.
					local action
					for _, item in ipairs(menu) do
						for _, row in ipairs(item.menu or {}) do
							if action == nil and row.title == require("infra.i18n").get(key) then action = row.fn end
						end
					end
					helpers.assert_eq(type(action), "function", "the hotstrings row is registered")
					action()
					helpers.assert_eq(changed, 1)
					helpers.assert_eq(questions, 0, "no scope row asks (restore-recommended-no-confirm)")
					helpers.assert_eq(c.RepeatKey.is_enabled(), mode == "recommended")
					for _, family in ipairs(COMMON_FAMILIES) do
						helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, mode == "clear" and 1.0 or 0.5, family)
					end
				end)
				root.top_level, os.execute = top, execute
				if not passed then error(err, 0) end
			end)
		end)
	end

	-- The Configuration row once deleted every explicit choice, which is the
	-- neutral state: every catalogue off, the opposite of its label.
	helpers.it("routes the Configuration restore row to the recommended hotstrings", function()
		with_scope(function(c)
			local execute = os.execute
			local passed, err = pcall(function()
				os.execute = function(command)
					if command:find("command -v zenity", 1, true) then return 0 end
					if command:find("zenity --question", 1, true) then return 0 end
					return execute(command)
				end
				local i18n = require("infra.i18n")
				local menu = require("ui.menu.menu_builder").build({ config = c.Config, paused = false,
					is_paused = function() return false end, dyn_hotstrings = c.dynamic,
					tooltip_preview = c.preview_port })
				local action
				for _, item in ipairs(menu) do
					if item.title == i18n.get("menu.configuration.title") then
						for _, row in ipairs(item.menu or {}) do
							if row.title == i18n.get("common.restore_recommended") then action = row.fn end
						end
					end
				end
				helpers.assert_eq(type(action), "function", "the Configuration row is registered")
				action()
				helpers.assert_true(c.Config.is_group_enabled("rolls"), "an explicit off choice is restored on")
				for index, family in ipairs(COMMON_FAMILIES) do
					helpers.assert_true(c.Config.is_section_enabled("autocorrection", family))
					local mapping = COMMON_TRIGGERS[index]
					helpers.assert_true(fires(c.engine, mapping.trigger, mapping.replacement), "the restored catalogue fires")
				end
				helpers.assert_true(c.RepeatKey.is_enabled())
				local document = Codec.decode(read(c.config_path))
				helpers.assert_eq(document.hotstrings.groups.rolls, true)
				helpers.assert_eq(document.other.value, 1)
			end)
			os.execute = execute
			if not passed then error(err, 0) end
		end)
	end)

	helpers.it("refuses to start while paused", function()
		with_scope(function(c)
			c.paused = true
			helpers.assert_eq(c.scope.apply("clear"), false)
			helpers.assert_eq(read(c.config_path), CONFIG)
			helpers.assert_eq(#c.published, 0)
		end)
	end)
end)

-- Delimiters the user switched, one of their own, and a state no delimiter owns.
local DELIMITER_CONFIG = '[hotstrings]\nunknown = "kept"\n'
	.. 'terminators = [{ key = "custom_¤", char = "¤", label = "¤", consume = true }]\n'
	.. '\n[hotstrings.terminator_states]\nspace = false\nslash = true\n"custom_¤" = false\nretired = true\n'
	.. '\n[other]\nvalue = 1\n'

--- Whether the shared catalogue holds a custom delimiter.
--- @param key string Delimiter identity.
--- @return boolean
local function has_custom(key)
	for _, def in ipairs(require("keymap.terminators").get_terminator_defs()) do
		if def.key == key and def.custom then return true end
	end
	return false
end

helpers.describe("hotstrings scope: word delimiters", function()
	-- They lived in storage.json, which no scope reaches. Both modes put the
	-- shipped delimiters back on their defaults, as the delimiter submenu's own
	-- restore row does, and keep the user's own delimiters, which are user data.
	for _, mode in ipairs({ "recommended", "clear" }) do
		helpers.it("returns the shipped word delimiters to the catalogue and keeps the user's on " .. mode, function()
			with_scope(function(c)
				local Terminators = require("keymap.terminators")
				helpers.assert_eq(Terminators.is_terminator_enabled("space"), false, "the fixture delimiters are loaded")
				helpers.assert_true(has_custom("custom_¤"))
				local committed, detail = c.scope.apply(mode)
				helpers.assert_true(committed, tostring(detail))
				local config = Codec.decode(read(c.config_path))
				local states = config.hotstrings.terminator_states or {}
				helpers.assert_nil(states.space)
				helpers.assert_nil(states.slash)
				helpers.assert_eq(states["custom_¤"], false, "a user delimiter keeps its state")
				helpers.assert_eq(config.hotstrings.terminators,
					{ { key = "custom_¤", char = "¤", label = "¤", consume = true } }, "a user delimiter is kept")
				helpers.assert_eq(states.retired, true, "a state no delimiter owns is left for the cleanup")
				helpers.assert_eq(config.hotstrings.unknown, "kept")
				helpers.assert_eq(config.other.value, 1)
				helpers.assert_eq(Terminators.is_terminator_enabled("space"), true, "the runtime follows the file")
				helpers.assert_eq(Terminators.is_terminator_enabled("slash"), false)
				helpers.assert_true(has_custom("custom_¤"))
				helpers.assert_eq(Terminators.is_terminator_enabled("custom_¤"), false)
				helpers.assert_eq(read(c.config_path .. c.suffix), DELIMITER_CONFIG, "config.toml backup is exact")
				local written = read(c.config_path)
				helpers.assert_true(c.Terminators.persist(), "ordinary delimiter writes resume")
				helpers.assert_eq(read(c.config_path), written, "the file already holds the runtime's delimiters")
			end, DELIMITER_CONFIG)
		end)
	end

	-- The scope used to delete the user's list, which the shared writer cannot
	-- address when it is written as [[hotstrings.terminators]] tables, so the
	-- whole restore refused.
	helpers.it("resets the shipped delimiters around a [[hotstrings.terminators]] list", function()
		local source = '[hotstrings]\nunknown = "kept"\n\n[hotstrings.terminator_states]\nspace = false\n'
			.. '\n[[hotstrings.terminators]]\nkey = "custom_¤"\nchar = "¤"\nlabel = "¤"\nconsume = true\n'
		with_scope(function(c)
			local committed, detail = c.scope.apply("clear")
			helpers.assert_true(committed, tostring(detail))
			local config = Codec.decode(read(c.config_path))
			helpers.assert_nil((config.hotstrings.terminator_states or {}).space)
			helpers.assert_eq(config.hotstrings.terminators,
				{ { key = "custom_¤", char = "¤", label = "¤", consume = true } })
			helpers.assert_true(has_custom("custom_¤"))
		end, source)
	end)

	helpers.it("puts the word delimiters back when config.toml publication is refused", function()
		with_scope(function(c)
			local Terminators = require("keymap.terminators")
			c.refuse = c.config_path
			helpers.assert_eq(c.scope.apply("clear"), false)
			helpers.assert_eq(read(c.config_path), DELIMITER_CONFIG)
			helpers.assert_eq(Terminators.is_terminator_enabled("space"), false)
			helpers.assert_eq(Terminators.is_terminator_enabled("slash"), true)
			helpers.assert_true(has_custom("custom_¤"))
			helpers.assert_eq(Terminators.is_terminator_enabled("custom_¤"), false)
			helpers.assert_eq(c.scope.pending(), false)
		end, DELIMITER_CONFIG)
	end)
end)

helpers.describe("hotstrings scope: composition", function()
	--- What the engine and the category gates say, to compare before and after.
	local function observed(c)
		return {
			autocorrection = c.Config.is_group_enabled("autocorrection"),
			rolls = c.Config.is_group_enabled("rolls"),
			names_fires = fires(c.engine, "cq", "names-result"),
			abbreviations_fires = fires(c.engine, "aq", "abbreviations-result"),
			technical_terms_fires = fires(c.engine, "tq", "technical-terms-result"),
			rolls_fires = fires(c.engine, "hq", "rolls-result"),
		}
	end

	helpers.it("reverts a committed restore to the exact bytes and runtime it replaced", function()
		with_scope(function(c)
			local before = observed(c)
			local committed, detail = c.scope.apply("recommended")
			helpers.assert_eq(committed, true, detail)
			helpers.assert_true(read(c.config_path) ~= CONFIG, "the restore changed config.toml")
			local reverted, why = c.scope.revert()
			helpers.assert_eq(reverted, true, why)
			helpers.assert_eq(read(c.config_path), CONFIG)
			helpers.assert_eq(read(c.override_path), OVERRIDES)
			helpers.assert_eq(observed(c), before)
			helpers.assert_eq(c.scope.pending(), false)
			helpers.assert_true(c.Config.disable_group("autocorrection"), "ordinary setters are released again")
		end)
	end)

	helpers.it("forgets its inverse once the composition commits", function()
		with_scope(function(c)
			local committed, detail = c.scope.apply("clear")
			helpers.assert_eq(committed, true, detail)
			local cleared = read(c.config_path)
			c.scope.release()
			local reverted = c.scope.revert()
			helpers.assert_eq(reverted, false)
			helpers.assert_eq(read(c.config_path), cleared)
			helpers.assert_eq(c.scope.pending(), false)
		end)
	end)
end)

helpers.describe("hotstrings retained native release debt", function()
	local expected_config = { hotstrings = { unknown = "kept", groups = { rolls = false, foreign = true },
		trigger_char = "§", preview_ai_enabled = true, dynamic = { date = { enabled = true } } }, other = { value = 1 } }
	local expected_overrides = { autocorrection = { delay = 3, color = "#111111", names = { delay = 9 },
		abbreviations = { delay = 9 }, technical_terms = { delay = 9 } }, rolls = { hc = { priority = 5 } },
		foreign = { delay = 4, unknown_field = "kept" }, _global = { delay = 2 } }
	local receipts = {
		{ name = "nil", reply = function() return nil end },
		{ name = "false", reply = function() return false end },
		{ name = "truthy string", reply = function() return "true" end },
		{ name = "wrong object", reply = function() return {} end },
		{ name = "exception", reply = function() error("native hotstrings release refused") end },
	}
	--- Wraps the actual claims without releasing a token on a controlled refusal.
	local function controlled_scope(c, selected, refusal)
		local blocked, live, acknowledged, faults = true, {}, {}, {}
		for _, entry in ipairs({ { "config", c.Config }, { "preferences", c.Preferences } }) do
			local name, native = entry[1], entry[2]
			local acquire, release = native.acquire, native.release
			native.acquire = function(token)
				if faults.acquire == name or (faults.reacquire == name and acknowledged[name]) then return false end
				local accepted = acquire(token)
				if accepted == true then
					helpers.assert_nil(live[name], "an acknowledged claim is not acquired twice")
					live[name] = token
				end
				return accepted
			end
			native.release = function(token)
				helpers.assert_eq(live[name], token, "only the exact live claim can be released")
				if name == selected and blocked then return refusal() end
				local accepted = release(token)
				if accepted == true then live[name] = nil; acknowledged[name] = (acknowledged[name] or 0) + 1 end
				return accepted
			end
		end
		local scope = require("infra.hotstrings_scope").new({ path = c.config_path, backup_suffix = c.suffix,
			files = c.files, is_paused = function() return c.paused end,
			config = c.Config, preferences = c.Preferences, repeat_key = c.RepeatKey, magic_key = c.MagicKey,
			preview_settings = require("modules.hotstrings.preview_settings"), terminators = c.Terminators,
			dynamic = c.dynamic, preview = c.preview_port })
		return scope, function(value) blocked = value == true end, live, faults
	end
	local function restored(c, live)
		helpers.assert_eq(Codec.decode(read(c.config_path)), expected_config, "complete authored configuration preimage")
		helpers.assert_eq(Codec.decode(read(c.override_path)), expected_overrides, "complete authored override preimage")
		helpers.assert_eq(c.MagicKey.get(), "§")
		helpers.assert_eq(c.Config.is_group_enabled("rolls"), false)
		for _, family in ipairs(COMMON_FAMILIES) do helpers.assert_eq(c.Config.resolve("autocorrection", family).delay, 9) end
		helpers.assert_eq(next(live), nil, "every actual native claim is acknowledged")
	end
	for _, mode in ipairs({ "clear", "recommended" }) do
		for _, receipt in ipairs(receipts) do
			helpers.it("compensates both files and runtime on " .. mode .. " " .. receipt.name .. " release", function()
				with_scope(function(c)
					local scope, unblock, live = controlled_scope(c, "config", receipt.reply)
					local called, committed = pcall(scope.apply, mode)
					helpers.assert_eq(called, true, "native refusal is a retained acknowledgement")
					helpers.assert_eq(committed, false)
					helpers.assert_eq(scope.pending(), true)
					helpers.assert_eq(scope.release(), false)
					helpers.assert_eq(scope.apply("recommended"), false)
					helpers.assert_eq(c.Config.enable_group("rolls"), false, "ordinary setters cannot replace owned debt")
					unblock()
					helpers.assert_eq(scope.retry_restore(), true)
					helpers.assert_eq(scope.pending(), false)
					restored(c, live)
				end)
			end)
		end
	end
	helpers.it("retains a partial native acquisition whose acquired claim cannot release", function()
		with_scope(function(c)
			local scope, unblock, live, faults = controlled_scope(c, "config", function() return false end)
			faults.acquire = "preferences"
			local called, committed = pcall(scope.apply, "clear")
			helpers.assert_eq(called, true)
			helpers.assert_eq(committed, false)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(read(c.config_path), CONFIG)
			helpers.assert_eq(read(c.override_path), OVERRIDES)
			helpers.assert_eq(#c.published, 0)
			unblock()
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(scope.pending(), false)
			restored(c, live)
		end)
	end)
	helpers.it("retains a committed candidate while a released claim refuses inverse reacquisition", function()
		with_scope(function(c)
			local scope, unblock, live, faults = controlled_scope(c, "config", function() return false end)
			faults.reacquire = "preferences"
			helpers.assert_eq(scope.apply("recommended"), false)
			local config, override = read(c.config_path), read(c.override_path)
			helpers.assert_true(config ~= CONFIG and override ~= OVERRIDES, "both candidate files are actually committed")
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(read(c.config_path), config)
			helpers.assert_eq(read(c.override_path), override)
			faults.reacquire = nil
			helpers.assert_eq(scope.retry_restore(), true)
			restored(c, live)
		end)
	end)
	helpers.it("preserves an external source successor until exact inverse repair", function()
		with_scope(function(c)
			local scope, unblock, live = controlled_scope(c, "config", function() return false end)
			local publish, writes, candidate = c.files.write_if_unchanged, 0, nil
			local foreign = '[external]\nowner = "later"\n'
			c.files.write_if_unchanged = function(target, content, expected)
				if target == c.config_path then writes = writes + 1; if writes == 2 then write(target, foreign) end end
				local ok, detail = publish(target, content, expected)
				if target == c.config_path and writes == 1 and ok == true then candidate = read(target) end
				return ok, detail
			end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(read(c.config_path), foreign)
			helpers.assert_eq(read(c.override_path), OVERRIDES, "the override inverse is already acknowledged")
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(read(c.config_path), foreign)
			local calls = #c.dynamic_calls
			write(c.config_path, candidate) -- Explicit fixture repair of the retained candidate generation.
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(#c.dynamic_calls, calls, "the acknowledged runtime inverse is not repeated")
			restored(c, live)
		end)
	end)
	helpers.it("retries only release after an acknowledged explicit inverse", function()
		with_scope(function(c)
			local scope, block, live = controlled_scope(c, "config", function() return false end)
			block(false)
			helpers.assert_eq(scope.apply("recommended"), true)
			block(true)
			helpers.assert_eq(scope.revert(), false)
			helpers.assert_eq(scope.pending(), true)
			local calls = #c.dynamic_calls
			block(false)
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(#c.dynamic_calls, calls)
			restored(c, live)
		end)
	end)
	helpers.it("stops the actual global composition before later categories on native release debt", function()
		with_scope(function(c)
			local scope, unblock, live = controlled_scope(c, "preferences", function() return false end)
			local trace = {}
			local before = { apply = function(_, done) trace[#trace + 1] = "before.apply"; done(true) end,
				revert = function(done) trace[#trace + 1] = "before.revert"; done(true) end,
				release = function() end, pending = function() return false end, retry_restore = function(done) done(true) end }
			local after = { apply = function(_, done) trace[#trace + 1] = "after.apply"; done(true) end,
				revert = function(done) done(true) end, release = function() end,
				pending = function() return false end, retry_restore = function(done) done(true) end }
			local actual = require("config_scope_participant").synchronous({ apply = scope.apply, owner = function() return scope end })
			local logger = {}; for _, name in ipairs({ "start", "success", "warn", "info", "error" }) do logger[name] = function() end end
			local global = require("config_scope_composition").new({ manifest = require("infra.manifest_reader"), scope = "global",
				logger = logger, participants = function() return { tap_holds = before, hotstrings = actual, llm = after } end })
			local verdict, report
			global.apply("recommended", function(ok, detail) verdict, report = ok, detail end)
			helpers.assert_eq(verdict, false)
			helpers.assert_eq(report.failed, "hotstrings")
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(trace, { "before.apply" })
			unblock()
			local settled
			global.retry_restore(function(ok) settled = ok end)
			helpers.assert_eq(settled, true)
			helpers.assert_eq(trace, { "before.apply", "before.revert" })
			helpers.assert_eq(global.pending(), false)
			restored(c, live)
		end)
	end)
end)
