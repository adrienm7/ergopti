--- tests/unit/platform/remap/config/test_config_lone_modifier_tap_window.lua

--- ==============================================================================
--- MODULE: Remap Configuration Lone Modifier Tap Window
--- DESCRIPTION:
--- tap_holds.lone_modifier_tap_max_ms survives a save and a reload of
--- tap_hold.toml. 0 is the strict tap-hold, a choice of its own that a
--- plain positive timing reader would have dropped; only the shipped default is
--- elided. A negative or fractional window is obsolete: the load reports it and
--- uses the default, and a candidate carrying one is refused before any write.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "platform.remap.config", "platform.remap.tap_hold_file", "adapters.file_system", "infra.logger",
	"logger.shim", "toml_codec", "infra.toml.codec" }
local LEAF = "tap_holds.lone_modifier_tap_max_ms" -- config-key-literal-ok: the persisted leaf under test

--- Runs body against one real source file; publication is captured in place.
--- @param original string Source, in the Karabiner model layout; the file
---   holds its shared tap_hold.toml text (`f.original`).
--- @param body function Receives the fixture.
local function with_file(original, body)
	helpers.with_stub_scope(MODULES, function()
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
		local Text = require("tests.support.tap_hold_file_text")
		local original_config
		original, original_config = Text.file(original)
		write(original)
		Text.write_config(path, original_config)
		local files = require("adapters.file_system")
		local native_write = files.write_if_unchanged
		local controls = { writes = 0 }
		-- The source fence is the writer's; this fixture records the exact
		-- candidate it would publish over the unchanged current source.
		files.write_if_unchanged = function(destination, content, expected)
			-- The config.toml beside it takes the manifest's tap-hold rows (schema v22).
			if destination == require("tests.support.tap_hold_file_text").config_path(path) then
				controls.config_writes = (controls.config_writes or 0) + 1
				local handle = assert(io.open(destination, "wb")); assert(handle:write(content)); assert(handle:close())
				return true
			end
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			helpers.assert_eq(expected, { status = "ok", content = read() })
			write(content)
			return true
		end
		local function load()
			return config.load_user_config({ { id = "escape" } }, { { id = "esc_tab" } }, path)
		end
		local ok, err = pcall(body, { config = config, path = path, warnings = warnings, errors = errors,
			controls = controls, load = load, read = read, decode = function(text) return Text.model(text, Text.read_config(path)) end, original = original })
		files.write_if_unchanged = native_write
		os.remove(path); os.remove(path .. ".tmp"); Text.remove_config(path)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Remap lone modifier tap window persistence (lone-tap-window)", function()
	helpers.it("an absent leaf loads the shipped default (lone-tap-window)", function()
		with_file('[future]\nkeep = 1\n', function(f)
			local state = f.load()
			helpers.assert_eq(state.lone_modifier_tap_max_ms, f.config.LONE_MODIFIER_TAP_MAX_MS_DEFAULT)
			helpers.assert_eq(#f.warnings, 0)
		end)
	end)

	helpers.it("0 and a chosen window round-trip; the default is elided (lone-tap-window)", function()
		with_file('[future]\nkeep = 1\n', function(f)
			for _, ms in ipairs({ 0, 1500 }) do
				local state = f.load()
				state.lone_modifier_tap_max_ms = ms
				helpers.assert_true(f.config.save_user_config(state, f.path), "the window " .. ms .. " is saved")
				helpers.assert_eq(f.decode(f.read()).tap_holds.lone_modifier_tap_max_ms, ms)
				helpers.assert_eq(f.load().lone_modifier_tap_max_ms, ms, "the window " .. ms .. " reloads")
			end
			local state = f.load()
			state.lone_modifier_tap_max_ms = f.config.LONE_MODIFIER_TAP_MAX_MS_DEFAULT
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_nil((f.decode(f.read()).tap_holds or {}).lone_modifier_tap_max_ms,
				"the shipped default is not written")
			helpers.assert_eq(f.decode(f.read()).future.keep, 1)
			helpers.assert_eq(#f.warnings, 0)
		end)
	end)

	for _, literal in ipairs({ "-5", "2.5", '"long"' }) do
		helpers.it("refuses the obsolete window " .. literal .. " and keeps it until the user sets one (lone-tap-window)",
			function()
				local original = "[tap_holds]\nlone_modifier_tap_max_ms = " .. literal .. "\n"
				with_file(original, function(f)
					local state = f.load()
					helpers.assert_eq(state.lone_modifier_tap_max_ms, f.config.LONE_MODIFIER_TAP_MAX_MS_DEFAULT)
					helpers.assert_eq(#f.warnings, 1, "the obsolete window is reported")
					state.lone_modifier_tap_max_ms = 0
					helpers.assert_eq(f.config.save_user_config(state, f.path), false,
						"a carried value never repairs the obsolete leaf")
					helpers.assert_eq(f.read(), f.original)
					helpers.assert_true(f.config.save_user_config(state, f.path, nil, nil, { leaves = { [LEAF] = true } }),
						"the setter of this leaf owns its repair")
					helpers.assert_eq(f.decode(f.read()).tap_holds.lone_modifier_tap_max_ms, 0)
					helpers.assert_eq(f.load().lone_modifier_tap_max_ms, 0)
				end)
			end)
	end

	helpers.it("a candidate carrying -5 is refused before any write (lone-tap-window)", function()
		local original = '[future]\nkeep = 1\n'
		with_file(original, function(f)
			local state = f.load()
			state.lone_modifier_tap_max_ms = -5
			helpers.assert_eq(f.config.save_user_config(state, f.path, nil, nil, { leaves = { [LEAF] = true } }), false)
			helpers.assert_eq(f.controls.writes, 0)
			helpers.assert_eq(f.read(), f.original)
			helpers.assert_true(#f.errors >= 1, "the refusal is logged")
		end)
	end)
end)

return true
