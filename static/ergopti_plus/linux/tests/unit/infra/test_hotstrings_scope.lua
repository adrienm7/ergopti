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
local OVERRIDES = '[autocorrection]\ndelay = 3\ncolor = "#111111"\n\n[autocorrection.caps]\ndelay = 9\n\n'
	.. '[rolls.hc]\npriority = 5\n\n[foreign]\ndelay = 4\nunknown_field = "kept"\n\n[_global]\ndelay = 2\n'

--- The catalogue the stub loader publishes: real category ids, corpus delays
--- that differ from and agree with the manifest recommendations, and a
--- personal pack whose section shares a name with a manifest row.
local CATEGORIES = {
	autocorrection = { id = "autocorrection", delay = 1.0, sections_order = { "caps" }, sections = { caps = { count = 1 } } },
	french_autocorrection = { id = "french_autocorrection", delay = 1.0, sections_order = { "accents" },
		sections = { accents = { count = 1 } } },
	rolls = { id = "rolls", delay = 0.5, sections_order = { "hc" }, sections = { hc = { count = 1 } } },
	personal = { id = "personal", delay = 2.0, sections_order = { "code" }, sections = { code = { count = 1 } } },
}
local MAPPINGS = {
	{ trigger = "cq", replacement = "caps-result", group = "autocorrection", section = "caps", auto_expand = true },
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
local function with_scope(body)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local directory = string.format("%s/ergopti_hotstrings_scope_%d_%d",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999))
	assert(os.execute("mkdir -p '" .. directory .. "'"))
	local ok, err = pcall(function()
		for _, name in ipairs({ "modules.hotstrings.hotstrings_config", "infra.hotstring_preferences",
			"modules.hotstrings.repeat_key", "modules.hotstrings.magic_key", "modules.hotstrings.preview_settings",
			"infra.hotstrings_scope" }) do
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
		write(config_path, CONFIG)
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
		context.suffix = ".hotstrings-test.bak"
		context.scope = require("infra.hotstrings_scope").new({
			path = config_path, backup_suffix = context.suffix, files = context.files,
			is_paused = function() return context.paused end,
			config = Config, preferences = context.Preferences, repeat_key = context.RepeatKey,
			magic_key = context.MagicKey, preview_settings = require("modules.hotstrings.preview_settings"),
			dynamic = context.dynamic, preview = context.preview_port,
		})
		body(context)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	os.execute("rm -rf '" .. directory .. "'")
	if not ok then error(err, 0) end
end

helpers.describe("hotstrings scope: restore recommended", function()
	helpers.it("enables the loaded catalogue, measures delays and keeps unknown entries", function()
		with_scope(function(c)
			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 9, "fixture override")
			local committed, detail = c.scope.apply("recommended")
			helpers.assert_true(committed, tostring(detail))

			local config = Codec.decode(read(c.config_path))
			for id in pairs(CATEGORIES) do helpers.assert_eq(config.hotstrings.groups[id], true, id) end
			helpers.assert_eq(config.hotstrings.modules.autocorrection.caps, true)
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
			helpers.assert_eq(overrides.autocorrection.caps.delay, 0.5,
				"deleting would inherit the corpus 1.0 s, so the recommendation is written")
			helpers.assert_eq(overrides.french_autocorrection.accents.delay, 0.5)
			helpers.assert_nil((overrides.rolls or {}).hc and overrides.rolls.hc.delay,
				"an inheritance equal to the recommendation stays sparse")
			helpers.assert_nil((overrides.rolls or {}).hc and overrides.rolls.hc.priority)
			helpers.assert_nil(overrides._global.delay)
			helpers.assert_eq(overrides.foreign.delay, 4, "an unknown category override survives")
			helpers.assert_eq(overrides.foreign.unknown_field, "kept")
			helpers.assert_nil((overrides.personal or {}).code, "user packs receive no recommendation")

			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 0.5)
			helpers.assert_eq(c.Config.resolve("rolls", "hc").delay, 0.5)
			helpers.assert_eq(c.Config.resolve("french_autocorrection", "accents").delay, 0.5)
			helpers.assert_true(fires(c.engine, "cq", "caps-result"), "the restored catalogue reaches the engine")
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
			helpers.assert_true(c.Config.toggle_section("autocorrection", "caps"))
			helpers.assert_true(fires(c.engine, "cq", "caps-result"))
			local committed, detail = c.scope.apply("clear")
			helpers.assert_true(committed, tostring(detail))
			local config = Codec.decode(read(c.config_path))
			helpers.assert_nil(config.hotstrings.groups.autocorrection)
			helpers.assert_eq(config.hotstrings.groups.foreign, true, "an unknown category choice survives")
			for _, sections in pairs(config.hotstrings.modules or {}) do
				helpers.assert_nil(sections.caps, "a known section choice is removed")
			end
			helpers.assert_nil(config.hotstrings.trigger_char)
			helpers.assert_nil(config.hotstrings.preview_ai_enabled, "clear revokes the AI preview")
			helpers.assert_nil(config.hotstrings.dynamic.date.enabled)
			helpers.assert_eq(config.hotstrings.unknown, "kept")
			local overrides = Codec.decode(read(c.override_path))
			helpers.assert_nil(overrides.autocorrection.caps.delay)
			helpers.assert_eq(overrides.foreign.unknown_field, "kept")
			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 1.0,
				"a cleared section resolves to its corpus inheritance")
			helpers.assert_eq(fires(c.engine, "cq", "caps-result"), false, "nothing fires after clear")
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
			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 9, "the runtime is back")
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
			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 9)
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
			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 9)
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
			helpers.assert_eq(c.scope.retry_restore(), false, "the foreign bytes still block the inverse")
			helpers.assert_eq(c.scope.pending(), true)
			c.before_publish = nil
			write(c.override_path, candidate)
			helpers.assert_true(c.scope.retry_restore(), "the inverse completes once its precondition holds")
			helpers.assert_eq(read(c.override_path), OVERRIDES)
			helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, 9)
			helpers.assert_eq(c.scope.pending(), false)
			helpers.assert_true(c.Config.toggle_group("rolls"), "a settled inverse releases the owners")
		end)
	end)

	for _, mode in ipairs({ "clear", "recommended", "cancel" }) do
		helpers.it("routes the rendered " .. mode .. " request to the public terminal", function()
			with_scope(function(c)
				local renderer = require("infra.manifest_menu")
				local root = renderer.get_root()
				local rows, top, execute = root.hotstrings_menu, root.top_level, os.execute
				local selected = mode == "recommended" and "recommended" or "clear"
				local key = selected == "clear" and "common.clear_to_system" or "common.restore_recommended"
				local changed = 0
				local passed, err = pcall(function()
					root.hotstrings_menu = { { type = "command", id = selected == "clear" and "scope_clear" or "scope_restore",
						i18n = key } }
					root.top_level = { { id = "hotstrings" } }
					os.execute = function(command)
						if command:find("command -v zenity", 1, true) then return 0 end
						if command:find("zenity --question", 1, true) then return mode == "cancel" and 1 or 0 end
						return execute(command)
					end
					local menu = require("ui.menu.menu_builder").build({ config = c.Config, paused = false,
						is_paused = function() return false end, dyn_hotstrings = c.dynamic,
						tooltip_preview = c.preview_port, on_menu_changed = function() changed = changed + 1 end })
					local action
					local function find(items)
						for _, row in ipairs(items) do
							if row.title == require("infra.i18n").get(key) then action = row.fn end
							if row.menu then find(row.menu) end
						end
					end
					find(menu)
					helpers.assert_eq(type(action), "function", "the hotstrings row is registered")
					action()
					local expected = mode ~= "cancel"
					helpers.assert_eq(changed, expected and 1 or 0)
					if expected then
						helpers.assert_eq(c.RepeatKey.is_enabled(), mode == "recommended")
						helpers.assert_eq(c.Config.resolve("autocorrection", "caps").delay, mode == "clear" and 1.0 or 0.5)
					else
						helpers.assert_eq(read(c.config_path), CONFIG)
						helpers.assert_eq(read(c.override_path), OVERRIDES)
					end
				end)
				root.hotstrings_menu, root.top_level, os.execute = rows, top, execute
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
				helpers.assert_true(c.Config.is_section_enabled("autocorrection", "caps"))
				helpers.assert_true(fires(c.engine, "cq", "caps-result"), "the restored catalogue fires")
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

helpers.describe("hotstrings scope: composition", function()
	--- What the engine and the category gates say, to compare before and after.
	local function observed(c)
		return {
			autocorrection = c.Config.is_group_enabled("autocorrection"),
			rolls = c.Config.is_group_enabled("rolls"),
			caps_fires = fires(c.engine, "cq", "caps-result"),
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
