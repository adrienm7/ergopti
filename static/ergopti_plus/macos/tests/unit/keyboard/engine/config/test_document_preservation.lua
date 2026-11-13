--- tests/unit/keyboard/engine/config/test_document_preservation.lua

--- ==============================================================================
--- MODULE: Remap Full-document Source Preservation
--- DESCRIPTION:
--- Actual private-file publication preserves unowned numeric kinds, precision
--- and array identities; source-generation, explicit reset and repair stay owned.
--- Native filesystem ports are the existing portable Hammerspoon test harness.
--- ==============================================================================

local helpers = require("tests.helpers")
require("tests.lua.settings.toml_document_shapes_contract")(helpers)

local FUTURE = '[future]\nmaximum = 9_223_372_036_854_775_807\n'
	.. 'precise = 1.2345678901234567\nkind = 1.0\nempty = []\n'
	.. 'exponent = 1.2345678901234567e+42\n'
	.. 'values = [9223372036854775807, 1.0, { precise = 0.12345678901234566, empty = [] }]\n'
	.. '[future."with.dot"]\n"" = []\n'

--- Runs the actual owner and conditional native file algorithm on a private path.
--- @param source string Independent source, in the Karabiner model layout (the
---   file holds its shared tap_hold.toml text), or the file's bytes with `raw`.
--- @param body function Assertions receiving the owner, source and publication seam.
--- @param raw boolean|nil True when `source` is already the file's bytes.
--- @param config_raw string|nil With `raw`: the bytes of the config.toml beside it.
local function with_file(source, body, raw, config_raw)
	helpers.with_stub_scope({ "keyboard.engine.runtime.config", "tap_hold.engine.file", "core.fs.adapters.file_system", "core.text.engine.toml.codec", "core.text.engine.toml_codec" }, function()
		local Config = helpers.load_with_stubs("keyboard.engine.runtime.config")
		local Files, Codec = require("core.fs.adapters.file_system"), require("core.text.engine.toml.codec")
		local path = require("tests.support.keyboard.tap_hold_file_text").private_path()
		local function write(text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		local function read()
			local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
		end
		local Text = require("tests.support.keyboard.tap_hold_file_text")
		local source_config = config_raw
		if not raw then source, source_config = Text.file(source) end
		write(source)
		Text.write_config(path, source_config)
		local state = Config.build_default_state({ { id = "tab" } }, {})
		state.enabled = nil
		state.tap_hold_timeout_ms = 1234
		local native, controls = Files.write_if_unchanged, { writes = 0 }
		Files.write_if_unchanged = function(destination, candidate, expected)
			-- The manifest rows publish to the config.toml beside it, counted apart.
			if destination == Text.config_path(path) then
				controls.config_writes = (controls.config_writes or 0) + 1
				return native(destination, candidate, expected)
			end
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			helpers.assert_eq(expected, { status = "ok", content = controls.expected or source })
			if controls.before_publish then controls.before_publish() end
			return native(destination, candidate, expected)
		end
		local ok, err = pcall(body, { config = Config, files = Files, codec = Codec, model = function(text) return Text.model(text, Text.read_config(path)) end, original = source, state = state,
			path = path, read = read, write = write, controls = controls,
			read_config = function() return Text.read_config(path) end })
		Files.write_if_unchanged = native
		Text.remove_private(path)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("remap source-bound full-document encoding", function()
	for _, vector in ipairs({
		{ name = "maximum integer", token = "maximum = 9_223_372_036_854_775_807" },
		{ name = "precise float", token = "precise = 1.2345678901234567" },
		{ name = "float kind", token = "kind = 1.0" },
		{ name = "empty array", token = "empty = []" },
		{ name = "exponent", token = "exponent = 1.2345678901234567e+42" },
		{ name = "nested inline values", token = "values = [9223372036854775807, 1.0, { empty = [], precise = 0.12345678901234566 }]" },
		{ name = "literal-dot and empty-name array", token = '"" = []' },
	}) do
		helpers.it("ordinary save preserves unowned " .. vector.name, function()
			with_file(FUTURE, function(f)
				helpers.assert_eq(f.config.save_user_config(f.state, f.path), true)
				helpers.assert_contains(f.read(), vector.token)
				helpers.assert_contains(f.read(), '[future."with.dot"]')
				helpers.assert_eq(f.model(f.read()), {
					future = { maximum = 9223372036854775807, precise = 1.2345678901234567,
						kind = 1.0, empty = {}, exponent = 1.2345678901234567e+42,
						values = { 9223372036854775807, 1.0, { precise = 0.12345678901234566, empty = {} } },
						["with.dot"] = { [""] = {} } }, tap_holds = { timeout_ms = 1234 },
				})
				local state, status = f.config.load_user_config({ { id = "tab" } }, {}, f.path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state.tap_hold_timeout_ms, 1234)
				helpers.assert_eq(f.controls.writes, 1)
			end)
		end)
	end

	helpers.it("preserves future leaf receipts inside an updated owned binding", function()
		-- The tokens of the file's own key table, so stated in its own layout.
		with_file('[_meta]\nschema_version = 1\n[tap_hold.keys.tab]\ntap_action = "copy"\nfuture = 1.0\nempty = []\n', function(f)
			f.state.tap_hold_config.tab = { tap = "paste", hold = "none" }
			helpers.assert_eq(f.config.save_user_config(f.state, f.path), true)
			helpers.assert_contains(f.read(), 'future = 1.0')
			helpers.assert_contains(f.read(), 'empty = []')
			helpers.assert_eq(f.model(f.read()), { tap_holds = {
				timeout_ms = 1234, config = { tab = { tap = "paste", future = 1.0, empty = {} } },
			} })
		end, true)
	end)

	helpers.it("preserves retired numeric kind and neutral obsolete leaves beside consent", function()
		with_file('[karabiner]\nenabled = 1.0\nintegration_enabled = false\n'
			.. '[tap_holds]\nenabled = "obsolete"\n' .. FUTURE, function(f)
			f.state.enabled = true
			helpers.assert_eq(f.config.save_user_config(f.state, f.path), true)
			helpers.assert_contains(f.read(), "enabled = 1.0")
			-- The Tap-Holds switch is a config.toml row.
			helpers.assert_contains(f.read_config(), 'enabled = "obsolete"')
			helpers.assert_contains(f.read(), "integration_enabled = true")
			helpers.assert_contains(f.read(), "kind = 1.0")
		end)
	end)

	for _, vector in ipairs({ { original = "-0.0", changed = "0.0" },
		{ original = "0.0", changed = "-0.0" } }) do
		helpers.it("publishes a changed owned floating-zero sign: " .. vector.original, function()
			-- The lone-tap window is a config.toml row.
			with_file("[_meta]\nschema_version = 1\n", function(f)
				f.state.lone_modifier_tap_max_ms = tonumber(vector.changed)
				helpers.assert_eq(f.config.save_user_config(f.state, f.path), true)
				helpers.assert_contains(f.read_config(), "lone_modifier_tap_max_ms = " .. vector.changed .. "\n")
				local value = f.model(f.read()).tap_holds.lone_modifier_tap_max_ms
				helpers.assert_eq(1 / value, 1 / tonumber(vector.changed))
				if math.type then helpers.assert_eq(math.type(value), "float") end
			end, true, "[tap_holds]\nlone_modifier_tap_max_ms = " .. vector.original .. "\n")
		end)
	end

	helpers.it("publishes an explicit owned integer zero with its integer kind", function()
		with_file("[_meta]\nschema_version = 1\n", function(f)
			f.state.lone_modifier_tap_max_ms = 0
			helpers.assert_eq(f.config.save_user_config(f.state, f.path), true)
			helpers.assert_contains(f.read_config(), "lone_modifier_tap_max_ms = 0\n")
			helpers.assert_eq(math.type(f.model(f.read()).tap_holds.lone_modifier_tap_max_ms), "integer")
		end, true, "[tap_holds]\nlone_modifier_tap_max_ms = 0.0\n")
	end)

	helpers.it("refuses a replaced source generation before publication", function()
		with_file(FUTURE, function(f)
			local newer = '[future]\nnewer = [1.0, []]\n'
			f.controls.before_publish = function() f.write(newer) end
			helpers.assert_eq(f.config.save_user_config(f.state, f.path), false)
			helpers.assert_eq(f.read(), newer)
		end)
	end)

	helpers.it("explicit reset replaces macOS's part and keeps another driver's section as written", function()
		with_file(FUTURE, function(f)
			helpers.assert_eq(f.config.save_user_config(f.state, f.path, true), true)
			-- The file is shared: the reset's own read of the source keeps its spelling.
			helpers.assert_contains(f.read(), "maximum = 9_223_372_036_854_775_807")
			helpers.assert_contains(f.read(), "precise = 1.2345678901234567")
			helpers.assert_eq(f.model(f.read()).tap_holds.timeout_ms, 1234)
		end)
	end)

	helpers.it("malformed ordinary source refuses while an exact backed repair uses default encoding", function()
		local source = '[future]\nvalue = [\n'
		with_file(source, function(f)
			helpers.assert_eq(f.config.save_user_config(f.state, f.path), false)
			helpers.assert_eq(f.read(), source)
			helpers.assert_eq(f.controls.writes, 0)
			local native = f.codec.encode_with_shapes
			f.codec.encode_with_shapes = function() error("malformed source granted a receipt") end
			local ok, err = pcall(function()
				helpers.assert_eq(f.config.save_user_config(f.state, f.path, false, { status = "ok", content = source }), true)
				helpers.assert_eq(f.model(f.read()), { tap_holds = { timeout_ms = 1234 } })
			end)
			f.codec.encode_with_shapes = native
			if not ok then error(err, 0) end
		end, true)
	end)
	for _, token in ipairs({ "1979-05-27", "07:32:00.123456", "1979-05-27T07:32:00",
		"1979-05-27T07:32:00.123456-07:00" }) do
		helpers.it("ordinary save retains a temporal literal's unquoted kind: " .. token, function()
			with_file('[future]\nvalue = ' .. token .. '\nquoted = "' .. token .. '"\n', function(f)
				helpers.assert_eq(f.config.save_user_config(f.state, f.path), true)
				helpers.assert_contains(f.read(), "value = " .. token .. "\n")
				helpers.assert_contains(f.read(), 'quoted = "' .. token .. '"')
				helpers.assert_eq(f.model(f.read()), { future = { value = token, quoted = token },
					tap_holds = { timeout_ms = 1234 } })
			end)
		end)
	end

end)
