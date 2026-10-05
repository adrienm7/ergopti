--- tests/unit/platform/remap/test_config_known_scalar_preservation.lua

--- ==============================================================================
--- MODULE: Known Scalar Remap Binding Preservation
--- DESCRIPTION:
--- Unrelated native saves retain unusable known scalar bindings while implicit
--- replacement candidates still refuse before conditional publication.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Drives the real codec, classified reader and conditional writer on private files.
--- @param original string Independent TOML fixture.
--- @param body function Assertions receiving actual owners and recorded ports.
local function with_file(original, body)
	helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.logger", "logger.shim", "toml_codec", "infra.toml.codec" }, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		require("config_outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local path = os.tmpname()
		local function write(text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		local function read()
			local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
		end
		write(original)
		local files = require("adapters.file_system")
		local native_read, native_write = files.read_with_status, files.write_if_unchanged
		local controls = { writes = 0 }
		files.write_if_unchanged = function(destination, content, expected)
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
			decode = require("infra.toml.codec").decode, native_read = native_read })
		files.read_with_status, files.write_if_unchanged = native_read, native_write
		os.remove(path); os.remove(path .. ".tmp")
		if not ok then error(err, 0) end
	end)
end

local VECTORS = {
	{ name = "string", literal = '"opaque"', value = "opaque" },
	{ name = "boolean", literal = "false", value = false },
	{ name = "integer", literal = "17", value = 17 },
	{ name = "float", literal = "1.25e+2", value = 125 },
}
local function fixture(vector)
	return '[tap_holds.config]\nescape = ' .. vector.literal .. '\n'
		.. '[tap_holds.config.retired.custom]\nnote = "keep"\n'
		.. '[mod_combos.config.esc_tab]\nhold = "ctrl"\n[future]\nkeep = "independent"\n'
end
helpers.describe("Known scalar remap binding preservation", function()
	for _, vector in ipairs(VECTORS) do
		helpers.it("(known-scalar-binding) unrelated save preserves " .. vector.name .. " and reloads neutral", function()
			with_file(fixture(vector), function(f)
				local state, status = f.load()
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state.tap_hold_config.escape, { tap = "none", hold = "none" })
				helpers.assert_eq(#f.warnings, 2)
				helpers.assert_contains(table.concat(f.warnings, "\n"), "'tap_holds.config.escape' in '" .. f.path .. "'")
				helpers.assert_eq(f.read(), fixture(vector), "loading preserves exact source bytes")
				state.tap_hold_config.tab = { tap = "copy", hold = "none" }
				helpers.assert_true(f.config.save_user_config(state, f.path), "neutral carried scalar cannot refuse unrelated edits")
				local stored = f.decode(f.read())
				helpers.assert_eq(stored.tap_holds.config.escape, vector.value, "the obsolete scalar model survives")
				helpers.assert_eq(stored.tap_holds.config.tab, { tap = "copy" })
				helpers.assert_eq(stored.tap_holds.config.retired, { custom = { note = "keep" } })
				helpers.assert_eq(stored.mod_combos.config.esc_tab, { hold = "ctrl" })
				helpers.assert_eq(stored.future, { keep = "independent" })
				local reloaded = f.load()
				helpers.assert_eq(reloaded.tap_hold_config.escape, { tap = "none", hold = "none" })
				helpers.assert_eq(reloaded.tap_hold_config.tab, { tap = "copy", hold = "none" })
				helpers.assert_eq(#f.warnings, 2, "load/save/reload share precise warning identity")
				helpers.assert_eq(f.errors, {})
				helpers.assert_eq(f.controls.writes, 1)
			end)
		end)
	end
	for _, fields in ipairs({ { tap = "copy", hold = "none" }, { tap = "none", hold = "ctrl" },
		{ tap = "none", hold = "none", timeout_ms = 250 } }) do
		helpers.it("(known-scalar-binding) changed candidate refuses without explicit repair " .. tostring(fields.tap) .. tostring(fields.hold) .. tostring(fields.timeout_ms), function()
			with_file(fixture(VECTORS[1]), function(f)
				local state = f.load()
				state.tap_hold_config.escape = fields
				helpers.assert_eq(f.config.save_user_config(state, f.path), false)
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_eq(f.read(), fixture(VECTORS[1]), "refusal preserves exact bytes")
				helpers.assert_eq(#f.errors, 1)
				helpers.assert_contains(f.errors[1], "tap_holds.config.escape")
				helpers.assert_contains(f.errors[1], f.path)
				f.write('[tap_holds.config.escape]\ntap = "none"\nhold = "none"\n')
				f.controls.expected = f.read()
				helpers.assert_true(f.config.save_user_config(state, f.path), "explicit file repair allows retry")
				helpers.assert_eq(f.controls.writes, 1)
			end)
		end)
	end
	helpers.it("(known-scalar-binding) actual conditional publication refuses a concurrent replacement", function()
		with_file(fixture(VECTORS[1]), function(f)
			local state = f.load()
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			local external = '# external replacement\n[future]\nkeep = "external"\n'
			f.controls.before_publish = function() f.write(external) end
			helpers.assert_eq(f.config.save_user_config(state, f.path), false)
			helpers.assert_eq(f.controls.writes, 1)
			helpers.assert_eq(f.read(), external)
			helpers.assert_eq(#f.errors, 2, "native source refusal and config failure both remain visible")
		end)
	end)
	helpers.it("(known-scalar-binding) valid legacy combo strings retain their explicit migration path", function()
		local original = '[mod_combos.config]\nesc_tab = "ctrl"\n'
		with_file(original, function(f)
			local state, status = f.load()
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.mod_combos_config.esc_tab, { tap = "none", hold = "ctrl", combo = "none" })
			helpers.assert_eq(f.warnings, {})
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_eq(f.config.save_user_config(state, f.path), false, "legacy conversion retains its existing repair owner")
			helpers.assert_eq(f.controls.writes, 0)
			helpers.assert_eq(f.read(), original)
		end)
	end)
end)

return true
