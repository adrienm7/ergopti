--- tests/unit/platform/remap/tap_hold/test_tap_hold_one_shot_timeout_setting.lua

--- ==============================================================================
--- MODULE: One-shot Shift Timeout Setting (Linux)
--- DESCRIPTION:
--- How long a one-shot Shift waits for its key is a user setting on every OS,
--- as macOS's tap_holds.sticky_timeout_ms (decision of 2026-11-06). Linux keeps
--- it in tap_hold.toml ([tap_hold] sticky_timeout_ms) beside the other tap-hold
--- timings: the writer's value is what the loader hands the engine, an invalid
--- one is refused for the timing registry's default, and the engine's one-shot
--- deadline follows it (one-shot-timeout-setting).
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_engine_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_engine_fixture")
local helpers, Engine = Fixture.helpers, Fixture.Engine
local Loader = require("platform.remap.tap_hold_loader")
local Timings = require("infra.timings")

local DEFAULTS_PATH = require("infra.paths").shared("tap_hold/defaults.toml")

local function write_file(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A writer bound to a throwaway tap_hold.toml.
--- @return table writer, string path, table state { reloads }
local function fresh_writer()
	local path = os.tmpname()
	os.remove(path)
	local state = { reloads = 0 }
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = path,
		reload = function() state.reloads = state.reloads + 1; return true end,
		is_tap_action = function(id) return id == "copy" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.hold_options").canonical(kind, id, Loader.load(DEFAULTS_PATH, nil).hold_picker)
		end,
	})
	return writer, path, state
end

helpers.describe("tap-hold storage: the one-shot timeout in tap_hold.toml (one-shot-timeout-setting)", function()

	helpers.it("loads the timing registry's default when the file sets none (one-shot-timeout-setting)", function()
		local default = Timings.ms("tap_hold", "one_shot_shift_timeout_ms")
		helpers.assert_eq(Loader.ONE_SHOT_TIMEOUT_DEFAULT_MS, default)
		helpers.assert_eq(Loader.load(DEFAULTS_PATH, nil).one_shot_timeout_ms, default)
		helpers.assert_eq(Loader.ONE_SHOT_TIMEOUT_FIELD, "sticky_timeout_ms", "the leaf macOS reads")
	end)

	helpers.it("round-trips the writer's value through the loader (one-shot-timeout-setting)", function()
		local writer, path, state = fresh_writer()
		for _, ms in ipairs({ 3500, 750 }) do
			helpers.assert_true(writer.set_one_shot_timeout_ms(ms), "a valid timeout is written")
			helpers.assert_eq(Loader.load(DEFAULTS_PATH, path).one_shot_timeout_ms, ms, "the engine runs the stored timeout")
		end
		helpers.assert_eq(state.reloads, 2, "each change is in force at once")
		os.remove(path)
	end)

	helpers.it("refuses zero, negative, fractional and non-numeric timeouts in the writer (one-shot-timeout-setting)", function()
		local writer, path, state = fresh_writer()
		for _, bad in ipairs({ 0, -1, 12.5, "1000", math.huge, 0 / 0 }) do
			helpers.assert_eq(writer.set_one_shot_timeout_ms(bad), false, "refused: " .. tostring(bad))
		end
		local written = io.open(path, "r")
		if written then written:close() end
		helpers.assert_nil(written, "no file is written")
		helpers.assert_eq(state.reloads, 0)
	end)

	helpers.it("reads an invalid stored timeout as the registry default (one-shot-timeout-setting)", function()
		local path = os.tmpname()
		for _, stored in ipairs({ "0", "-5", "12.5", '"1000"', "true" }) do
			write_file(path, "[tap_hold]\nsticky_timeout_ms = " .. stored .. "\n")
			helpers.assert_eq(Loader.load(DEFAULTS_PATH, path).one_shot_timeout_ms, Loader.ONE_SHOT_TIMEOUT_DEFAULT_MS,
				"refused: " .. stored)
		end
		os.remove(path)
	end)

	helpers.it("arms the one-shot deadline at the configured timeout (one-shot-timeout-setting)", function()
		local engine = Engine.new({ keys = {}, tap_min_ms = 50, lone_tap_max_ms = 0, one_shot_timeout_ms = 3500,
			key_text = Fixture.us_text, plan_text = Fixture.us_plan, one_shot_result = Fixture.one_shot_result })
		helpers.assert_eq(engine.one_shot_timeout_ms, 3500)
	end)

	helpers.it("hands the engine the loaded timeout, not the registry constant (one-shot-timeout-setting)", function()
		local source = assert(io.open(require("infra.paths").driver_root() .. "/platform/remap/tap_hold_manager.lua", "r"))
		local text = source:read("*a")
		source:close()
		helpers.assert_true(text:find("one_shot_timeout_ms = loaded.one_shot_timeout_ms,", 1, true) ~= nil,
			"the manager builds the engine from the loaded configuration")
		helpers.assert_nil(text:find('one_shot_timeout_ms = Timings.ms("tap_hold", "one_shot_shift_timeout_ms")', 1, true),
			"the registry constant no longer bypasses the user's setting")
	end)

	helpers.it("lets the recommended scope drop the timeout (one-shot-timeout-setting)", function()
		local writer = fresh_writer()
		local preset = Loader.preset_keys(DEFAULTS_PATH)
		local text = writer.render_scope("recommended",
			require("toml_codec").decode("[tap_hold]\nsticky_timeout_ms = 4000\n"), {}, preset)
		local decoded = require("toml_codec").decode(text)
		helpers.assert_nil(decoded.tap_hold and decoded.tap_hold.sticky_timeout_ms, "the recommendation sets no timeout")
	end)
end)
