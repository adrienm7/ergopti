--- tests/unit/platform/remap/config/test_config_array_parent_preservation.lua

--- ==============================================================================
--- MODULE: Array Remap Dictionary Preservation
--- DESCRIPTION:
--- Unrelated native saves retain obsolete array dictionaries while implicit
--- replacement candidates still refuse before conditional publication.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Drives the real codec, classified reader and conditional writer on private files.
--- @param original string Independent TOML fixture.
--- @param body function Assertions receiving actual owners and recorded ports.
local function with_file(original, body)
	helpers.with_stub_scope({ "platform.remap.config", "platform.remap.tap_hold_file", "adapters.file_system", "infra.logger", "core.logger.engine.shim", "core.text.engine.toml_codec", "infra.toml.codec" }, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"], package.loaded["core.logger.engine.shim"] = logger, logger
		require("settings.engine.migration.outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local path = require("tests.support.tap_hold_file_text").private_path()
		local function write(text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		local function read()
			local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
		end
		local Text = require("tests.support.tap_hold_file_text")
		local original_config
		original, original_config = Text.file(original)
		write(original)
		Text.write_config(path, original_config)
		local files = require("adapters.file_system")
		local native_read, native_write = files.read_with_status, files.write_if_unchanged
		local controls = { writes = 0 }
		files.write_if_unchanged = function(destination, content, expected)
			-- The manifest rows publish to the config.toml beside it, counted apart.
			if destination == Text.config_path(path) then
				controls.config_writes = (controls.config_writes or 0) + 1
				return native_write(destination, content, expected)
			end
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			helpers.assert_eq(expected, { status = "ok", content = controls.expected or original })
			if controls.before_publish then controls.before_publish() end
			return native_write(destination, content, expected)
		end
		local function load()
			return config.load_user_config({ { id = "escape" }, { id = "tab" } }, { { id = "esc_tab" } }, path)
		end
		local ok, err = pcall(body, { config = config, files = files, path = path, warnings = warnings,
			errors = errors, controls = controls, load = load, read = read, write = write,
			decode = function(text) return Text.model(text, Text.read_config(path)) end, file = function(text) local tap, rows = Text.file(text); Text.write_config(path, rows); return tap end, original = original, native_read = native_read })
		files.read_with_status, files.write_if_unchanged = native_read, native_write
		Text.remove_private(path)
		if not ok then error(err, 0) end
	end)
end

local VECTORS = {
	-- `file` is where the shared tap_hold.toml keeps the model's table.
	{ name = "tap_holds", file = "tap_hold", source = "tap_holds = ", section = "tap_holds", mode = "root" },
	{ name = "tap_holds.config", file = "tap_hold.keys", source = "[tap_holds]\nconfig = ", section = "tap_holds", mode = "config" },
	{ name = "tap_holds.config.escape", file = "tap_hold.keys.escape", source = "[tap_holds.config]\nescape = ", section = "tap_holds", mode = "binding", id = "escape" },
	{ name = "mod_combos", file = "mod_combos", config = true, source = "mod_combos = ", section = "mod_combos", mode = "root" },
	{ name = "mod_combos.config", file = "mod_combos.config", config = true, source = "[mod_combos]\nconfig = ", section = "mod_combos", mode = "config" },
	{ name = "mod_combos.config.esc_tab", file = "mod_combos.config.escape_then_tab", config = true, source = "[mod_combos.config]\nesc_tab = ", section = "mod_combos", mode = "binding", id = "esc_tab" },
}
local ARRAYS = { { source = "[]", value = {} }, { source = '[["opaque"], []]', value = { { "opaque" }, {} } },
	{ source = '[{ future = [[], ["keep"]] }]', value = { { future = { {}, { "keep" } } } } } }
local function obsolete(model, vector)
	local value = model[vector.section]
	if vector.mode ~= "root" then value = value.config end
	if vector.mode == "binding" then value = value[vector.id] end
	return value
end
local function change_collision(state, vector)
	if vector.section == "tap_holds" then
		state.tap_hold_config.escape = { tap = "copy", hold = "none" }
	else
		state.mod_combos_config.esc_tab = { tap = "copy", hold = "none", combo = "none" }
	end
end
helpers.describe("Array remap dictionaries", function()
	for _, vector in ipairs(VECTORS) do
		for _, array in ipairs(ARRAYS) do
			local original = vector.source .. array.source .. '\n[future]\nkeep = [[], ["literal-neighbor"]]\n'
			helpers.it("(array-parent) unrelated save preserves " .. vector.name .. " " .. array.source, function()
				with_file(original, function(f)
					local state, status = f.load()
					helpers.assert_eq(status, "ok")
					helpers.assert_eq(state.tap_hold_config.escape, { tap = "none", hold = "none" })
					helpers.assert_eq(state.mod_combos_config.esc_tab, { tap = "none", hold = "none", combo = "none" })
					helpers.assert_eq(#f.warnings, 1)
					-- [mod_combos] is a config.toml section, named in the config.toml beside it.
					local owner = vector.config and require("tests.support.tap_hold_file_text").config_path(f.path) or f.path
					helpers.assert_contains(f.warnings[1], "'" .. vector.file .. "' in '" .. owner .. "'")
					helpers.assert_eq(f.read(), f.original, "read-only admission retains exact bytes")
					state.enabled = false
					helpers.assert_true(f.config.save_user_config(state, f.path))
					local codec = require("infra.toml.codec")
					local stored, shapes = codec.decode_with_shapes(f.read())
					local model, is_array = require("tests.support.tap_hold_file_text").decode_pair(f.path)
					local preserved = obsolete(model, vector)
					helpers.assert_eq(preserved, array.value)
					helpers.assert_true(is_array(preserved), "source remains an array, including empty arrays")
					helpers.assert_eq(stored.future, { keep = { {}, { "literal-neighbor" } } })
					helpers.assert_true(shapes.arrays[stored.future.keep[1]])
					helpers.assert_eq(stored.karabiner, { integration_enabled = false })
					f.load()
					helpers.assert_eq(#f.warnings, 1, "load/save/reload share exact warning identity")
					helpers.assert_eq(f.errors, {})
					helpers.assert_eq(f.controls.writes, 1)
				end)
			end)
		end
		helpers.it("(array-parent) changed binding refuses until explicit repair " .. vector.name, function()
			local original = vector.source .. '[]\n[future]\nkeep = "unrelated"\n'
			with_file(original, function(f)
				local state = f.load()
				change_collision(state, vector)
				helpers.assert_eq(f.config.save_user_config(state, f.path), false)
				helpers.assert_eq(f.read(), f.original)
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_contains(f.errors[1], vector.name)
				f.write(f.file('[future]\nkeep = "repaired"\n'))
				f.controls.expected = f.read()
				helpers.assert_true(f.config.save_user_config(state, f.path))
				helpers.assert_eq(f.decode(f.read()).future, { keep = "repaired" })
			end)
		end)
	end
	for _, vector in ipairs({ VECTORS[1], VECTORS[4] }) do
		helpers.it("(array-parent) section timing collision refuses " .. vector.name, function()
			local original = vector.source .. '[]\n'
			with_file(original, function(f)
				local state = f.load()
				if vector.section == "tap_holds" then state.tap_hold_timeout_ms = state.tap_hold_timeout_ms + 1
				else state.simultaneous_threshold_ms = state.simultaneous_threshold_ms + 1 end
				helpers.assert_eq(f.config.save_user_config(state, f.path), false)
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_eq(f.read(), f.original)
				helpers.assert_contains(f.errors[1], vector.name)
			end)
		end)
	end
	for _, vector in ipairs({ VECTORS[2], VECTORS[5] }) do
		helpers.it("(array-parent) independent section timing remains editable " .. vector.name, function()
			local original = vector.source .. '[]\n'
			with_file(original, function(f)
				local state = f.load()
				if vector.section == "tap_holds" then state.tap_hold_timeout_ms = 1234
				else state.simultaneous_threshold_ms = 1234 end
				helpers.assert_true(f.config.save_user_config(state, f.path))
				local stored, is_array = require("tests.support.tap_hold_file_text").decode_pair(f.path)
				helpers.assert_eq(obsolete(stored, vector), {})
				helpers.assert_true(is_array(obsolete(stored, vector)))
				helpers.assert_eq(stored[vector.section][vector.section == "tap_holds" and "timeout_ms"
					or "simultaneous_threshold_ms"], 1234)
			end)
		end)
	end
	for _, literal in ipairs({ '[]', '[["opaque"]]', '[{ integration_enabled = true }]' }) do
		helpers.it("(array-parent) integration consent refuses array " .. literal, function()
			local original = 'karabiner = ' .. literal .. '\n'
			with_file(original, function(f)
				local state, status = f.load()
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(f.read(), f.original)
				local candidate = f.config.build_default_state({}, {})
				helpers.assert_eq(f.config.save_user_config(candidate, f.path), false)
				helpers.assert_eq(f.controls.writes, 0)
			end)
		end)
	end
	helpers.it("(array-parent) valid dictionary bindings keep nested future lists", function()
		local original = '[tap_holds.config.escape]\ntap = "copy"\nfuture = [[], ["retained"]]\n'
			.. '[mod_combos.config.esc_tab]\nhold = "ctrl"\nfuture = [{ choices = [] }]\n'
		with_file(original, function(f)
			local state, status = f.load()
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.tap_hold_config.escape.tap, "copy")
			helpers.assert_eq(state.mod_combos_config.esc_tab.hold, "ctrl")
			state.enabled = false
			helpers.assert_true(f.config.save_user_config(state, f.path))
			local stored, is_array = require("tests.support.tap_hold_file_text").decode_pair(f.path)
			helpers.assert_eq(stored.tap_holds.config.escape, { tap = "copy", future = { {}, { "retained" } } })
			helpers.assert_eq(stored.mod_combos.config.esc_tab, { hold = "ctrl", future = { { choices = {} } } })
			helpers.assert_true(is_array(stored.tap_holds.config.escape.future[1]))
			helpers.assert_true(is_array(stored.mod_combos.config.esc_tab.future[1].choices))
			helpers.assert_eq(f.warnings, {})
		end)
	end)
	helpers.it("(array-parent) conditional publication retains a concurrent replacement", function()
		with_file('[tap_holds.config]\nescape = []\n', function(f)
			local state = f.load()
			state.enabled = false
			local external = '# foreign writer\n[future]\nkeep = [[], []]\n'
			f.controls.before_publish = function() f.write(external) end
			helpers.assert_eq(f.config.save_user_config(state, f.path), false)
			helpers.assert_eq(f.read(), external)
			helpers.assert_eq(f.controls.writes, 1)
		end)
	end)
end)

return true
