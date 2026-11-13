--- tests/unit/keyboard/tap_hold/test_one_shot_timeout_setting.lua

--- ==============================================================================
--- MODULE: One-shot Shift Timeout Setting (Linux)
--- DESCRIPTION:
--- How long a one-shot Shift waits for its key is a user setting on every OS,
--- as macOS's tap_holds.sticky_timeout_ms (decision of 2026-11-06). Every OS
--- keeps it in config.toml ([tap_holds] sticky_timeout_ms, decision of
--- 2026-11-11): the writer's value is what the loader hands the engine, an
--- invalid one is refused for the timing registry's default, and the engine's
--- one-shot deadline follows it (one-shot-timeout-setting).
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_engine_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_engine_fixture")
local helpers, Engine = Fixture.helpers, Fixture.Engine
local Loader = require("platform.remap.tap_hold_loader")
local Timings = require("core.timing.engine.timings")

local DEFAULTS_PATH = require("core.fs.engine.paths").shared("tap_hold/data/defaults.toml")

local function write_file(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A writer bound to the tap_hold.toml of a throwaway folder, whose
--- config.toml holds the timeout.
--- @return table writer, string path, table state { reloads }, string config_path
local function fresh_writer()
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local path = dir .. "/tap_hold.toml"
	local state = { reloads = 0 }
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = path,
		reload = function() state.reloads = state.reloads + 1; return true end,
		is_tap_action = function(id) return id == "copy" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.engine.hold_options").canonical(kind, id, Loader.load(DEFAULTS_PATH, nil).hold_picker)
		end,
	})
	return writer, path, state, dir .. "/config.toml"
end

--- Removes a fresh_writer() folder and the files it may hold.
local function discard(path)
	local dir = path:match("^(.*)/[^/]+$")
	for _, name in ipairs({ "tap_hold.toml", "config.toml", "config.toml.tmp" }) do os.remove(dir .. "/" .. name) end
	os.execute('rmdir "' .. dir .. '"')
end

helpers.describe("tap-hold storage: the one-shot timeout in config.toml (one-shot-timeout-setting)", function()

	helpers.it("loads the timing registry's default when the file sets none (one-shot-timeout-setting)", function()
		local default = Timings.ms("tap_hold", "one_shot_shift_timeout_ms")
		helpers.assert_eq(Loader.ONE_SHOT_TIMEOUT_DEFAULT_MS, default)
		helpers.assert_eq(Loader.load(DEFAULTS_PATH, nil).one_shot_timeout_ms, default)
		helpers.assert_eq(Loader.ONE_SHOT_TIMEOUT_FIELD, "sticky_timeout_ms", "the leaf macOS reads")
	end)

	helpers.it("round-trips the writer's value through the loader (one-shot-timeout-setting)", function()
		local writer, path, state, config_path = fresh_writer()
		for _, ms in ipairs({ 3500, 750 }) do
			helpers.assert_true(writer.set_one_shot_timeout_ms(ms), "a valid timeout is written")
			helpers.assert_eq(Loader.load(DEFAULTS_PATH, path, config_path).one_shot_timeout_ms, ms,
				"the engine runs the stored timeout")
		end
		helpers.assert_true(writer.set_one_shot_timeout_ms(Loader.ONE_SHOT_TIMEOUT_DEFAULT_MS))
		local stored = require("core.text.engine.toml_codec").decode(assert(io.open(config_path, "r")):read("*a"))
		helpers.assert_nil(stored.tap_holds and stored.tap_holds.sticky_timeout_ms, "the default is written as an absence")
		helpers.assert_eq(state.reloads, 3, "each change is in force at once")
		helpers.assert_nil(io.open(path, "r"), "tap_hold.toml is not written: the timeout is a config.toml row")
		discard(path)
	end)

	helpers.it("refuses zero, negative, fractional and non-numeric timeouts in the writer (one-shot-timeout-setting)", function()
		local writer, path, state, config_path = fresh_writer()
		for _, bad in ipairs({ 0, -1, 12.5, "1000", math.huge, 0 / 0 }) do
			helpers.assert_eq(writer.set_one_shot_timeout_ms(bad), false, "refused: " .. tostring(bad))
		end
		for _, file in ipairs({ path, config_path }) do
			local written = io.open(file, "r")
			if written then written:close() end
			helpers.assert_nil(written, "no file is written")
		end
		helpers.assert_eq(state.reloads, 0)
		discard(path)
	end)

	helpers.it("reads an invalid stored timeout as the registry default (one-shot-timeout-setting)", function()
		local config_path = os.tmpname()
		for _, stored in ipairs({ "0", "-5", "12.5", '"1000"', "true" }) do
			write_file(config_path, "[tap_holds]\nsticky_timeout_ms = " .. stored .. "\n")
			helpers.assert_eq(Loader.load(DEFAULTS_PATH, nil, config_path).one_shot_timeout_ms,
				Loader.ONE_SHOT_TIMEOUT_DEFAULT_MS, "refused: " .. stored)
		end
		write_file(config_path, "[tap_hold]\nsticky_timeout_ms = 4000\n")
		helpers.assert_eq(Loader.load(DEFAULTS_PATH, config_path).one_shot_timeout_ms,
			Loader.ONE_SHOT_TIMEOUT_DEFAULT_MS, "a timeout left in tap_hold.toml is never read")
		os.remove(config_path)
	end)

	helpers.it("arms the one-shot deadline at the configured timeout (one-shot-timeout-setting)", function()
		local engine = Engine.new({ keys = {}, tap_min_ms = 50, lone_tap_max_ms = 0, one_shot_timeout_ms = 3500,
			key_text = Fixture.us_text, plan_text = Fixture.us_plan, one_shot_result = Fixture.one_shot_result })
		helpers.assert_eq(engine.one_shot_timeout_ms, 3500)
	end)

	helpers.it("hands the engine the loaded timeout, not the registry constant (one-shot-timeout-setting)", function()
		local source = assert(io.open(require("core.fs.engine.paths").driver_root() .. "/platform/remap/tap_hold_manager.lua", "r"))
		local text = source:read("*a")
		source:close()
		helpers.assert_true(text:find("one_shot_timeout_ms = loaded.one_shot_timeout_ms,", 1, true) ~= nil,
			"the manager builds the engine from the loaded configuration")
		helpers.assert_nil(text:find('one_shot_timeout_ms = Timings.ms("tap_hold", "one_shot_shift_timeout_ms")', 1, true),
			"the registry constant no longer bypasses the user's setting")
	end)

	helpers.it("lets the recommended scope drop a timeout left in tap_hold.toml (one-shot-timeout-setting)", function()
		local writer, path = fresh_writer()
		local preset = Loader.preset_keys(DEFAULTS_PATH)
		local text = writer.render_scope("recommended",
			require("core.text.engine.toml_codec").decode("[tap_hold]\nsticky_timeout_ms = 4000\n"), {}, preset)
		local decoded = require("core.text.engine.toml_codec").decode(text)
		helpers.assert_nil(decoded.tap_hold and decoded.tap_hold.sticky_timeout_ms, "the recommendation sets no timeout")
		discard(path)
	end)

end)
