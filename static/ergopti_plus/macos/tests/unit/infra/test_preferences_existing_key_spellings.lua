--- tests/unit/infra/test_preferences_existing_key_spellings.lua

--- The Hotstrings switch saves the complete preference state through one
--- sparse batch. On a config.toml an older build wrote (every empty map as its
--- own [header]), after the boot migration, or with a hand-written quoted key
--- or [[list]], the shared writer refused that batch: "the batch cannot address
--- an existing quoted or nested key", settings NOT saved
--- (toml-batch-existing-key).

local helpers = require("tests.helpers")
local Codec = require("toml_codec.codec")
local Migrate = require("config_migrate")

local PATH = "/switch/config.toml"
local GROUPS = { "autocorrection", "distancesreduction", "magickey" }
local SECTIONS = { { name = "accents" }, { name = "qu" } }
local _modules = nil

--- Loads the real modules whose defaults form the saved state, once per file.
--- @return table modules Core modules for build_initial_state and snapshot.
local function core_modules()
	if not _modules then
		package.loaded["modules.keylogger.kc_bridge"] = { init = function() return true end }
		_modules = {}
		for key, name in pairs({ keymap = "keymap", dyn_hot_mod = "dynamic_hotstrings",
			shortcuts_mod = "shortcuts", gestures = "gestures", keylogger = "keylogger" }) do
			_modules[key] = helpers.load_with_stubs("modules." .. name)
		end
	end
	local modules = {}
	for key, module in pairs(_modules) do modules[key] = module end
	-- Every section reads as enabled, as the switch leaves them.
	modules.keymap = setmetatable({
		get_sections = function() return SECTIONS end,
		is_section_enabled = function() return true end,
	}, { __index = _modules.keymap })
	return modules
end

--- Boots preferences on source, applies one state change and saves the full batch.
--- @param source string config.toml bytes.
--- @param change function Mutates the loaded state.
--- @return boolean saved
--- @return string disk Bytes after the save.
local function save_after(source, change)
	return helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system" }, function()
		local modules = core_modules()
		local disk = source
		package.loaded["adapters.file_system"] = {
			read_with_status = function() return disk, "ok" end,
			write = function() error("the save must keep its source precondition") end,
			write_if_unchanged = function(_, content, expected)
				helpers.assert_eq(expected.content, disk)
				disk = content
				return true
			end,
		}
		local prefs = helpers.load_with_stubs("infra.preferences")
		local hotfiles = {}
		for _, group in ipairs(GROUPS) do hotfiles[#hotfiles + 1] = group .. ".toml" end
		local state = prefs.build_initial_state(hotfiles, {}, modules)
		local saved, status = prefs.load(PATH)
		helpers.assert_eq(status, "ok")
		prefs.merge_saved_data(state, saved)
		change(state)
		local ok = prefs.save(PATH, state, hotfiles, modules)
		return ok, disk
	end)
end

--- The state change of the Hotstrings switch turned on (toggle_all_hotstrings).
--- @param state table Menu state.
local function switch_on(state)
	state.keymap = true
	for _, group in ipairs(GROUPS) do state.hotstrings[group] = true end
end

--- A config.toml as the whole-file encoder of older macOS builds wrote it:
--- every empty map of the state is its own header.
--- @return string source
local function old_build_file()
	return "# kept comment\n" .. Codec.encode({
		hotstrings = {
			enabled = false, delays = {}, terminator_states = {}, order_overrides = {},
			groups = { autocorrection = false, magickey = false },
			modules = { autocorrection = { accents = false } },
			editor = { close_on_add = false, shortcut = {} },
		},
		llm = {
			enabled = false,
			models = { selected = "mlx", user_models = {} },
			profiles = { active = "basic", shortcuts = {}, user_profiles = {} },
			trigger = { debounce_ms = 200, disabled_apps = {} },
			navigation = { nav_modifiers = {} },
		},
		metrics = { enabled = true, disabled_apps = {} },
		shortcuts = { enabled = true, keys = {} },
		gestures = { enabled = true, modes = {}, sensitivities = {} },
		future = { keep = 99 },
	})
end

--- The same file after this build's boot migration (stamped, v2 -> current).
--- @return string source
local function migrated_old_build_file()
	local registry = assert(Migrate.load_registry(helpers.shared(Migrate.REGISTRY_PATH)))
	local catalogue = dofile(helpers.shared("../macos/_generated/action_catalogue.lua"))
	local context, detail = Migrate.load_context(helpers.shared("modules/actions/modifier_chords.json"), catalogue)
	helpers.assert_true(context ~= nil, detail)
	local plan = Migrate.plan(old_build_file(), registry, "hs", context)
	helpers.assert_eq(plan.outcome, "migrated", plan.detail)
	return plan.candidate
end

--- Reads a file below _shared/.
--- @param relative string Path below _shared/.
--- @return string content
local function shared_file(relative)
	local handle = assert(io.open(helpers.shared(relative), "rb"))
	local content = handle:read("*a")
	handle:close()
	return content
end

helpers.describe("the Hotstrings switch saves over existing key spellings (toml-batch-existing-key)", function()
	helpers.it("saves over every config.toml shape an older build, the migration or a hand edit left", function()
		local shapes = {
			{ "older build whole-file encoder", old_build_file() },
			{ "older build after the boot migration", migrated_old_build_file() },
			{ "shipped macOS example config", shared_file("core/config_schema/examples/hs_config.example.toml") },
			{ "quoted bare-compatible keys", '# kept comment\n[hotstrings]\n"enabled" = false\n"magic_key_source" = "auto"\n'
				.. '[hotstrings.groups]\n"autocorrection" = false\n[future]\nkeep = 99\n' },
			{ "hand-written [[hotstrings.terminators]] list", '# kept comment\n[hotstrings]\nexpansion_delay = 0.5\n\n'
				.. '[[hotstrings.terminators]]\nkey = "custom_x"\nchar = "¤"\nlabel = "¤"\nconsume = true\n\n[future]\nkeep = 99\n' },
		}
		for _, shape in ipairs(shapes) do
			local ok, disk = save_after(shape[2], switch_on)
			helpers.assert_eq(ok, true, shape[1])
			local decoded = Codec.decode(disk)
			helpers.assert_true(type(decoded) == "table", shape[1] .. ": the saved file stays valid TOML")
			for _, group in ipairs(GROUPS) do
				helpers.assert_eq(decoded.hotstrings.groups[group], true, shape[1] .. " " .. group)
				helpers.assert_eq(decoded.hotstrings.modules[group].accents, true, shape[1] .. " " .. group)
			end
			if shape[2]:find("# kept comment\n", 1, true) then
				helpers.assert_true(disk:find("# kept comment\n", 1, true) ~= nil, shape[1] .. ": comments are kept")
				helpers.assert_eq(decoded.future.keep, 99, shape[1] .. ": unrelated tables are kept")
			end
		end
	end)

	helpers.it("keeps a hand-written [[hotstrings.terminators]] list untouched when it did not change", function()
		local source = '[hotstrings]\nexpansion_delay = 0.5\n\n[[hotstrings.terminators]]\n'
			.. 'key = "custom_x"\nchar = "¤"\nlabel = "¤"\nconsume = true\n'
		local ok, disk = save_after(source, switch_on)
		helpers.assert_eq(ok, true)
		helpers.assert_true(disk:find('[[hotstrings.terminators]]\nkey = "custom_x"\nchar = "¤"\nlabel = "¤"\nconsume = true\n',
			1, true) ~= nil, "the list keeps its spelling")
	end)

	helpers.it("preserves retired Metrics bindings as unknown source data through a full save", function()
		local legacy = '# retained legacy dashboard bindings\n[metrics]\n'
			.. 'shortcut = { mods = ["cmd"], key = "m", future = { keep = 9 } } # retained typing\n'
			.. 'apps_shortcut = "unsupported historical value" # retained apps\n'
		local ok, disk = save_after(legacy, function(state)
			state.keylogger_enabled = false
			state.metrics_shortcut, state.apps_time_shortcut = false, false
		end)
		helpers.assert_eq(ok, true)
		local checked = 0
		for line in legacy:gmatch("[^\n]+") do
			checked = checked + 1
			helpers.assert_true(disk:find(line .. "\n", 1, true) ~= nil,
				"an ordinary save owns neither retired binding nor its source comment: " .. line)
		end
		helpers.assert_eq(checked, 4, "all four independently written legacy lines are checked")
		helpers.assert_eq(Codec.decode(disk).metrics.shortcut.future.keep, 9)
		helpers.assert_eq(Codec.decode(disk).metrics.apps_shortcut, "unsupported historical value")
	end)

	helpers.it("keeps outdated entries when a table is reset, header or inline", function()
		for _, source in ipairs({ "[hotstrings.delays]\nretired_delay = 0.2\nautocorrection = 0.8\n",
			"[hotstrings]\ndelays = { retired_delay = 0.2, autocorrection = 0.8 }\n" }) do
			local ok, disk = save_after(source, function(state)
				helpers.assert_eq(state.delays.autocorrection, 0.8, "the valid delay is read")
				state.delays = {}
			end)
			helpers.assert_eq(ok, true, source)
			helpers.assert_eq(Codec.decode(disk).hotstrings.delays, { retired_delay = 0.2 }, source)
		end
	end)
end)
