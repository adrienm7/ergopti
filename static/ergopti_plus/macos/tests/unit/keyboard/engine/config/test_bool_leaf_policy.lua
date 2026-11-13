--- tests/unit/keyboard/engine/config/test_bool_leaf_policy.lua

--- ==============================================================================
--- MODULE: Obsolete Remap Boolean Leaf Policy
--- DESCRIPTION:
--- Ordinary native saves preserve unusable Boolean leaf models while implicit
--- changed candidates refuse until explicit manual source repair.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Drives the actual owner, canonical codec and conditional native writer on private files.
--- @param original string Independently handwritten TOML fixture.
--- @param body function Assertions receiving the owner and recorded boundary ports.
local function with_file(original, body)
	helpers.with_stub_scope({ "keyboard.engine.runtime.config", "tap_hold.engine.file", "core.fs.adapters.file_system", "core.logger.engine.logger", "core.logger.engine.shim", "core.text.engine.toml_codec", "core.text.engine.toml.codec" }, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["core.logger.engine.logger"], package.loaded["core.logger.engine.shim"] = logger, logger
		require("settings.engine.migration.outdated").reset_for_tests()
		local config = helpers.load_with_stubs("keyboard.engine.runtime.config")
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
		local files = require("core.fs.adapters.file_system")
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

--- How a warning names a model leaf: both leaves audited here are config.toml
--- rows (`_shared/tap_hold/data/SCHEMA.md`), spelled as the model spells them.
--- @param leaf table `{ section, key }` in the Karabiner model.
--- @return string
local function file_leaf(leaf)
	return leaf.section .. "." .. leaf.key
end

--- The file a warning about a config.toml row names: the one beside tap_hold.toml.
--- @param f table The with_file() context.
--- @return string
local function owner_path(f)
	return require("tests.support.tap_hold_file_text").config_path(f.path)
end

helpers.describe("TODO33 Boolean leaf audit", function()
	for _, leaf in ipairs({
		{ section = "tap_holds", key = "enabled", state = "tap_holds_enabled" },
		{ section = "mod_combos", key = "symmetric", state = "combo_symmetric" },
	}) do
		helpers.it("(todo33-bool-audit) unrelated save preserves " .. leaf.section .. "." .. leaf.key, function()
			local source = "[" .. leaf.section .. "]\n" .. leaf.key .. ' = "obsolete"\n'
				.. '[future]\nkeep = "independent"\n[tap_holds.config.escape.custom]\nnote = "keep"\n'
			with_file(source, function(f)
				local state, status = f.load()
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state[leaf.state], false)
				state.tap_hold_config.tab = { tap = "copy", hold = "none" }
				helpers.assert_true(f.config.save_user_config(state, f.path))
				local stored = f.decode(f.read())
				helpers.assert_eq(stored[leaf.section] and stored[leaf.section][leaf.key], "obsolete")
				helpers.assert_eq(#f.warnings, 1, "load/save report once by exact file/path/reason")
				helpers.assert_eq(f.errors, {})
			end)
		end)
		helpers.it("(todo33-bool-audit) reads invalid neutral with precise warning " .. leaf.section .. "." .. leaf.key, function()
			local source = "[" .. leaf.section .. "]\n" .. leaf.key .. ' = "obsolete"\n'
			with_file(source, function(f)
				local state, status = f.load()
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state[leaf.state], false)
				helpers.assert_eq(#f.warnings, 1)
				helpers.assert_contains(f.warnings[1], file_leaf(leaf))
				helpers.assert_contains(f.warnings[1], owner_path(f))
				helpers.assert_eq(f.read(), f.original)
				helpers.assert_eq(f.errors, {})
			end)
		end)
	end
end)

local LEAVES = {
	{ section = "tap_holds", key = "enabled", state = "tap_holds_enabled" },
	{ section = "mod_combos", key = "symmetric", state = "combo_symmetric" },
}
local VECTORS = {
	{ name = "string", literal = '"obsolete"' },
	{ name = "integer", literal = "17" },
	{ name = "array", literal = "[true, false]" },
	{ name = "inline table", literal = '{ retained = "opaque", flag = true }' },
}

--- Constructs the independent complete input, including usable and foreign neighbors.
--- @param leaf table Exact owned section/key identity.
--- @param literal string Handwritten source value.
--- @return string source Independent TOML source.
local function fixture(leaf, literal)
	return "[" .. leaf.section .. "]\n" .. leaf.key .. " = " .. literal .. "\n"
		.. '[future]\nkeep = "independent"\n[future.nested]\nvalues = [1, 2]\n'
		.. '[tap_holds.config.escape.custom]\nnote = "keep"\n'
		.. '[mod_combos.config.esc_tab]\nhold = "ctrl"\n'
end

--- Constructs the independently handwritten full expected model after an unrelated save.
--- @param leaf table Exact owned section/key identity.
--- @param literal string Handwritten obsolete source value.
--- @return string expected Complete expected TOML model, not generated from the owner.
local function saved_fixture(leaf, literal)
	return fixture(leaf, literal)
		.. '[karabiner]\nintegration_enabled = true\n[tap_holds.config.tab]\ntap = "copy"\n'
end

helpers.describe("Obsolete remap Boolean leaf publication contracts", function()
	for _, leaf in ipairs(LEAVES) do
		for _, vector in ipairs(VECTORS) do
			helpers.it("(bool-leaf-policy) whole-model save preserves " .. leaf.section .. "." .. leaf.key .. " " .. vector.name, function()
				local source = fixture(leaf, vector.literal)
				with_file(source, function(f)
					local state, status = f.load()
					helpers.assert_eq(status, "ok")
					helpers.assert_eq(state[leaf.state], false)
					helpers.assert_eq(f.read(), f.original, "load never mutates obsolete source bytes")
					helpers.assert_eq(#f.warnings, 1)
					helpers.assert_contains(f.warnings[1], "'" .. file_leaf(leaf) .. "' in '" .. owner_path(f) .. "'")
					state.tap_hold_config.tab = { tap = "copy", hold = "none" }
					helpers.assert_true(f.config.save_user_config(state, f.path))
					helpers.assert_eq(f.decode(f.read()), f.decode(f.file(saved_fixture(leaf, vector.literal))),
						"the complete independently specified source model survives publication")
					local fresh, fresh_status = f.load()
					helpers.assert_eq(fresh_status, "ok")
					helpers.assert_eq(fresh[leaf.state], false)
					helpers.assert_eq(fresh.tap_hold_config.tab, { tap = "copy", hold = "none" })
					helpers.assert_eq(fresh.mod_combos_config.esc_tab, { tap = "none", hold = "ctrl", combo = "none" })
					helpers.assert_eq(#f.warnings, 1, "load/save/reload retain one exact file/path/reason warning")
					helpers.assert_eq(f.errors, {})
					helpers.assert_eq(f.controls.writes, 1)
				end)
			end)
			helpers.it("(bool-leaf-policy) changed candidate refuses " .. leaf.section .. "." .. leaf.key .. " " .. vector.name, function()
				local source = fixture(leaf, vector.literal)
				with_file(source, function(f)
					local state = f.load()
					state[leaf.state] = true
					helpers.assert_eq(f.config.save_user_config(state, f.path), false)
					helpers.assert_eq(f.controls.writes, 0, "implicit replacement never reaches the native writer")
					helpers.assert_eq(f.read(), f.original)
					helpers.assert_eq(#f.errors, 1)
					helpers.assert_contains(f.errors[1], "candidate has no explicit repair owner for " .. leaf.section .. "." .. leaf.key)
					helpers.assert_contains(f.errors[1], f.path)
					local repaired = f.file(fixture(leaf, "false"))
					f.write(repaired)
					f.controls.expected = repaired
					helpers.assert_true(f.config.save_user_config(state, f.path), "manual source repair permits the same candidate to retry")
					helpers.assert_eq(f.controls.writes, 1)
					local fresh = f.load()
					helpers.assert_eq(fresh[leaf.state], true, "acknowledged publication persists the requested Boolean")
					helpers.assert_eq(f.decode(f.read())[leaf.section][leaf.key], true)
					helpers.assert_eq(#f.errors, 1)
					helpers.assert_eq(#f.warnings, 1)
				end)
			end)
		end
		for _, value in ipairs({ { name = "absent", expected = false }, { name = "false", literal = "false", expected = false },
			{ name = "true", literal = "true", expected = true } }) do
			helpers.it("(bool-leaf-policy) valid sparse behavior " .. leaf.section .. "." .. leaf.key .. " " .. value.name, function()
				local source = value.literal and fixture(leaf, value.literal)
					or '[future]\nkeep = "independent"\n'
				with_file(source, function(f)
					local state, status = f.load()
					helpers.assert_eq(status, "ok")
					helpers.assert_eq(state[leaf.state], value.expected)
					helpers.assert_true(f.config.save_user_config(state, f.path))
					local stored = f.decode(f.read())
					if value.expected then
						helpers.assert_eq(stored[leaf.section][leaf.key], true)
					else
						helpers.assert_eq(stored[leaf.section] and stored[leaf.section][leaf.key], nil)
					end
					local fresh = f.load()
					helpers.assert_eq(fresh[leaf.state], value.expected)
					helpers.assert_eq(f.warnings, {})
					helpers.assert_eq(f.errors, {})
					helpers.assert_eq(f.controls.writes, 1)
				end)
			end)
		end
		helpers.it("(bool-leaf-policy) conditional native fence preserves external replacement " .. leaf.section .. "." .. leaf.key, function()
			local source = fixture(leaf, '"obsolete"')
			with_file(source, function(f)
				local state = f.load()
				state.tap_hold_config.tab = { tap = "copy", hold = "none" }
				local external = '# independent external replacement\n[future]\nkeep = "external"\n'
				f.controls.before_publish = function() f.write(external) end
				helpers.assert_eq(f.config.save_user_config(state, f.path), false)
				helpers.assert_eq(f.controls.writes, 1)
				helpers.assert_eq(f.read(), external, "the actual native fence retains the newer generation")
				helpers.assert_eq(#f.errors, 2, "both native source refusal and owner publication refusal remain visible")
				helpers.assert_eq(#f.warnings, 1)
			end)
		end)
	end
end)
