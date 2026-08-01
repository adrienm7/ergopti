--- tests/unit/modules/karabiner/test_config_corrupt_toml.lua

--- ==============================================================================
--- MODULE: config_karabiner.toml Corruption Guard
--- DESCRIPTION:
--- Guards that a corrupt (unparseable) config_karabiner.toml is surfaced loudly
--- via Logger.error rather than silently reset to defaults and overwritten.
--- Before the fix, _load_toml_file returned nil for both "file absent" and
--- "present but corrupt", and load_user_config treated both identically — logging
--- the misleading INFO "No user config found" and reinitialising from defaults,
--- which the next save_user_config call then persisted over the still-recoverable
--- corrupt file, permanently destroying the user's tap/hold + combo configuration.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub the TOML codec so we can control decode behaviour.
local _toml_stub = { encode = function() return "" end, decode = function() return {} end }
package.loaded["toml_codec"]     = _toml_stub
package.loaded["infra.toml.codec"] = _toml_stub

-- Capture Logger calls via the runtime capture helper.
local Logger = require("infra.logger")
local captured = {}
local original_fn = {}
for _, level in ipairs({"debug", "info", "warn", "error"}) do
	local cap_level = "Logger_captured_" .. level
	if not Logger[cap_level] then
		original_fn[level] = Logger[level]
		Logger[level] = function(tag, fmt, ...)
			local msg = string.format(tostring(fmt or ""), ...)
			table.insert(captured, { level = level, tag = tag, msg = msg })
			if original_fn[level] then original_fn[level](tag, fmt, ...) end
		end
	end
end

local Config = helpers.load_with_stubs("modules.karabiner.config")

-- Clear captured log entries between tests.
local function reset_captured()
	for i = #captured, 1, -1 do captured[i] = nil end
end


helpers.describe("Config._load_toml_file — corrupt TOML detection (karabiner-silent-reset)", function()

	helpers.it("returns nil,'parse_error' when the file exists but decode fails", function()
		reset_captured()
		-- Make TomlCodec.decode return nil (simulating malformed TOML).
		local orig_decode = _toml_stub.decode
		_toml_stub.decode = function(_raw) return nil end

		local data, err = Config._load_toml_file(helpers.driver_root() .. "modules/karabiner/config.lua")
		_toml_stub.decode = orig_decode

		helpers.assert_nil(data, "corrupt TOML must return nil data")
		helpers.assert_eq(err, "parse_error",
			"corrupt TOML must return second value 'parse_error' to distinguish from absent file")

		-- A Logger.error must have been emitted naming the corrupt file.
		local found = false
		for _, entry in ipairs(captured) do
			if entry.level == "error" and entry.msg:find("Cannot parse") then
				found = true
				break
			end
		end
		helpers.assert_true(found,
			"corrupt TOML must emit a Logger.error with 'Cannot parse' (RED before fix: zero error logs)")
	end)

	helpers.it("returns nil (no error) when the file is genuinely absent", function()
		reset_captured()
		local data, err = Config._load_toml_file("/nonexistent/path/ergopti_fake_config.toml")
		helpers.assert_nil(data, "absent file must return nil data")
		helpers.assert_nil(err, "absent file must NOT return 'parse_error'")

		-- No error-level log must have been emitted.
		for _, entry in ipairs(captured) do
			helpers.assert_true(entry.level ~= "error",
				"absent file must not emit Logger.error (got: " .. entry.msg .. ")")
		end
	end)

end)


helpers.describe("Config.load_user_config — corrupt file vs absent (karabiner-silent-reset)", function()

	helpers.it("surfaces corruption with an ERROR and does NOT log misleading 'No user config found'", function()
		reset_captured()
		-- Make decode return nil so the real _load_toml_file fails through
		-- the decode path (rather than monkeypatching _load_toml_file directly).
		local orig_decode = _toml_stub.decode
		_toml_stub.decode = function(_raw) return nil end

		local state = Config.load_user_config({}, {}, helpers.driver_root() .. "modules/karabiner/config.lua")
		_toml_stub.decode = orig_decode

		-- Must still return a usable default state (no crash).
		helpers.assert_true(type(state) == "table", "must return a state table even on corrupt config")
		helpers.assert_eq(state.enabled, false, "default state must start disabled")

		-- Must NOT log the misleading "No user config found" INFO.
		for _, entry in ipairs(captured) do
			helpers.assert_true(
				not entry.msg:find("No user config found"),
				"corrupt file must NOT log 'No user config found' (got: " .. entry.msg .. ")"
			)
		end

		-- Must emit an ERROR naming corruption via _load_toml_file.
		local found = false
		for _, entry in ipairs(captured) do
			if entry.level == "error" and entry.msg:find("Cannot parse") then
				found = true
				break
			end
		end
		helpers.assert_true(found,
			"corrupt file must emit Logger.error with 'Cannot parse' from _load_toml_file (RED before fix: silent fallback)")
	end)

	helpers.it("handles genuine first-launch (absent file) with quiet INFO", function()
		reset_captured()
		local orig_load = Config._load_toml_file
		Config._load_toml_file = function(_path)
			return nil  -- absent, not corrupt
		end

		local state = Config.load_user_config({}, {}, "/fake/first_launch.toml")
		Config._load_toml_file = orig_load

		helpers.assert_true(type(state) == "table")

		-- Must emit the standard "No user config found" INFO.
		local found = false
		for _, entry in ipairs(captured) do
			if entry.msg:find("No user config found") then
				found = true
				break
			end
		end
		helpers.assert_true(found,
			"first-launch must log 'No user config found' INFO")
	end)

end)
