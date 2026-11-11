--- _shared/lua/test/shared_helpers_contract.lua

--- ==============================================================================
--- MODULE: Small Shared Modules Contract
--- DESCRIPTION:
--- Direct controls for four shared modules that were only reached through a
--- driver: process/interpreter (the launch metadata the managed-process
--- adapters re-execute), sqlite/event_id_policy (the exact-integer bound of
--- event cursors), keystats/walker (its streak and timestamp helpers) and
--- layouts/composer (the settings table and the checks over what the page
--- saves). The two Lua drivers share every one of them.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Interpreter = require("process.interpreter")
	local EventIdPolicy = require("sqlite.event_id_policy")
	local Walker = require("keystats.walker")
	local Composer = require("layouts.composer")
	local Json = require("json")

	helpers.describe("shared process and sqlite helpers (shared-helpers-contract)", function()
		helpers.it("(shared-helpers-contract) reads the interpreter before every launch option", function()
			helpers.assert_eq(Interpreter.from_arguments({ [0] = "script.lua", [-1] = "luajit" }), "luajit")
			helpers.assert_eq(Interpreter.from_arguments({ [0] = "script.lua", [-1] = "-e", [-2] = "x", [-3] = "lua" }), "lua",
				"options and their values sit between the script and the interpreter")
			helpers.assert_eq(Interpreter.from_arguments({ [0] = "script.lua", [1] = "arg" }), nil,
				"a script launched without metadata has no interpreter")
			helpers.assert_nil(Interpreter.from_arguments(nil))
			helpers.assert_nil(Interpreter.from_arguments("lua"))
			helpers.assert_nil(Interpreter.from_arguments({ [0] = "s", [-1] = "" }))
			helpers.assert_nil(Interpreter.from_arguments({ [0] = "s", [-1] = 7 }))
		end)

		helpers.it("(shared-helpers-contract) bounds event cursors where Lua numbers stop being exact", function()
			local bound = EventIdPolicy.MAX_EXACT_LUA_CURSOR
			helpers.assert_eq(bound, 9007199254740991)
			helpers.assert_eq(bound % 1, 0)
			helpers.assert_true(bound - 1 ~= bound and (bound - 1) + 1 == bound, "up to the bound every integer is exact")
			helpers.assert_eq(bound + 1, bound + 2, "past the bound neighbours collapse, so the bound must not rise")
		end)
	end)

	helpers.describe("keystats walker helpers (shared-helpers-contract)", function()
		helpers.it("(shared-helpers-contract) counts same-finger and same-hand runs and breaks both on an unknown finger", function()
			local ergo = { same_finger_streak_max = 0, same_hand_streak_max = 0 }
			local ctx = {}
			Walker.advance_streak(ergo, ctx, "l_idx")
			Walker.advance_streak(ergo, ctx, "l_idx")
			helpers.assert_eq(ctx.same_finger_run, 2)
			Walker.advance_streak(ergo, ctx, "l_mid")
			helpers.assert_eq(ctx.same_finger_run, 1)
			helpers.assert_eq(ctx.same_hand_run, 3)
			Walker.advance_streak(ergo, ctx, "r_idx")
			helpers.assert_eq(ctx.same_hand_run, 1)
			helpers.assert_eq(ergo.same_finger_streak_max, 2)
			helpers.assert_eq(ergo.same_hand_streak_max, 3)
			Walker.advance_streak(nil, ctx, nil)
			helpers.assert_eq(ctx.last_finger, nil)
			helpers.assert_eq(ctx.same_finger_run, 0)
			Walker.advance_streak(ergo, ctx, "r_idx")
			helpers.assert_eq(ctx.same_finger_run, 1, "an unknown finger restarts the run instead of extending it")
			helpers.assert_eq(ergo.same_finger_streak_max, 2)
		end)

		helpers.it("(shared-helpers-contract) bins an entry to the hour and five-minute slot it was typed in", function()
			helpers.assert_eq(Walker.timestamp_slot("2026-10-25 14:07:33"), { hour = "14", min5 = "14:05" })
			helpers.assert_eq(Walker.timestamp_slot("2026-10-25 14:59:00"), { hour = "14", min5 = "14:55" })
			helpers.assert_eq(Walker.timestamp_slot("2026-10-25 09:00"), { hour = "09", min5 = "09:00" })
			helpers.assert_eq(Walker.timestamp_slot("2026-10-25 14:xx"), { hour = "14", min5 = "14:00" })
			helpers.assert_nil(Walker.timestamp_slot("not a time"))
			helpers.assert_nil(Walker.timestamp_slot(nil))
			helpers.assert_nil(Walker.timestamp_slot(1234))
		end)

		helpers.it("(shared-helpers-contract) refuses a walker without the timings it divides by", function()
			helpers.assert_throws(function() Walker.new(nil) end)
			helpers.assert_throws(function() Walker.new({}) end)
			helpers.assert_throws(function() Walker.new({ timings = {} }) end)
		end)
	end)

	helpers.describe("layout composer store (shared-helpers-contract)", function()
		-- A fixture: the shipped cap lives in _shared/modules/layouts/defaults.json
		local DEFAULTS = { composer = { id = "composed", folder = "layout_composer",
			declaration_file = "composition.json", max_declaration_bytes = 8192,
			source_file = "layout_source.toml", max_source_bytes = 262144,
			emulation_file = "layout_source_emulation.json", max_emulation_bytes = 262144,
			keylayout_file = "layout_source.keylayout", family = "composed" } }

		--- A copy of the defaults with one composer field changed.
		local function with(field, value)
			local copy = {}
			for key, current in pairs(DEFAULTS.composer) do copy[key] = current end
			copy[field] = value
			return { composer = copy }
		end

		helpers.it("(shared-helpers-contract) validates the composer table of the layout defaults field by field", function()
			local settings = Composer.settings(DEFAULTS)
			helpers.assert_eq(settings, DEFAULTS.composer)
			for _, bad in ipairs({
				{ with("id", "Not An Id") }, { with("family", 3) }, { with("folder", "a/b") },
				{ with("declaration_file", "../x.json") }, { with("max_declaration_bytes", 0) },
				{ with("max_declaration_bytes", 1.5) }, { with("max_declaration_bytes", "9") },
				{ with("source_file", "../x.toml") }, { with("max_source_bytes", 0) },
				{ with("emulation_file", "../x.json") }, { with("emulation_file", "layout_source.toml") },
				{ with("emulation_file", "composition.json") }, { with("max_emulation_bytes", 0) },
				{ with("keylayout_file", nil) }, { with("keylayout_file", "../x.keylayout") },
				{ with("keylayout_file", "layout_source.toml") }, { with("keylayout_file", "composition.json") },
			}) do
				local value, err = Composer.settings(bad[1])
				helpers.assert_nil(value)
				helpers.assert_eq(type(err), "string")
			end
			local value, err = Composer.settings({})
			helpers.assert_nil(value)
			helpers.assert_contains(err, "composer table")
		end)

		local settings = Composer.settings(DEFAULTS)
		local function declaration(overrides)
			local table_ = { schema_version = 1, name = "My Layout", keycode_convention = "iso" }
			for key, value in pairs(overrides or {}) do table_[key] = value end
			return Json.encode(table_)
		end
		local function keylayout(name, map_set)
			return '<?xml version="1.1" encoding="UTF-8"?>\n<keyboard group="126" id="1" name="' .. name .. '">\n'
				.. '<layouts><layout first="0" last="0" mapSet="' .. map_set .. '" modifiers="m"/></layouts>\n'
				.. '<modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>\n'
				.. '<keyMapSet id="' .. map_set .. '"><keyMap index="0"><key code="0" output="a"/></keyMap></keyMapSet>\n</keyboard>\n'
		end
		local function check(text, layout, limit)
			return Composer.check(settings, limit or 100000, text, layout, Json.decode)
		end

		helpers.it("(shared-helpers-contract) accepts a composer product named after its composition", function()
			local checked, code = check(declaration(), keylayout("My Layout", "composed"))
			helpers.assert_nil(code)
			helpers.assert_eq(checked, { name = "My Layout", convention = "iso" })
			local escaped = check(declaration({ name = "A & B" }), keylayout("A &amp; B", "composed"))
			helpers.assert_eq(escaped and escaped.name, "A & B", "XML references in the keyboard name are decoded")
		end)

		helpers.it("(shared-helpers-contract) refuses what the page may not save, each with the invalid code", function()
			local good_layout = keylayout("My Layout", "composed")
			local cases = {
				{ "non-text composition", 7, good_layout },
				{ "non-text layout", declaration(), nil },
				{ "oversized declaration", string.rep(" ", settings.max_declaration_bytes + 1), good_layout },
				{ "not json", "{ not json", good_layout },
				{ "unknown schema", declaration({ schema_version = 2 }), good_layout },
				{ "blank name", declaration({ name = "  " }), keylayout("  ", "composed") },
				{ "control character in name", declaration({ name = "a\1b" }), keylayout("a\1b", "composed") },
				{ "overlong name", declaration({ name = string.rep("x", Composer.MAX_NAME_LENGTH + 1) }),
					keylayout(string.rep("x", Composer.MAX_NAME_LENGTH + 1), "composed") },
				{ "unknown convention", declaration({ keycode_convention = "jis" }), good_layout },
				{ "not an xml layout", declaration(), "<keyboard/>" },
				{ "entity declaration", declaration(), (good_layout:gsub("<keyboard", "<!ENTITY x 'y'><keyboard")) },
				{ "other keyboard name", declaration(), keylayout("Other", "composed") },
				{ "other map set", declaration(), keylayout("My Layout", "qwerty") },
			}
			for _, case in ipairs(cases) do
				local checked, code, detail = check(case[2], case[3])
				helpers.assert_nil(checked, case[1])
				helpers.assert_eq(code, Composer.FAILURE_INVALID, case[1])
				helpers.assert_eq(type(detail), "string", case[1])
			end
			local checked, code = check(declaration(), good_layout, #good_layout - 1)
			helpers.assert_nil(checked)
			helpers.assert_eq(code, Composer.FAILURE_INVALID, "the compiled layout is bounded by the registry limit")
		end)

		helpers.it("(shared-helpers-contract) records the composition as the layout of the reserved id", function()
			local text = keylayout("My Layout", "composed")
			local entry = Composer.entry(settings, { name = "My Layout", convention = "ansi" }, text, string.rep("0", 64), "linux")
			helpers.assert_eq(entry.id, "composed")
			helpers.assert_eq(entry.file, "composed/composed.keylayout")
			helpers.assert_eq(entry.size, #text)
			helpers.assert_eq(entry.keycode_convention, "ansi")
			helpers.assert_eq(entry.platforms, { "linux" })
			helpers.assert_eq(entry.sha256, string.rep("0", 64))
			helpers.assert_eq(entry.version, Composer.RECORD_VERSION)
		end)

		-- A layout source stored for the emulation alone (« Emulate without installing »).
		local Toml = require("toml_codec")
		local Settings = require("layouts.emulation_settings")
		local SOURCE = 'format = "ergopti-layout"\nversion = 1\n[layout]\nid = "mine"\nname = "Mine"\n'
		local function store_env(files)
			local logs = {}
			local env = {
				settings = settings, max_file_bytes = 100000, platform = "linux", config_dir = "/cfg/",
				decode_json = Json.decode, decode_toml = Toml.decode,
				exists = function(path) return files[path] ~= nil end,
				read = function(path) return files[path] end,
				write = function(path, text) files[path] = text return true end,
				delete = function(path) files[path] = nil return true end,
				install = function() error("the emulation alone must not install anything") end,
				select = function() error("the emulation alone must not select an input source") end,
				log = function(level, message, ...) logs[#logs + 1] = level .. ": " .. string.format(message, ...) end,
			}
			return Composer.new(env), logs
		end

		helpers.it("(shared-helpers-contract) stores a source to emulate without installing it", function()
			local files = { ["/cfg/layout_composer/composition.json"] = "{}" }
			local operations = store_env(files)
			local result
			operations.store({ source = SOURCE, keylayout = keylayout("mine", "x") },
				function(ok, code, detail, id) result = { ok = ok, code = code, detail = detail, id = id } end)
			helpers.assert_eq(result, { ok = true, id = "composed" })
			helpers.assert_eq(files["/cfg/layout_composer/layout_source.toml"], SOURCE)
			helpers.assert_eq(files["/cfg/layout_composer/layout_source.keylayout"], keylayout("mine", "x"))
			helpers.assert_nil(files["/cfg/layout_composer/composition.json"], "one composed layout at a time")
			local composed, err = Composer.read_composed(settings, "/cfg/", 100000,
				{ exists = function(path) return files[path] ~= nil end, read = function(path) return files[path] end,
					decode_toml = Toml.decode })
			helpers.assert_nil(err)
			helpers.assert_eq(composed, { text = keylayout("mine", "x"), convention = "iso" })
		end)

		helpers.it("(shared-helpers-contract) refuses to emulate what is not a source the composer accepts", function()
			for _, case in ipairs({
				{ "a composition", { declaration = declaration(), keylayout = keylayout("My Layout", "composed") } },
				{ "a layout of another name", { source = SOURCE, keylayout = keylayout("other", "x") } },
				{ "an emulation table of another platform", { source = SOURCE, keylayout = keylayout("mine", "x"),
					emulation = Json.encode({ layout = "mine", platform = "macos", keys = {} }) } },
			}) do
				local files = {}
				local operations = store_env(files)
				local result
				operations.store(case[2], function(ok, code) result = { ok = ok, code = code } end)
				helpers.assert_eq(result, { ok = false, code = Composer.FAILURE_INVALID }, case[1])
				helpers.assert_eq(next(files), nil, case[1] .. ": nothing is written")
			end
		end)

		helpers.it("(shared-helpers-contract) the emulation reads the stored copy while the composed layout is not installed", function()
			local ports = { installed = {}, composer_id = "composed",
				read_installed = function() error("nothing is installed") end,
				shipped = function() return nil, "not shipped" end,
				read_composed = function() return { text = "<stored/>", convention = "ansi" }, nil end,
				read_emulation = function() return { layout = "mine" }, nil end }
			local source = Settings.source("composed", ports)
			helpers.assert_eq(source, { id = "composed", text = "<stored/>", convention = "ansi", composer = true,
				emulation = { layout = "mine" } })
			ports.read_composed = function() return nil, nil end
			local none, err = Settings.source("composed", ports)
			helpers.assert_nil(none)
			helpers.assert_eq(err, "not shipped", "neither installed, stored nor shipped")
			ports.installed = { composed = { keycode_convention = "iso" } }
			ports.read_installed = function() return "<installed/>" end
			helpers.assert_eq(Settings.source("composed", ports).text, "<installed/>", "an installed copy comes first")
		end)
	end)
end

return M
