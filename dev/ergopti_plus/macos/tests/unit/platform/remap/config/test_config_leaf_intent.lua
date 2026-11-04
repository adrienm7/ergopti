--- tests/unit/platform/remap/config/test_config_leaf_intent.lua

--- ==============================================================================
--- MODULE: Remap Configuration Explicit Leaf Intent
--- DESCRIPTION:
--- An obsolete leaf of config_karabiner.toml (a timing spelled as text, a
--- switch that is not a Boolean, a binding that is not a table) survives every
--- ordinary full-state save, and a non-neutral candidate value at that leaf is
--- refused, because a carried value never proves that the user repaired it.
--- The menu setter of that exact leaf is such a proof: it names the leaf it
--- changes, and that save replaces the obsolete value. Without it the setting
--- could never be changed from the menu again (every retry was refused).
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "platform.remap.config", "adapters.file_system", "infra.logger", "logger.shim",
	"toml_codec", "infra.toml.codec" }

--- Runs body against one real source file; publication is captured in place.
--- @param original string Source bytes.
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
		write(original)
		local files = require("adapters.file_system")
		local native_write = files.write_if_unchanged
		local controls = { writes = 0 }
		-- The source fence is the writer's; this fixture records the exact
		-- candidate it would publish over the unchanged source.
		files.write_if_unchanged = function(destination, content, expected)
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			helpers.assert_eq(expected, { status = "ok", content = original })
			write(content)
			return true
		end
		local function load()
			return config.load_user_config({ { id = "escape" } }, { { id = "esc_tab" } }, path)
		end
		local ok, err = pcall(body, { config = config, path = path, warnings = warnings, errors = errors,
			controls = controls, load = load, read = read, decode = require("infra.toml.codec").decode })
		files.write_if_unchanged = native_write
		os.remove(path); os.remove(path .. ".tmp")
		if not ok then error(err, 0) end
	end)
end

local LEAVES = {
	{ section = "mod_combos", key = "enabled", state = "mod_combos_enabled", literal = '"old"', explicit = false },
	{ section = "tap_holds", key = "enabled", state = "tap_holds_enabled", literal = '"old"', explicit = true },
	{ section = "mod_combos", key = "symmetric", state = "combo_symmetric", literal = "17", explicit = true },
	{ section = "tap_holds", key = "timeout_ms", state = "tap_hold_timeout_ms", literal = '"slow"', explicit = 321 },
	{ section = "tap_holds", key = "sticky_timeout_ms", state = "sticky_timeout_ms", literal = '"later"', explicit = 654 },
	{ section = "mod_combos", key = "simultaneous_threshold_ms", state = "simultaneous_threshold_ms",
		literal = '"soon"', explicit = 87 },
}

local function source(leaf)
	return "[" .. leaf.section .. "]\n" .. leaf.key .. " = " .. leaf.literal
		.. '\n[future]\nkeep = "independent"\n[tap_holds.config.escape.custom]\nnote = "keep"\n'
end

helpers.describe("Remap explicit leaf intent (remap-leaf-intent)", function()
	for _, leaf in ipairs(LEAVES) do
		local id = leaf.section .. "." .. leaf.key
		helpers.it("the user's explicit set replaces the obsolete " .. id .. " (remap-leaf-intent)", function()
			with_file(source(leaf), function(f)
				local state = f.load()
				helpers.assert_eq(#f.warnings, 1)
				state[leaf.state] = leaf.explicit
				helpers.assert_eq(f.config.save_user_config(state, f.path), false,
					"control: an ordinary full-state save still refuses the carried value")
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_true(f.config.save_user_config(state, f.path, nil, nil, { leaves = { [id] = true } }),
					"the setter of this exact leaf owns its repair")
				local stored = f.decode(f.read())
				helpers.assert_eq(stored[leaf.section][leaf.key], leaf.explicit)
				helpers.assert_eq(stored.future.keep, "independent")
				helpers.assert_eq(stored.tap_holds.config.escape.custom.note, "keep")
				helpers.assert_eq(f.load()[leaf.state], leaf.explicit)
				helpers.assert_eq(#f.warnings, 1, "the repaired leaf is not reported again")
			end)
		end)
		helpers.it("intent for another leaf never repairs " .. id .. " (remap-leaf-intent)", function()
			local original = source(leaf)
			with_file(original, function(f)
				local state = f.load()
				state[leaf.state] = leaf.explicit
				local other = leaf.key == "simultaneous_threshold_ms" and "tap_holds.timeout_ms"
					or "mod_combos.simultaneous_threshold_ms"
				helpers.assert_eq(f.config.save_user_config(state, f.path, nil, nil, { leaves = { [other] = true } }),
					false)
				helpers.assert_eq(f.read(), original)
				helpers.assert_eq(f.controls.writes, 0)
			end)
		end)
	end

	helpers.it("an explicit neutral timing removes the obsolete leaf instead of a silent no-op (remap-leaf-intent)", function()
		with_file('[tap_holds]\ntimeout_ms = "slow"\n', function(f)
			local state = f.load()
			helpers.assert_true(f.config.save_user_config(state, f.path, nil, nil,
				{ leaves = { ["tap_holds.timeout_ms"] = true } }))
			helpers.assert_nil((f.decode(f.read()).tap_holds or {}).timeout_ms)
		end)
	end)

	helpers.it("an explicit binding replaces an obsolete scalar binding (remap-leaf-intent)", function()
		with_file('[tap_holds.config]\nescape = "opaque"\n[future]\nkeep = 1\n', function(f)
			local state = f.load()
			state.tap_hold_config.escape = { tap = "copy", hold = "none" }
			helpers.assert_eq(f.config.save_user_config(state, f.path), false)
			helpers.assert_true(f.config.save_user_config(state, f.path, nil, nil,
				{ leaves = { ["tap_holds.config.escape"] = true } }))
			local stored = f.decode(f.read())
			helpers.assert_eq(stored.tap_holds.config.escape, { tap = "copy" })
			helpers.assert_eq(stored.future.keep, 1)
		end)
	end)

	helpers.it("refuses a malformed or reset-combined intent before any write (remap-leaf-intent)", function()
		with_file('[tap_holds]\ntimeout_ms = "slow"\n', function(f)
			local state = f.load()
			for _, intent in ipairs({ "tap_holds.timeout_ms", { leaves = { ["tap_holds.unknown"] = true } },
				{ leaves = { ["tap_holds.timeout_ms"] = "yes" } }, { leaves = {}, extra = true } }) do
				local called = pcall(f.config.save_user_config, state, f.path, nil, nil, intent)
				helpers.assert_eq(called, false, "a malformed intent raises")
			end
			local reset = pcall(f.config.save_user_config, state, f.path, true, nil,
				{ leaves = { ["tap_holds.timeout_ms"] = true } })
			helpers.assert_eq(reset, false, "a reset already owns every leaf")
			helpers.assert_eq(f.controls.writes, 0)
		end)
	end)
end)

return true
