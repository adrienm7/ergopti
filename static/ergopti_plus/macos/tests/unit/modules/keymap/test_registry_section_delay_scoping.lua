--- tests/unit/modules/keymap/test_registry_section_delay_scoping.lua
--- Behavioral regression coverage for group-owned section delays.

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.keymap.registry",
	"modules.keymap.registry_groups",
	"modules.keymap.registry_index",
	"modules.keymap.terminators",
	"modules.keymap.state",
	"modules.keymap.utils",
	"infra.toml.reader",
	"infra.timings",
	"modules.hotstrings.hotstrings_config",
}

local function group_data(trigger, delay)
	local meta = {}
	if delay ~= nil then meta.section_delays = { rolls = delay } end
	return {
		sections_order = { "rolls" },
		sections = {
			rolls = {
				[trigger] = { output = trigger:upper() },
			},
		},
		meta = meta,
	}
end

local function with_registry(data_by_path, callback)
	return helpers.with_fresh_modules(OWNED_MODULES, function()
		package.loaded["infra.toml.reader"] = {
			parse = function(path) return data_by_path[path], true end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			get_user_override = function() return nil end,
		}
		local State = helpers.load_with_stubs("modules.keymap.state")
		package.loaded["infra.timings"] = {
			sec = function() return 0.01 end,
		}
		local Registry = require("modules.keymap.registry")
		local state = State.new(
			{ trigger_char = "★", expansion_delay = 0.4 },
			{ group_a = 0.4, group_b = 0.4 })
		helpers.assert_eq(Registry.init(state), true)
		return callback(state, Registry)
	end)
end

local function mapping_for(state, trigger)
	for _, mapping in ipairs(state.mappings) do
		if mapping.trigger == trigger then return mapping end
	end
	return nil
end

helpers.describe("Registry section-delay ownership", function()
	helpers.it("scopes colliding section names by group and prunes disabled owners", function()
		with_registry({
			["/virtual/group-b.toml"] = group_data("btrigger", 2.5),
			["/virtual/group-a.toml"] = group_data("atrigger", 0),
		}, function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_b", "/virtual/group-b.toml"), true)
			helpers.assert_eq(Registry.load_toml("group_a", "/virtual/group-a.toml"), true)

			local mapping_a = mapping_for(state, "atrigger")
			local mapping_b = mapping_for(state, "btrigger")
			helpers.assert_true(mapping_a ~= nil and mapping_b ~= nil,
				"both real registry mappings must be live before testing their delay policy")
			helpers.assert_eq(state.resolve_mapping_delay(mapping_a), 0,
				"group A must retain its always-active section delay")
			helpers.assert_eq(state.resolve_mapping_delay(mapping_b), 2.5,
				"group B must not inherit group A's colliding section name")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0,
				"an enabled always-active owner still requires an infinite word timeout")

			helpers.assert_eq(Registry.disable_group("group_a"), true)
			helpers.assert_nil(state.SECTION_DELAYS.group_a,
				"disabling a group must remove its complete section-delay ownership")
			helpers.assert_eq(state.resolve_mapping_delay(mapping_b), 2.5,
				"the remaining group must retain its own colliding section delay")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 3.0,
				"the word timeout must be recomputed after the infinite owner is removed")

			helpers.assert_eq(Registry.enable_group("group_a"), true)
			local reloaded_a = mapping_for(state, "atrigger")
			helpers.assert_true(reloaded_a ~= nil, "re-enabling the group must restore its mappings")
			helpers.assert_eq(state.resolve_mapping_delay(reloaded_a), 0,
				"re-enabling the group must restore its own section-delay ownership")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0,
				"the restored always-active owner must restore the infinite timeout")
		end)
	end)

	helpers.it("replaces a group's delay set when the same file is reloaded", function()
		local data_by_path = {
			["/virtual/group-a.toml"] = group_data("atrigger", 0),
		}
		with_registry(data_by_path, function(state, Registry)
			helpers.assert_eq(Registry.load_toml("group_a", "/virtual/group-a.toml"), true)
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0)

			data_by_path["/virtual/group-a.toml"] = group_data("atrigger", nil)
			helpers.assert_eq(Registry.reload_toml("group_a", "/virtual/group-a.toml"), true)

			local mapping = mapping_for(state, "atrigger")
			helpers.assert_true(mapping ~= nil, "the reloaded mapping must remain registered")
			local group_delays = state.SECTION_DELAYS.group_a or {}
			helpers.assert_nil(group_delays.rolls,
				"a removed source override must not survive a same-file reload")
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 0.4,
				"the reloaded mapping must fall back to its group delay")
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0.9,
				"the timeout must shrink after the removed infinite override")
		end)
	end)
end)

helpers.describe("canonical hotstring override delays reach the real runtime", function()
	local function fixture(source, callback, expected_init_admission)
		local owned = {}
		for _, name in ipairs(OWNED_MODULES) do owned[#owned + 1] = name end
		owned[#owned + 1] = "adapters.file_system"
		return helpers.with_fresh_modules(owned, function()
			local State = helpers.load_with_stubs("modules.keymap.state")
			local reader = require("infra.toml.reader")
			local data = group_data("atrigger", 0.2)
			data.meta.delay = 1.2
			local other = group_data("btrigger", 3)
			package.loaded["infra.toml.reader"] = { parse = function(path)
				if path == "/virtual/group_a.toml" then return data, true end
				if path == "/virtual/group_b.toml" then return other, true end
				return reader.parse(path)
			end }
			local files, control = { overrides = source }, { writes = 0, refuse = false }
			package.loaded["adapters.file_system"] = {
				read_with_status = function(path)
					helpers.assert_eq(path, "overrides")
					return files[path], files[path] and "ok" or "absent"
				end,
				write_if_unchanged = function(path, content, expected)
					control.writes = control.writes + 1
					if control.refuse then return false end
					if expected.status ~= (files[path] and "ok" or "absent")
						or (expected.status == "ok" and expected.content ~= files[path]) then return false end
					files[path] = content
					return true
				end,
			}
			local Registry = require("modules.keymap.registry")
			local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { group_a = 0.4, group_b = 0.4 })
			helpers.assert_true(Registry.init(state))
			local Config = require("modules.hotstrings.hotstrings_config")
			local initialized = Config.init({
				override_path = "overrides",
				toml_resolver = function(category) return "/virtual/" .. category .. ".toml" end,
				delay_transaction = Registry.with_hotstring_delays,
			})
			if expected_init_admission == false then
				helpers.assert_eq(initialized, false, "an open physical record cannot establish safe override admission")
				helpers.assert_eq(Config.common_autocorrection_admitted(), false)
				helpers.assert_eq(Config.reload(), false, "a repeated classified read never silently admits unsafe bytes")
				helpers.assert_eq(control.writes, 0)
				helpers.assert_eq(files.overrides, source)
			else
				helpers.assert_true(initialized)
			end
			helpers.assert_true(Registry.load_toml("group_a", "/virtual/group_a.toml"))
			helpers.assert_true(Registry.load_toml("group_b", "/virtual/group_b.toml"))
			callback(state, Registry, Config, files, control)
		end)
	end

	helpers.it("applies persisted section overrides before the first activation decision", function()
		fixture("[group_a.rolls]\ndelay = 2\n", function(state)
			local mapping = mapping_for(state, "atrigger")
			helpers.assert_not_nil(mapping)
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 2)
			helpers.assert_true(state.mapping_delay_remaining(mapping, 1.9))
			helpers.assert_eq(state.mapping_delay_remaining(mapping, 2), false)
		end)
	end)

	helpers.it("set and clear update the live section cascade without reloading mappings", function()
		fixture(nil, function(state, _, Config, files, control)
			local mapping = mapping_for(state, "atrigger")
			helpers.assert_eq(control.writes, 0, "absence must not create a source at boot")
			helpers.assert_nil(files.overrides)
			helpers.assert_true(Config.set_override("group_a", nil, "delay", 4))
			helpers.assert_true(Config.set_override("group_a", "rolls", "delay", 0))
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 0)
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, 0)
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "btrigger")), 3)
			helpers.assert_true(Config.clear_override("group_a", "rolls", "delay"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 4)
			helpers.assert_true(Config.clear_override("group_a", nil, "delay"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 0.2)
			helpers.assert_true(mapping == mapping_for(state, "atrigger"))
		end)
	end)

	helpers.it("retains unknown nested neighbors through both set and clear", function()
		fixture('[group_a.rolls]\ndelay = 1\nfuture = { nested = { keep = [1, 2] } }\n[untouched.deep]\nvalue = "same"\n', function(_, _, Config, files)
			helpers.assert_true(Config.set_override("group_a", "rolls", "delay", 2))
			helpers.assert_true(Config.clear_override("group_a", "rolls", "delay"))
			local data = require("toml_codec").decode(files.overrides)
			helpers.assert_nil(data.group_a.rolls.delay)
			helpers.assert_eq(data.group_a.rolls.future.nested.keep[2], 2)
			helpers.assert_eq(data.untouched.deep.value, "same")
		end)
	end)

	for _, unknown in ipairs({
		"[unowned.deep.nested]\ndelay = 9\n",
		'future = """\n[group_a.rolls]\ndelay = 9\n"""\n',
	}) do
		helpers.it("does not consume delays embedded in unknown records", function()
			fixture("[group_a.rolls]\ndelay = 2\n" .. unknown, function(state, _, Config, files)
				helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 2)
				helpers.assert_true(Config.set_override("group_a", "rolls", "delay", 3))
				helpers.assert_true(files.overrides:find(unknown, 1, true) ~= nil)
				helpers.assert_true(Config.reload())
				helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 3)
			end)
		end)
	end

	helpers.it("restores section deadlines and timeout when publication refuses", function()
		fixture("[group_a.rolls]\ndelay = 2\n", function(state, _, Config, files, control)
			local source, timeout = files.overrides, state.WORD_TIMEOUT_SEC
			control.refuse = true
			helpers.assert_eq(Config.set_override("group_a", "rolls", "delay", 0), false)
			helpers.assert_eq(files.overrides, source)
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 2)
			helpers.assert_eq(state.WORD_TIMEOUT_SEC, timeout)
			helpers.assert_eq(Config.get_user_override("group_a", "rolls").delay, 2)
		end)
	end)

	helpers.it("refuses before publication when the runtime projection cannot settle", function()
		fixture(nil, function(state, _, Config, files, control)
			local recompute = state.recompute_word_timeout
			state.recompute_word_timeout = function() error("injected projection refusal") end
			local result = Config.set_override("group_a", "rolls", "delay", 2)
			state.recompute_word_timeout = recompute
			helpers.assert_eq(result, false)
			helpers.assert_eq(control.writes, 0)
			helpers.assert_nil(files.overrides)
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 0.2)
		end)
	end)

	helpers.it("reload to absent clears stale overrides and later group reload keeps the current owner", function()
		fixture("[group_a.rolls]\ndelay = 2\n", function(state, Registry, Config, files)
			files.overrides = nil
			helpers.assert_true(Config.reload())
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 0.2)
			helpers.assert_true(Config.set_override("group_a", "rolls", "delay", 5))
			helpers.assert_true(Registry.reload_toml("group_a", "/virtual/group_a.toml"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 5)
		end)
	end)

	helpers.it("section authority wins over stale category and magic-key timing caches", function()
		fixture("[group_a.rolls]\ndelay = 2\n", function(state)
			local mapping = mapping_for(state, "atrigger")
			state.DELAYS.group_a = 99
			state.DELAYS.STAR_TRIGGER = 88
			mapping.has_magic = true
			helpers.assert_eq(state.resolve_mapping_delay(mapping), 2)
		end)
	end)

	helpers.it("preserves an external winner and adopts its runtime delay after a lost source race", function()
		fixture("[group_a.rolls]\ndelay = 2\n", function(state, _, Config, files, control)
			local winner = "[group_a.rolls]\ndelay = 7\nfuture = { keep = true }\n"
			files.overrides = winner
			helpers.assert_eq(Config.set_override("group_a", "rolls", "delay", 4), false)
			helpers.assert_eq(files.overrides, winner)
			helpers.assert_eq(control.writes, 1)
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 7)
		end)
	end)

	helpers.it("a disabled group consumes the latest delay only when its real owner re-enables it", function()
		fixture(nil, function(state, Registry, Config)
			helpers.assert_true(Registry.disable_group("group_a"))
			helpers.assert_true(Config.set_override("group_a", "rolls", "delay", 6))
			helpers.assert_nil(state.SECTION_DELAYS.group_a)
			helpers.assert_true(Registry.enable_group("group_a"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 6)
		end)
	end)

	for _, example in ipairs({
		{ name = "unterminated neighbor", source = "[group_a.rolls]\ndelay = 2\nfuture = [1,\n", init_admitted = false },
		{ name = "inline ancestor", source = "[group_a]\nrolls = { delay = 2, future = true }\n" },
		{ name = "table-valued leaf", source = "[group_a.rolls.delay]\nfuture = true\n" },
		{ name = "duplicate header", source = "[group_a.rolls]\ndelay = 2\n[group_a.rolls]\nfuture = true\n" },
		{ name = "duplicate field", source = "[group_a.rolls]\ndelay = 2\ndelay = 3\n" },
		{ name = "quoted reader-unowned header", source = '[group_a."rolls"]\ndelay = 2\n' },
		{ name = "case-normalized header", source = "[GROUP_A.rolls]\ndelay = 2\n" },
	}) do
		helpers.it("refuses a conflicting source without publication: " .. example.name, function()
			fixture(example.source, function(state, _, Config, files, control)
				local before, delays = {}, {}
				for index, mapping in ipairs(state.mappings) do
					before[index] = {}
					for field, value in pairs(mapping) do
						helpers.assert_true(type(value) ~= "table", "the independent fixture snapshots every mapping scalar")
						before[index][field] = value
					end
					delays[index] = state.resolve_mapping_delay(mapping)
				end
				local sequence, timeout = state.seq_counter, state.WORD_TIMEOUT_SEC
				helpers.assert_eq(Config.set_override("group_a", "rolls", "delay", 6), false)
				helpers.assert_eq(control.writes, 0)
				helpers.assert_eq(files.overrides, example.source)
				helpers.assert_eq(state.mappings, before, "refusal retains every unrelated native mapping field")
				helpers.assert_eq(state.seq_counter, sequence)
				helpers.assert_eq(state.WORD_TIMEOUT_SEC, timeout)
				for index, mapping in ipairs(state.mappings) do
					helpers.assert_eq(state.resolve_mapping_delay(mapping), delays[index])
				end
			end, example.init_admitted)
		end)
	end

	helpers.it("restores the committed resolver after an enclosing registry transaction refuses", function()
		fixture("[group_a.rolls]\ndelay = 2\n", function(state, Registry)
			helpers.assert_eq(Registry.registry_transaction("outer owner refusal", function()
				helpers.assert_true(Registry.with_hotstring_delays(function() return 9 end, function() return true end))
				return false
			end), false)
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 2)
			helpers.assert_true(Registry.reload_toml("group_a", "/virtual/group_a.toml"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 2)
		end)
	end)

	helpers.it("uses the existing extension override owner for a colon/slash runtime category", function()
		fixture("[ext.team.rolls]\ndelay = 4\n", function(state, Registry, Config, files, control)
			helpers.assert_true(Registry.disable_group("group_a"))
			local group = require("hotstrings.extensions").category_key("team", "snippets/work")
			helpers.assert_true(Registry.load_toml(group, "/virtual/group_a.toml"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 4)
			helpers.assert_true(Config.set_override("ext.team", "rolls", "delay", 6))
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 6)
			helpers.assert_true(Config.clear_override("ext.team", "rolls", "delay"))
			helpers.assert_eq(state.resolve_mapping_delay(mapping_for(state, "atrigger")), 0.2)
			local writes, content = control.writes, files.overrides
			helpers.assert_eq(Config.set_override(group, "rolls", "delay", 5), false)
			helpers.assert_eq(control.writes, writes)
			helpers.assert_eq(files.overrides, content)
		end)
	end)
end)

helpers.describe("hotstring delay boot admission", function()
	for _, admitted in ipairs({ true, false }) do
		helpers.it("requires the real delay owner before keymap startup: " .. tostring(admitted), function()
			local source = helpers.read_driver_unit('local hotstring_config_ready = hotstrings_config.init({')
			local first = assert(source:find('local hotstrings_config = require("modules.hotstrings.hotstrings_config")', 1, true))
			local last = assert(source:find("-- Wire the config window", first, true))
			local start = assert(source:find("local keymap_started = keymap.start()", last, true))
			helpers.assert_true(first < last and last < start)
			local selected
			local transaction = function() return true end
			local env = setmetatable({
				keymap = { with_hotstring_delays = transaction },
				config_paths = { get_config_dir = function() return "/virtual" end },
				require = function(name)
					helpers.assert_eq(name, "modules.hotstrings.hotstrings_config")
					return { init = function(opts) selected = opts; return admitted end }
				end,
			}, { __index = _G })
			local chunk = assert(load(source:sub(first, last - 1), "@hotstrings-boot-fragment", "t", env))
			local ok, detail = pcall(chunk)
			if admitted then
				helpers.assert_eq(detail, nil)
			else
				helpers.assert_true(tostring(detail):find("hotstring override owner did not initialize", 1, true) ~= nil)
			end
			helpers.assert_eq(ok, admitted)
			helpers.assert_true(selected.delay_transaction == transaction)
		end)
	end
end)
