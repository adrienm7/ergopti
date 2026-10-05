--- tests/unit/ui/menu/test_hotstrings_scope.lua

--- ==============================================================================
--- MODULE: macOS Hotstrings Scope Tests
--- DESCRIPTION:
--- Drives the Hotstrings « restore recommended » and « clear » commands through
--- the real preferences, override-file, planner, writer and transaction owners.
--- Only the keymap is a fake, and it projects delays with the real resolver over
--- the real corpus metadata, so the delay a section runs with is measured.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Paths = require("infra.paths")
local TomlReader = require("infra.toml.reader")
local Languages = require("hotstrings.languages")
local Extensions = require("hotstrings.extensions")

local ORIGINAL_CONFIG = table.concat({
	"[hotstrings]",
	"enabled = true",
	'trigger_char = "§"',
	"repeat_key_enabled = false",
	"expansion_delay = 0.9",
	"preview_ai_enabled = true",
	"future = { keep = 1 }",
	"groups = { autocorrection = true, rolls = false, personal = true }",
	"delays = { autocorrection = 3.0, dynamichotstrings = 1.5 }",
	"",
	"[hotstrings.modules.autocorrection]",
	"caps = true",
	"",
	"[hotstrings.magic_key.replace]",
	"enabled = false",
	"",
	"[llm]",
	"enabled = true",
	"",
}, "\n")

local ORIGINAL_OVERRIDES = table.concat({
	"# kept comment",
	"[__global__]",
	'word_delimiters = " .,"',
	'consumed_delimiters = "x"',
	"",
	"[autocorrection.caps]",
	"delay = 2.0",
	'color = "#123456"',
	"",
	"[rolls]",
	"priority = 40",
	"",
	"[futurepack.section]",
	"delay = 3.0",
	"",
}, "\n")

local DELIMITER_CONFIG = ORIGINAL_CONFIG:gsub("future = { keep = 1 }",
	'future = { keep = 1 }\nterminators = [{ key = "custom_¤", char = "¤", label = "¤", consume = true }]')
	.. '\n[hotstrings.terminator_states]\nspace = false\nslash = true\n"custom_¤" = false\nretired = true\n'

--- The file a bundled category loads from: the bundled folder, or the file the
--- shipped Ergopti extension binds to that category (SFB reduction and rolls
--- moved there), resolved by the shared extension scanner the drivers use.
--- @param name string Corpus stem.
--- @return string path
local function corpus_path(name)
	local bundled = Paths.shared("modules/hotstrings/" .. name .. ".toml")
	local handle = io.open(bundled, "rb")
	if handle then
		handle:close()
		return bundled
	end
	local shipped = require("modules.keymap.layout_registry").shipped_extension_root({
		settings = { ergopti_family = "ergopti" },
		bundled_dir = Paths.shared("../../layouts/registry/"),
		exists = function(path)
			local file = io.open(path, "rb")
			if file then file:close() end
			return file ~= nil
		end,
	})
	local found = Extensions.scan({ assert(shipped, "the Ergopti extension ships with the app") }, {
		list_dirs = function() return {} end,
		list_files = function(dir)
			local files = {}
			local listing = assert(io.popen('ls -1 "' .. dir .. '" 2>/dev/null'))
			for entry in listing:lines() do
				if entry:match("%.toml$") then files[#files + 1] = dir .. "/" .. entry end
			end
			listing:close()
			return files
		end,
		read_file = function(path)
			local file = io.open(path, "rb")
			if not file then return nil end
			local content = file:read("*a")
			file:close()
			return content
		end,
	})
	return assert(Extensions.bound_source(found, name), "no bundled or bound corpus for " .. name)
end

--- Parses a bundled corpus file the way the registry registers it.
--- @param name string Corpus stem.
--- @return table entry { sections, metadata }
local function corpus(name)
	local parsed, committed = TomlReader.parse(corpus_path(name))
	assert(committed == true, "corpus fixture unreadable: " .. name)
	local sections = {}
	for _, section in ipairs(parsed.sections_order or {}) do
		if section ~= "-" then sections[#sections + 1] = { name = section } end
	end
	return { sections = sections, metadata = parsed.meta or {} }
end

--- A keymap whose delay projection runs the real resolver it is handed.
--- @param controls table Test switches.
--- @return table keymap
local function fake_keymap(controls)
	local Manifest = require("infra.manifest_reader")
	local Preferences = require("infra.preferences")
	package.loaded["keymap.terminators"] = nil
	package.loaded["keymap.terminators_catalogue"] = nil
	local Terminators = require("keymap.terminators")
	local registered = { autocorrection = corpus("autocorrection"), rolls = corpus("rolls"),
		personal = { sections = { { name = "code" } }, metadata = {} } }
	local groups = { autocorrection = true, rolls = false, personal = true, dynamichotstrings = true }
	local lua_sections = { dynamichotstrings = { { name = "datefr" } } }
	local km = { DELAY_KEY_TO_CATEGORY = { autocorrection = "autocorrection", rolls = "rolls" },
		delays = {}, chosen = {}, previews = {}, reloads = {}, repeat_enabled = false, base = 0.9, trigger = "§",
		projected = {} }
	km.get_terminator_defs = Terminators.get_terminator_defs
	km.is_terminator_enabled = Terminators.is_terminator_enabled
	km.add_custom_terminator = Terminators.add_custom_terminator
	km.is_terminator = Terminators.is_terminator
	function km.set_terminators_enabled(changes)
		km.terminator_calls = (km.terminator_calls or 0) + 1
		if controls.refuse_terminators or controls.refuse_terminator_call == km.terminator_calls then
			controls.refuse_terminators = false
			return false
		end
		return Terminators.set_terminators_enabled(changes)
	end
	function km.list_groups()
		local copy = {}
		for name, enabled in pairs(groups) do copy[name] = enabled end
		return copy
	end
	function km.get_sections(name)
		return (registered[name] and registered[name].sections) or lua_sections[name]
	end
	function km.is_group_enabled(name) return groups[name] == true end
	function km.is_section_enabled(group, section)
		local chosen = km.chosen[group .. "/" .. section]
		if chosen ~= nil then return chosen end
		local shipped = Languages.section_default(Manifest.features(), group, section)
		if shipped == nil then return true end
		return shipped
	end
	function km.apply_hotstring_preferences(saved)
		if controls.refuse_groups then
			controls.refuse_groups = false
			return false
		end
		local desired = Preferences.project_hotstring_preferences(saved, km.list_groups(), km.get_sections)
		for name, enabled in pairs(desired.hotstrings) do groups[name] = enabled end
		for name, sections in pairs(desired.section_states) do
			for section, enabled in pairs(sections) do km.chosen[name .. "/" .. section] = enabled end
		end
		return true
	end
	function km.hotstring_delay_inventory()
		local inventory = {}
		for name, entry in pairs(registered) do
			local sections = {}
			for _, section in ipairs(entry.sections) do sections[#sections + 1] = section.name end
			inventory[name] = { sections = sections, metadata = entry.metadata }
		end
		return inventory
	end
	function km.with_hotstring_delays(resolve, publish)
		local previous, projected = km.projected, {}
		for name, entry in pairs(km.hotstring_delay_inventory()) do
			for _, section in ipairs(entry.sections) do
				projected[name .. "/" .. section] = resolve(name, section, entry.metadata)
			end
		end
		km.projected = projected
		if publish() ~= true then
			km.projected = previous
			return false
		end
		return true
	end
	function km.registry_transaction(_, mutation) return mutation() end
	function km.disable_group(name)
		groups[name] = false
		km.reloads[#km.reloads + 1] = name
		return true
	end
	function km.enable_group(name)
		groups[name] = true
		return true
	end
	function km.set_delay(key, value)
		km.delays[key] = value
		return true
	end
	function km.is_repeat_feature_enabled() return km.repeat_enabled end
	function km.set_repeat_feature_enabled(value) km.repeat_enabled = value; return true end
	function km.get_base_delay() return km.base end
	function km.set_base_delay(value) km.base = value; return true end
	function km.get_magic_key_source() return km.magic_key_source end
	function km.set_magic_key_source(value) km.magic_key_source = value; return true end
	function km.get_trigger_char() return km.trigger end
	function km.set_trigger_char(value)
		if controls.refuse_trigger then
			controls.refuse_trigger = false
			return false
		end
		km.trigger = value
		return true
	end
	for _, name in ipairs({ "star", "autocorrect", "colored", "ai" }) do
		local setter = name == "colored" and "set_preview_colored_tooltips" or ("set_preview_" .. name .. "_enabled")
		km[setter] = function(value)
			km.previews[name] = value
			return true
		end
	end
	return km
end

--- Builds the scope over in-memory files and the real owners.
--- @return table fixture
local function fixture(options)
	options = options or {}
	local overrides = ORIGINAL_OVERRIDES
	if options.overrides ~= nil then overrides = options.overrides or nil end
	local files = { config = options.config or ORIGINAL_CONFIG, overrides = overrides }
	local controls, removed = {}, {}
	local adapter = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("conditional publication is required") end,
		write_if_unchanged = function(path, content, expected)
			if controls.refuse == path then
				if controls.then_refuse then controls.refuse = controls.then_refuse; controls.then_refuse = nil end
				return false
			end
			if expected.status == "ok" and expected.content ~= files[path] then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			files[path] = content
			return true
		end,
	}
	package.loaded["adapters.file_system"] = adapter
	package.loaded["ui.menu.hotstrings_scope"] = nil
	package.loaded["ui.menu.scoped_preferences"] = nil
	local prefs = helpers.load_with_stubs("infra.preferences")
	prefs.load("config")
	local km = fake_keymap(controls)
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local Config = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	helpers.assert_eq(Config.init({ override_path = "overrides", delay_transaction = km.with_hotstring_delays,
		toml_resolver = function(category) return Paths.shared("modules/hotstrings/" .. category .. ".toml") end }), true)
	local state = { keymap = true, trigger_char = "§", repeat_key_enabled = false, expansion_delay = 0.9,
		preview_ai_enabled = true, preview_star_enabled = false, preview_autocorrect_enabled = false,
		preview_colored_tooltips = false, dynamichotstrings_enabled = false,
		hotstrings = { autocorrection = true, rolls = false, personal = true, dynamichotstrings = true },
		delays = { autocorrection = 3.0, dynamichotstrings = 1.5 } }
	local hotstrings = Codec.decode(files.config).hotstrings or {}
	state.terminator_states = hotstrings.terminator_states or {}
	state.custom_terminators = hotstrings.terminators or {}
	for _, entry in ipairs(state.custom_terminators) do
		assert(km.add_custom_terminator(entry.key, entry.char, entry.label, entry.consume))
	end
	local known = {}
	for _, entry in ipairs(km.get_terminator_defs()) do
		if entry.key and type(state.terminator_states[entry.key]) == "boolean" then
			known[entry.key] = state.terminator_states[entry.key]
		end
	end
	assert(km.set_terminators_enabled(known))
	local hotfiles = { "autocorrection", "rolls", "personal", "dynamichotstrings" }
	local core = { keymap = km }
	local PT = require("ui.menu.preferences_transaction")
	local save, checkpoint = PT.bind(prefs, { path = "config", state = state, hotfiles = hotfiles, core_modules = core,
		initial_state = state, initial_preferences = prefs.snapshot(state, hotfiles, core),
		restore_runtime = function() return true end })
	local engine = { started = true, starts = 0, stops = 0 }
	local editor = { trigger = nil }
	local generation = 0
	local owner = require("ui.menu.hotstrings_scope").new({
		path = "config", files = adapter, state = state, preferences = prefs, checkpoint = checkpoint,
		demotions = require("ui.menu.session_demotions").new(),
		capture_preferences = function() return prefs.snapshot(state, hotfiles, core) end,
		backup_path = function() generation = generation + 1; return "config-backup-" .. generation end,
		override_backup_path = function() generation = generation + 1; return "overrides-backup-" .. generation end,
		admission = function(_, callback) return callback() end,
		paused = function() return false end,
		keymap = km, config = Config, is_personal = function(name) return name == "personal" end,
		editor = { set_trigger_char = function(value) editor.trigger = value end },
		start_engine = function()
			if controls.refuse_start then return false end
			engine.started, engine.starts = true, engine.starts + 1
			return true
		end,
		stop_engine = function()
			engine.started, engine.stops = false, engine.stops + 1
			return true
		end,
		remove = function(path) removed[#removed + 1] = path; files[path] = nil; return true end,
	})
	return { owner = owner, files = files, controls = controls, km = km, config = Config, state = state,
		prefs = prefs, save = save, engine = engine, editor = editor, removed = removed }
end

--- Returns the only file whose name starts with a prefix, or nil.
--- @param files table In-memory files.
--- @param prefix string Name prefix.
--- @return string|nil content
local function backup(files, prefix)
	for name, content in pairs(files) do
		if name:sub(1, #prefix) == prefix then return content end
	end
	return nil
end

helpers.describe("macOS hotstrings scope", function()
	helpers.it("restores the recommended 0.5 s where deleting the override would inherit 1.0 s", function()
		local f = fixture()
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
		helpers.assert_eq(f.owner.apply("recommended"), true)
		local overrides = f.config.parse_override_content(f.files.overrides)
		helpers.assert_eq(overrides.autocorrection.sections.caps.delay, 0.5)
		helpers.assert_eq(overrides.autocorrection.sections.caps.color, nil)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 0.5, "the engine runs the recommended delay")
		helpers.assert_eq(f.config.resolve("autocorrection", "caps").delay, 0.5)
		helpers.assert_eq(f.config.scope_snapshot().source.content, f.files.overrides)
	end)

	helpers.it("clears every override so each section runs its corpus inheritance", function()
		local f = fixture()
		helpers.assert_eq(f.owner.apply("clear"), true)
		local overrides = f.config.parse_override_content(f.files.overrides)
		helpers.assert_nil(((overrides.autocorrection or {}).sections or {}).caps
			and overrides.autocorrection.sections.caps.delay)
		helpers.assert_nil((overrides.rolls or {}).priority)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 1.0)
		helpers.assert_eq(f.config.resolve("autocorrection", "caps").delay, 1.0)
	end)

	helpers.it("keeps every override field and table the scope does not own, with a verified backup", function()
		for _, mode in ipairs({ "recommended", "clear" }) do
			local f = fixture()
			helpers.assert_eq(f.owner.apply(mode), true)
			local overrides = f.config.parse_override_content(f.files.overrides)
			helpers.assert_eq(overrides.futurepack.sections.section.delay, 3.0)
			helpers.assert_true(f.files.overrides:find("# kept comment", 1, true) ~= nil, "comment kept")
			helpers.assert_true(f.files.overrides:find('consumed_delimiters = "x"', 1, true) ~= nil,
				"a sibling driver's global kept")
			helpers.assert_eq(f.config.get_word_delimiters(), " .,")
			helpers.assert_eq(backup(f.files, "overrides-backup-"), ORIGINAL_OVERRIDES)
			helpers.assert_eq(backup(f.files, "config-backup-"), ORIGINAL_CONFIG)
		end
	end)

	helpers.it("restores recommended choices and scalars, keeping consent and unknown leaves", function()
		local f = fixture()
		helpers.assert_eq(f.owner.apply("recommended"), true)
		local decoded = Codec.decode(f.files.config)
		helpers.assert_eq(decoded.hotstrings.groups.rolls, true)
		helpers.assert_eq(decoded.hotstrings.modules.autocorrection.caps, true)
		helpers.assert_eq(decoded.hotstrings.repeat_key_enabled, true)
		helpers.assert_eq(decoded.hotstrings.preview_ai_enabled, true, "restore keeps the AI consent")
		helpers.assert_nil(decoded.hotstrings.trigger_char)
		helpers.assert_eq(decoded.hotstrings.future, { keep = 1 })
		helpers.assert_eq(decoded.hotstrings.delays, { dynamichotstrings = 1.5 })
		local replace = (decoded.hotstrings.magic_key or {}).replace or {}
		helpers.assert_nil(replace.enabled, "a Windows reader's row is not written here")
		helpers.assert_eq(decoded.llm.enabled, true)
		helpers.assert_eq(f.km.repeat_enabled, true)
		helpers.assert_eq(f.km.trigger, "★")
		helpers.assert_eq(f.editor.trigger, "★")
		helpers.assert_eq(f.km.base, 0.75)
		helpers.assert_eq(f.km.previews.star, true)
		helpers.assert_eq(f.km.previews.ai, nil, "consent is not re-applied")
		helpers.assert_eq(f.km.is_group_enabled("rolls"), true)
		helpers.assert_eq(f.state.hotstrings.rolls, true)
		helpers.assert_eq(f.state.delays, { dynamichotstrings = 1.5 })
		helpers.assert_eq(f.km.delays.autocorrection, 1.0, "the legacy shadow follows the override file")
		helpers.assert_eq(f.km.reloads, { "rolls" }, "a changed priority is registered again")
		helpers.assert_eq(f.engine.stops, 0)
		helpers.assert_eq(f.prefs.source_snapshot("config").content, f.files.config)
		helpers.assert_eq(f.save(), true)
		local saved = Codec.decode(f.files.config)
		helpers.assert_eq(saved.hotstrings.groups.rolls, true)
		helpers.assert_eq(saved.hotstrings.repeat_key_enabled, true)
		helpers.assert_nil(saved.hotstrings.trigger_char)
	end)

	helpers.it("clears to the neutral engine: stopped, defaults, no choices, consent revoked", function()
		local f = fixture()
		helpers.assert_eq(f.owner.apply("clear"), true)
		local decoded = Codec.decode(f.files.config)
		helpers.assert_nil(decoded.hotstrings.enabled)
		helpers.assert_nil(decoded.hotstrings.groups)
		helpers.assert_nil(((decoded.hotstrings.modules or {}).autocorrection or {}).caps)
		helpers.assert_nil(decoded.hotstrings.preview_ai_enabled)
		helpers.assert_eq(decoded.hotstrings.future, { keep = 1 })
		helpers.assert_eq(f.engine.stops, 1)
		helpers.assert_eq(f.state.keymap, false)
		helpers.assert_eq(f.km.previews.ai, false)
		helpers.assert_eq(f.km.is_group_enabled("autocorrection"), false)
		helpers.assert_eq(f.km.is_section_enabled("autocorrection", "caps"), false)
		helpers.assert_eq(f.save(), true)
		helpers.assert_nil(Codec.decode(f.files.config).hotstrings.groups)
	end)

	helpers.it("puts both files and the runtime back when config.toml publication is refused", function()
		local f = fixture()
		f.controls.refuse = "config"
		helpers.assert_eq(f.owner.apply("clear"), false)
		helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
		helpers.assert_eq(f.config.scope_snapshot().source.content, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.km.is_group_enabled("autocorrection"), true)
		helpers.assert_eq(f.km.trigger, "§")
		helpers.assert_eq(f.km.base, 0.9)
		helpers.assert_eq(f.state.keymap, true)
		helpers.assert_eq(f.engine.started, true)
		helpers.assert_eq(f.state.delays, { autocorrection = 3.0, dynamichotstrings = 1.5 })
		helpers.assert_eq(f.km.delays.autocorrection, 3.0)
		helpers.assert_eq(f.owner.pending(), false)
		helpers.assert_eq(f.config.set_override("rolls", nil, "delay", 0.4), true, "the file is released")
	end)

	helpers.it("puts both files and the runtime back when a native owner refuses", function()
		for _, refusal in ipairs({ "refuse_trigger", "refuse_groups" }) do
			local f = fixture()
			f.controls[refusal] = true
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
			helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
			helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
			helpers.assert_eq(f.state.keymap, true)
			helpers.assert_eq(f.owner.pending(), false)
		end
		local f = fixture({ config = ORIGINAL_CONFIG:gsub("enabled = true\n", "enabled = false\n", 1) })
		f.state.keymap, f.engine.started = false, false
		f.controls.refuse_start = true
		helpers.assert_eq(f.owner.apply("recommended"), false)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.state.keymap, false)
	end)

	helpers.it("retains a refused restoration, fences ordinary writes, and settles on retry", function()
		local f = fixture()
		f.controls.refuse, f.controls.then_refuse = "config", "overrides"
		helpers.assert_eq(f.owner.apply("clear"), false)
		helpers.assert_eq(f.owner.pending(), true)
		helpers.assert_true(f.files.overrides ~= ORIGINAL_OVERRIDES, "the published candidate is still owed")
		helpers.assert_eq(f.config.set_override("rolls", nil, "delay", 0.4), false, "ordinary writes wait")
		helpers.assert_eq(f.owner.apply("recommended"), false, "no second transaction while debt is owed")
		f.controls.refuse = nil
		helpers.assert_eq(f.owner.retry_restore(), true)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
		helpers.assert_eq(f.owner.pending(), false)
		helpers.assert_eq(f.config.set_override("rolls", nil, "delay", 0.4), true)
	end)

	helpers.it("refuses before any change when the override file changed since it was loaded", function()
		local f = fixture()
		f.files.overrides = ORIGINAL_OVERRIDES .. "[rolls.hc]\ndelay = 0.1\n"
		helpers.assert_eq(f.owner.apply("clear"), false)
		helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
		helpers.assert_nil(backup(f.files, "overrides-backup-"))
		helpers.assert_nil(backup(f.files, "config-backup-"))
		helpers.assert_eq(f.owner.pending(), false)
	end)

	helpers.it("refuses when the engine's reader would still see a change the plan removed", function()
		local f = fixture()
		local parse = f.config.parse_override_content
		f.config.parse_override_content = function(content)
			local parsed = parse(content)
			parsed.autocorrection = { sections = { caps = { delay = 2.0 } } }
			return parsed
		end
		helpers.assert_eq(f.owner.apply("clear"), false)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
		helpers.assert_nil(backup(f.files, "overrides-backup-"))
	end)

	helpers.it("clears a case-variant table the reader and the writer both address", function()
		local f = fixture({ overrides = "[AutoCorrection.caps]\ndelay = 2.0\n" })
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
		helpers.assert_eq(f.owner.apply("clear"), true)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 1.0)
	end)

	helpers.it("reverts a committed restore to both files and the runtime, then releases the fence", function()
		local f = fixture()
		helpers.assert_eq(f.owner.apply("recommended"), true)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 0.5)
		helpers.assert_eq(f.owner.revert(), true)
		helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
		helpers.assert_eq(f.config.scope_snapshot().source.content, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.prefs.source_snapshot("config").content, ORIGINAL_CONFIG)
		helpers.assert_eq(f.km.is_group_enabled("rolls"), false)
		helpers.assert_eq(f.km.repeat_enabled, false)
		helpers.assert_eq(f.km.trigger, "§")
		helpers.assert_eq(f.editor.trigger, "§")
		helpers.assert_eq(f.state.delays, { autocorrection = 3.0, dynamichotstrings = 1.5 })
		helpers.assert_eq(f.owner.pending(), false)
		helpers.assert_eq(f.owner.revert(), false, "one commit has one inverse")
		helpers.assert_eq(f.config.set_override("rolls", nil, "delay", 0.4), true, "the file is released")
	end)

	helpers.it("retains a refused revert, fences ordinary writes, and settles it on retry", function()
		local f = fixture()
		helpers.assert_eq(f.owner.apply("clear"), true)
		f.controls.refuse = "overrides"
		helpers.assert_eq(f.owner.revert(), false)
		helpers.assert_eq(f.owner.pending(), true)
		helpers.assert_eq(f.config.set_override("rolls", nil, "delay", 0.4), false, "ordinary writes wait")
		f.controls.refuse = nil
		helpers.assert_eq(f.owner.retry_restore(), true)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
		helpers.assert_eq(f.state.keymap, true)
		helpers.assert_eq(f.engine.started, true)
		helpers.assert_eq(f.owner.pending(), false)
		helpers.assert_eq(f.config.set_override("rolls", nil, "delay", 0.4), true)
	end)

	-- Configuration › « Restore recommended values » composes this owner with
	-- the others; a later category's refusal must undo this one exactly.
	helpers.it("takes part in the global scope, reverted when a later category refuses", function()
		local f = fixture()
		local refused = {
			apply = function() return false end,
			revert = function() return false end,
			release = function() end,
			pending = function() return false end,
			retry_restore = function() return true end,
		}
		local refreshes = {}
		package.loaded["ui.menu.global_scope"] = nil
		local global = require("ui.menu.global_scope").new({
			owners = { hotstrings = function() return f.owner end, llm = function() return refused end },
			backup_path = function(scope) return "remap-" .. scope end,
			defer = function(continuation) continuation(); return true end,
			paused = function() return false end,
			refresh = function(committed, report) refreshes[#refreshes + 1] = { committed, report } end,
		})
		helpers.assert_eq(global.apply("recommended"), true)
		helpers.assert_eq(#refreshes, 1)
		helpers.assert_eq(refreshes[1][1], false)
		helpers.assert_eq(refreshes[1][2].failed, "llm")
		helpers.assert_eq(refreshes[1][2].reverted, true)
		helpers.assert_eq(f.files.config, ORIGINAL_CONFIG)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 2.0)
		helpers.assert_eq(f.km.is_group_enabled("rolls"), false)
		helpers.assert_eq(f.owner.pending(), false)
	end)

	-- The global restore composes this owner with every other category; one it
	-- cannot serve because of its second file must be skipped and named, not
	-- refuse every other category with it.
	helpers.it("names why it cannot serve a composed restore, and nothing when it can", function()
		local f = fixture()
		helpers.assert_nil(f.owner.unavailable(), "a cleanly read override file is served")
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES, "the check writes nothing")
		local parse = f.config.parse_override_content
		f.config.parse_override_content = function(content)
			local parsed = parse(content)
			parsed.autocorrection = { sections = { caps = { delay = 2.0 } } }
			return parsed
		end
		local reason = f.owner.unavailable()
		helpers.assert_true(type(reason) == "string" and reason:find("cannot address", 1, true) ~= nil, tostring(reason))
		f.config.parse_override_content = parse
		local snapshot = f.config.scope_snapshot
		f.config.scope_snapshot = function() return nil end
		helpers.assert_true(type(f.owner.unavailable()) == "string", "an unread override file is named")
		f.config.scope_snapshot = snapshot
		helpers.assert_eq(f.owner.apply("clear"), true, "the check leaves the owner usable")
	end)

	helpers.it("leaves a retained inverse to the composition and its override file intact", function()
		local f = fixture()
		f.controls.refuse, f.controls.then_refuse = "config", "overrides"
		helpers.assert_eq(f.owner.apply("clear"), false)
		helpers.assert_eq(f.owner.pending(), true)
		helpers.assert_nil(f.owner.unavailable(), "the composition reports the debt itself")
		f.controls.refuse = nil
		helpers.assert_eq(f.owner.retry_restore(), true)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES, "the retained inverse still restores its file")
		helpers.assert_eq(f.owner.pending(), false)
	end)

	helpers.it("creates an absent override file for a recommendation and removes it on rollback", function()
		local f = fixture({ overrides = false })
		f.controls.refuse = "config"
		helpers.assert_eq(f.owner.apply("recommended"), false)
		helpers.assert_nil(f.files.overrides)
		helpers.assert_eq(f.removed, { "overrides" })
		f.controls.refuse = nil
		helpers.assert_eq(f.owner.apply("recommended"), true)
		helpers.assert_eq(f.config.parse_override_content(f.files.overrides).autocorrection.sections.caps.delay, 0.5)
		helpers.assert_eq(f.km.projected["autocorrection/caps"], 0.5)
	end)
end)

helpers.describe("hotstrings scope: delimiter parity (hotstrings-delimiter-scope-parity)", function()
	for _, mode in ipairs({ "recommended", "clear" }) do
		helpers.it("resets shipped delimiters and retains personal entries on " .. mode, function()
			local f = fixture({ config = DELIMITER_CONFIG })
			helpers.assert_eq(f.km.is_terminator(" "), false, "the configured space is initially off")
			helpers.assert_eq(f.km.is_terminator("/"), true, "the configured slash is initially on")
			helpers.assert_eq(f.owner.apply(mode), true)
			local states = Codec.decode(f.files.config).hotstrings.terminator_states or {}
			helpers.assert_nil(states.space, "the file inherits the shipped space default")
			helpers.assert_nil(states.slash, "the file inherits the shipped slash default")
			helpers.assert_eq(states["custom_¤"], false)
			helpers.assert_eq(states.retired, true, "cleanup still owns the outdated entry")
			helpers.assert_eq(f.km.is_terminator(" "), true, "the runtime adopts the restored space")
			helpers.assert_eq(f.km.is_terminator("/"), false, "the runtime adopts the restored slash")
			helpers.assert_eq(f.km.is_terminator_enabled("custom_¤"), false)
			helpers.assert_nil(f.state.terminator_states.space, "the next save must not resurrect the override")
			helpers.assert_nil(f.state.terminator_states.slash)
			helpers.assert_eq(backup(f.files, "config-backup-"), DELIMITER_CONFIG)
			helpers.assert_eq(f.save(), true)
			local saved = Codec.decode(f.files.config).hotstrings
			helpers.assert_nil((saved.terminator_states or {}).space)
			helpers.assert_eq(saved.terminators,
				{ { key = "custom_¤", char = "¤", label = "¤", consume = true } })
		end)
	end

	helpers.it("keeps a hand-written delimiter table array while resetting shipped states", function()
		local source = ORIGINAL_CONFIG .. '\n[hotstrings.terminator_states]\nspace = false\n'
			.. '\n[[hotstrings.terminators]]\nkey = "custom_¤"\nchar = "¤"\nlabel = "¤"\nconsume = true\n'
		local f = fixture({ config = source })
		helpers.assert_eq(f.owner.apply("clear"), true)
		helpers.assert_nil((Codec.decode(f.files.config).hotstrings.terminator_states or {}).space)
		helpers.assert_true(f.files.config:find("[[hotstrings.terminators]]", 1, true) ~= nil)
		helpers.assert_eq(f.km.is_terminator("¤"), true)
	end)

	for _, refusal in ipairs({ "config", "refuse_terminators" }) do
		helpers.it("restores exact delimiters after " .. refusal .. " refusal", function()
			local f = fixture({ config = DELIMITER_CONFIG })
			if refusal == "config" then f.controls.refuse = "config" else f.controls[refusal] = true end
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.files.config, DELIMITER_CONFIG)
			helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
			helpers.assert_eq(f.km.is_terminator(" "), false)
			helpers.assert_eq(f.km.is_terminator("/"), true)
			helpers.assert_eq(f.state.terminator_states.space, false)
			helpers.assert_eq(f.owner.pending(), false)
		end)
	end

	helpers.it("reverts a composed restore to the exact delimiter runtime and source", function()
		local f = fixture({ config = DELIMITER_CONFIG })
		helpers.assert_eq(f.owner.apply("recommended"), true)
		helpers.assert_eq(f.km.is_terminator(" "), true)
		helpers.assert_eq(f.owner.revert(), true)
		helpers.assert_eq(f.files.config, DELIMITER_CONFIG)
		helpers.assert_eq(f.km.is_terminator(" "), false)
		helpers.assert_eq(f.km.is_terminator("/"), true)
		helpers.assert_eq(f.state.terminator_states.space, false)
	end)

	helpers.it("retains a refused delimiter inverse and settles it before admitting another scope", function()
		local f = fixture({ config = DELIMITER_CONFIG })
		f.controls.refuse = "config"
		f.controls.refuse_terminator_call = f.km.terminator_calls + 2
		helpers.assert_eq(f.owner.apply("clear"), false)
		helpers.assert_eq(f.owner.pending(), true, "a refused runtime inverse stays owned")
		helpers.assert_eq(f.km.is_terminator(" "), true, "the un-restored runtime is visible")
		helpers.assert_eq(f.owner.apply("recommended"), false, "no second scope before settlement")
		f.controls.refuse = nil
		helpers.assert_eq(f.owner.retry_restore(), true)
		helpers.assert_eq(f.owner.pending(), false)
		helpers.assert_eq(f.files.config, DELIMITER_CONFIG)
		helpers.assert_eq(f.km.is_terminator(" "), false)
		helpers.assert_eq(f.km.is_terminator("/"), true)
		helpers.assert_eq(f.state.terminator_states.space, false)
		helpers.assert_eq(f.owner.apply("recommended"), true, "ordinary scopes resume after settlement")
	end)
end)

helpers.describe("Hotstrings refused secondary publication receipt", function()
	helpers.it("retains unadopted native debt and external conflicts until the exact inverse settles", function()
		local f = fixture()
		local fs = package.loaded["adapters.file_system"]
		local original = fs.write_if_unchanged
		local blocked, owed, releases = true, true, 0
		fs.write_if_unchanged = function(path, content, source)
			local written = original(path, content, source)
			if path == "overrides" and owed and written == true then
				owed = false
				return false, "native publication release refused", function()
					releases = releases + 1
					return not blocked, "release remains pending", true
				end
			end
			return written
		end
		helpers.assert_eq(f.owner.apply("recommended"), false)
		helpers.assert_eq(f.owner.pending(), true, "unadopted partial publication retains the owning transaction")
		helpers.assert_eq(f.owner.retry_restore(), false)
		local candidate = f.files.overrides
		f.files.overrides = "external successor"
		blocked = false
		helpers.assert_eq(f.owner.retry_restore(), false, "release alone cannot compensate changed bytes")
		helpers.assert_eq(f.owner.retry_restore(), false, "secondary debt must outlive its settled release")
		helpers.assert_eq(f.files.overrides, "external successor")
		f.files.overrides = candidate
		helpers.assert_eq(f.owner.retry_restore(), true)
		helpers.assert_eq(f.files.overrides, ORIGINAL_OVERRIDES)
		helpers.assert_eq(f.owner.pending(), false)
		helpers.assert_true(releases >= 2)
	end)
end)
